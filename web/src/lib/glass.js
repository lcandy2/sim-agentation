// Liquid glass for the toolbar capsules: the Glass Effect layer of macOS 27's
// Segmented Control (Figma, macOS 27 Community, node 4370:41840), rendered
// with liquid-glass-studio's shader math (github.com/iyinchao/liquid-glass-
// studio, src/shaders/fragment-main.glsl, the final step).
//
// The capsule's Fill + Shadow layers are plain CSS (style.css, .pill). This
// adds the Glass Effect over them, computed per pixel once per size:
// - Refraction and dispersion: the shader bends what's behind the glass near
//   its edge (Snell's law across the depth, along the shape's normal), each
//   color channel by its own index. Here that becomes a displacement map in
//   an SVG filter, run on the real backdrop through backdrop-filter after
//   the frost blur. Chromium runs SVG filters there; other browsers keep the
//   blur alone.
// - Light: Figma's inner shadow (#e6e6e6, 0 40 30 -40, inset) under the
//   shader's glare, as a see-through image.

// Figma's Liquid Glass variables for the control.
const FIGMA = { depth: 30, refraction: 70, dispersion: 20, frost: 6, lightAngle: 0 };

export const PARAMS = {
  roundness: 2,                              // Figma's radius 1000: round ends
  refThickness: FIGMA.depth,                 // px from the edge that bend
  refFactor: 1 + FIGMA.refraction / 100,     // index of refraction, 1 = none
  refReach: 0.35,                            // edge shift: 35% of the capsule's height
  dispersion: FIGMA.dispersion,              // the shader's refDispersion
  blur: FIGMA.frost / 2,                     // CSS px; Figma's blurs are radii, CSS takes half
  // Figma's light at 0°, as two of the shader's glares fitted to Figma's
  // render of the control (to within 2 levels of 255 on average): a thin rim
  // lit from the light, and a wide glow on the far edge, where the light
  // comes out of the glass.
  glares: [
    { angle: 0, range: 28, hardness: 0.05, factor: 0.71, convergence: 0.34, opposite: 0.81 },
    { angle: Math.PI, range: 48, hardness: 0.24, factor: 0.9, convergence: 0.48, opposite: 0.36 },
  ].map((g) => ({ ...g, angle: g.angle + (FIGMA.lightAngle * Math.PI) / 180 })),
};
// Figma's inner shadow for the Glass Effect: color, y offset, blur, spread.
const INNER = { color: '#e6e6e6', y: 40, blur: 30, spread: -40 };

const clamp01 = (v) => Math.min(1, Math.max(0, v));
const asinSafe = (x) => Math.asin(Math.max(-1, Math.min(1, x)));

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

// Figma's inner shadow, drawn the way CSS draws an inset box-shadow: a frame
// around the spread hole, shadowed into the shape.
function innerShadow(ctx, W, H, r, dpr) {
  const s = -INNER.spread * dpr;
  ctx.save();
  ctx.beginPath();
  ctx.roundRect(0, 0, W, H, r);
  ctx.clip();
  ctx.shadowColor = INNER.color;
  ctx.shadowBlur = INNER.blur * dpr;
  ctx.shadowOffsetY = INNER.y * dpr;
  ctx.beginPath();
  ctx.rect(-W - 4 * s, -H - 4 * s, 3 * W + 8 * s, 3 * H + 8 * s);
  ctx.roundRect(-s, -s, W + 2 * s, H + 2 * s, r + s);
  ctx.fillStyle = INNER.color;
  ctx.fill('evenodd');
  ctx.restore();
}

/** One capsule at dpr: { light, map, reach }. light is the Glass Effect's
 *  light as RGBA; map holds the refraction shift (R → x, G → y, 128 = none)
 *  for feDisplacementMap at scale 2 × reach, in CSS px. */
