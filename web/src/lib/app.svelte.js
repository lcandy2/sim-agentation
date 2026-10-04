// App state and behaviour. `ui` is reactive and drives the components;
// `rt` holds what changes every frame or pointer move (stream, frozen frame,
// hover, drag) and is never rendered directly.

import { tick } from 'svelte';
import { notify } from './notify.svelte.js';
import { hitTest, describe, nodesInRect, isSpringBoard, isWidget } from './ax.js';
import { sampler, warm, containerAround, containersAround, partsWithin } from './visual.js';
import { matchesFrontApp, sdkContainers, sourceFor, viewContext } from './sdk.js';
import { createDecoder, decodeCapabilities, decodesSmoothly, formatLabel, pickFormat } from './stream.js';
import { HIDDEN_FPS, createAuto, decide, newFormat, observe, probeFor, probed, restart } from './auto.js';
import { sdkToPortrait, treeToPortrait, uprightDegrees } from './rotation.js';

export const storage = {
  get(k) {
    try { return localStorage.getItem(`sim-agentation:${k}`); } catch { return null; }
  },
  set(k, v) {
    try { localStorage.setItem(`sim-agentation:${k}`, v); } catch {}
  },
};

export const ui = $state({
  sims: [],
  query: '',
  udid: null,
  simName: 'No simulator',
  runtime: '',
  chrome: null,       // device chrome: body, screen rect and buttons, in points
  running: false,     // the selected device is booted; its controls work
  live: false,        // frames are arriving
  starting: false,
  message: null,      // replaces the device, e.g. when there's no artwork
  mode: 'interact',
  frozen: false,
  sdkAvailable: false,
  sdkEnabled: storage.get('sdk') !== 'off',
  status: '',
  flash: null,
  zoom: storage.get('zoom') ?? 'fit', // 'fit' or CSS pixels per point
  scale: 1,
  shown: 0,           // counts each time a device is shown at its size, for the grow-in
  panels: {
    sidebar: storage.get('panel-sidebar') !== 'hidden',
    inspector: storage.get('panel-inspector') !== 'hidden',
    tab: storage.get('inspector-tab') === 'annotations' ? 'annotations' : storage.get('inspector-tab') ? 'info' : 'annotations', // 'info' (with the settings) or 'annotations'
  },
  filter: storage.get('filter') ?? 'all', // the device list: 'all', 'running', 'iphone' or 'ipad'
  orientation: 'portrait', // the device's, as sent to it: see ROTATION
  inputShadowed: false, // Xcode's Device Hub holds this device's buttons (see checkInput)
  sheet: null, // the … menu's dialog open now: 'rename', 'erase' or 'remove'
  managing: null, // what the … menu is doing to the device: 'Shutting Down…' and so on
  reclaiming: false,
  recording: false,
  annotations: [],
  draft: null,        // { label, box } while the composer is open: the selection's box, viewport px
  stream: {
    choice: storage.get('stream-format') ?? 'auto', // 'auto', or a format to always use
    format: null,     // the format streaming now: 'hevc', 'hevc422', 'avcc' (H.264) or 'mjpeg'
    skipped: [],      // [{ format, reason }]: what Auto gave up on this session
    // With the codec on Auto, resolution and bitrate are worked out too; a
    // pinned codec uses these, which start from what Auto last chose.
    scaleChoice: Number(storage.get('stream-scale')) || 1, // 1 full resolution, 2 half
    bitrateChoice: Number(storage.get('stream-bitrate')) || 8_000_000, // video only
    scale: 1,         // what streams now
    bitrate: 8_000_000,
    playable: { mjpeg: true, avcc: false, hevc: false, hevc422: false },
    hardwareDecode: { mjpeg: null, avcc: null, hevc: null, hevc422: null },
    fpsTarget: 60,    // what the host streams at: 60, less for a slow connection or a hidden page
    why: { scale: null, bitrate: null, fps: null }, // why Auto went below full, sharp and 60
    net: null,        // which of those the connection is why of (see auto.js decide)
    link: null,       // { behindMs, carried, backingUp }: the connection, from the host's last report
    estimate: Infinity, // bits/s the connection carries, as far as Auto has seen
    encodeMs: 0,      // the host's time to scale and encode a frame
    fps: 0,           // frames painted in the last second
    mbps: 0,          // megabits received in the last second
    hardware: null,   // the video decoder runs in hardware (null: unknown or JPEG)
  },
});

const rt = {
  ws: null,
  decoder: null,
  decoderErrors: 0,
  watchdog: null,
  pending: null,     // newest decoded frame, not painted yet
  frame: null,       // last painted frame: ImageBitmap or VideoFrame
  counts: { frames: 0, bytes: 0 },
  frozen: null,      // { bitmap, tree, points, pixels, sdk, sdkAvailable, marks }
  pendingTree: null,
  hover: null,       // { point, targets: [{ rect, label, node? }], level }
  drag: null,
  draft: null,       // { kind, rect, point?, label, parts? }: what the composer will save
  picks: [],         // what's selected, each { id, kind, rect, point?, label, color, el }
  failed: new Set(), // formats Auto gave up on this session
  auto: createAuto(), // what Auto has learned about the connection and decoder (see auto.js)
  seen: { received: 0, decoded: 0, bytes: 0, at: 0 }, // the page's counts at the host's last report
  bytesIn: 0,        // every binary byte the stream has brought
  touching: false,
  canvas: null,
  ctx: null,
  overlay: null,
  float: null,       // unmasked layer over the screen: labels and markers may spill past its edges
  stage: null,
  previewInfo: null,
};

// For poking at from the devtools console.
if (typeof window !== 'undefined') window.simAgentation = { ui, rt, hover: () => rt.hover, partsWithin };

// ---------- status ----------

let flashTimer = null;

export function setStatus(text) {
  ui.status = text;
}

/** Shows a message for a moment, then goes back to the current status. */
export function flashStatus(text, ms = 2000) {
  clearTimeout(flashTimer);
  ui.flash = text;
  flashTimer = setTimeout(() => (ui.flash = null), ms);
}

// ---------- stage elements ----------

export function attachStage({ canvas, overlay, float, stage, previewInfo }) {
  rt.canvas = canvas;
  rt.ctx = canvas.getContext('2d');
  rt.overlay = overlay;
  rt.float = float;
  rt.stage = stage;
  rt.previewInfo = previewInfo;
}

// ---------- stream ----------

function connect(udid) {
  stopStream();
  setStatus('Connecting…');
  restart(rt.auto);
  settleStream();
  const { format, scale, bitrate, fpsTarget } = ui.stream;
  const ws = new WebSocket(`ws://${location.host}/ws/${encodeURIComponent(udid)}?format=${format}&scale=${scale}&bitrate=${bitrate}&fps=${fpsTarget}`);
  ws.binaryType = 'arraybuffer';
  rt.ws = ws;
  const newDecoder = () =>
    createDecoder(format, {
      onFrame: (frame) => {
        rt.pending?.close?.();
        rt.pending = frame;
      },
      // A dead video decoder can't recover: start a new one from a fresh
      // keyframe. Auto gives up on the format if it dies again.
      onError: (e) => {
        if (rt.ws !== ws) return;
        if (++rt.decoderErrors >= 2 && fallBack(format, `decoder error: ${e?.message ?? e}`)) return;
        rt.decoder?.dispose();
        rt.decoder = newDecoder();
        send({ type: 'force_idr' });
      },
    });
  rt.decoder = newDecoder();
  rt.decoderErrors = 0;
  rt.seen = { received: 0, decoded: 0, bytes: rt.bytesIn, at: performance.now() };
  // Whether this browser decodes the device's full resolution smoothly.
  decodesSmoothly(format, devicePixels()).then((smooth) => {
    if (rt.ws !== ws) return;
    rt.auto.smooth = smooth;
    settleStream();
  });

  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'snapshot' }));
    ws.send(JSON.stringify({ type: 'orientation', orientation: ui.orientation }));
    // Nudge with a harmless scroll so an idle screen still emits a frame.
    setTimeout(() => !rt.frame && send({ type: 'scroll', deltaX: 0, deltaY: 0 }), 600);
    // Once video arrives, a working decoder shows something within moments
    // (the host re-encodes even a still screen 60 times a second). No video
    // at all, as while a simulator boots, is the host's to report.
    clearInterval(rt.watchdog);
    const watchdog = setInterval(() => {
      const stats = rt.decoder?.stats;
      if (rt.ws !== ws || stats?.decoded) return clearInterval(watchdog);
      if (stats?.received && performance.now() - stats.firstAt > 3000) fallBack(format, 'frames arrive but none decode');
    }, 500);
    rt.watchdog = watchdog;
  };
  ws.onmessage = (e) => {
    if (typeof e.data === 'string') return onText(JSON.parse(e.data));
    const tag = new Uint8Array(e.data, 0, 1)[0];
    rt.bytesIn += e.data.byteLength;
    if (tag === 0x05) return rt.onStill?.(e.data); // a full-size still, not the stream
    if (tag === 0x06) return; // a probe's padding (see auto.js probeFor)
    rt.counts.bytes += e.data.byteLength;
    rt.decoder?.feed(e.data);
  };
  ui.live = false;
  ws.onclose = () => {
    if (rt.ws === ws) {
      ui.live = false;
      setStatus('Disconnected');
      setTimeout(() => rt.ws === ws && connect(udid), 1500);
    }
  };
}

