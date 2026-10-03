// Liquid glass for macOS 27's controls and menus, layer for layer from the
// Figma file (macOS 27 Community: the Segmented Control, node 4370:41840,
// and the Menu, node 4370:42750), with liquid-glass-studio's shader math for
// the refraction and the light (github.com/iyinchao/liquid-glass-studio,
// src/shaders/fragment-main.glsl, the final step).
//
// Each Figma glass is a "Fill + Shadow" frame (fills blended normal, Linear
// Dodge or Luminosity over what's behind; drop shadows) under a "Glass
// Effect" frame (the Glass effect: frost, refraction, dispersion, light; and
// inner shadows blended Linear Dodge or Linear Burn). In Chromium all of it
// that lands inside the shape runs in one SVG filter on the real backdrop,
// through backdrop-filter: the frost blur, the refraction (a displacement
// map per color channel), the fills (one color matrix: over an opaque
// backdrop they are affine in its color) and the inner shadows (images
// added or taken away). The drop shadows are CSS (style.css); the Glass
// effect's light is an image over it all. Other browsers keep CSS layers.

// What the Figma file holds, per material. Its Glass effect's light (an
// intensity and an angle) has no published formula: glares stand in for it,
// two of the shader's, fitted to Figma's renders over everything else here
// (to 1.2 and 1.7 levels of 255 on average, control and menu).
export const MATERIALS = {
  control: {
    selector: '.pill, .search',
    glass: { frost: 6, refraction: 0.7, depth: 30, dispersion: 0.2, lightAngle: 0, lightIntensity: 0.25 },
    fills: [
      { blend: 'normal', gray: 0, opacity: 0.25 },
      { blend: 'normal', gray: 1, opacity: 0.25 },
      { blend: 'dodge', gray: 0.2667, opacity: 0.6 },
      { blend: 'luminosity', gray: 0.9725, opacity: 0.2 },
    ],
    inner: [
      { blend: 'burn', gray: 0.902, y: 40, blur: 30, spread: -40 },
      { blend: 'dodge', gray: 0.1569, y: -40, blur: 10, spread: -40 },
      { blend: 'dodge', gray: 0.1569, y: 40, blur: 10, spread: -40 },
    ],
    glares: [
      { angle: 0, range: 32.4, hardness: 0.054, factor: 0.721, convergence: 0.282, opposite: 0.957 },
      { angle: Math.PI, range: 31.8, hardness: 0.197, factor: 0.279, convergence: 0.46, opposite: 0.322 },
    ],
  },
  // Popovers (the composer): white at 70% under #bfbfbf at 10% (Lighten
  // and Darken, which over this light a glass come to plain mixes), bright
  // 1 pt rims inside top and bottom (Linear and Color Dodge, here both
  // added), the Glass effect at frost 26, depth 40, light 0.15. Its light
  // stands in with the menu's fitted glares, the nearest measured.
  popover: {
    selector: '.composer',
    glass: { frost: 26, refraction: 0.7, depth: 40, dispersion: 0.2, lightAngle: 0, lightIntensity: 0.15 },
    fills: [
      { blend: 'normal', gray: 1, opacity: 0.7 },
      { blend: 'normal', gray: 0.749, opacity: 0.1 },
    ],
    inner: [
      { blend: 'dodge', gray: 0.2, y: 1, blur: 1, spread: 0 },
      { blend: 'dodge', gray: 0.2, y: -1, blur: 1, spread: 0 },
    ],
    glares: [
      { angle: 0, range: 18.4, hardness: 0, factor: 0.24, convergence: 0.236, opposite: 0.793 },
      { angle: Math.PI, range: 25.3, hardness: 0.107, factor: 0.092, convergence: 0.348, opposite: 0.541 },
    ],
  },
  // Notifications (the screenshot banner, the Device Hub notice): #bfbfbf at
  // 25% Lightening what's behind, #1a1a1a added on top (Linear Dodge),
  // bright rims inside top and bottom, frost 25, depth 30, light 0.25 (the
  // control's, so its fitted glares). Over the device's darker content its
  // text needs more body than Figma's: a white tint at 30% on top.
  notice: {
    selector: '.notice',
    glass: { frost: 25, refraction: 0.7, depth: 30, dispersion: 0.2, lightAngle: 0, lightIntensity: 0.25 },
    fills: [
      { blend: 'lighten', gray: 0.749, opacity: 0.25 },
      { blend: 'dodge', gray: 0.102, opacity: 1 },
      { blend: 'normal', gray: 1, opacity: 0.3 },
    ],
    inner: [
      { blend: 'dodge', gray: 0.1569, y: -40, blur: 5, spread: -40 },
      { blend: 'dodge', gray: 0.1569, y: 40, blur: 5, spread: -40 },
    ],
    glares: [
      { angle: 0, range: 32.4, hardness: 0.054, factor: 0.721, convergence: 0.282, opposite: 0.957 },
      { angle: Math.PI, range: 31.8, hardness: 0.197, factor: 0.279, convergence: 0.46, opposite: 0.322 },
    ],
  },
  menu: {
    selector: '.popover',
    glass: { frost: 25, refraction: 0.7, depth: 40, dispersion: 0.4, lightAngle: 0, lightIntensity: 0.2 },
    fills: [
      { blend: 'luminosity', gray: 0.85, opacity: 0.55 },
      { blend: 'normal', gray: 0.851, opacity: 0.4 },
    ],
    inner: [
      { blend: 'dodge', gray: 0.15, y: 0, blur: 0, spread: 0.5 },
      { blend: 'dodge', gray: 0.05, y: -40, blur: 10, spread: -40 },
      { blend: 'dodge', gray: 0.051, y: 40, blur: 10, spread: -40 },
    ],
    glares: [
      { angle: 0, range: 18.4, hardness: 0, factor: 0.24, convergence: 0.236, opposite: 0.793 },
      { angle: Math.PI, range: 25.3, hardness: 0.107, factor: 0.092, convergence: 0.348, opposite: 0.541 },
    ],
  },
};

