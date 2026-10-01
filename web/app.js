import { hitTest, describe, nodesInRect } from '/web/ax.js';
import { sampler, warm, containersAround } from '/web/visual.js';
import { matchesFrontApp, sdkContainers, sourceFor, viewContext } from '/web/sdk.js';

const $ = (id) => document.getElementById(id);
const canvas = $('screen');
const ctx = canvas.getContext('2d');
const overlay = $('overlay');
const deviceEl = $('device-frame');

const state = {
  udid: null,
  ws: null,
  layout: null,      // baguette chrome layout (input coordinate space)
  frame: null,       // latest ImageBitmap
  frameBytes: null,  // latest JPEG bytes
  frozen: null,      // { bitmap, tree, points: {width, height}, marks: [] }
  mode: 'interact',
  pendingTree: null,
  draft: null,       // selection waiting for a comment
};

// ---------- stream ----------

function connect(udid) {
  state.ws?.close();
  state.udid = udid;
  setStatus('Connecting…');
  const ws = new WebSocket(`ws://${location.host}/ws/${encodeURIComponent(udid)}`);
  ws.binaryType = 'arraybuffer';
  state.ws = ws;
  let frames = 0;
  const fpsTimer = setInterval(() => {
    if (state.ws === ws) setStatus(state.frozen ? state.frozen.status : `${frames} fps`);
    frames = 0;
  }, 1000);

  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'snapshot' }));
    // Nudge with a harmless scroll so an idle screen still emits a frame.
    setTimeout(() => !state.frame && send({ type: 'scroll', deltaX: 0, deltaY: 0 }), 600);
  };
  ws.onmessage = async (e) => {
    if (typeof e.data === 'string') return onText(JSON.parse(e.data));
    frames++;
    const bytes = e.data;
    const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/jpeg' })).catch(() => null);
    if (!bitmap) return;
    state.frame?.close?.();
    state.frame = bitmap;
    state.frameBytes = bytes;
    if (!state.frozen) paint(bitmap);
  };
  ws.onclose = () => {
    clearInterval(fpsTimer);
    if (state.ws === ws) {
      setStatus('Disconnected');
      setTimeout(() => state.ws === ws && connect(udid), 1500);
    }
  };
}

function send(msg) {
  if (state.ws?.readyState === WebSocket.OPEN) state.ws.send(JSON.stringify(msg));
}

function paint(bitmap) {
  if (canvas.width !== bitmap.width || canvas.height !== bitmap.height) {
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    deviceEl.style.aspectRatio = `${bitmap.width} / ${bitmap.height}`;
  }
  ctx.drawImage(bitmap, 0, 0);
}

function onText(msg) {
  if (msg.type === 'describe_ui_result') {
    state.pendingTree?.(msg.ok ? msg.tree : null);
    state.pendingTree = null;
  } else if (msg.type === 'error' || msg.ok === false) {
    setStatus(msg.error || 'Error');
  }
}

function fetchTree() {
  return new Promise((resolve) => {
    state.pendingTree = resolve;
    send({ type: 'describe_ui' });
    setTimeout(() => {
      if (state.pendingTree === resolve) {
        state.pendingTree = null;
        resolve(null);
      }
    }, 4000);
  });
}

// ---------- coordinates ----------

function fraction(e) {
  const r = overlay.getBoundingClientRect();
  return {
    fx: Math.min(Math.max((e.clientX - r.left) / r.width, 0), 1),
    fy: Math.min(Math.max((e.clientY - r.top) / r.height, 0), 1),
  };
}

function inputPoint(e) {
  const { fx, fy } = fraction(e);
  const { width, height } = state.layout.screen;
  return { x: fx * width, y: fy * height, width, height };
}

// Annotation space = accessibility points.
function axPoint(e) {
  const { fx, fy } = fraction(e);
  const { width, height } = state.frozen.points;
  return { x: fx * width, y: fy * height };
}

function placeBox(el, rect) {
  const { width, height } = state.frozen.points;
  el.style.left = `${(rect.x / width) * 100}%`;
  el.style.top = `${(rect.y / height) * 100}%`;
  el.style.width = `${(rect.width / width) * 100}%`;
  el.style.height = `${(rect.height / height) * 100}%`;
}

function clearLayer(cls) {
  overlay.querySelectorAll(cls).forEach((n) => n.remove());
}

// ---------- interact mode ----------

let touching = false;

overlay.addEventListener('pointerdown', (e) => {
  overlay.focus();
  if (state.mode === 'annotate') return annotateDown(e);
  if (!state.layout) return;
  touching = true;
  overlay.setPointerCapture(e.pointerId);
  send({ type: 'touch1-down', ...inputPoint(e) });
});

overlay.addEventListener('pointermove', (e) => {
  if (state.mode === 'annotate') return annotateMove(e);
  if (touching) send({ type: 'touch1-move', ...inputPoint(e) });
});

