// App state and behaviour. `ui` is reactive and drives the components;
// `rt` holds what changes every frame or pointer move (stream, frozen frame,
// hover, drag) and is never rendered directly.

import { tick } from 'svelte';
import { hitTest, describe, nodesInRect } from './ax.js';
import { sampler, warm, containersAround } from './visual.js';
import { matchesFrontApp, sdkContainers, sourceFor, viewContext } from './sdk.js';

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
  panels: {
    sidebar: storage.get('panel-sidebar') !== 'hidden',
    inspector: storage.get('panel-inspector') !== 'hidden',
  },
  annotations: [],
  draft: null,        // { label, x, y } while the composer is open (viewport px)
});

const rt = {
  ws: null,
  frame: null,       // latest ImageBitmap
  frozen: null,      // { bitmap, tree, points, pixels, sdk, sdkAvailable, marks }
  pendingTree: null,
  hover: null,       // { point, targets: [{ rect, label, node? }], level }
  drag: null,
  draft: null,       // { kind, rect, point?, label }
  touching: false,
  canvas: null,
  ctx: null,
  overlay: null,
  stage: null,
  previewInfo: null,
};

// For poking at from the devtools console.
if (typeof window !== 'undefined') window.simAgentation = { ui, rt, hover: () => rt.hover };

// ---------- status ----------

let flashTimer = null;

export function setStatus(text) {
  ui.status = text;
}

/** Shows a message for a moment, then goes back to the current status. */
export function flashStatus(text) {
  clearTimeout(flashTimer);
  ui.flash = text;
  flashTimer = setTimeout(() => (ui.flash = null), 2000);
}

// ---------- stage elements ----------

export function attachStage({ canvas, overlay, stage, previewInfo }) {
  rt.canvas = canvas;
  rt.ctx = canvas.getContext('2d');
  rt.overlay = overlay;
  rt.stage = stage;
  rt.previewInfo = previewInfo;
}

// ---------- stream ----------

function connect(udid) {
  rt.ws?.close();
  setStatus('Connecting…');
  const ws = new WebSocket(`ws://${location.host}/ws/${encodeURIComponent(udid)}`);
  ws.binaryType = 'arraybuffer';
  rt.ws = ws;

  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'snapshot' }));
    // Nudge with a harmless scroll so an idle screen still emits a frame.
    setTimeout(() => !rt.frame && send({ type: 'scroll', deltaX: 0, deltaY: 0 }), 600);
  };
  ws.onmessage = async (e) => {
    if (typeof e.data === 'string') return onText(JSON.parse(e.data));
    const bitmap = await createImageBitmap(new Blob([e.data], { type: 'image/jpeg' })).catch(() => null);
    if (!bitmap) return;
    rt.frame?.close?.();
    rt.frame = bitmap;
    if (rt.frozen) return;
    if (!ui.live) {
      ui.live = true;
      setStatus(''); // streaming is the normal state; say nothing
    }
    paint(bitmap);
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
  ui.live = false;
  rt.frame = null;
  ws?.close();
}

export function send(msg) {
  if (rt.ws?.readyState === WebSocket.OPEN) rt.ws.send(JSON.stringify(msg));
}

function paint(bitmap) {
  const { canvas, ctx } = rt;
  if (!canvas) return;
  if (canvas.width !== bitmap.width || canvas.height !== bitmap.height) {
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
  }
  ctx.drawImage(bitmap, 0, 0);
}