// The shader's optics, shared: how far the edge shifts what's behind.
const REACH = 12.6; // CSS px at the very edge: 35% of a control's 36
const ROUNDNESS = 2; // round corners and ends

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const asinSafe = (x) => Math.asin(Math.max(-1, Math.min(1, x)));

// The fills as one affine color transform of the backdrop, for
// feColorMatrix: normal mixes toward the gray, Linear Dodge adds it,
// Luminosity moves the color's luminance toward the gray's, keeping its hue.
const LUMA = [0.3, 0.59, 0.11]; // the blend modes' luminance
export function fillMatrix(fills) {
  let M = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];
  let b = [0, 0, 0];
  for (const { blend, gray, opacity: a } of fills) {
    if (blend === 'normal') {
      M = M.map((row) => row.map((v) => v * (1 - a)));
      b = b.map((v) => v * (1 - a) + a * gray);
    } else if (blend === 'dodge') {
      b = b.map((v) => v + a * gray);
    } else if (blend === 'luminosity') {
      const lum = [0, 1, 2].map((j) => LUMA[0] * M[0][j] + LUMA[1] * M[1][j] + LUMA[2] * M[2][j]);
      const lumB = LUMA[0] * b[0] + LUMA[1] * b[1] + LUMA[2] * b[2];
      M = M.map((row) => row.map((v, j) => v - a * lum[j]));
      b = b.map((v) => v + a * (gray - lumB));
    }
  }
  const f = (v) => +v.toFixed(5);
  return [...M.map((row, i) => [...row.map(f), 0, f(b[i])]), [0, 0, 0, 1, 0]].map((r) => r.join(' ')).join('  ');
}

// The shader's rounded rect with superellipse corners.
function shapeSDF(x, y, w, h, r, n) {
  const dx = Math.abs(x) - w / 2;
  const dy = Math.abs(y) - h / 2;
  if (dx > -r && dy > -r) {
    const cx = Math.abs(x) - (w / 2 - r);
    const cy = Math.abs(y) - (h / 2 - r);
    return (Math.abs(cx) ** n + Math.abs(cy) ** n) ** (1 / n) - r;
  }
  return Math.min(Math.max(dx, dy), 0) + Math.hypot(Math.max(dx, 0), Math.max(dy, 0));
}

// A popover's pointer: Figma's Cartouche, 10.5 by 46, pointing right with its
// base on x = 0. A popover's box takes it in on one side, and its outline
// is the body and the pointer as one, as Figma draws them.
const POINTER_PATH = 'M10.5 23C10.5 21.65 10.2 20.4 8.81 19.07L5.5 15.76 2.85 13.11C1.92 12.17.94 11.15.5 10.03.06 8.9 0 7.78 0 5.28V0 46 40.72C0 38.22.06 37.1.5 35.97.94 34.84 1.92 33.83 2.85 32.89L5.5 30.24 8.81 26.93C10.19 25.6 10.5 24.35 10.5 23Z';
export const POINTER = { depth: 10.5, span: 46 };