overlay.addEventListener('pointerup', (e) => {
  if (state.mode === 'annotate') return annotateUp(e);
  if (!touching) return;
  touching = false;
  send({ type: 'touch1-up', ...inputPoint(e) });
});

overlay.addEventListener('wheel', (e) => {
  e.preventDefault();
  if (state.mode === 'interact') send({ type: 'scroll', deltaX: e.deltaX, deltaY: e.deltaY });
  else if (Math.abs(e.deltaY) > 2) changeLevel(e.deltaY < 0 ? 1 : -1);
}, { passive: false });

const KEY_CODES = new Set(['Enter', 'Backspace', 'Tab', 'Escape', 'Space', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight']);

overlay.addEventListener('keydown', (e) => {
  if (state.mode !== 'interact') return;
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
});

$('btn-home').onclick = () => send({ type: 'button', button: 'home' });
$('btn-lock').onclick = () => send({ type: 'button', button: 'lock' });

// ---------- annotate mode ----------

async function setMode(mode) {
  if (mode === state.mode) return;
  state.mode = mode;
  $('mode-interact').classList.toggle('on', mode === 'interact');
  $('mode-annotate').classList.toggle('on', mode === 'annotate');
  deviceEl.classList.toggle('annotating', mode === 'annotate');
  closeComposer();

  if (mode === 'annotate') {
    if (!state.frame) return;
    // Freeze the frame on screen right now, then fetch the accessibility tree
    // and SDK data and warm the pixel regions while those requests are out.
    const data = Promise.all([
      fetchTree(),
      fetch('/api/sdk').then((r) => (r.status === 200 ? r.json() : null)).catch(() => null),
    ]);
    const bitmap = state.frame;
    state.frame = null; // keep the frozen bitmap alive
    const scale = Math.round(bitmap.width / state.layout.screen.width); // pixels per point
    const f = (state.frozen = {
      bitmap,
      tree: null,
      sdkAvailable: null,
      points: { width: bitmap.width / scale, height: bitmap.height / scale },
      marks: [],
      status: 'Freezing…',
    });
    paint(bitmap);
    $('frozen-badge').hidden = false;
    setStatus(f.status);
    await new Promise(requestAnimationFrame); // let the frozen frame paint first
    f.pixels = sampler(bitmap, f.points.width, f.points.height);
    warm(f.pixels);

    const [tree, sdk] = await data;
    if (state.frozen !== f) return; // left annotate mode meanwhile
    f.tree = tree;
    if (tree?.frame?.width) f.points = { width: tree.frame.width, height: tree.frame.height };
    f.sdkAvailable = matchesFrontApp(sdk, tree) ? sdk : null;
    applySdk();
  } else {
    state.frozen?.bitmap.close?.();
    state.frozen = null;
    $('btn-sdk').hidden = true;
    clearLayer('.hl, .sel, .marker');
    hover = null;
    $('frozen-badge').hidden = true;
    send({ type: 'snapshot' });
  }
  overlay.focus();
}

// SDK on/off, to compare exact view data with the pixel fallback on the same frame.
let sdkEnabled = localStorageGet('sdk') !== 'off';

function applySdk() {
  const f = state.frozen;
  if (!f) return;
  f.sdk = sdkEnabled ? f.sdkAvailable : null;
  const button = $('btn-sdk');
  button.hidden = !f.sdkAvailable;
  button.classList.toggle('on', sdkEnabled);
  f.status = !f.tree ? 'Frozen (no accessibility data)' : f.sdk ? 'Frozen · SDK' : f.sdkAvailable ? 'Frozen · pixels' : 'Frozen';
  setStatus(f.status);
  // Recompute what's under the cursor with the new source.
  if (hover) {
    hover = { point: hover.point, targets: targetsAt(hover.point), level: 0 };
    highlight();
  }
}

function toggleSdk() {
  if (!state.frozen?.sdkAvailable) return;
  sdkEnabled = !sdkEnabled;
  localStorageSet('sdk', sdkEnabled ? 'on' : 'off');
  applySdk();
}

$('btn-sdk').onclick = () => {
  toggleSdk();
  overlay.focus();
};
$('mode-interact').onclick = () => setMode('interact');
$('mode-annotate').onclick = () => setMode('annotate');

let drag = null;
let hover = null; // { point, targets: [{ rect, label, node? }], level }

function annotateDown(e) {
  if (!state.frozen || state.draft) return;
  overlay.setPointerCapture(e.pointerId);
  drag = { start: axPoint(e), moved: false };
}

function annotateMove(e) {
  if (!state.frozen || state.draft) return;
  const p = axPoint(e);
  if (drag) {
    const dx = p.x - drag.start.x;
    const dy = p.y - drag.start.y;
    if (!drag.moved && Math.hypot(dx, dy) < 4) return;
    drag.moved = true;
    clearLayer('.hl');
    hover = null;
    let sel = overlay.querySelector('.sel');
    if (!sel) overlay.append((sel = Object.assign(document.createElement('div'), { className: 'sel' })));
    placeBox(sel, normalize(drag.start, p));
    return;
  }
  const targets = targetsAt(p);
  const same = hover && targets.length === hover.targets.length &&
    targets.every((t, i) => sameRect(t.rect, hover.targets[i].rect));
  hover = { point: p, targets, level: same ? hover.level : 0 };
  highlight();
}

function annotateUp(e) {
  if (!drag) return;
  const p = axPoint(e);
  const wasDrag = drag.moved;
  const start = drag.start;
  drag = null;
  if (wasDrag) {
    openComposer({ kind: 'area', rect: normalize(start, p), label: 'Area' });
    return;
  }
  const target = hover?.targets[hover.level] ?? targetsAt(p)[0];
  const rect = target ? { ...target.rect } : { x: p.x - 22, y: p.y - 22, width: 44, height: 44 };
  clearLayer('.hl');
  const sel = Object.assign(document.createElement('div'), { className: 'sel' });
  placeBox(sel, rect);
  overlay.append(sel);
  openComposer({
    kind: target?.node ? 'element' : 'area',
    rect,
    point: target?.node ? p : undefined,
    label: target?.label ?? 'Area',
  });
}

// Everything selectable under a point, innermost first: the accessibility
// element, then the cards and rows drawn around it.
function targetsAt(p) {
  const f = state.frozen;
  const hit = f.tree ? hitTest(f.tree, p.x, p.y) : null;
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
  const names = state.frozen.tree
    ? nodesInRect(state.frozen.tree, rect)
        .sort((a, b) => a.node.frame.y - b.node.frame.y || a.node.frame.x - b.node.frame.x)
        .map((e) => e.node.label?.trim())
        .filter(Boolean)
    : [];
  if (!names.length) return 'Container';
  const shown = names.slice(0, 2).map((n) => `"${n}"`).join(', ');
  return `Container: ${shown}${names.length > 2 ? ` +${names.length - 2}` : ''}`;
}

function sameRect(a, b) {
  return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
}

function changeLevel(delta) {
  if (!hover?.targets.length || state.draft) return false;
  const level = Math.min(Math.max(hover.level + delta, 0), hover.targets.length - 1);
  if (level === hover.level) return true;
  hover.level = level;
  highlight();
  return true;
}

function normalize(a, b) {
  return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(a.x - b.x), height: Math.abs(a.y - b.y) };
}

function highlight() {
  let hl = overlay.querySelector('.hl');
  const target = hover?.targets[hover.level];
  if (!target) return hl?.remove();
  if (!hl) {
    hl = Object.assign(document.createElement('div'), { className: 'hl' });
    hl.append(Object.assign(document.createElement('span'), { className: 'hl-label' }));
    overlay.append(hl);
  }
  placeBox(hl, target.rect);
  const more = hover.level < hover.targets.length - 1 ? '  ↑ parent' : '';
  hl.firstChild.textContent = target.label + more;
}

// ---------- composer ----------

const composer = $('composer');
const composerText = $('composer-text');

function openComposer(draft) {
  state.draft = draft;
  $('composer-target').textContent = draft.label;
  composerText.value = '';
  composer.hidden = false;
  const box = overlay.querySelector('.sel').getBoundingClientRect();
  const left = Math.min(box.right + 12, innerWidth - composer.offsetWidth - 12);
  const top = Math.min(Math.max(box.top, 12), innerHeight - composer.offsetHeight - 12);
  composer.style.left = `${left}px`;
  composer.style.top = `${top}px`;
  composerText.focus();
}

function closeComposer() {
  state.draft = null;
  composer.hidden = true;
  clearLayer('.sel');
}

composer.addEventListener('submit', async (e) => {
  e.preventDefault();
  const comment = composerText.value.trim();
  if (!comment || !state.draft) return;
  const draft = state.draft;
  closeComposer();
  await submit(draft, comment);
});

$('composer-cancel').onclick = () => closeComposer();

composerText.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) composer.requestSubmit();
  if (e.key === 'Escape') {
    e.stopPropagation();
    closeComposer();
    overlay.focus();
  }
});

