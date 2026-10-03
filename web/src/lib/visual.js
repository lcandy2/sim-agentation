// Finds visual containers (cards, rows, grouped sections) from pixels.
// SwiftUI rarely exposes stacks and backgrounds in the accessibility
// tree, so we look at the fill an element sits on instead.
//
// `warm()` splits the frame into regions of one fill colour, once per
// freeze. After that a lookup only reads the pixels around a rect, so
// hovering anywhere costs microseconds.

const TOLERANCE = 5; // max per-channel difference to count as the same fill (cards are often only ~10 levels off the page)
const RING = 3; // pt outside the rect to sample the surrounding background
const PAGE = 0.6; // a fill spanning more than this share of the screen is the page, not a container
const MIN_PIXELS = 16;

// Downscales the frame to `width`×`height` (1 pixel per point) and reads it.
export function sampler(bitmap, width, height) {
  const w = Math.round(width);
  const h = Math.round(height);
  const canvas = new OffscreenCanvas(w, h);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(bitmap, 0, 0, w, h);
  return { data: ctx.getImageData(0, 0, w, h).data, width: w, height: h, regions: null };
}

// Labels every pixel with the region of same-coloured pixels it belongs to,
// and records each region's bounding box and size. One pass over the frame.
export function warm(img) {
  if (img.regions) return img.regions;
  const { width, height, data } = img;
  const n = width * height;
  const label = new Int32Array(n).fill(-1);
  const queue = new Int32Array(n);
  const boxes = []; // minX, minY, maxX, maxY, count for each region, flat

  // Grows one region from `start`, taking every connected pixel close to its colour.
  const grow = (start) => {
    const id = boxes.length / 5;
    const k = start * 4;
    const r = data[k], g = data[k + 1], b = data[k + 2];
    let head = 0;
    let tail = 0;
    const visit = (j) => {
      if (label[j] >= 0) return;
      const q = j * 4;
      if (Math.abs(data[q] - r) <= TOLERANCE && Math.abs(data[q + 1] - g) <= TOLERANCE && Math.abs(data[q + 2] - b) <= TOLERANCE) {
        label[j] = id;
        queue[tail++] = j;
      }
    };
    label[start] = id;
    queue[tail++] = start;
    let minX = width, minY = height, maxX = -1, maxY = -1;
    while (head < tail) {
      const i = queue[head++];
      const x = i % width;
      const y = (i - x) / width;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (x + 1 < width) visit(i + 1);
      if (x > 0) visit(i - 1);
      if (y + 1 < height) visit(i + width);
      if (y > 0) visit(i - width);
    }
    boxes.push(minX, minY, maxX, maxY, tail);
  };

  // A region compares every pixel to the colour it started from, so start
  // regions inside flat areas first: JPEG edges and anti-aliasing are a few
  // levels off and would split one fill into several regions.
  const step = (a, b) =>
    Math.max(Math.abs(data[a] - data[b]), Math.abs(data[a + 1] - data[b + 1]), Math.abs(data[a + 2] - data[b + 2]));
  const flat = (i) => {
    const x = i % width;
    if (x === 0 || x === width - 1 || i < width || i >= n - width) return false;
    const k = i * 4;
    return step(k, k - 4) <= 2 && step(k, k + 4) <= 2 && step(k, k - width * 4) <= 2 && step(k, k + width * 4) <= 2;
  };
  for (let i = 0; i < n; i++) if (label[i] < 0 && flat(i)) grow(i);
  for (let i = 0; i < n; i++) if (label[i] < 0) grow(i); // edges and noise left over

  img.regions = { label, boxes };
  return img.regions;
}

// The region most of the pixels just outside `rect` belong to: the fill it sits on.
function surrounding(img, rect) {
  const { label } = warm(img);
  const { width, height } = img;
  const x0 = Math.max(0, Math.floor(rect.x - RING));
  const y0 = Math.max(0, Math.floor(rect.y - RING));
  const x1 = Math.min(width - 1, Math.ceil(rect.x + rect.width + RING));
  const y1 = Math.min(height - 1, Math.ceil(rect.y + rect.height + RING));
  const counts = new Map();
  const count = (x, y) => {
    const id = label[y * width + x];
    counts.set(id, (counts.get(id) ?? 0) + 1);
  };
  for (let x = x0; x <= x1; x++) {
    count(x, y0);
    count(x, y1);
  }
  for (let y = y0 + 1; y < y1; y++) {
    count(x0, y);
    count(x1, y);
  }
  let best = -1;
  let most = 0;
  for (const [id, n] of counts) {
    if (n > most) {
      best = id;
      most = n;
    }
  }
  return best;
}

// Bounding box of the fill that surrounds `rect`, or null when that fill
// is the page itself.
export function containerAround(img, rect) {
  const id = surrounding(img, rect);
  if (id < 0) return null;
  const { boxes } = img.regions;
  const [minX, minY, maxX, maxY, count] = boxes.slice(id * 5, id * 5 + 5);
  if (count < MIN_PIXELS) return null;
  const x = Math.min(minX, rect.x);
  const y = Math.min(minY, rect.y);
  const box = {
    x,
    y,
    width: Math.max(maxX + 1, rect.x + rect.width) - x,
    height: Math.max(maxY + 1, rect.y + rect.height) - y,
  };
  if (box.width * box.height > img.width * img.height * PAGE) return null;
  return box;
}