// The pointer with its base at x = base, centered at y, pointing out of that side.
function pointerPath(side, base, y) {
  let command = '';
  let pair = 0;
  return POINTER_PATH.replace(/[MCLVZ]|-?(?:\d+\.?\d*|\.\d+)/g, (t) => {
    if (/[A-Z]/.test(t)) { command = t; pair = 0; return t; }
    const v = Number(t);
    const isY = command === 'V' || pair++ % 2 === 1;
    const out = isY ? v + y - POINTER.span / 2 : side === 'left' ? base - v : base + v;
    return ` ${+out.toFixed(3)}`;
  });
}
const roundedRect = (x, w, h, r) => `M${x + r} 0H${x + w - r}A${r} ${r} 0 0 1 ${x + w} ${r}V${h - r}A${r} ${r} 0 0 1 ${x + w - r} ${h}H${x + r}A${r} ${r} 0 0 1 ${x} ${h - r}V${r}A${r} ${r} 0 0 1 ${x + r} 0Z`;

/** A glass's outline in CSS px, for a box w by h with corners r and maybe a
 *  pointer ({ side: 'left' | 'right', y }), which the box's width includes. */
export function outlinePath(w, h, r, pointer) {
  if (!pointer) return roundedRect(0, w, h, r);
  const body = w - POINTER.depth;
  const x = pointer.side === 'left' ? POINTER.depth : 0;
  return roundedRect(x, body, h, r) + pointerPath(pointer.side, pointer.side === 'left' ? POINTER.depth : body, pointer.y);
}

// Distance from each pixel inside a mask to the nearest pixel outside it, in
// px (Felzenszwalb and Huttenlocher's exact transform, squared, rows then
// columns), on a grid padded by one outside pixel all round.
function distanceInside(alpha, W, H) {
  const GW = W + 2;
  const GH = H + 2;
  const BIG = 1e12;
  const grid = new Float64Array(GW * GH);
  for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) grid[(j + 1) * GW + i + 1] = alpha[(j * W + i) * 4 + 3] >= 128 ? BIG : 0;
  const n = Math.max(GW, GH);
  const f = new Float64Array(n), d = new Float64Array(n), v = new Int32Array(n), z = new Float64Array(n + 1);
  const pass = (len) => {
    let k = 0;
    v[0] = 0; z[0] = -Infinity; z[1] = Infinity;
    for (let q = 1; q < len; q++) {
      let s;
      while ((s = (f[q] + q * q - (f[v[k]] + v[k] * v[k])) / (2 * q - 2 * v[k])) <= z[k]) k--;
      k++; v[k] = q; z[k] = s; z[k + 1] = Infinity;
    }
    k = 0;
    for (let q = 0; q < len; q++) { while (z[k + 1] < q) k++; d[q] = (q - v[k]) ** 2 + f[v[k]]; }
  };
  for (let x = 0; x < GW; x++) { for (let y = 0; y < GH; y++) f[y] = grid[y * GW + x]; pass(GH); for (let y = 0; y < GH; y++) grid[y * GW + x] = d[y]; }
  for (let y = 0; y < GH; y++) { for (let x = 0; x < GW; x++) f[x] = grid[y * GW + x]; pass(GW); for (let x = 0; x < GW; x++) grid[y * GW + x] = Math.sqrt(d[x]); }
  return (i, j) => grid[(j + 1) * GW + i + 1];
}

// An inner shadow's strength (0..1) per pixel, drawn the way Figma and CSS
// draw one: a frame around the spread hole, shadowed into the shape. With a
// pointer the hole takes it in too, as Figma's outline does, so no rim runs
// across the pointer's base.
function innerShadow(W, H, r, dpr, { y, blur, spread }, pointer) {
  const canvas = new OffscreenCanvas(W, H);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  const s = -spread * dpr;
  const far = Math.abs(s) * 4 + Math.abs(y * dpr) + blur * dpr * 2 + W + H;
  if (pointer) {
    const outline = new Path2D();
    outline.addPath(new Path2D(outlinePath(W / dpr, H / dpr, r / dpr, pointer)), new DOMMatrix([dpr, 0, 0, dpr, 0, 0]));
    ctx.clip(outline);
  } else {
    ctx.beginPath();
    ctx.roundRect(0, 0, W, H, r);
    ctx.clip();
  }
  ctx.shadowColor = '#fff';
  ctx.shadowBlur = blur * dpr;
  ctx.shadowOffsetY = y * dpr;
  const frame = new Path2D();
  frame.rect(-far, -far, W + 2 * far, H + 2 * far);
  if (pointer) frame.addPath(new Path2D(outlinePath(W / dpr, H / dpr, r / dpr, pointer)), new DOMMatrix([dpr, 0, 0, dpr, 0, 0]));
  else frame.roundRect(-s, -s, W + 2 * s, H + 2 * s, Math.max(0, r + s));
  ctx.fillStyle = '#fff';
  ctx.fill(frame, 'evenodd');
  const alpha = ctx.getImageData(0, 0, W, H).data;
  return (o) => alpha[o + 3] / 255;
}