export function renderGlass(width, height, radius, dpr, dark, params = PARAMS) {
  const W = Math.round(width * dpr);
  const H = Math.round(height * dpr);
  const r = Math.min(radius, width / 2, height / 2) * dpr;
  const P = params;
  const canvas = new OffscreenCanvas(W, H);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  if (!dark) innerShadow(ctx, W, H, r, dpr); // a light-mode layer; dark has none in the design
  const light = ctx.getImageData(0, 0, W, H);
  const map = new ImageData(W, H);
  const reach = P.refReach * Math.min(width, height);
  const sdf = (x, y) => shapeSDF(x - W / 2, y - H / 2, W, H, r, P.roundness);

  for (let j = 0; j < H; j++) {
    for (let i = 0; i < W; i++) {
      const o = (j * W + i) * 4;
      map.data[o] = map.data[o + 1] = 128;
      map.data[o + 2] = 0;
      map.data[o + 3] = 255;
      const x = i + 0.5;
      const y = j + 0.5;
      const d = sdf(x, y);                 // device px, negative inside
      const coverage = clamp01(0.5 - d);   // one-pixel antialiased edge
      if (coverage <= 0) continue;
      const inset = Math.max(0, -d) / dpr; // CSS px from the edge
      let nx = sdf(x + 0.5, y) - sdf(x - 0.5, y);
      let ny = sdf(x, y + 0.5) - sdf(x, y - 0.5); // y down
      const len = Math.hypot(nx, ny) || 1;
      nx /= len;
      ny /= len;

      // Refraction: the shader's edge factor, sampling inward along the normal.
      if (inset < P.refThickness) {
        const thetaI = asinSafe((1 - inset / P.refThickness) ** 2);
        const thetaT = asinSafe(Math.sin(thetaI) / P.refFactor);
        const shift = -Math.tan(thetaT - thetaI) * reach;
        map.data[o] = Math.round(128 + (-nx * shift / (2 * reach)) * 255);
        map.data[o + 1] = Math.round(128 + (-ny * shift / (2 * reach)) * 255);
      }

      // Glares, white, over the inner shadow (source-over, straight alpha).
      let theta = Math.atan2(-ny, nx); // y up, as in GL
      if (theta < 0) theta += 2 * Math.PI;
      let clear = 1;
      for (const G of P.glares) {
        const geo = clamp01((1 - inset * (500 / G.range) ** 2 / 1500 + G.hardness) ** 5);
        if (geo <= 0) continue;
        const angle = (theta - Math.PI / 4 + G.angle) * 2;
        const far = (angle > Math.PI * 1.5 && angle < Math.PI * 3.5) || angle < -Math.PI * 0.5;
        const factor = (0.5 + Math.sin(angle) * 0.5) * (far ? 1.2 * G.opposite : 1.2) * G.factor;
        clear *= 1 - clamp01(Math.max(factor, 0) ** (0.1 + G.convergence * 2)) * geo;
      }
      const g = (1 - clear) * coverage;
      if (g <= 0) continue;
      const a0 = light.data[o + 3] / 255;
      const a = g + a0 * (1 - g);
      for (let c = 0; c < 3; c++) light.data[o + c] = Math.round((255 * g + light.data[o + c] * a0 * (1 - g)) / a);
      light.data[o + 3] = Math.round(a * 255);
    }
  }
  return { light, map, reach };
}

const pngOf = (data) => {
  const canvas = new OffscreenCanvas(data.width, data.height);
  canvas.getContext('2d').putImageData(data, 0, 0);
  return canvas.convertToBlob({ type: 'image/png' });
};
// SVG filters load their images by data URL.
const dataURLOf = (blob) => new Promise((done) => {
  const reader = new FileReader();
  reader.onload = () => done(reader.result);
  reader.readAsDataURL(blob);
});

// Chromium runs SVG filters in backdrop-filter; elsewhere url() there would
// drop the blur too, so it only goes on in Chromium.
const refracts = typeof navigator !== 'undefined' && !!navigator.userAgentData?.brands?.some((b) => /Chromium/.test(b.brand));
let defs = null;
let filters = 0;
const glasses = new Map(); // size + scheme → Promise<{ lightURL, filter }>