function onText(msg) {
  if (msg.type === 'describe_ui_result') {
    rt.pendingTree?.(msg.ok ? msg.tree : null);
    rt.pendingTree = null;
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

function fraction(e) {
  const r = rt.overlay.getBoundingClientRect();
  return {
    fx: Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1),
    fy: Math.min(Math.max((e.clientY - r.top) / r.height, 0), 1),
  };
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
  rt.overlay?.querySelectorAll(selector).forEach((n) => n.remove());
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
    const actions = { '=': zoomIn, '+': zoomIn, '-': zoomOut, 0: () => setZoom(1), 9: () => setZoom('fit') };
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

export function pressButton(button, duration) {
  send({ type: 'button', button, ...(duration > 0.4 ? { duration } : {}) });
}

/** Saves what's on screen (the frozen frame while annotating). */
export async function saveScreenshot() {
  const bitmap = rt.frozen?.bitmap ?? rt.frame;
  if (!bitmap) return;
  const out = new OffscreenCanvas(bitmap.width, bitmap.height);
  out.getContext('2d').drawImage(bitmap, 0, 0);
  const blob = await out.convertToBlob({ type: 'image/png' });
  const stamp = new Date().toISOString().slice(0, 19).replace('T', ' at ').replaceAll(':', '.');
  const link = Object.assign(document.createElement('a'), { href: URL.createObjectURL(blob), download: `${ui.simName} ${stamp}.png` });
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
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
    const bitmap = rt.frame;
    rt.frame = null; // keep the frozen bitmap alive
    const scale = Math.round(bitmap.width / ui.chrome.screen.width); // pixels per point
    const f = (rt.frozen = {
      bitmap,
      tree: null,
      sdk: null,
      sdkAvailable: null,
      points: { width: bitmap.width / scale, height: bitmap.height / scale },
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
    f.tree = tree;
    if (tree?.frame?.width) f.points = { width: tree.frame.width, height: tree.frame.height };
    f.sdkAvailable = matchesFrontApp(sdk, tree) ? sdk : null;
    applySdk();
  } else {
    rt.frozen?.bitmap.close?.();
    rt.frozen = null;
    ui.frozen = false;
    ui.sdkAvailable = false;
    clearLayer('.hl, .sel, .marker');
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

export function toggleSdk() {
  if (!rt.frozen?.sdkAvailable) return;
  ui.sdkEnabled = !ui.sdkEnabled;
  storage.set('sdk', ui.sdkEnabled ? 'on' : 'off');
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
    clearLayer('.hl');
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
  clearLayer('.hl');
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
  return [...targets, ...containers];
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
  const hover = rt.hover;
  const target = hover?.targets[hover.level];
  if (!target) return hl?.remove();
  if (!hl) {
    hl = Object.assign(document.createElement('div'), { className: 'hl' });
    hl.append(Object.assign(document.createElement('span'), { className: 'hl-label' }));
    rt.overlay.append(hl);
  }
  placeBox(hl, target.rect);
  const more = hover.level < hover.targets.length - 1 ? '  ↑ parent' : '';
  hl.firstChild.textContent = target.label + more;
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
  fc.strokeStyle = '#ff3b30';
  fc.lineWidth = Math.max(3, scale * 1.5);
  fc.strokeRect(r.x * scale, r.y * scale, r.width * scale, r.height * scale);

  // Close-up with some context around the box.
  const pad = 16;
  const cx = Math.max(0, (r.x - pad) * scale);
  const cy = Math.max(0, (r.y - pad) * scale);
  const cw = Math.min(img.width - cx, (r.width + pad * 2) * scale);
  const ch = Math.min(img.height - cy, (r.height + pad * 2) * scale);
  const crop = new OffscreenCanvas(Math.max(1, cw), Math.max(1, ch));
  crop.getContext('2d').drawImage(img, cx, cy, cw, ch, 0, 0, cw, ch);

  const body = {
    udid: ui.udid,
    comment,
    kind: draft.kind,
    rect: r,
    point: draft.point,
    tree: f.tree,
    app: f.sdk ? { bundleId: f.sdk.bundleId, name: f.sdk.appName } : undefined,
    source: f.sdk ? sourceFor(f.sdk, r) : undefined,
    ...(f.sdk ? viewContext(f.sdk, r) : {}),
    full: await toBase64(full),
    crop: await toBase64(crop),
  };
  const res = await fetch('/api/annotations', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  if (!res.ok) return setStatus((await res.json().catch(() => null))?.error || 'Save failed');
  refresh();
  if (rt.frozen !== f) return; // resumed while saving: no marker on the live screen

  f.marks.push(r);
  const marker = Object.assign(document.createElement('div'), { className: 'marker', textContent: f.marks.length });
  marker.style.left = `${(r.x / f.points.width) * 100}%`;
  marker.style.top = `${(r.y / f.points.height) * 100}%`;
  rt.overlay.append(marker);
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

const PREVIEW_HEIGHT = 300; // px, the not-running device picture
export const MARGIN = 14; // pt around the body for buttons that slide out
const ZOOM_STEP = 1.25;

function fitScale() {
  const stage = rt.stage;
  if (!stage || !ui.chrome) return 1;
  const pad = getComputedStyle(stage);
  const width = stage.clientWidth - parseFloat(pad.paddingLeft) - parseFloat(pad.paddingRight);
  const height = stage.clientHeight - parseFloat(pad.paddingTop) - parseFloat(pad.paddingBottom);
  const info = rt.previewInfo ? rt.previewInfo.offsetHeight + 22 : 0;
  const { size } = ui.chrome;
  return Math.max(0.15, Math.min(width / (size.width + MARGIN * 2), (height - info) / (size.height + MARGIN * 2)));
}

function currentScale() {
  if (!ui.chrome) return 1;
  if (!ui.running) return Math.min(PREVIEW_HEIGHT / ui.chrome.size.height, fitScale());
  return ui.zoom === 'fit' ? fitScale() : Number(ui.zoom);
}

export function updateScale() {
  ui.scale = currentScale();
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

export async function togglePanel(name) {
  ui.panels[name] = !ui.panels[name];
  storage.set(`panel-${name}`, ui.panels[name] ? 'shown' : 'hidden');
  await tick();
  onStageResize();
}

// ---------- start ----------

export function start() {
  loadDevices();
  refresh();
  const timer = setInterval(refresh, 1500);
  return () => clearInterval(timer);
}