/** One shape at dpr: { light, map, add, burn }. light is the Glass effect's
 *  light as RGBA; map holds the refraction shift (R → x, G → y, 128 = none)
 *  for feDisplacementMap at scale 2 × REACH, in CSS px; add and burn are the
 *  inner shadows, opaque, to add (Linear Dodge) and to burn in (Linear Burn:
 *  white is none). */
export function renderGlass(width, height, radius, dpr, dark, material, pointer = null) {
  const W = Math.round(width * dpr);
  const H = Math.round(height * dpr);
  const r = Math.min(radius, width / 2, height / 2) * dpr;
  const { glass } = material;
  const refFactor = 1 + glass.refraction; // index of refraction, 1 = none
  const light = new ImageData(W, H);
  const map = new ImageData(W, H);
  const add = new ImageData(W, H);
  const burn = new ImageData(W, H);
  const inner = dark ? [] : material.inner.map((s) => ({ ...s, at: innerShadow(W, H, r, dpr, s, pointer) }));
  let sdf = (x, y) => shapeSDF(x - W / 2, y - H / 2, W, H, r, ROUNDNESS);
  let cover = null;
  if (pointer) {
    // With a pointer the outline isn't a rounded rect: its edge distances
    // come from a distance transform of it, its coverage from drawing it.
    const canvas = new OffscreenCanvas(W, H);
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    const outline = new Path2D();
    outline.addPath(new Path2D(outlinePath(width, height, r / dpr, pointer)), new DOMMatrix([dpr, 0, 0, dpr, 0, 0]));
    ctx.fill(outline);
    const alpha = ctx.getImageData(0, 0, W, H).data;
    const dist = distanceInside(alpha, W, H);
    const at = (i, j) => (i < 0 || j < 0 || i >= W || j >= H ? 0 : dist(i, j));
    sdf = (x, y) => 0.5 - at(Math.floor(x), Math.floor(y));
    cover = (i, j) => alpha[(j * W + i) * 4 + 3] / 255;
  }

  for (let j = 0; j < H; j++) {
    for (let i = 0; i < W; i++) {
      const o = (j * W + i) * 4;
      map.data[o] = map.data[o + 1] = 128;
      map.data[o + 3] = add.data[o + 3] = burn.data[o + 3] = 255;
      burn.data[o] = burn.data[o + 1] = burn.data[o + 2] = 255;

      // Inner shadows: Linear Dodge adds the shadow's color, Linear Burn takes
      // away what its color lacks of white.
      let plus = 0;
      let minus = 0;
      for (const s of inner) {
        const k = s.at(o);
        if (s.blend === 'dodge') plus += s.gray * k;
        else minus += (1 - s.gray) * k;
      }
      add.data[o] = add.data[o + 1] = add.data[o + 2] = Math.round(clamp01(plus) * 255);
      burn.data[o] = burn.data[o + 1] = burn.data[o + 2] = Math.round((1 - clamp01(minus)) * 255);

      const x = i + 0.5;
      const y = j + 0.5;
      const d = sdf(x, y);                 // device px, negative inside
      const coverage = cover ? cover(i, j) : clamp01(0.5 - d); // one-pixel antialiased edge
      if (coverage <= 0) continue;
      const inset = Math.max(0, -d) / dpr; // CSS px from the edge
      const step = cover ? 1 : 0.5; // a distance transform changes per whole pixel
      let nx = sdf(x + step, y) - sdf(x - step, y);
      let ny = sdf(x, y + step) - sdf(x, y - step); // y down
      const len = Math.hypot(nx, ny) || 1;
      nx /= len;
      ny /= len;

      // Refraction: the shader's edge factor across the depth, sampling
      // inward along the normal.
      if (inset < glass.depth) {
        const thetaI = asinSafe((1 - inset / glass.depth) ** 2);
        const thetaT = asinSafe(Math.sin(thetaI) / refFactor);
        const shift = -Math.tan(thetaT - thetaI) * REACH;
        map.data[o] = Math.round(128 + (-nx * shift / (2 * REACH)) * 255);
        map.data[o + 1] = Math.round(128 + (-ny * shift / (2 * REACH)) * 255);
      }

      // The Glass effect's light: the shader's glares, white.
      let theta = Math.atan2(-ny, nx); // y up, as in GL
      if (theta < 0) theta += 2 * Math.PI;
      let clear = 1;
      for (const G of material.glares) {
        const geo = clamp01((1 - inset * (500 / G.range) ** 2 / 1500 + G.hardness) ** 5);
        if (geo <= 0) continue;
        const angle = (theta - Math.PI / 4 + G.angle + (glass.lightAngle * Math.PI) / 180) * 2;
        const far = (angle > Math.PI * 1.5 && angle < Math.PI * 3.5) || angle < -Math.PI * 0.5;
        const factor = (0.5 + Math.sin(angle) * 0.5) * (far ? 1.2 * G.opposite : 1.2) * G.factor;
        clear *= 1 - clamp01(Math.max(factor, 0) ** (0.1 + G.convergence * 2)) * geo;
      }
      const g = (1 - clear) * coverage;
      if (g > 0) {
        light.data[o] = light.data[o + 1] = light.data[o + 2] = 255;
        light.data[o + 3] = Math.round(g * 255);
      }
    }
  }
  return { light, map, add, burn };
}

