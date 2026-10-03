// App state and behaviour. `ui` is reactive and drives the components;
// `rt` holds what changes every frame or pointer move (stream, frozen frame,
// hover, drag) and is never rendered directly.

import { tick } from 'svelte';
import { hitTest, describe, nodesInRect } from './ax.js';
import { sampler, warm, containersAround, partsWithin } from './visual.js';
import { matchesFrontApp, sdkContainers, sourceFor, viewContext } from './sdk.js';
import { createDecoder, decodeCapabilities, formatLabel, pickFormat } from './stream.js';
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
  recording: false,
  annotations: [],
  draft: null,        // { label, x, y } while the composer is open (viewport px)
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
  draft: null,       // { kind, rect, point?, label }
  failed: new Set(), // formats Auto gave up on this session
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
  settleStream();
  const { format, scale, bitrate } = ui.stream;
  const ws = new WebSocket(`ws://${location.host}/ws/${encodeURIComponent(udid)}?format=${format}&scale=${scale}&bitrate=${bitrate}`);
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

// Auto resolution and bitrate, with the codec on Auto. The device renders at 3x (iPad 2x); the page
// shows it at ui.scale CSS px per point on a devicePixelRatio display. When
// that is no more than half the device's pixels, half resolution looks the
// same and costs a quarter. Going back to full waits for 60%, so a window
// dragged across the line doesn't flip the encoder back and forth.
const BITS_PER_PIXEL = { hevc: 0.035, avcc: 0.05, hevc422: 0.06 }; // per frame, at 60 fps
let settleTimer;

function devicePixels() {
  const sim = ui.sims.find((s) => s.udid === ui.udid);
  const k = sim?.deviceType.includes('iPad') ? 2 : 3;
  const screen = ui.chrome?.screen ?? { width: 402, height: 874 };
  return { width: screen.width * k, height: screen.height * k };
}

function autoScale() {
  if (!ui.chrome) return ui.stream.scale;
  const shown = (ui.chrome.screen.width * ui.scale * (window.devicePixelRatio || 1)) / devicePixels().width;
  if (ui.stream.scale === 2) return shown > 0.6 ? 1 : 2;
  return shown <= 0.5 ? 2 : 1;
}

function autoBitrate(format, scale) {
  const { width, height } = devicePixels();
  const bps = (width / scale) * (height / scale) * 60 * (BITS_PER_PIXEL[format] ?? 0.05);
  return Math.min(16, Math.max(2, Math.round(bps / 1e6))) * 1e6;
}

/** Works out the resolution and bitrate to stream now, and tells the host what changed. */
function settleStream() {
  const s = ui.stream;
  const auto = s.choice === 'auto';
  const scale = auto ? autoScale() : s.scaleChoice;
  const bitrate = auto ? autoBitrate(s.format, scale) : s.bitrateChoice;
  if (scale !== s.scale) {
    s.scale = scale;
    send({ type: 'set_scale', scale });
  }
  if (bitrate !== s.bitrate) {
    s.bitrate = bitrate;
    send({ type: 'set_bitrate', bps: bitrate });
  }
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
  } else if (msg.type === 'stream_error') {
    // The host couldn't encode this format (no encoder for it on this Mac).
    if (!fallBack(msg.format, msg.error)) setStatus(msg.error);
  } else if (msg.type === 'error' || msg.ok === false) {
    setStatus(msg.error || 'Error');
  }
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