function stopStream() {
  const ws = rt.ws;
  rt.ws = null;
  clearInterval(rt.watchdog);
  ui.live = false;
  rt.decoder?.dispose();
  rt.decoder = null;
  rt.pending?.close?.();
  rt.pending = null;
  rt.frame?.close?.();
  rt.frame = null;
  ws?.close();
}

// Paints the newest decoded frame once per display refresh; older ones are
// dropped, as in baguette's StreamSession.
function paintLoop() {
  const frame = rt.pending;
  if (frame) {
    rt.pending = null;
    rt.frame?.close?.();
    rt.frame = frame;
    rt.counts.frames++;
    if (!rt.frozen) {
      if (!ui.live) {
        ui.live = true;
        setStatus(''); // streaming is the normal state; say nothing
      }
      paint(frame);
    }
  }
  requestAnimationFrame(paintLoop);
}

function sampleStats() {
  ui.stream.fps = rt.counts.frames;
  ui.stream.mbps = (rt.counts.bytes * 8) / 1e6;
  ui.stream.hardware = rt.decoder?.hardware ?? null;
  rt.counts = { frames: 0, bytes: 0 };
}

/** 'auto' or a format to always use; the stream restarts if the format changes. */
export function setStreamChoice(choice) {
  if (choice === ui.stream.choice) return;
  if (choice !== 'auto' && !ui.stream.playable[choice]) return;
  // Pinning a codec keeps the resolution and (nearest) bitrate Auto had
  // chosen, as the starting point for choosing them by hand.
  if (ui.stream.choice === 'auto' && choice !== 'auto') {
    const nearest = BITRATE_STEPS.reduce((a, b) => (Math.abs(b - ui.stream.bitrate) < Math.abs(a - ui.stream.bitrate) ? b : a));
    ui.stream.scaleChoice = ui.stream.scale;
    ui.stream.bitrateChoice = nearest;
    storage.set('stream-scale', String(ui.stream.scale));
    storage.set('stream-bitrate', String(nearest));
  }
  ui.stream.choice = choice;
  storage.set('stream-format', choice);
  settleStream();
  // An explicit pick deserves a fresh try at everything.
  rt.failed.clear();
  ui.stream.skipped = [];
  useFormat(pickFormat(choice, capabilities()));
}

const capabilities = () => ({ playable: ui.stream.playable, hardware: ui.stream.hardwareDecode });

function useFormat(format) {
  if (format === ui.stream.format) return;
  ui.stream.format = format;
  newFormat(rt.auto);
  if (ui.running && ui.udid) connect(ui.udid);
}

/**
 * Auto only: drops a format that failed and moves to the next one. Returns
 * false when the user picked the format, which then stays put.
 */
function fallBack(format, reason) {
  if (ui.stream.choice !== 'auto' || format !== ui.stream.format || format === 'mjpeg') return false;
  rt.failed.add(format);
  ui.stream.skipped = [...ui.stream.skipped, { format, reason }];
  const next = pickFormat('auto', capabilities(), rt.failed);
  flashStatus(`${formatLabel(format)} failed (${reason}); using ${formatLabel(next)}`, 6000);
  useFormat(next);
  return true;
}

export const BITRATE_STEPS = [4_000_000, 8_000_000, 16_000_000]; // the choices with a pinned codec

/** 1 (full) or 2 (half), with a pinned codec. */
export function setStreamScale(scale) {
  ui.stream.scaleChoice = scale;
  storage.set('stream-scale', String(scale));
  settleStream();
}

/** Bits per second, with a pinned codec. */
export function setStreamBitrate(bps) {
  ui.stream.bitrateChoice = bps;
  storage.set('stream-bitrate', String(bps));
  settleStream();
}

// With the codec on Auto, resolution, bitrate and frame rate are Auto's too
// (see auto.js). A pinned codec streams the resolution and bitrate chosen
// for it at 60 fps. Either way a hidden page gets a few frames a second.
let settleTimer;

function devicePixels() {
  const sim = ui.sims.find((s) => s.udid === ui.udid);
  const k = sim?.deviceType.includes('iPad') ? 2 : 3;
  const screen = ui.chrome?.screen ?? { width: 402, height: 874 };
  return { width: screen.width * k, height: screen.height * k };
}

/** The share of the device's pixels the page draws: ui.scale CSS px per point on a devicePixelRatio display. */
function shownShare() {
  if (!ui.chrome) return ui.stream.scale === 2 ? 0.5 : 1;
  return (ui.chrome.screen.width * ui.scale * (window.devicePixelRatio || 1)) / devicePixels().width;
}

/** Works out what to stream now, and tells the host what changed. */
function settleStream() {
  const s = ui.stream;
  const hidden = document.hidden;
  let scale = s.scaleChoice;
  let bitrate = s.bitrateChoice;
  let fps = hidden ? HIDDEN_FPS : 60;
  if (s.choice === 'auto' && s.format) {
    const d = decide(rt.auto, { format: s.format, pixels: devicePixels(), shown: shownShare(), current: s.scale, hidden });
    ({ scale, fps } = d);
    bitrate = d.bitrate ?? s.bitrate; // JPEG has none
    s.why = d.why;
    s.net = d.net;
  } else {
    s.why = { scale: null, bitrate: null, fps: hidden ? 'the page is hidden' : null };
    s.net = null;
  }
  if (scale !== s.scale) {
    s.scale = scale;
    rt.auto.quiet = Math.max(rt.auto.quiet, 1); // a new size starts with a keyframe
    send({ type: 'set_scale', scale });
  }
  if (bitrate !== s.bitrate) {
    s.bitrate = bitrate;
    send({ type: 'set_bitrate', bps: bitrate });
  }
  if (fps !== s.fpsTarget) {
    s.fpsTarget = fps;
    send({ type: 'set_fps', fps });
  }
}

/** Once a second from the host: how the stream kept up. Auto learns from it, with the decoder's side. */
function onStats(host) {
  rt.hostStats = host; // for the devtools console
  const s = ui.stream;
  const now = performance.now();
  const stats = rt.decoder?.stats;
  const page = {
    fed: 0,
    decoded: 0,
    backlog: 0,
    received: ((rt.bytesIn - rt.seen.bytes) * 8) / (Math.max(250, now - rt.seen.at) / 1000),
    offset: now - host.t,
  };
  if (stats) {
    Object.assign(page, { fed: stats.received - rt.seen.received, decoded: stats.decoded - rt.seen.decoded, backlog: stats.backlog });
    stats.backlog = 0;
  }
  rt.seen = { received: stats?.received ?? 0, decoded: stats?.decoded ?? 0, bytes: rt.bytesIn, at: now };
  observe(rt.auto, host, page, { format: s.format, fps: s.fpsTarget, scale: s.scale, hidden: document.hidden });
  s.link = rt.auto.link;
  s.estimate = rt.auto.estimate;
  s.encodeMs = host.encodeMs;
  if (s.choice !== 'auto') return;
  const probe = probeFor(rt.auto, { format: s.format, pixels: devicePixels(), hidden: document.hidden });
  if (probe) send({ type: 'probe', ...probe, ms: 400 });
  settleStream();
}

/** The host's answer to a probe: the connection took the padding, or not. */
function onProbe(result) {
  probed(rt.auto, { ...result, offset: performance.now() - result.t });
  ui.stream.estimate = rt.auto.estimate;
  if (ui.stream.choice === 'auto') settleStream();
}

