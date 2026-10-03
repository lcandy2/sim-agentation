import { hitTest, describe, nodesInRect } from '/web/ax.js';
import { sampler, warm, containersAround } from '/web/visual.js';
import { matchesFrontApp, sdkContainers, sourceFor, viewContext } from '/web/sdk.js';
import { icon, hydrateIcons } from '/web/icons.js';

const $ = (id) => document.getElementById(id);
const canvas = $('screen');
const ctx = canvas.getContext('2d');
const overlay = $('overlay');
const deviceEl = $('device-frame');
const bezelEl = $('bezel');

hydrateIcons();

const state = {
  udid: null,
  ws: null,
  chrome: null,      // device chrome: body, screen rect and buttons, in points
  frame: null,       // latest ImageBitmap
  frameBytes: null,  // latest JPEG bytes
  frozen: null,      // { bitmap, tree, points: {width, height}, marks: [] }
  mode: 'interact',
  running: false,    // the selected device is booted; its controls work
  live: false,       // frames are arriving
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

  ws.onopen = () => {
    ws.send(JSON.stringify({ type: 'snapshot' }));
    // Nudge with a harmless scroll so an idle screen still emits a frame.
    setTimeout(() => !state.frame && send({ type: 'scroll', deltaX: 0, deltaY: 0 }), 600);
  };
  ws.onmessage = async (e) => {
    if (typeof e.data === 'string') return onText(JSON.parse(e.data));
    const bytes = e.data;
    const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/jpeg' })).catch(() => null);
    if (!bitmap) return;
    state.frame?.close?.();
    state.frame = bitmap;
    state.frameBytes = bytes;
    if (state.frozen) return;
    if (!state.live) {
      state.live = true;
      setStatus(''); // streaming is the normal state; say nothing
    }
    paint(bitmap);
  };
  state.live = false;
  ws.onclose = () => {
    if (state.ws === ws) {
      state.live = false;
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
    }, 10000); // the host may probe for up to ~5 s, or restart a stale accessibility bridge
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
  const { width, height } = state.chrome.screen;
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
  if (!state.running) return;
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
$('btn-switcher').onclick = () => send({ type: 'button', button: 'app-switcher' });

// Saves what's on screen (the frozen frame while annotating).
$('btn-screenshot').onclick = async () => {
  const bitmap = state.frozen?.bitmap ?? state.frame;
  if (!bitmap) return;
  const out = new OffscreenCanvas(bitmap.width, bitmap.height);
  out.getContext('2d').drawImage(bitmap, 0, 0);
  const blob = await out.convertToBlob({ type: 'image/png' });
  const name = $('device-name').textContent;
  const stamp = new Date().toISOString().slice(0, 19).replace('T', ' at ').replaceAll(':', '.');
  const link = Object.assign(document.createElement('a'), { href: URL.createObjectURL(blob), download: `${name} ${stamp}.png` });
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 1000);
};

// ---------- annotate mode ----------