// The shader's dispersion: red, green and blue bend by 1 ∓ 0.02 × dispersion
// of the shift, each taken from its own displacement and added back up.
const CHANNELS = [
  ['R', 1 + 0.02 * PARAMS.dispersion, '1 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 1 0'],
  ['G', 1, '0 0 0 0 0  0 1 0 0 0  0 0 0 0 0  0 0 0 1 0'],
  ['B', 1 - 0.02 * PARAMS.dispersion, '0 0 0 0 0  0 0 0 0 0  0 0 1 0 0  0 0 0 1 0'],
];

function filterFor(mapURL, width, height, reach) {
  if (!defs) {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('aria-hidden', 'true');
    svg.style.cssText = 'position:absolute;width:0;height:0';
    defs = document.createElementNS(svg.namespaceURI, 'defs');
    svg.append(defs);
    document.body.append(svg);
  }
  const id = `liquid-glass-${++filters}`;
  const channels = CHANNELS.map(([c, k, matrix]) => `
      <feDisplacementMap in="SourceGraphic" in2="map" scale="${2 * reach * k}" xChannelSelector="R" yChannelSelector="G"/>
      <feColorMatrix values="${matrix}" result="${c}"/>`).join('');
  defs.insertAdjacentHTML('beforeend', `
    <filter id="${id}" x="0" y="0" width="${width}" height="${height}" filterUnits="userSpaceOnUse" primitiveUnits="userSpaceOnUse" color-interpolation-filters="sRGB">
      <feImage href="${mapURL}" x="0" y="0" width="${width}" height="${height}" preserveAspectRatio="none" result="map"/>${channels}
      <feComposite in="R" in2="G" operator="arithmetic" k2="1" k3="1" result="RG"/>
      <feComposite in="RG" in2="B" operator="arithmetic" k2="1" k3="1"/>
    </filter>`);
  return id;
}

function glassFor(width, height, radius, dpr, dark) {
  const key = `${width}x${height}r${radius}@${dpr}:${dark}`;
  if (!glasses.has(key)) {
    glasses.set(key, (async () => {
      const { light, map, reach } = renderGlass(width, height, radius, dpr, dark);
      const lightURL = URL.createObjectURL(await pngOf(light));
      const filter = refracts ? filterFor(await dataURLOf(await pngOf(map)), width, height, reach) : null;
      return { lightURL, filter };
    })());
  }
  return glasses.get(key);
}

// ---------- applying it ----------

const SELECTOR = '.pill:not(.seg-text)';

async function paint(el) {
  const { offsetWidth: w, offsetHeight: h } = el;
  if (!w || !h) return;
  const dark = matchMedia('(prefers-color-scheme: dark)').matches;
  const radius = parseFloat(getComputedStyle(el).borderTopLeftRadius) || h / 2;
  const { lightURL, filter } = await glassFor(w, h, radius, devicePixelRatio || 1, dark);
  el.style.setProperty('--glass-light', `url("${lightURL}")`);
  const backdrop = `blur(${PARAMS.blur}px)${filter ? ` url(#${filter})` : ''}`;
  el.style.setProperty('-webkit-backdrop-filter', backdrop);
  el.style.setProperty('backdrop-filter', backdrop);
  el.classList.add('glass-on');
}

/** Paints every capsule under root and keeps them painted as they come, go and resize. */
export function attachGlass(root = document.body) {
  const sizes = new ResizeObserver((entries) => entries.forEach((e) => paint(e.target)));
  const watch = (el) => { sizes.observe(el); paint(el); };
  root.querySelectorAll(SELECTOR).forEach(watch);
  new MutationObserver((records) => {
    for (const r of records) for (const n of r.addedNodes) {
      if (n.nodeType !== 1) continue;
      if (n.matches(SELECTOR)) watch(n);
      n.querySelectorAll?.(SELECTOR).forEach(watch);
    }
  }).observe(root, { childList: true, subtree: true });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => root.querySelectorAll(SELECTOR).forEach(paint));
}