export function send(msg) {
  if (rt.ws?.readyState === WebSocket.OPEN) rt.ws.send(JSON.stringify(msg));
}

const frameSize = (f) => ({ width: f.displayWidth ?? f.width, height: f.displayHeight ?? f.height });

function paint(frame) {
  const { canvas, ctx } = rt;
  if (!canvas) return;
  const { width, height } = frameSize(frame);
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  ctx.drawImage(frame, 0, 0);
}

function onText(msg) {
  if (msg.type === 'describe_ui_result') {
    rt.pendingTree?.(msg.ok ? msg.tree : null);
    rt.pendingTree = null;
  } else if (msg.type === 'stats') {
    onStats(msg);
  } else if (msg.type === 'probe_result') {
    onProbe(msg);
  } else if (msg.type === 'stream_error') {
    // The host couldn't encode this format (no encoder for it on this Mac).
    if (!fallBack(msg.format, msg.error)) setStatus(msg.error);
  } else if (msg.type === 'error' || msg.ok === false) {
    setStatus(msg.error || 'Error');
  }
}

/** A full-resolution picture of the screen now, or null if none comes. */
function requestStill() {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      rt.onStill = null;
      resolve(null);
    }, 2000);
    rt.onStill = (buffer) => {
      clearTimeout(timer);
      rt.onStill = null;
      createImageBitmap(new Blob([new Uint8Array(buffer, 1)], { type: 'image/jpeg' })).then(resolve, () => resolve(null));
    };
    send({ type: 'still' });
  });
}

function fetchTree() {
  return new Promise((resolve) => {
    rt.pendingTree = resolve;
    send({ type: 'describe_ui' });
    setTimeout(() => {
      if (rt.pendingTree === resolve) {
        rt.pendingTree = null;
        resolve(null);
      }
    }, 10000); // the host may probe for up to ~5 s, or restart a stale accessibility bridge
  });
}

// ---------- coordinates ----------

// offsetX/Y are in the overlay's own coordinates, so they hold when the
// device is rotated: the framebuffer, touches and the tree stay portrait.
function fraction(e) {
  const el = rt.overlay;
  const clamp = (v) => Math.min(Math.max(v, 0), 1);
  return { fx: clamp(e.offsetX / el.clientWidth), fy: clamp(e.offsetY / el.clientHeight) };
}

function inputPoint(e) {
  const { fx, fy } = fraction(e);
  const { width, height } = ui.chrome.screen;
  return { x: fx * width, y: fy * height, width, height };
}

/** Annotation space = accessibility points. */
function axPoint(e) {
  const { fx, fy } = fraction(e);
  const { width, height } = rt.frozen.points;
  return { x: fx * width, y: fy * height };
}

function placeBox(el, rect) {
  const { width, height } = rt.frozen.points;
  el.style.left = `${(rect.x / width) * 100}%`;
  el.style.top = `${(rect.y / height) * 100}%`;
  el.style.width = `${(rect.width / width) * 100}%`;
  el.style.height = `${(rect.height / height) * 100}%`;
}

function clearLayer(selector) {
  for (const layer of [rt.overlay, rt.float]) layer?.querySelectorAll(selector).forEach((n) => n.remove());
}

// ---------- pointer and keyboard on the screen ----------

export function onPointerDown(e) {
  rt.overlay.focus();
  if (ui.mode === 'annotate') return annotateDown(e);
  if (!ui.running) return;
  rt.touching = true;
  rt.overlay.setPointerCapture(e.pointerId);
  send({ type: 'touch1-down', ...inputPoint(e) });
}

export function onPointerMove(e) {
  if (ui.mode === 'annotate') return annotateMove(e);
  if (rt.touching) send({ type: 'touch1-move', ...inputPoint(e) });
}

export function onPointerUp(e) {
  if (ui.mode === 'annotate') return annotateUp(e);
  if (!rt.touching) return;
  rt.touching = false;
  send({ type: 'touch1-up', ...inputPoint(e) });
}

export function onWheel(e) {
  e.preventDefault();
  if (ui.mode === 'interact') send({ type: 'scroll', deltaX: e.deltaX, deltaY: e.deltaY });
  else if (Math.abs(e.deltaY) > 2) changeLevel(e.deltaY < 0 ? 1 : -1);
}