export function onScreenKey(e) {
  if (ui.mode !== 'interact') return;
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

/** Window-level shortcuts: modes, Esc, ↑/↓ parent, S for SDK, ⌘ zoom keys. */
export function onWindowKey(e) {
  if (e.target.closest?.('.composer')) return;
  if (e.metaKey) {
    if (e.target.matches?.('input')) return;
    const actions = { '=': zoomIn, '+': zoomIn, '-': zoomOut, 9: () => setZoom('fit') };
    if (actions[e.key]) {
      e.preventDefault();
      actions[e.key]();
    }
    return;
  }
  if (e.key === 'Escape' && ui.mode === 'annotate') {
    e.preventDefault();
    setMode('interact');
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

/**
 * Home. A device with a home button gets the button; on the others (Face ID
 * iPhones, newer iPads) iOS 27 ignores that legacy press (measured on 27.2:
 * the app stayed in front), so Home is their swipe up from the bottom edge.
 */
export function pressHome() {
  const hasButton = ui.chrome?.buttons?.some((b) => b.name === 'home');
  send({ type: 'button', button: hasButton ? 'home' : 'swipe-to-home' });
}

/** The app switcher: a double home press with a home button, the swipe-and-hold elsewhere. */
export function pressAppSwitcher() {
  const hasButton = ui.chrome?.buttons?.some((b) => b.name === 'home');
  send({ type: 'button', button: hasButton ? 'app-switcher' : 'swipe-to-app-switcher' });
}

export function pressButton(button, duration) {
  send({ type: 'button', button, ...(duration > 0.4 ? { duration } : {}) });
}

/** Saves what's on screen (the frozen frame while annotating). */
export async function saveScreenshot() {
  const frame = rt.frozen?.bitmap ?? rt.frame;
  if (!frame) return;
  const { width, height } = frameSize(frame);
  const out = new OffscreenCanvas(width, height);
  out.getContext('2d').drawImage(frame, 0, 0);
  download(await out.convertToBlob({ type: 'image/png' }), 'png');
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
  recorder.onstop = () => {
    stream.getTracks().forEach((t) => t.stop());
    download(new Blob(chunks, { type: recorder.mimeType }), recorder.mimeType.startsWith('video/mp4') ? 'mp4' : 'webm');
    recorder = null;
    ui.recording = false;
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
export async function rotate() {
  if (!ui.running) return;
  await setMode('interact');
  ui.orientation = TURN_ORDER[(TURN_ORDER.indexOf(ui.orientation) + 1) % TURN_ORDER.length];
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
  rt.overlay?.focus();
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

function annotateDown(e) {
  if (!rt.frozen || rt.draft) return;
  rt.overlay.setPointerCapture(e.pointerId);
  rt.drag = { start: axPoint(e), moved: false };
}

function annotateMove(e) {
  if (!rt.frozen || rt.draft) return;
  const p = axPoint(e);
  if (rt.drag) {
    const dx = p.x - rt.drag.start.x;
    const dy = p.y - rt.drag.start.y;
    if (!rt.drag.moved && Math.hypot(dx, dy) < 4) return;
    rt.drag.moved = true;
    clearLayer('.hl, .hl-label');
    rt.hover = null;
    let sel = rt.overlay.querySelector('.sel');
    if (!sel) rt.overlay.append((sel = Object.assign(document.createElement('div'), { className: 'sel' })));
    placeBox(sel, normalize(rt.drag.start, p));
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
  const { moved, start } = rt.drag;
  rt.drag = null;
  if (moved) {
    openComposer({ kind: 'area', rect: normalize(start, p), label: 'Area' });
    return;
  }
  const target = rt.hover?.targets[rt.hover.level] ?? targetsAt(p)[0];
  const rect = target ? { ...target.rect } : { x: p.x - 22, y: p.y - 22, width: 44, height: 44 };
  clearLayer('.hl, .hl-label');
  const sel = Object.assign(document.createElement('div'), { className: 'sel' });
  placeBox(sel, rect);
  rt.overlay.append(sel);
  openComposer({ kind: target?.node ? 'element' : 'area', rect, point: target?.node ? p : undefined, label: target?.label ?? 'Area' });
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
  const containers = containersAround(f.pixels, toMap(seed)).map((r) => {
    const rect = fromMap(r);
    return { rect, label: containerLabel(rect) };
  });
  return [...partAt(hit, p, toMap, fromMap), ...targets, ...containers];
}

// The icon or text run under the pointer inside the element the tree found,
// for elements the tree doesn't split further. Innermost, so it's picked
// first; ↑ goes on to the element itself.
const SLACK = 3; // pt around a part that still counts as on it
function partAt(hit, p, toMap, fromMap) {
  if (!hit) return [];
  const parts = partsWithin(rt.frozen.pixels, toMap(hit.node.frame)).map((r) => ({ ...fromMap(r), kind: r.kind }));
  const on = (r) => p.x >= r.x - SLACK && p.x <= r.x + r.width + SLACK && p.y >= r.y - SLACK && p.y <= r.y + r.height + SLACK;
  const part = parts.filter(on).sort((a, b) => a.width * a.height - b.width * b.height)[0];
  if (!part) return [];
  const owner = describe(hit.node).replace(/"([^"]{28})[^"]+"/, '"$1…"'); // a row's label can be a paragraph
  const texts = parts.filter((r) => r.kind === 'Text').length;
  const name = hit.node.label?.trim();
  const label = part.kind === 'Text' && texts === 1 && name ? `Text "${name}"` : `${part.kind} in ${owner}`;
  const { kind, ...rect } = part;
  return [{ rect, label }];
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
  if (!hover?.targets.length || rt.draft) return false;
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
  const more = hover.level < hover.targets.length - 1 ? '  ↑ parent' : '';
  label.textContent = target.label + more;
}

// ---------- composer ----------

/** Opens the comment popover beside the selection; the popover keeps itself on screen. */
function openComposer(draft) {
  rt.draft = draft;
  const box = rt.overlay.querySelector('.sel').getBoundingClientRect();
  ui.draft = { label: draft.label, x: box.right + 12, y: box.top };
}

export function closeComposer() {
  rt.draft = null;
  ui.draft = null;
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
  fc.strokeStyle = '#ff383c'; // --mark
  fc.lineWidth = Math.max(3, scale * 1.5);
  // Just outside the box, as on screen, so the line doesn't cover the text.
  const out = 1 + fc.lineWidth / scale / 2;
  fc.strokeRect((r.x - out) * scale, (r.y - out) * scale, (r.width + out * 2) * scale, (r.height + out * 2) * scale);

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
  if (ui.running) connect(sim.udid);
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

export async function togglePanel(name, show = !ui.panels[name]) {
  ui.panels[name] = show;
  storage.set(`panel-${name}`, show ? 'shown' : 'hidden');
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
  // Settle the format before the first device connects.
  decodeCapabilities().then(({ playable, hardware }) => {
    ui.stream.playable = playable;
    ui.stream.hardwareDecode = hardware;
    ui.stream.format = pickFormat(ui.stream.choice, capabilities());
    loadDevices();
  });
  refresh();
  const timer = setInterval(refresh, 1500);
  return () => {
    clearInterval(timer);
    clearInterval(stats);
  };
}