async function submit(draft, comment) {
  const f = state.frozen;
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
    udid: state.udid,
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
  if (!res.ok) return setStatus((await res.json()).error || 'Save failed');

  f.marks.push(r);
  const marker = Object.assign(document.createElement('div'), { className: 'marker', textContent: f.marks.length });
  marker.style.left = `${(r.x / f.points.width) * 100}%`;
  marker.style.top = `${(r.y / f.points.height) * 100}%`;
  overlay.append(marker);
  refresh();
}

async function toBase64(offscreen) {
  const blob = await offscreen.convertToBlob({ type: 'image/jpeg', quality: 0.85 });
  const bytes = new Uint8Array(await blob.arrayBuffer());
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

// ---------- shortcuts ----------

document.addEventListener('keydown', (e) => {
  if (e.target === composerText) return;
  if (e.key === 'Escape' && state.mode === 'annotate') {
    e.preventDefault();
    return setMode('interact');
  }
  if (state.mode === 'annotate' && (e.key === 'ArrowUp' || e.key === 'ArrowDown')) {
    if (changeLevel(e.key === 'ArrowUp' ? 1 : -1)) e.preventDefault();
    return;
  }
  // Letter shortcuts only while not typing into the simulator.
  if (state.mode === 'interact' && document.activeElement === overlay) return;
  if (e.key === 's' && !e.metaKey && state.mode === 'annotate') toggleSdk();
  if (e.key === 'a' && !e.metaKey) setMode('annotate');
  if (e.key === 'i' && !e.metaKey) setMode('interact');
});

// ---------- sidebar ----------

async function refresh() {
  const list = await fetch('/api/annotations').then((r) => r.json()).catch(() => []);
  $('empty').hidden = list.length > 0;
  $('list').replaceChildren(...list.slice().reverse().map(renderItem));
}

function renderItem(a) {
  const li = document.createElement('li');
  li.className = 'item';
  const img = Object.assign(document.createElement('img'), { src: `/images/${a.id}-crop.jpg`, alt: '' });
  const body = document.createElement('div');
  const target = a.target ? describe(a.target) : 'Area';
  body.innerHTML = '<p class="item-comment"></p><div class="item-meta"><span class="pill"></span><span class="t"></span></div>';
  body.querySelector('.item-comment').textContent = a.comment;
  const pill = body.querySelector('.pill');
  pill.classList.add(a.status);
  pill.textContent = a.status;
  body.querySelector('.t').textContent = `${a.id} · ${target}`;
  for (const r of a.replies) addNote(body, r.from, r.message);
  if (a.resolution) addNote(body, a.status === 'dismissed' ? 'dismissed' : 'done', a.resolution);
  li.append(img, body);
  return li;
}

function addNote(parent, who, text) {
  const div = document.createElement('div');
  div.className = 'item-reply';
  div.innerHTML = '<b></b> <span></span>';
  div.querySelector('b').textContent = who;
  div.querySelector('span').textContent = text;
  parent.append(div);
}

$('btn-clear').onclick = async () => {
  await fetch('/api/annotations/finished', { method: 'DELETE' });
  refresh();
};

$('btn-copy').onclick = async () => {
  const pending = await fetch('/api/annotations?status=pending').then((r) => r.json());
  const full = await Promise.all(pending.map((a) => fetch(`/api/annotations/${a.id}`).then((r) => r.json())));
  await navigator.clipboard.writeText(full.map((a) => a.markdown).join('\n\n'));
  setStatus(`Copied ${full.length}`);
};

setInterval(refresh, 1500);

// ---------- devices ----------

function setStatus(text) {
  $('status').textContent = text;
}

async function loadDevices() {
  const sims = await fetch('/api/sims').then((r) => r.json());
  const select = $('device');
  const booted = sims.filter((s) => s.state === 'Booted');
  const saved = localStorageGet('udid');
  select.replaceChildren(
    ...sims
      .sort((a, b) => (b.state === 'Booted') - (a.state === 'Booted'))
      .map((s) => new Option(`${s.state === 'Booted' ? '● ' : ''}${s.name} (${s.runtime})`, s.udid)),
  );
  const pick = booted.find((s) => s.udid === saved) ?? booted[0] ?? sims.find((s) => s.udid === saved);
  if (pick) {
    select.value = pick.udid;
    await useDevice(pick.udid, pick.state !== 'Booted');
  } else {
    setStatus('Pick a simulator');
  }
  select.onchange = () => {
    const s = sims.find((x) => x.udid === select.value);
    useDevice(s.udid, s.state !== 'Booted');
  };
}

async function useDevice(udid, boot) {
  await setMode('interact');
  if (boot) {
    setStatus('Booting…');
    await fetch(`/api/sims/${udid}/boot`, { method: 'POST' });
  }
  localStorageSet('udid', udid);
  state.layout = await fetch(`/api/sims/${udid}/layout`).then((r) => r.json());
  state.frame = null;
  connect(udid);
}

function localStorageGet(k) {
  try { return localStorage.getItem(`sim-agentation:${k}`); } catch { return null; }
}
function localStorageSet(k, v) {
  try { localStorage.setItem(`sim-agentation:${k}`, v); } catch {}
}

loadDevices();
refresh();

// Inspect from the devtools console: simAgentation.hover()
window.simAgentation = { state, hover: () => hover };