// Containers around a rect, innermost first.
export function containersAround(img, rect, levels = 3) {
  const out = [];
  let current = rect;
  for (let i = 0; i < levels; i++) {
    const next = containerAround(img, current);
    if (!next || next.width * next.height <= current.width * current.height * 1.05) break;
    out.push(next);
    current = next;
  }
  return out;
}

// ---------- parts inside an element ----------
// The accessibility tree often stops at a whole row or button (a Settings
// cell, a home-screen app). Its pixels don't: on its background sit an icon,
// a run of text, a chevron. These are the foreground pieces inside a rect,
// grouped the way they read: glyphs within GAP points on one line merge into
// a text run, while the wider gap between an icon and its label keeps them
// apart.

const GAP = 5; // pt between glyphs that still belong to one run
const INK = 28; // per-channel difference from the background that counts as ink

export function partsWithin(img, rect) {
  const { data, width } = img;
  const x0 = Math.max(0, Math.round(rect.x));
  const y0 = Math.max(0, Math.round(rect.y));
  const x1 = Math.min(img.width, Math.round(rect.x + rect.width));
  const y1 = Math.min(img.height, Math.round(rect.y + rect.height));
  const w = x1 - x0;
  const h = y1 - y0;
  if (w < 6 || h < 6) return [];

  // The background, interpolated from the rect's four edges, so a solid fill
  // and a wallpaper gradient both work. Ink is what stands out from it.
  const at = (x, y) => (y * width + x) * 4;
  const ink = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) {
    const ty = h > 1 ? y / (h - 1) : 0;
    const left = at(x0, y0 + y);
    const right = at(x1 - 1, y0 + y);
    for (let x = 0; x < w; x++) {
      const tx = w > 1 ? x / (w - 1) : 0;
      const top = at(x0 + x, y0);
      const bottom = at(x0 + x, y1 - 1);
      const k = at(x0 + x, y0 + y);
      let diff = 0;
      for (let c = 0; c < 3; c++) {
        const bg = ((data[left + c] * (1 - tx) + data[right + c] * tx) + (data[top + c] * (1 - ty) + data[bottom + c] * ty)) / 2;
        diff = Math.max(diff, Math.abs(data[k + c] - bg));
      }
      ink[y * w + x] = diff > INK ? 1 : 0;
    }
  }

  // Ink as 8-connected components. Along the rect's edge, thin ones are
  // separators, sparse ones spanning it are outlines, and small ones in a
  // corner are rounded corners; a solid block there (a home-screen icon as
  // wide as its button) is content.
  const seen = new Uint8Array(w * h);
  const queue = new Int32Array(w * h);
  const pieces = [];
  for (let start = 0; start < w * h; start++) {
    if (seen[start] || !ink[start]) continue;
    let head = 0;
    let tail = 0;
    queue[tail++] = start;
    seen[start] = 1;
    let minX = start % w, maxX = minX, minY = (start - minX) / w, maxY = minY;
    while (head < tail) {
      const i = queue[head++];
      const x = i % w;
      const y = (i - x) / w;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (let dy = -1; dy <= 1; dy++) {
        for (let dx = -1; dx <= 1; dx++) {
          const nx = x + dx;
          const ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          const j = ny * w + nx;
          if (seen[j] || !ink[j]) continue;
          seen[j] = 1;
          queue[tail++] = j;
        }
      }
    }
    const pw = maxX - minX + 1;
    const ph = maxY - minY + 1;
    const edgeX = minX === 0 || maxX === w - 1;
    const edgeY = minY === 0 || maxY === h - 1;
    const solid = tail / (pw * ph); // share of the box that is ink
    if (edgeX || edgeY) {
      if (pw <= 3 || ph <= 3) continue;
      if (edgeX && edgeY && pw * ph < w * h * 0.05) continue;
      if (solid < 0.2 && (pw >= w * 0.9 || ph >= h * 0.9)) continue;
    }
    pieces.push({ x: minX, y: minY, x2: maxX + 1, y2: maxY + 1, pieces: 1 });
  }

  // Merge pieces on one line within GAP of each other, and overlapping ones.
  const overlapY = (a, b) => Math.min(a.y2, b.y2) - Math.max(a.y, b.y);
  const near = (a, b) => {
    const gapX = Math.max(a.x, b.x) - Math.min(a.x2, b.x2);
    const lineUp = overlapY(a, b) >= Math.min(a.y2 - a.y, b.y2 - b.y) * 0.5;
    return (gapX <= GAP && lineUp) || (gapX <= 0 && overlapY(a, b) > 0);
  };
  let merged = true;
  while (merged) {
    merged = false;
    for (let i = 0; i < pieces.length && !merged; i++) {
      for (let j = i + 1; j < pieces.length; j++) {
        const a = pieces[i];
        const b = pieces[j];
        if (!near(a, b)) continue;
        pieces[i] = { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), x2: Math.max(a.x2, b.x2), y2: Math.max(a.y2, b.y2), pieces: a.pieces + b.pieces };
        pieces.splice(j, 1);
        merged = true;
        break;
      }
    }
  }

  return pieces
    .map((p) => {
      const part = { x: x0 + p.x, y: y0 + p.y, width: p.x2 - p.x, height: p.y2 - p.y };
      const aspect = part.width / part.height;
      // Several glyphs on a wide line read as text; a squarish block as an icon.
      part.kind = p.pieces >= 3 && aspect > 1.6 ? 'Text' : aspect > 0.55 && aspect < 1.8 && part.width >= 8 ? 'Icon' : 'Shape';
      return part;
    })
    .filter((p) => p.width * p.height < w * h * 0.85 && p.width >= 3 && p.height >= 3);
}