const pngOf = (data) => {
  const canvas = new OffscreenCanvas(data.width, data.height);
  canvas.getContext('2d').putImageData(data, 0, 0);
  return canvas.convertToBlob({ type: 'image/png' });
};
// SVG filters load their images by data URL.
const dataURLOf = async (data) => {
  const blob = await pngOf(data);
  return new Promise((done) => {
    const reader = new FileReader();
    reader.onload = () => done(reader.result);
    reader.readAsDataURL(blob);
  });
};

// Chromium runs SVG filters in backdrop-filter; elsewhere url() there would
// drop the blur too, so it only goes on in Chromium.
const refracts = typeof navigator !== 'undefined' && !!navigator.userAgentData?.brands?.some((b) => /Chromium/.test(b.brand));
let defs = null;
let filters = 0;
const glasses = new Map(); // material + size + scheme → Promise<{ lightURL, filter }>

// The shader's dispersion: red, green and blue bend by 1 ∓ 0.02 × its
// refDispersion (Figma's dispersion × 100) of the shift, each taken from its
// own displacement and added back up.
const channels = (dispersion) => [
  ['R', 1 + 2 * dispersion, '1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0'],
  ['G', 1, '0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0'],
  ['B', 1 - 2 * dispersion, '0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0'],
];

// The fills as filter steps on the backdrop, ending in "filled": runs of
// affine fills fold into one color matrix; Lighten (each channel's max with
// its gray, mixed in by its opacity) is a table transfer and a mix.
function fillSteps(fills, input) {
  let out = '';
  let from = input;
  let n = 0;
  let run = [];
  const step = () => (n += 1, `fill${n}`);
  const flush = () => {
    if (!run.length) return;
    const to = step();
    out += `<feColorMatrix in="${from}" values="${fillMatrix(run)}" result="${to}"/>`;
    from = to;
    run = [];
  };
  for (const fill of fills) {
    if (fill.blend !== 'lighten') { run.push(fill); continue; }
    flush();
    const lit = step();
    const table = Array.from({ length: 129 }, (_, k) => Math.max(k / 128, fill.gray).toFixed(4)).join(' ');
    out += `<feComponentTransfer in="${from}" result="${lit}">${['R', 'G', 'B'].map((c) => `<feFunc${c} type="table" tableValues="${table}"/>`).join('')}</feComponentTransfer>`;
    const to = step();
    out += `<feComposite in="${lit}" in2="${from}" operator="arithmetic" k2="${fill.opacity}" k3="${1 - fill.opacity}" result="${to}"/>`;
    from = to;
  }
  flush();
  return out + `<feMerge result="filled"><feMergeNode in="${from}"/></feMerge>`;
}