const KEY_CODES = new Set(['Enter', 'Backspace', 'Tab', 'Escape', 'Space', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight']);

// While the device has focus, Simulator.app's shortcuts (SHORTCUTS) work as
// they do there, and the keys the browser and the Mac answer stay theirs:
// switching tabs (⌘1–⌘8, ⌘⇧[ ⌘⇧], ⌃Tab) and windows (⌘`), new and closing
// tabs, hiding, minimizing, quitting, settings, the developer tools (⌘⌥…).
// The rest, editing keys included (⌘C ⌘V ⌘A ⌘Z, ⌘F), go to the device.
const BROWSER_KEYS = new Set(['KeyT', 'KeyW', 'KeyN', 'KeyQ', 'KeyM', 'KeyH', 'Backquote', 'Comma']);
function forBrowser(e) {
  if (e.ctrlKey && e.code === 'Tab') return true;
  if (!e.metaKey) return false;
  return /^Digit[1-9]$/.test(e.code) || e.altKey || (e.shiftKey && (e.code === 'BracketLeft' || e.code === 'BracketRight')) || BROWSER_KEYS.has(e.code);
}

export function onScreenKey(e) {
  if (ui.mode !== 'interact' || SHORTCUTS[combo(e)] || forBrowser(e)) return;
  const mods = ['shift', 'control', 'option', 'command'].filter((m, i) => [e.shiftKey, e.ctrlKey, e.altKey, e.metaKey][i]);
  if (e.metaKey && e.key === 'v') {
    navigator.clipboard.readText().then((text) => text && send({ type: 'paste', text }));
  } else if (KEY_CODES.has(e.code) || e.metaKey || e.ctrlKey) {
    send({ type: 'key', code: e.code, modifiers: mods });
  } else if (e.key.length === 1) {
    send(/^[\x20-\x7e]$/.test(e.key) ? { type: 'type', text: e.key } : { type: 'paste', text: e.key });
  } else {
    return;
  }
  e.preventDefault();
}

// Simulator.app's shortcuts, from its menus, so hands used to it work here;
// then this page's zoom keys. Keyed by physical key, modifiers first.
const combo = (e) => [e.ctrlKey && 'ctrl', e.altKey && 'alt', e.shiftKey && 'shift', e.metaKey && 'meta', e.code].filter(Boolean).join('+');
const SHORTCUTS = {
  'meta+KeyS': () => saveScreenshot(),                      // File ▸ Save Screen
  'meta+KeyR': () => toggleRecording(),                     // File ▸ Record Screen
  'ctrl+meta+KeyC': () => copyScreen(),                     // Edit ▸ Copy Screen
  'shift+meta+KeyH': () => pressHome(),                     // I/O ▸ Home
  'ctrl+shift+meta+KeyH': () => pressAppSwitcher(),         // I/O ▸ App Switcher
  'meta+KeyL': () => pressButton('lock'),                   // I/O ▸ Lock
  'meta+ArrowLeft': () => rotateBy(-1),                     // I/O ▸ Rotate Left
  'meta+ArrowRight': () => rotateBy(1),                     // I/O ▸ Rotate Right
  'meta+ArrowUp': () => pressButton('volume-up'),           // I/O ▸ Increase Volume
  'meta+ArrowDown': () => pressButton('volume-down'),       // I/O ▸ Decrease Volume
  'ctrl+meta+KeyZ': () => feature('shake'),                 // I/O ▸ Shake
  'shift+meta+KeyA': () => feature('appearance'),           // Features ▸ Toggle Appearance
  'alt+shift+meta+Equal': () => feature('text-bigger'),     // Features ▸ Increase Preferred Text Size
  'alt+shift+meta+Minus': () => feature('text-smaller'),    // Features ▸ Decrease Preferred Text Size
  'alt+meta+KeyM': () => feature('biometric-match'),        // Features ▸ Face ID ▸ Matching Face
  'alt+meta+KeyN': () => feature('biometric-mismatch'),     // Features ▸ Face ID ▸ Non-matching Face
  'shift+meta+KeyD': () => setMode(ui.mode === 'annotate' ? 'interact' : 'annotate'), // Design Mode, in and out
  'meta+Digit4': () => setZoom('fit'),                      // Window ▸ Fit Screen
  'meta+Digit9': () => setZoom('fit'),
  'meta+Equal': () => zoomIn(),
  'shift+meta+Equal': () => zoomIn(),
  'meta+Minus': () => zoomOut(),
};

/** Window-level shortcuts: Simulator.app's and zoom, modes, Esc, ↑/↓ parent, S for SDK. */
export function onWindowKey(e) {
  if (e.target.closest?.('.composer')) return;
  const shortcut = SHORTCUTS[combo(e)];
  if (shortcut && !e.target.matches?.('input, textarea, select')) {
    e.preventDefault();
    shortcut();
    return;
  }
  if (e.metaKey) return;
  if (e.key === 'Escape' && ui.mode === 'annotate') {
    // A selection goes first, then Design Mode.
    e.preventDefault();
    if (ui.draft) cancelComposer();
    else setMode('interact');
    return;
  }
  if (ui.mode === 'annotate' && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
    if (changeLevel(e.key === 'ArrowUp' ? 1 : -1)) e.preventDefault();
    return;
  }
  // Letter shortcuts only while not typing into the simulator or a field.
  if (ui.mode === 'interact' && document.activeElement === rt.overlay) return;
  if (e.target.matches?.('input, textarea')) return;
  if (e.key === 's' && ui.mode === 'annotate') toggleSdk();
  if (e.key === 'a') setMode('annotate');
  if (e.key === 'i') setMode('interact');
}

// ---------- device buttons ----------

/** Home: the home button press, which SpringBoard takes on every device, Face ID too (as baguette sends it). */
export function pressHome() {
  send({ type: 'button', button: 'home' });
  checkInput();
}

/** The app switcher: two home presses 150 ms apart (baguette's and idb's recipe). */
export function pressAppSwitcher() {
  send({ type: 'button', button: 'app-switcher' });
  checkInput();
}

// Xcode 27's Device Hub, once it attaches to a simulator, takes its legacy
// input: the home button and the app switcher stop working while the host
// still reports success. The page asks when a device connects and when its
// buttons are pressed, and offers to take the input back.
export async function checkInput() {
  const udid = ui.udid;
  if (!udid || !ui.running) return;
  const state = await fetch(`/api/sims/${udid}/input`).then((r) => (r.ok ? r.json() : null)).catch(() => null);
  if (udid === ui.udid) ui.inputShadowed = !!state?.shadowed;
}

/** Restarts the simulator's SpringBoard with its legacy input live again (open apps close). */
export async function reclaimInput() {
  const udid = ui.udid;
  ui.reclaiming = true;
  const res = await fetch(`/api/sims/${udid}/reclaim`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }).catch(() => null);
  ui.reclaiming = false;
  if (!res?.ok) return flashStatus("Couldn't take the buttons back", 6000);
  if (udid === ui.udid) ui.inputShadowed = false;
  flashStatus('Buttons are back');
}

export function pressButton(button, duration) {
  send({ type: 'button', button, ...(duration > 0.4 ? { duration } : {}) });
}

/** Saves what's on screen (the frozen frame while annotating). */
/** Saves what's on screen as Simulator.app's Save Screen does: the host
 *  puts it on the Desktop, and a banner opens it in Finder. */
export async function saveScreenshot() {
  const png = await screenPNG();
  if (png) saveFile({ route: 'screenshots', field: 'png', blob: png, extension: 'png', title: 'Screenshot Saved', picture: png });
}

/** Has the host save a screenshot or recording where Simulator.app puts
 *  them, then says so in a banner that opens it in Finder. A host that
 *  can't (an older one, or a recording too long to send): the browser's
 *  download instead. */
async function saveFile({ route, field, blob, extension, title, picture }) {
  const data = await new Promise((done) => {
    const reader = new FileReader();
    reader.onload = () => done(String(reader.result).split(',')[1]);
    reader.readAsDataURL(blob);
  });
  const res = await fetch(`/api/${route}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ udid: ui.udid, [field]: data }),
  }).catch(() => null);
  const saved = res?.ok ? await res.json().catch(() => null) : null;
  if (!saved) return download(blob, extension);
  notify({
    image: picture && URL.createObjectURL(picture),
    title,
    message: 'Open in Finder',
    action: () => fetch(`/api/${route}/${saved.id}/reveal`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }),
  });
}

/** Copies what's on screen to the clipboard, as Simulator's Copy Screen does. */
export async function copyScreen() {
  const png = screenPNG();
  if (!(await png)) return;
  await navigator.clipboard.write([new ClipboardItem({ 'image/png': png })]);
  flashStatus('Copied the screen');
}

function screenPNG() {
  const frame = rt.frozen?.bitmap ?? rt.frame;
  if (!frame) return Promise.resolve(null);
  const { width, height } = frameSize(frame);
  const out = new OffscreenCanvas(width, height);
  out.getContext('2d').drawImage(frame, 0, 0);
  return out.convertToBlob({ type: 'image/png' });
}

/** Simulator.app's Features on the device: appearance, text size, shake, Face ID. */
export async function feature(name) {
  if (!ui.running) return;
  const res = await fetch(`/api/sims/${ui.udid}/feature`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name }),
  }).catch(() => null);
  const result = await res?.json().catch(() => null);
  if (!res?.ok) return flashStatus(result?.error ?? "Couldn't change the simulator", 6000);
  const SAID = {
    appearance: `${result.value === 'dark' ? 'Dark' : 'Light'} Appearance`,
    'text-bigger': `Text Size: ${result.value}`,
    'text-smaller': `Text Size: ${result.value}`,
    shake: 'Shake',
    'biometric-match': 'Matching Face',
    'biometric-mismatch': 'Non-matching Face',
  };
  flashStatus(SAID[name] ?? name);
}

function download(blob, extension) {
  const stamp = new Date().toISOString().slice(0, 19).replace('T', ' at ').replaceAll(':', '.');
  const link = Object.assign(document.createElement('a'), { href: URL.createObjectURL(blob), download: `${ui.simName} ${stamp}.${extension}` });
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

// Records the screen as the page shows it, as baguette's recorder.js does:
// MP4 where MediaRecorder can, else WebM.
const RECORDING_TYPES = ['video/mp4;codecs=avc1.640033', 'video/mp4;codecs=avc1.42E01E', 'video/webm;codecs=vp9', 'video/webm'];
let recorder = null;

export function toggleRecording() {
  if (recorder) return recorder.stop();
  if (!ui.running || !rt.canvas || typeof MediaRecorder === 'undefined') return;
  const type = RECORDING_TYPES.find((t) => MediaRecorder.isTypeSupported(t)) ?? '';
  const stream = rt.canvas.captureStream(60);
  const chunks = [];
  recorder = new MediaRecorder(stream, { ...(type && { mimeType: type }), videoBitsPerSecond: 12_000_000 });
  recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  recorder.onstop = async () => {
    stream.getTracks().forEach((t) => t.stop());
    const video = new Blob(chunks, { type: recorder.mimeType });
    const extension = recorder.mimeType.startsWith('video/mp4') ? 'mp4' : 'webm';
    recorder = null;
    ui.recording = false;
    // The banner's picture: the screen as the recording ends.
    saveFile({ route: 'recordings', field: 'video', blob: video, extension, title: 'Recording Saved', picture: await screenPNG() });
  };
  recorder.start(1000);
  ui.recording = true;
}

// ---------- rotation ----------

/** Degrees the device turns on screen for each orientation (UIDeviceOrientation names). */
export const ROTATION = { portrait: 0, 'landscape-right': 90, 'portrait-upside-down': 180, 'landscape-left': -90 };
const TURN_ORDER = ['portrait', 'landscape-right', 'portrait-upside-down', 'landscape-left']; // clockwise

export const isLandscape = () => ui.running && ui.orientation.startsWith('landscape');

/** Turns the device a quarter clockwise: iOS rotates its interface, the page rotates the device. */
export function rotate() {
  return rotateBy(1);
}

/** Turns the device a quarter: 1 clockwise (Rotate Right), -1 the other way. */
export async function rotateBy(step) {
  if (!ui.running) return;
  await setMode('interact');
  ui.orientation = TURN_ORDER[(TURN_ORDER.indexOf(ui.orientation) + step + TURN_ORDER.length) % TURN_ORDER.length];
  send({ type: 'orientation', orientation: ui.orientation });
  await tick();
  updateScale();
}

// ---------- annotate mode ----------

export async function setMode(mode) {
  if (mode === ui.mode) return;
  // Nothing to freeze yet: no live frame from a running device.
  if (mode === 'annotate' && (!rt.frame || !ui.chrome)) return;
  ui.mode = mode;
  closeComposer();

  if (mode === 'annotate') {
    // Design Mode's annotations show in the inspector: its tab, and the
    // inspector itself unless a narrow window put it away (not saved).
    ui.panels.tab = 'annotations';
    storage.set('inspector-tab', 'annotations');
    if (!ui.panels.inspector && !crowdedOut.inspector) showPanel('inspector', true);
    // Freeze the frame on screen right now, then fetch the accessibility tree
    // and SDK data and warm the pixel regions while those requests are out.
    const data = Promise.all([
      fetchTree(),
      fetch('/api/sdk').then((r) => (r.status === 200 ? r.json() : null)).catch(() => null),
    ]);
    // Freeze a copy: video frames belong to the decoder and must be closed soon.
    const source = rt.frame;
    rt.frame = null;
    const bitmap = await createImageBitmap(source);
    source.close?.();
    // A stream below full resolution blurs small things together (a ring of
    // dots, a word and its icon), so ask for the screen at full size too.
    const still = bitmap.width < devicePixels().width ? requestStill() : Promise.resolve(null);
    if (ui.mode !== 'annotate') return bitmap.close(); // left annotate mode meanwhile
    const f = (rt.frozen = {
      bitmap,
      tree: null,
      sdk: null,
      sdkAvailable: null,
      // The stream may be scaled down, so points come from the device, not the frame.
      points: { width: ui.chrome.screen.width, height: ui.chrome.screen.height },
      marks: [],
    });
    paint(bitmap);
    ui.frozen = true;
    setStatus('Freezing…');
    await new Promise(requestAnimationFrame); // let the frozen frame paint first
    f.pixels = sampler(bitmap, f.points.width, f.points.height);
    warm(f.pixels);
    // The full-size still replaces the frame: what's read, drawn and saved.
    const full = await still;
    if (rt.frozen !== f) return full?.close();
    if (full) {
      f.bitmap.close?.();
      f.bitmap = full;
      paint(full);
      f.pixels = sampler(full, f.points.width, f.points.height);
      warm(f.pixels);
    }

    const [tree, sdk] = await data;
    if (rt.frozen !== f) return; // left annotate mode meanwhile
    // A turned interface reports turned coordinates; bring them into the
    // framebuffer's, where the overlay, pixels and touches live.
    const screen = ui.chrome.screen;
    f.turned = tree?.frame && tree.frame.width > tree.frame.height ? ui.orientation : null;
    f.tree = treeToPortrait(tree, ui.orientation, screen);
    if (f.tree?.frame?.width) f.points = { width: f.tree.frame.width, height: f.tree.frame.height };
    f.sdkAvailable = matchesFrontApp(sdk, tree) ? sdkToPortrait(sdk, ui.orientation, screen) : null;
    applySdk();
  } else {
    rt.frozen?.bitmap.close?.();
    rt.frozen = null;
    ui.frozen = false;
    ui.sdkAvailable = false;
    clearLayer('.hl, .hl-label, .sel, .marker');
    rt.hover = null;
    setStatus(ui.live ? '' : 'Connecting…');
    send({ type: 'snapshot' });
  }
  // The tree can take a while: a composer opened meanwhile keeps its focus.
  if (!ui.draft) rt.overlay?.focus();
}

/** SDK on/off, to compare exact view data with the pixel fallback on the same frame. */
function applySdk() {
  const f = rt.frozen;
  if (!f) return;
  f.sdk = ui.sdkEnabled ? f.sdkAvailable : null;
  ui.sdkAvailable = !!f.sdkAvailable;
  setStatus(!f.tree ? 'Frozen (no accessibility data)' : f.sdk ? 'Frozen · SDK' : f.sdkAvailable ? 'Frozen · pixels' : 'Frozen');
  // Recompute what's under the cursor with the new source.
  if (rt.hover) {
    rt.hover = { point: rt.hover.point, targets: targetsAt(rt.hover.point), level: 0 };
    highlight();
  }
}

/** The preference applies to the next freeze too, so it works from Settings any time. */
export function toggleSdk() {
  ui.sdkEnabled = !ui.sdkEnabled;
  storage.set('sdk', ui.sdkEnabled ? 'on' : 'off');
  if (!rt.frozen?.sdkAvailable) return;
  applySdk();
  rt.overlay?.focus();
}

// Several selected tell apart by color: the first in Design Mode's indigo,
// each next in the first of these not taken (style.css's --pick-*), and the
// screenshot draws them so, in their light values.
const PICK_COLORS = [
  ['indigo', '#6155f5'], ['orange', '#ff8d28'], ['green', '#34c759'], ['pink', '#ff2d55'],
  ['cyan', '#00c0e8'], ['purple', '#cb30e0'], ['yellow', '#ffcc00'], ['brown', '#ac7f5e'],
];
function nextColor() {
  const taken = new Set(rt.picks.map((k) => k.color));
  return (PICK_COLORS.find(([name]) => !taken.has(name)) ?? PICK_COLORS[rt.picks.length % PICK_COLORS.length])[0];
}
let pickIds = 0;
// A chip's symbol says what it is, from its role (or the kind the pixels or
// the SDK found, the label's first word): an image, a field, a button,
// text, else a view; an area dragged out is a dashed box.
function pickType({ kind, label, role }) {
  if (kind === 'area' && label === 'Area') return 'area';
  const word = (role ?? label).replace(/^AX/, '').split(/[\s"·]/)[0].toLowerCase();
  if (/image|icon|photo|picture/.test(word)) return 'kind-image';
  if (/field|textview|search|secure/.test(word)) return 'kind-field';
  if (/button|link|switch|toggle|menuitem|tab|checkbox|radio|slider|stepper|segment|picker/.test(word)) return 'kind-button';
  if (/text|label|heading/.test(word)) return 'kind-text';
  return 'kind-view';
}
// A chip's name: the element's label, short ("Maps"), or "Area".
const shortName = (label) => {
  const name = label.match(/"([^"]+)"/)?.[1] ?? label;
  return name.length > 18 ? `${name.slice(0, 17)}…` : name;
};
function selectionBox(color) {
  const el = Object.assign(document.createElement('div'), { className: 'sel' });
  el.style.setProperty('--pick', `var(--pick-${color})`);
  return el;
}

// With the composer open, hovering and selecting go on: a click or a drag
// takes the selection's place, Shift+click adds an element to it (or takes
// a selected one away) and Shift+drag adds an area. The composer, its note
// kept, moves beside whatever is selected.
function annotateDown(e) {
  if (!rt.frozen) return;
  rt.overlay.setPointerCapture(e.pointerId);
  rt.drag = { start: axPoint(e), moved: false, add: e.shiftKey, box: null, color: null };
}

function annotateMove(e) {
  if (!rt.frozen) return;
  const p = axPoint(e);
  if (rt.drag) {
    const dx = p.x - rt.drag.start.x;
    const dy = p.y - rt.drag.start.y;
    if (!rt.drag.moved && Math.hypot(dx, dy) < 4) return;
    rt.drag.moved = true;
    clearLayer('.hl, .hl-label');
    rt.hover = null;
    if (!rt.drag.box) {
      if (!rt.drag.add) clearPicks();
      rt.drag.color = nextColor();
      rt.overlay.append((rt.drag.box = selectionBox(rt.drag.color)));
    }
    placeBox(rt.drag.box, normalize(rt.drag.start, p));
    return;
  }
  const targets = targetsAt(p);
  const hover = rt.hover;
  const same = hover && targets.length === hover.targets.length && targets.every((t, i) => sameRect(t.rect, hover.targets[i].rect));
  rt.hover = { point: p, targets, level: same ? hover.level : 0 };
  highlight();
}

function annotateUp(e) {
  if (!rt.drag) return;
  const p = axPoint(e);
  const { moved, start, add, box, color: dragged } = rt.drag;
  rt.drag = null;
  if (moved) {
    rt.picks.push({ id: ++pickIds, kind: 'area', rect: normalize(start, p), label: 'Area', color: dragged, el: box });
    return openComposer();
  }
  const target = rt.hover?.targets[rt.hover.level] ?? targetsAt(p)[0];
  const rect = target ? { ...target.rect } : { x: p.x - 22, y: p.y - 22, width: 44, height: 44 };
  clearLayer('.hl, .hl-label');
  const picked = rt.picks.findIndex((k) => sameRect(k.rect, rect));
  if (add && picked >= 0) {
    rt.picks.splice(picked, 1)[0].el.remove();
    return rt.picks.length ? openComposer() : closeComposer();
  }
  if (!add) clearPicks();
  const color = nextColor();
  const el = selectionBox(color);
  placeBox(el, rect);
  rt.overlay.append(el);
  rt.picks.push({ id: ++pickIds, kind: target?.node ? 'element' : 'area', rect, point: target?.node ? p : undefined, label: target?.label ?? 'Area', role: target?.node?.role, color, el });
  openComposer();
}

/** Everything selectable under a point, innermost first: the accessibility
 *  element, then the cards and rows drawn around it. */
function targetsAt(p) {
  const f = rt.frozen;
  const hit = f.tree ? hitTest(f.tree, p.x, p.y, f.points) : null;
  const targets = hit ? [{ rect: hit.node.frame, label: describe(hit.node), node: hit.node }] : [];
  // With the in-app SDK we know the real views and layers; otherwise guess from pixels.
  if (f.sdk) return [...targets, ...sdkContainers(f.sdk, p, hit?.node.frame)];
  if (!f.pixels) return targets;
  const seed = hit ? hit.node.frame : { x: p.x, y: p.y, width: 1, height: 1 };
  // Regions were warmed at freeze time, so this is a lookup. The pixel map is
  // 1px per point; scale in case the accessibility tree reports another size.
  const k = f.pixels.width / f.points.width;
  const toMap = (r) => ({ x: r.x * k, y: r.y * k, width: r.width * k, height: r.height * k });
  const fromMap = (r) => ({ x: r.x / k, y: r.y / k, width: r.width / k, height: r.height / k });
  // SpringBoard is its accessibility elements, as they are: its wallpaper
  // has no cards and its icons no parts worth picking. Only a widget, one
  // element over a whole card, gets what's drawn on the card.
  if (isSpringBoard(f.tree)) return isWidget(hit?.node) ? [...partAt(hit, p, toMap, fromMap), ...targets] : targets;
  const containers = containersAround(f.pixels, toMap(seed)).map((r) => {
    const rect = fromMap(r);
    return { rect, label: containerLabel(rect) };
  });
  return [...partAt(hit, p, toMap, fromMap), ...targets, ...containers];
}

// The icon or text run under the pointer inside the element the tree found,
// for elements the tree doesn't split further. Innermost, so it's picked
// first; ↑ goes on to the element itself. When the pointer is on a card
// drawn inside the element (a widget's), the parts are the card's, found
// against the card, and the card is the next level up.
const SLACK = 3; // pt around a part that still counts as on it
function partAt(hit, p, toMap, fromMap) {
  if (!hit) return [];
  const img = rt.frozen.pixels;
  const frame = toMap(hit.node.frame);
  const mapped = toMap({ x: p.x, y: p.y, width: 1, height: 1 });
  const card = containerAround(img, mapped);
  const onCard =
    card &&
    card.x >= frame.x - 1 && card.y >= frame.y - 1 &&
    card.x + card.width <= frame.x + frame.width + 1 && card.y + card.height <= frame.y + frame.height + 1 &&
    card.width * card.height < frame.width * frame.height * 0.97;
  const area = onCard ? { x: card.x + 2, y: card.y + 2, width: card.width - 4, height: card.height - 4 } : frame;
  const parts = partsWithin(img, area, { panel: !!onCard }).map((r) => ({ ...fromMap(r), kind: r.kind }));
  const on = (r) => p.x >= r.x - SLACK && p.x <= r.x + r.width + SLACK && p.y >= r.y - SLACK && p.y <= r.y + r.height + SLACK;
  const part = parts.filter(on).sort((a, b) => a.width * a.height - b.width * b.height)[0];
  const owner = describe(hit.node).replace(/"([^"]{28})[^"]+"/, '"$1…"'); // a row's label can be a paragraph
  const out = [];
  if (part) {
    const texts = parts.filter((r) => r.kind === 'Text').length;
    const name = hit.node.label?.trim();
    const label = part.kind === 'Text' && texts === 1 && name && !onCard ? `Text "${name}"` : `${part.kind} in ${owner}`;
    const { kind, ...rect } = part;
    out.push({ rect, label });
  }
  if (onCard) out.push({ rect: fromMap(card), label: `Card in ${owner}` });
  return out;
}

function containerLabel(rect) {
  const tree = rt.frozen.tree;
  const names = tree
    ? nodesInRect(tree, rect)
        .sort((a, b) => a.node.frame.y - b.node.frame.y || a.node.frame.x - b.node.frame.x)
        .map((e) => e.node.label?.trim())
        .filter(Boolean)
    : [];
  if (!names.length) return 'Container';
  const shown = names.slice(0, 2).map((n) => `"${n}"`).join(', ');
  return `Container: ${shown}${names.length > 2 ? ` +${names.length - 2}` : ''}`;
}

const sameRect = (a, b) => a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;

function changeLevel(delta) {
  const hover = rt.hover;
  if (!hover?.targets.length) return false;
  const level = Math.min(Math.max(hover.level + delta, 0), hover.targets.length - 1);
  if (level === hover.level) return true;
  hover.level = level;
  highlight();
  return true;
}

const normalize = (a, b) => ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y) });

function highlight() {
  let hl = rt.overlay.querySelector('.hl');
  let label = rt.float.querySelector('.hl-label');
  const hover = rt.hover;
  const target = hover?.targets[hover.level];
  if (!target) return clearLayer('.hl, .hl-label');
  if (!hl) rt.overlay.append((hl = Object.assign(document.createElement('div'), { className: 'hl' })));
  // The label sits on the unmasked layer so it stays whole above the top of the screen.
  if (!label) rt.float.append((label = Object.assign(document.createElement('span'), { className: 'hl-label' })));
  placeBox(hl, target.rect);
  // Anchor at the box corner that is top-left on screen; the label then turns
  // back upright (--unrotate), so it reads level however the device is turned.
  const { width, height } = rt.frozen.points;
  const { x, y, width: w, height: h } = target.rect;
  const [ax, ay] = { 90: [x, y + h], 180: [x + w, y + h], [-90]: [x + w, y] }[ROTATION[ui.orientation]] ?? [x, y];
  label.style.left = `${(ax / width) * 100}%`;
  label.style.top = `${(ay / height) * 100}%`;
  const more = hover.level < hover.targets.length - 1 ? '  ↑' : ''; // there's a parent: ↑ goes to it
  label.textContent = target.label + more;
}

// ---------- composer ----------

/** Opens the comment popover beside what's selected, or moves it there; the
 *  popover keeps itself on screen. Several picked make one annotation: its
 *  box holds them all, and each goes along as a part. */
function openComposer() {
  const picks = rt.picks;
  const [first] = picks;
  rt.draft = picks.length === 1
    ? { kind: first.kind, rect: first.rect, point: first.point, label: first.label }
    : {
        kind: 'area',
        rect: union(picks.map((k) => k.rect)),
        label: picks.map((k) => k.label).join(', '),
        parts: picks.map(({ kind, rect, point, label, color }) => ({ kind, rect, point, label, color })),
      };
  const boxes = picks.map((k) => k.el.getBoundingClientRect());
  ui.draft = {
    label: picks.length === 1 ? first.label : `${first.label} and ${picks.length - 1} more`,
    // The composer shows them as chips, each in its color.
    picks: picks.map((k) => ({ id: k.id, label: k.label, short: shortName(k.label), type: pickType(k), color: k.color })),
    box: {
      left: Math.min(...boxes.map((b) => b.left)),
      right: Math.max(...boxes.map((b) => b.right)),
      top: Math.min(...boxes.map((b) => b.top)),
      bottom: Math.max(...boxes.map((b) => b.bottom)),
    },
  };
}

/** Takes one selection away (its chip's x); the composer goes with the last. */
export function removePick(id) {
  const i = rt.picks.findIndex((k) => k.id === id);
  if (i < 0) return;
  rt.picks.splice(i, 1)[0].el?.remove();
  if (rt.picks.length) openComposer();
  else cancelComposer();
}

function clearPicks() {
  for (const k of rt.picks) k.el?.remove();
  rt.picks = [];
}

const union = (rects) => {
  const x = Math.min(...rects.map((r) => r.x));
  const y = Math.min(...rects.map((r) => r.y));
  return { x, y, width: Math.max(...rects.map((r) => r.x + r.width)) - x, height: Math.max(...rects.map((r) => r.y + r.height)) - y };
};

export function closeComposer() {
  rt.draft = null;
  ui.draft = null;
  clearPicks();
  clearLayer('.sel');
}

export function cancelComposer() {
  closeComposer();
  rt.overlay?.focus();
}

export async function submitComposer(comment) {
  const draft = rt.draft;
  if (!comment || !draft) return;
  closeComposer();
  const f = rt.frozen;
  const img = f.bitmap;
  const scale = img.width / f.points.width;
  const r = draft.rect;

  // Full screenshot with the box drawn on it.
  const full = new OffscreenCanvas(img.width, img.height);
  const fc = full.getContext('2d');
  fc.drawImage(img, 0, 0);
  fc.lineWidth = Math.max(3, scale * 1.5);
  // Just outside each box, as on screen, so the line doesn't cover the text:
  // one in red (--mark), several each in its color.
  const out = 1 + fc.lineWidth / scale / 2;
  const boxes = draft.parts?.map((part) => [part.rect, PICK_COLORS.find(([name]) => name === part.color)?.[1] ?? '#ff383c']) ?? [[r, '#ff383c']];
  for (const [b, color] of boxes) {
    fc.strokeStyle = color;
    fc.strokeRect((b.x - out) * scale, (b.y - out) * scale, (b.width + out * 2) * scale, (b.height + out * 2) * scale);
  }

  // Close-up with some context around the box.
  const pad = 16;
  const cx = Math.max(0, (r.x - pad) * scale);
  const cy = Math.max(0, (r.y - pad) * scale);
  const cw = Math.min(img.width - cx, (r.width + pad * 2) * scale);
  const ch = Math.min(img.height - cy, (r.height + pad * 2) * scale);
  const crop = new OffscreenCanvas(Math.max(1, cw), Math.max(1, ch));
  crop.getContext('2d').drawImage(img, cx, cy, cw, ch, 0, 0, cw, ch);
  // Screenshots go to the agent upright, as the interface was showing.
  const degrees = f.turned ? uprightDegrees(f.turned) : 0;

  const body = {
    udid: ui.udid,
    comment,
    kind: draft.kind,
    label: draft.label,
    rect: r,
    point: draft.point,
    parts: draft.parts?.map((part) => ({ ...part, source: f.sdk ? sourceFor(f.sdk, part.rect) : undefined })),
    tree: f.tree,
    app: f.sdk ? { bundleId: f.sdk.bundleId, name: f.sdk.appName } : undefined,
    source: f.sdk ? sourceFor(f.sdk, r) : undefined,
    ...(f.sdk ? viewContext(f.sdk, r) : {}),
    full: await toBase64(turn(full, degrees)),
    crop: await toBase64(turn(crop, degrees)),
  };
  const res = await fetch('/api/annotations', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  if (!res.ok) return setStatus((await res.json().catch(() => null))?.error || 'Save failed');
  refresh();
  if (rt.frozen !== f) return; // resumed while saving: no marker on the live screen

  f.marks.push(r);
  const marker = Object.assign(document.createElement('div'), { className: 'marker', textContent: f.marks.length });
  marker.style.left = `${(r.x / f.points.width) * 100}%`;
  marker.style.top = `${(r.y / f.points.height) * 100}%`;
  rt.float.append(marker);
}

/** The canvas turned a quarter, for landscape screenshots. */
function turn(canvas, degrees) {
  if (!degrees) return canvas;
  const out = new OffscreenCanvas(canvas.height, canvas.width);
  const g = out.getContext('2d');
  g.translate(out.width / 2, out.height / 2);
  g.rotate((degrees * Math.PI) / 180);
  g.drawImage(canvas, -canvas.width / 2, -canvas.height / 2);
  return out;
}

async function toBase64(offscreen) {
  const blob = await offscreen.convertToBlob({ type: 'image/jpeg', quality: 0.85 });
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

// ---------- annotations ----------

let lastList = null;

export async function refresh() {
  const text = await fetch('/api/annotations').then((r) => (r.ok ? r.text() : null)).catch(() => null);
  if (text === null || text === lastList) return; // unchanged: keep the DOM and thumbnails
  lastList = text;
  ui.annotations = JSON.parse(text);
}

export async function deleteAnnotation(id) {
  const res = await fetch(`/api/annotations/${id}`, { method: 'DELETE' }).catch(() => null);
  if (!res?.ok) {
    flashStatus("Couldn't delete the annotation");
    return false;
  }
  ui.annotations = ui.annotations.filter((a) => a.id !== id);
  refresh();
  return true;
}

export async function clearDone() {
  await fetch('/api/annotations/finished', { method: 'DELETE' });
  refresh();
}

export async function copyPending() {
  const pending = await fetch('/api/annotations?status=pending').then((r) => r.json());
  const full = await Promise.all(pending.map((a) => fetch(`/api/annotations/${a.id}`).then((r) => r.json())));
  await navigator.clipboard.writeText(full.map((a) => a.markdown).join('\n\n'));
  flashStatus(full.length ? `Copied ${full.length} to the clipboard` : 'Nothing pending to copy');
}

// ---------- devices ----------

const chromes = new Map(); // udid → Promise<chrome | null>

export function chromeOf(udid) {
  if (!chromes.has(udid)) {
    chromes.set(udid, fetch(`/api/sims/${udid}/chrome`).then((r) => (r.ok ? r.json() : null)).catch(() => null));
  }
  return chromes.get(udid);
}

export async function loadDevices() {
  ui.sims = await fetch('/api/sims').then((r) => (r.ok ? r.json() : [])).catch(() => []);
  const saved = storage.get('udid');
  const pick = ui.sims.find((s) => s.udid === saved) ?? ui.sims.find((s) => s.state === 'Booted') ?? ui.sims[0];
  if (pick) await selectDevice(pick);
  else ui.message = 'No simulators found. Create one in Xcode first.';
}

/** Selecting shows the device; only a running one streams. Starting is explicit. */
export async function selectDevice(sim) {
  await setMode('interact');
  stopStream();
  ui.udid = sim.udid;
  storage.set('udid', sim.udid);
  ui.simName = sim.name;
  ui.runtime = sim.runtime;
  ui.orientation = 'portrait';
  if (recorder) recorder.stop();
  setStatus('');

  const chrome = await chromeOf(sim.udid);
  if (ui.udid !== sim.udid) return; // picked another device meanwhile
  ui.chrome = chrome;
  if (!chrome) {
    ui.message = `No device artwork for ${sim.name}.`;
    return;
  }
  ui.message = null;
  ui.running = sim.state === 'Booted';
  ui.starting = false;
  if (!ui.running) rt.ctx?.clearRect(0, 0, rt.canvas.width, rt.canvas.height);
  await tick();
  updateScale();
  ui.shown++;
  ui.inputShadowed = false;
  if (ui.running) {
    connect(sim.udid);
    checkInput();
  }
}

export async function startDevice() {
  const sim = ui.sims.find((s) => s.udid === ui.udid);
  if (!sim) return;
  ui.starting = true;
  const res = await fetch(`/api/sims/${sim.udid}/boot`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }).catch(() => null);
  if (!res?.ok) {
    ui.starting = false;
    flashStatus((await res?.json().catch(() => null))?.error ?? "Couldn't start the simulator");
    return;
  }
  sim.state = 'Booted';
  if (ui.udid === sim.udid) await selectDevice(sim);
}

// ---------- devices changed elsewhere ----------

let lastSims = '';

/**
 * The device list as CoreSimulator has it now, so devices started, shut
 * down, created or deleted elsewhere (Xcode, Simulator.app, simctl) show
 * up, and the stage follows the device on it: shut down, it goes back to
 * the preview with Start; started, it streams; deleted, another is shown.
 * Not while this page is starting or changing it (that reselects when
 * done), nor in Design Mode, whose frozen frame still serves; the next
 * look after leaving it catches up.
 */
async function followSims() {
  const text = await fetch('/api/sims').then((r) => (r.ok ? r.text() : null)).catch(() => null);
  if (text === null) return;
  if (text !== lastSims) {
    lastSims = text;
    ui.sims = JSON.parse(text);
  }
  if (!ui.udid || ui.starting || ui.managing || ui.mode === 'annotate') return;
  const sim = ui.sims.find((s) => s.udid === ui.udid);
  if (!sim) {
    flashStatus(`${ui.simName} was removed`, 4000);
    const next = ui.sims.find((s) => s.state === 'Booted') ?? ui.sims[0];
    if (next) await selectDevice(next);
    return;
  }
  if ((sim.state === 'Booted') === ui.running) return;
  flashStatus(sim.state === 'Booted' ? `${sim.name} started` : `${sim.name} was shut down`, 4000);
  await selectDevice(sim);
}

// ---------- the … menu: shut down, restart, rename, reset, remove ----------

async function reloadSims() {
  ui.sims = await fetch('/api/sims').then((r) => (r.ok ? r.json() : ui.sims)).catch(() => ui.sims);
}

/** One of the host's simctl verbs on the selected device, then the list and the stage catch up. */
async function manage(verb, { method = 'POST', body = {}, doing } = {}) {
  const udid = ui.udid;
  ui.managing = doing;
  if (doing) setStatus(doing);
  const res = await fetch(`/api/sims/${udid}${verb ? `/${verb}` : ''}`, {
    method,
    headers: { 'content-type': 'application/json' },
    body: method === 'DELETE' ? undefined : JSON.stringify(body),
  }).catch(() => null);
  ui.managing = null;
  setStatus('');
  if (!res?.ok) {
    flashStatus((await res?.json().catch(() => null))?.error ?? "Couldn't change the simulator", 6000);
    return false;
  }
  await reloadSims();
  return true;
}

async function reselect(udid) {
  const sim = ui.sims.find((s) => s.udid === udid);
  if (sim) await selectDevice(sim);
}

export async function shutdownDevice() {
  const udid = ui.udid;
  stopStream();
  if (await manage('shutdown', { doing: 'Shutting Down…' })) await reselect(udid);
}

export async function restartDevice() {
  const udid = ui.udid;
  stopStream();
  if (await manage('restart', { doing: 'Restarting…' })) await reselect(udid);
}

export async function renameDevice(name) {
  const udid = ui.udid;
  if (!(await manage('rename', { body: { name } }))) return false;
  if (ui.udid === udid) ui.simName = name;
  return true;
}

/** Erases all content and settings; a running device comes back up. */
export async function eraseDevice() {
  const udid = ui.udid;
  stopStream();
  if (await manage('erase', { doing: 'Erasing…' })) await reselect(udid);
}

/** Deletes the simulator, then shows another (a running one first). */
export async function removeDevice() {
  stopStream();
  if (!(await manage('', { method: 'DELETE', doing: 'Removing…' }))) return;
  const next = ui.sims.find((s) => s.state === 'Booted') ?? ui.sims[0];
  if (next) await selectDevice(next);
}

// ---------- zoom ----------

const PREVIEW_HEIGHT = 197; // px, the not-running device picture, measured in Device Hub
export const MARGIN = 14; // pt around the body for buttons that slide out
const ZOOM_STEP = 1.25;

function fitScale() {
  const stage = rt.stage;
  if (!stage || !ui.chrome) return 1;
  const pad = getComputedStyle(stage);
  const width = stage.clientWidth - parseFloat(pad.paddingLeft) - parseFloat(pad.paddingRight);
  const height = stage.clientHeight - parseFloat(pad.paddingTop) - parseFloat(pad.paddingBottom);
  const info = rt.previewInfo ? rt.previewInfo.offsetHeight + 24 : 0;
  const { size } = ui.chrome;
  const [w, h] = isLandscape() ? [size.height, size.width] : [size.width, size.height];
  return Math.max(0.15, Math.min(width / (w + MARGIN * 2), (height - info) / (h + MARGIN * 2)));
}

function currentScale() {
  if (!ui.chrome) return 1;
  if (!ui.running) return Math.min(PREVIEW_HEIGHT / ui.chrome.size.height, fitScale());
  return ui.zoom === 'fit' ? fitScale() : Number(ui.zoom);
}

export function updateScale() {
  ui.scale = currentScale();
  // Zoom and window size move the auto resolution; settle once they stop.
  clearTimeout(settleTimer);
  settleTimer = setTimeout(settleStream, 400);
}

/** On stage resize: only fit-to-window and the preview follow the window. */
export function onStageResize() {
  if (ui.zoom === 'fit' || !ui.running) updateScale();
}

export function setZoom(next) {
  if (!ui.running) return;
  ui.zoom = next === 'fit' ? 'fit' : String(Math.min(3, Math.max(0.25, Math.round(next * 100) / 100)));
  storage.set('zoom', ui.zoom);
  closeComposer();
  updateScale();
}

export const zoomIn = () => setZoom(currentScale() * ZOOM_STEP);
export const zoomOut = () => setZoom(currentScale() / ZOOM_STEP);

// ---------- panels ----------

// As the window narrows the sidebar steps aside for the device, then the
// inspector too; each comes back once there's room. That isn't saved, and
// their buttons still bring them back meanwhile.
const ROOM = { sidebar: '(max-width: 999px)', inspector: '(max-width: 719px)' };
const crowdedOut = {};

/** Fits the panels to the window, now and as it resizes. */
export function fitPanels() {
  for (const [name, query] of Object.entries(ROOM)) {
    const narrow = matchMedia(query);
    const fit = () => {
      if (narrow.matches && ui.panels[name]) {
        crowdedOut[name] = true;
        showPanel(name, false);
      } else if (!narrow.matches && crowdedOut[name]) {
        crowdedOut[name] = false;
        showPanel(name, true);
      }
    };
    narrow.addEventListener('change', fit);
    fit();
  }
}

export async function togglePanel(name, show = !ui.panels[name]) {
  crowdedOut[name] = false;
  storage.set(`panel-${name}`, show ? 'shown' : 'hidden');
  await showPanel(name, show);
}

async function showPanel(name, show) {
  ui.panels[name] = show;
  await tick();
  onStageResize();
}

/** Device Hub's collapse button: the device alone, then both panels back. */
export async function toggleFocus() {
  const show = !ui.panels.sidebar && !ui.panels.inspector;
  await Promise.all([togglePanel('sidebar', show), togglePanel('inspector', show)]);
}

/** A tab opens the inspector on it; the tab that is already open closes it. */
export function setInspectorTab(tab) {
  if (ui.panels.inspector && ui.panels.tab === tab) return togglePanel('inspector', false);
  ui.panels.tab = tab;
  storage.set('inspector-tab', tab);
  if (!ui.panels.inspector) togglePanel('inspector', true);
}

export function setFilter(filter) {
  ui.filter = filter;
  storage.set('filter', filter);
}

// ---------- new simulators ----------

export const simulatorOptions = () => fetch('/api/sims/new').then((r) => (r.ok ? r.json() : null)).catch(() => null);

/** `simctl create`, then select it; it starts shut down, ready for Start. */
export async function createSimulator({ name, deviceType, runtime }) {
  const res = await fetch('/api/sims', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ name, deviceType, runtime }),
  }).catch(() => null);
  const body = await res?.json().catch(() => null);
  if (!res?.ok) {
    flashStatus(body?.error ?? "Couldn't create the simulator", 6000);
    return false;
  }
  ui.sims = await fetch('/api/sims').then((r) => (r.ok ? r.json() : ui.sims)).catch(() => ui.sims);
  const sim = ui.sims.find((s) => s.udid === body.udid);
  if (sim) await selectDevice(sim);
  return true;
}

// ---------- start ----------

export function start() {
  requestAnimationFrame(paintLoop);
  const stats = setInterval(sampleStats, 1000);
  document.addEventListener('visibilitychange', settleStream);
  // Settle the format before the first device connects.
  decodeCapabilities().then(({ playable, hardware }) => {
    ui.stream.playable = playable;
    ui.stream.hardwareDecode = hardware;
    ui.stream.format = pickFormat(ui.stream.choice, capabilities());
    loadDevices();
  });
  refresh();
  const timer = setInterval(() => {
    refresh();
    followSims();
  }, 1500);
  return () => {
    clearInterval(timer);
    clearInterval(stats);
    document.removeEventListener('visibilitychange', settleStream);
  };
}