async function setMode(mode) {
  if (mode === state.mode) return;
  // Nothing to freeze yet: no live frame from a running device.
  if (mode === 'annotate' && (!state.frame || !state.chrome)) return;
  state.mode = mode;
  $('mode-interact').classList.toggle('on', mode === 'interact');
  $('mode-annotate').classList.toggle('on', mode === 'annotate');
  deviceEl.classList.toggle('annotating', mode === 'annotate');
  bezelEl.classList.toggle('annotating', mode === 'annotate');
  closeComposer();

  if (mode === 'annotate') {
    // Freeze the frame on screen right now, then fetch the accessibility tree
    // and SDK data and warm the pixel regions while those requests are out.
    const data = Promise.all([
      fetchTree(),
      fetch('/api/sdk').then((r) => (r.status === 200 ? r.json() : null)).catch(() => null),
    ]);
    const bitmap = state.frame;
    state.frame = null; // keep the frozen bitmap alive
    const scale = Math.round(bitmap.width / state.chrome.screen.width); // pixels per point
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
    setStatus(state.live ? '' : 'Connecting…');
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
  if (!res.ok) return setStatus((await res.json().catch(() => null))?.error || 'Save failed');
  refresh();
  if (state.frozen !== f) return; // resumed while saving: no marker on the live screen

  f.marks.push(r);
  const marker = Object.assign(document.createElement('div'), { className: 'marker', textContent: f.marks.length });
  marker.style.left = `${(r.x / f.points.width) * 100}%`;
  marker.style.top = `${(r.y / f.points.height) * 100}%`;
  overlay.append(marker);
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

let lastList = null;

async function refresh() {
  const text = await fetch('/api/annotations').then((r) => (r.ok ? r.text() : null)).catch(() => null);
  if (text === null || text === lastList) return; // unchanged: keep the DOM and thumbnails
  lastList = text;
  const list = JSON.parse(text);
  $('empty').hidden = list.length > 0;
  const open = list.filter((a) => a.status === 'pending' || a.status === 'acknowledged').length;
  $('count').textContent = open ? String(open) : '';
  $('list').replaceChildren(...list.slice().reverse().map(renderItem));
}

function renderItem(a) {
  const li = document.createElement('li');
  li.className = 'item';
  const img = Object.assign(document.createElement('img'), { src: `/images/${a.id}-crop.jpg`, alt: '' });
  const body = document.createElement('div');
  const target = a.target ? describe(a.target) : 'Area';
  body.innerHTML = '<p class="item-comment"></p><div class="item-meta"><span class="badge"></span><span class="t"></span></div>';
  body.querySelector('.item-comment').textContent = a.comment;
  const badge = body.querySelector('.badge');
  badge.classList.add(a.status);
  badge.textContent = a.status;
  body.querySelector('.t').textContent = `${a.id} · ${target}`;
  for (const r of a.replies) addNote(body, r.from, r.message);
  if (a.resolution) addNote(body, a.status === 'dismissed' ? 'dismissed' : 'done', a.resolution);
  const remove = Object.assign(document.createElement('button'), { className: 'item-delete icon-btn', title: 'Delete annotation' });
  remove.setAttribute('aria-label', `Delete annotation ${a.id}`);
  remove.innerHTML = icon('trash');
  remove.onclick = async () => {
    remove.disabled = true;
    const res = await fetch(`/api/annotations/${a.id}`, { method: 'DELETE' }).catch(() => null);
    if (!res?.ok) {
      remove.disabled = false;
      return flashStatus("Couldn't delete the annotation");
    }
    li.remove();
    refresh();
  };
  li.append(img, body, remove);
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
  flashStatus(full.length ? `Copied ${full.length} to the clipboard` : 'Nothing pending to copy');
};

setInterval(refresh, 1500);

// ---------- devices ----------

let statusText = '';
let flashTimer = null;

function setStatus(text) {
  statusText = text;
  if (!flashTimer) $('status').textContent = text;
}

// Shows a message for a moment, then goes back to the current status.
function flashStatus(text) {
  clearTimeout(flashTimer);
  $('status').textContent = text;
  flashTimer = setTimeout(() => {
    flashTimer = null;
    $('status').textContent = statusText;
  }, 2000);
}

let sims = [];
const chromes = new Map(); // udid → Promise<chrome | null>

function chromeOf(udid) {
  if (!chromes.has(udid)) {
    chromes.set(udid, fetch(`/api/sims/${udid}/chrome`).then((r) => (r.ok ? r.json() : null)).catch(() => null));
  }
  return chromes.get(udid);
}

async function loadDevices() {
  sims = await fetch('/api/sims').then((r) => (r.ok ? r.json() : [])).catch(() => []);
  const saved = localStorageGet('udid');
  const pick = sims.find((s) => s.udid === saved) ?? sims.find((s) => s.state === 'Booted') ?? sims[0];
  renderDevices();
  if (pick) await selectDevice(pick);
  else showMessage('No simulators found. Create one in Xcode first.');
}

const version = (runtime) => runtime.replace(/^\D+/, '');
const byVersionThenName = (a, b) =>
  version(b.runtime).localeCompare(version(a.runtime), undefined, { numeric: true }) || a.name.localeCompare(b.name);

function renderDevices() {
  const query = $('device-search').value.trim().toLowerCase();
  const shown = sims.filter((s) => !query || `${s.name} ${s.runtime}`.toLowerCase().includes(query));
  const sections = [
    ['Running', shown.filter((s) => s.state === 'Booted')],
    ['Available', shown.filter((s) => s.state !== 'Booted')],
  ];
  const nodes = [];
  for (const [title, list] of sections) {
    if (!list.length) continue;
    nodes.push(Object.assign(document.createElement('h3'), { textContent: title }));
    for (const sim of list.sort(byVersionThenName)) nodes.push(deviceRow(sim));
  }
  if (!nodes.length) nodes.push(Object.assign(document.createElement('p'), { className: 'none', textContent: 'No simulators match.' }));
  $('devices').replaceChildren(...nodes);
}

function deviceRow(sim) {
  const row = document.createElement('button');
  row.className = 'device-row';
  row.classList.toggle('booted', sim.state === 'Booted');
  row.classList.toggle('selected', sim.udid === state.udid);
  row.title = `${sim.name}, ${sim.runtime}`;
  row.innerHTML = `<span class="glyph">${icon('phone')}</span><span class="text"><div class="name"></div><div class="kind">Simulator</div></span><span class="version"></span>`;
  row.querySelector('.name').textContent = sim.name;
  row.querySelector('.version').textContent = version(sim.runtime);
  row.onclick = () => selectDevice(sim);
  // Swap the generic glyph for a picture of the device once its chrome loads.
  chromeOf(sim.udid)
    .then((c) => c && thumbnail(c, THUMB_HEIGHT))
    .then((url) => {
      if (url) row.querySelector('.glyph').replaceChildren(Object.assign(new Image(), { src: url, alt: '' }));
    });
  return row;
}

$('device-search').addEventListener('input', renderDevices);

function showMessage(text) {
  $('device-wrap').hidden = !!text;
  $('stage-message').hidden = !text;
  $('stage-message').textContent = text ?? '';
}

// Selecting shows the device; only a running one streams. Starting is explicit.
async function selectDevice(sim) {
  await setMode('interact');
  stopStream();
  state.udid = sim.udid;
  localStorageSet('udid', sim.udid);
  $('device-name').textContent = sim.name;
  $('device-runtime').textContent = sim.runtime;
  setStatus('');
  renderDevices();

  const chrome = await chromeOf(sim.udid);
  if (state.udid !== sim.udid) return; // picked another device meanwhile
  state.chrome = chrome;
  if (!chrome) {
    showMessage(`No device artwork for ${sim.name}.`);
    return;
  }
  showMessage(null);
  buildBezel(chrome);
  if (sim.state === 'Booted') {
    setLive(true);
    connect(sim.udid);
  } else {
    setLive(false);
    $('preview-name').textContent = sim.name;
    $('preview-sub').textContent = `${sim.runtime} Simulator`;
    $('btn-start').disabled = false;
    $('btn-start').textContent = 'Start';
  }
  applyZoom();
}

async function startDevice() {
  const sim = sims.find((s) => s.udid === state.udid);
  if (!sim) return;
  $('btn-start').disabled = true;
  $('btn-start').textContent = 'Starting…';
  const res = await fetch(`/api/sims/${sim.udid}/boot`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' }).catch(() => null);
  if (!res?.ok) {
    $('btn-start').disabled = false;
    $('btn-start').textContent = 'Start';
    flashStatus((await res?.json().catch(() => null))?.error ?? "Couldn't start the simulator");
    return;
  }
  sim.state = 'Booted';
  if (state.udid === sim.udid) await selectDevice(sim);
  else renderDevices();
}

$('btn-start').onclick = startDevice;

function stopStream() {
  const ws = state.ws;
  state.ws = null;
  state.live = false;
  state.frame = null;
  ws?.close();
}

// Live: the screen streams and the device controls work. Otherwise a preview with Start.
function setLive(live) {
  state.running = live;
  $('canvas').classList.toggle('offline', !live);
  deviceEl.classList.toggle('preview', !live);
  $('preview-info').hidden = live;
  $('canvas-bottom').hidden = !live;
  if (!live) ctx.clearRect(0, 0, canvas.width, canvas.height);
}

// ---------- bezel and zoom ----------

// Hardware buttons sit under the body. At rest they show OUTSET points; the
// chrome's rollover offset slides them further out on hover, as in Device Hub.
const OUTSET = 13; // pt, measured from Device Hub: |normal offset| 8 → 5 pt showing

function buttonFrame(b, size) {
  const { width: w, height: h } = b.size;
  const o = b.normal;
  const along = (offset, length, total) => (b.align === 'trailing' ? total + offset - length : offset);
  switch (b.anchor) {
    case 'left': return { x: o.x - OUTSET, y: along(o.y, h, size.height), w, h };
    case 'right': return { x: size.width + o.x + OUTSET - w, y: along(o.y, h, size.height), w, h };
    case 'top': return { x: along(o.x, w, size.width), y: o.y - OUTSET, w, h };
    default: return { x: along(o.x, w, size.width), y: size.height + o.y + OUTSET - h, w, h };
  }
}

function buildBezel(chrome) {
  const s = chrome.slices;
  $('bezel-art').replaceChildren(
    ...['topLeft', 'top', 'topRight', 'left', null, 'right', 'bottomLeft', 'bottom', 'bottomRight'].map((key) =>
      key ? Object.assign(new Image(), { src: s[key].url, alt: '', draggable: false }) : document.createElement('span'),
    ),
  );
  if (chrome.mask) {
    deviceEl.style.maskImage = deviceEl.style.webkitMaskImage = `url("${chrome.mask}")`;
  } else {
    deviceEl.style.maskImage = deviceEl.style.webkitMaskImage = '';
  }
  $('side-buttons').replaceChildren(...chrome.buttons.map((b) => sideButton(b, chrome)));
}

function sideButton(b, chrome) {
  const el = document.createElement('button');
  el.className = 'side-button';
  el.classList.toggle('on-top', b.onTop);
  el.title = b.name.replace('-', ' ');
  el.dataset.name = b.name;
  const img = Object.assign(new Image(), { src: b.image, alt: '', draggable: false });
  new Image().src = b.imageDown; // preload so the press swap is instant
  el.append(img);
  const rest = () => {
    el.style.transform = '';
    img.src = b.image;
  };
  const hover = () => {
    const k = currentScale();
    el.style.transform = `translate(${(b.rollover.x - b.normal.x) * k}px, ${(b.rollover.y - b.normal.y) * k}px)`;
    img.src = b.image;
  };
  let down = 0;
  el.onpointerenter = hover;
  el.onpointerleave = () => {
    down = 0;
    rest();
  };
  el.onpointerdown = (e) => {
    if (!state.running) return;
    down = performance.now();
    el.setPointerCapture(e.pointerId);
    el.style.transform = ''; // pressed in, back to the resting position
    img.src = b.imageDown;
  };
  el.onpointerup = () => {
    if (!down) return;
    const held = (performance.now() - down) / 1000;
    down = 0;
    hover();
    // Hold to long-press, like the hardware button.
    send({ type: 'button', button: b.name, ...(held > 0.4 ? { duration: held } : {}) });
  };
  return el;
}

let zoom = localStorageGet('zoom') ?? 'fit'; // 'fit' or CSS pixels per point
const PREVIEW_HEIGHT = 300; // px, the not-running device picture
const MARGIN = 14; // pt around the body for buttons that slide out

function fitScale() {
  const stage = $('stage');
  const pad = getComputedStyle(stage);
  const width = stage.clientWidth - parseFloat(pad.paddingLeft) - parseFloat(pad.paddingRight);
  const height = stage.clientHeight - parseFloat(pad.paddingTop) - parseFloat(pad.paddingBottom);
  const info = $('preview-info').hidden ? 0 : $('preview-info').offsetHeight + 22;
  const { size } = state.chrome;
  return Math.max(0.15, Math.min(width / (size.width + MARGIN * 2), (height - info) / (size.height + MARGIN * 2)));
}

function currentScale() {
  if (!state.chrome) return 1;
  if (!state.running) return Math.min(PREVIEW_HEIGHT / state.chrome.size.height, fitScale());
  return zoom === 'fit' ? fitScale() : Number(zoom);
}

function applyZoom() {
  const chrome = state.chrome;
  if (!chrome) return;
  const k = currentScale();
  const px = (n) => `${n * k}px`;
  const { size, screen, slices } = chrome;
  Object.assign(bezelEl.style, { width: px(size.width), height: px(size.height), margin: px(MARGIN) });
  Object.assign($('bezel-art').style, {
    gridTemplateColumns: `${px(slices.topLeft.width)} 1fr ${px(slices.topRight.width)}`,
    gridTemplateRows: `${px(slices.topLeft.height)} 1fr ${px(slices.bottomLeft.height)}`,
  });
  Object.assign(deviceEl.style, { left: px(screen.x), top: px(screen.y), width: px(screen.width), height: px(screen.height) });
  chrome.buttons.forEach((b, i) => {
    const f = buttonFrame(b, size);
    const el = $('side-buttons').children[i];
    Object.assign(el.style, { left: px(f.x), top: px(f.y), width: px(f.w), height: px(f.h) });
  });
  $('zoom-fit').classList.toggle('on', zoom === 'fit');
  $('zoom-actual').classList.toggle('on', zoom !== 'fit' && Number(zoom) === 1);
}

function setZoom(next) {
  if (!state.running) return;
  zoom = next === 'fit' ? 'fit' : String(Math.min(3, Math.max(0.25, Math.round(next * 100) / 100)));
  localStorageSet('zoom', zoom);
  closeComposer();
  applyZoom();
}

const ZOOM_STEP = 1.25;
$('zoom-in').onclick = () => setZoom(currentScale() * ZOOM_STEP);
$('zoom-out').onclick = () => setZoom(currentScale() / ZOOM_STEP);
$('zoom-fit').onclick = () => setZoom('fit');
$('zoom-actual').onclick = () => setZoom(1);
new ResizeObserver(() => (zoom === 'fit' || !state.running) && applyZoom()).observe($('stage'));

document.addEventListener('keydown', (e) => {
  if (!e.metaKey || e.target === composerText || e.target === $('device-search')) return;
  const actions = { '=': () => $('zoom-in').click(), '+': () => $('zoom-in').click(), '-': () => $('zoom-out').click(), 0: () => setZoom(1), 9: () => setZoom('fit') };
  if (actions[e.key]) {
    e.preventDefault();
    actions[e.key]();
  }
});

// Small device pictures for the list: nine-slice bezel with a blue screen,
// sitting in a 34 px circle with room around it, as in Device Hub.
const THUMB_HEIGHT = 20; // px
const thumbnails = new Map(); // chrome id + screen size → Promise<data URL>

function thumbnail(chrome, height) {
  const key = `${chrome.id}:${chrome.screen.width}x${chrome.screen.height}:${height}`;
  if (!thumbnails.has(key)) thumbnails.set(key, drawThumbnail(chrome, height).catch(() => null));
  return thumbnails.get(key);
}

async function drawThumbnail(chrome, height) {
  const load = (url) => fetch(url).then((r) => r.blob()).then((b) => createImageBitmap(b));
  const dpr = 3;
  const k = (height / chrome.size.height) * dpr;
  const { size, screen, slices } = chrome;
  const canvas = new OffscreenCanvas(Math.ceil(size.width * k), Math.ceil(size.height * k));
  const g = canvas.getContext('2d');
  const s = Object.fromEntries(await Promise.all(Object.entries(slices).map(async ([key, v]) => [key, await load(v.url)])));
  const L = slices.topLeft.width, T = slices.topLeft.height, R = slices.topRight.width, B = slices.bottomLeft.height;
  const W = size.width, H = size.height;
  const draw = (img, x, y, w, h) => g.drawImage(img, x * k, y * k, w * k, h * k);
  draw(s.topLeft, 0, 0, L, T);
  draw(s.top, L, 0, W - L - R, T);
  draw(s.topRight, W - R, 0, R, T);
  draw(s.left, 0, T, L, H - T - B);
  draw(s.right, W - R, T, R, H - T - B);
  draw(s.bottomLeft, 0, H - B, L, B);
  draw(s.bottom, L, H - B, W - L - R, B);
  draw(s.bottomRight, W - R, H - B, R, B);
  // Screen: gradient, cut to the device's real screen shape.
  const sc = new OffscreenCanvas(Math.ceil(screen.width * k), Math.ceil(screen.height * k));
  const sg = sc.getContext('2d');
  const grad = sg.createLinearGradient(0, 0, 0, sc.height);
  grad.addColorStop(0, '#3d8bd9');
  grad.addColorStop(1, '#62b0ef');
  sg.fillStyle = grad;
  sg.fillRect(0, 0, sc.width, sc.height);
  if (chrome.mask) {
    sg.globalCompositeOperation = 'destination-in';
    sg.drawImage(await load(chrome.mask), 0, 0, sc.width, sc.height);
  }
  g.drawImage(sc, screen.x * k, screen.y * k);
  const blob = await canvas.convertToBlob({ type: 'image/png' });
  return URL.createObjectURL(blob);
}

// ---------- panels ----------

function setPanel(name, shown) {
  $('window').classList.toggle(`no-${name}`, !shown);
  $(`toggle-${name}`).classList.toggle('on', shown);
  localStorageSet(`panel-${name}`, shown ? 'shown' : 'hidden');
  if (zoom === 'fit') requestAnimationFrame(applyZoom);
}

for (const name of ['sidebar', 'inspector']) {
  setPanel(name, localStorageGet(`panel-${name}`) !== 'hidden');
  $(`toggle-${name}`).onclick = () => setPanel(name, $('window').classList.contains(`no-${name}`));
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