function filterFor(material, urls, width, height) {
  if (!defs) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('aria-hidden', 'true');
    svg.style.cssText = 'position:absolute;width:0;height:0';
    defs = document.createElementNS(svg.namespaceURI, 'defs');
    svg.append(defs);
    document.body.append(svg);
  }
  const id = `liquid-glass-${++filters}`;
  const image = (href, result) => `<feImage href="${href}" x="0" y="0" width="${width}" height="${height}" preserveAspectRatio="none" result="${result}"/>`;
  const bend = channels(material.glass.dispersion).map(([c, k, matrix]) => `
      <feDisplacementMap in="SourceGraphic" in2="map" scale="${2 * REACH * k}" xChannelSelector="R" yChannelSelector="G"/>
      <feColorMatrix values="${matrix}" result="${c}"/>`).join('');
  defs.insertAdjacentHTML('beforeend', `
    <filter id="${id}" x="0" y="0" width="${width}" height="${height}" filterUnits="userSpaceOnUse" primitiveUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      ${image(urls.map, 'map')}${bend}
      <feComposite in="R" in2="G" operator="arithmetic" k2="1" k3="1" result="RG"/>
      <feComposite in="RG" in2="B" operator="arithmetic" k2="1" k3="1" result="bent"/>
      ${fillSteps(material.fills, 'bent')}
      ${image(urls.add, 'add')}
      <feComposite in="filled" in2="add" operator="arithmetic" k2="1" k3="1" result="lit"/>
      ${image(urls.burn, 'burn')}
      <feComposite in="lit" in2="burn" operator="arithmetic" k2="1" k3="1" k4="-1"/>
    </filter>`);
  return id;
}

function glassFor(name, width, height, radius, dpr, dark, pointer) {
  const key = `${name}:${width}x${height}r${radius}@${dpr}:${dark}:${pointer ? `${pointer.side}${pointer.y}` : ''}`;
  if (!glasses.has(key)) {
    glasses.set(key, (async () => {
      const material = MATERIALS[name];
      const { light, map, add, burn } = renderGlass(width, height, radius, dpr, dark, material, pointer);
      const lightURL = URL.createObjectURL(await pngOf(light));
      const filter = refracts && !dark
        ? filterFor(material, { map: await dataURLOf(map), add: await dataURLOf(add), burn: await dataURLOf(burn) }, width, height)
        : null;
      return { lightURL, filter };
    })());
  }
  return glasses.get(key);
}

// ---------- applying it ----------

async function paint(el, name) {
  const { offsetWidth: w, offsetHeight: h } = el;
  if (!w || !h) return;
  const dark = matchMedia('(prefers-color-scheme: dark)').matches;
  const radius = parseFloat(getComputedStyle(el).borderTopLeftRadius) || h / 2;
  // data-pointer="left 64": a popover's pointer, on that edge, centered 64 px down.
  const [side, at] = (el.dataset.pointer ?? '').split(' ');
  const pointer = side ? { side, y: Math.round(Number(at)) } : null;
  const { lightURL, filter } = await glassFor(name, w, h, radius, devicePixelRatio || 1, dark, pointer);
  el.style.setProperty('--glass-light', `url("${lightURL}")`);
  // Figma's frost radius as a CSS blur, which takes half: then the filter.
  const backdrop = `blur(${MATERIALS[name].glass.frost / 2}px)${filter ? ` url(#${filter})` : ''}`;
  el.style.setProperty('-webkit-backdrop-filter', backdrop);
  el.style.setProperty('backdrop-filter', backdrop);
  el.classList.add('glass-on');
  el.classList.toggle('glass-filtered', !!filter);
}

/** Paints every control and menu under root and keeps them painted as they come, go and resize. */
export function attachGlass(root = document.body) {
  const names = new WeakMap();
  const sizes = new ResizeObserver((entries) => entries.forEach((e) => paint(e.target, names.get(e.target))));
  const watch = (el, name) => { names.set(el, name); sizes.observe(el); paint(el, name); };
  const each = (node, fn) => {
    for (const [name, { selector }] of Object.entries(MATERIALS)) {
      if (node.matches?.(selector)) fn(node, name);
      node.querySelectorAll?.(selector).forEach((el) => fn(el, name));
    }
  };
  each(root, watch);
  new MutationObserver((records) => {
    for (const r of records) {
      if (r.type === 'attributes') { if (names.has(r.target)) paint(r.target, names.get(r.target)); continue; }
      for (const n of r.addedNodes) if (n.nodeType === 1) each(n, watch);
    }
  }).observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-pointer'] });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => each(root, paint));
}
