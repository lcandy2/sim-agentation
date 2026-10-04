// Where the 3D book's screen lands on the page. The host sends the lit
// screen as flat pieces (one for the cover, the unfolded screen's two
// halves), each a quad in the rendered frame with its corners in the
// framebuffer's order and the part of the framebuffer it shows. A flat
// piece seen in perspective is a homography of the framebuffer, so the
// page can map a point either way exactly, and lay a layer of framebuffer
// coordinates onto each piece with CSS `matrix3d`: Design Mode's boxes,
// labels and markers, drawn as on the flat screen, land on the book.

/** The 3×3 homography taking each `from` point to its `to` point (four each). */
function homography(from, to) {
  // a x + b y + c − g x X − h y X = X, d x + e y + f − g x Y − h y Y = Y
  const rows = [];
  from.forEach(([x, y], i) => {
    const [X, Y] = to[i];
    rows.push([x, y, 1, 0, 0, 0, -x * X, -y * X, X]);
    rows.push([0, 0, 0, x, y, 1, -x * Y, -y * Y, Y]);
  });
  for (let col = 0; col < 8; col++) {
    let pivot = col;
    for (let r = col + 1; r < 8; r++) if (Math.abs(rows[r][col]) > Math.abs(rows[pivot][col])) pivot = r;
    [rows[col], rows[pivot]] = [rows[pivot], rows[col]];
    const p = rows[col][col] || 1e-12;
    for (let r = 0; r < 8; r++) {
      if (r === col) continue;
      const k = rows[r][col] / p;
      for (let c = col; c < 9; c++) rows[r][c] -= k * rows[col][c];
    }
  }
  const [a, b, c, d, e, f, g, h] = rows.map((row, i) => row[8] / row[i]);
  return [a, b, c, d, e, f, g, h, 1];
}

function apply([a, b, c, d, e, f, g, h, i], [x, y]) {
  const w = g * x + h * y + i;
  return [(a * x + b * y + c) / w, (d * x + e * y + f) / w, w];
}

function invert([a, b, c, d, e, f, g, h, i]) {
  const A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
  const det = a * A + b * B + c * C;
  return [A, -(b * i - c * h), b * f - c * e, B, a * i - c * g, -(a * f - c * d), C, -(a * h - b * g), a * e - b * d].map((v) => v / det);
}

/** The framebuffer region a piece shows, as its four corners (TL, TR, BR, BL). */
const region = ({ u: [u0, u1], v: [v0, v1] }) => [[u0, v0], [u1, v0], [u1, v1], [u0, v1]];

/**
 * Each piece's map from the framebuffer (normalized) to the stage (CSS px,
 * the 3D view `box` being the whole rendered frame), and back.
 */
export function pieceMaps(pieces, box) {
  return pieces.map((piece) => {
    const toStage = homography(region(piece), piece.corners.map(([x, y]) => [x * box.width, y * box.height]));
    return { piece, toStage, fromStage: invert(toStage) };
  });
}

/**
 * A stage point (CSS px in the 3D view) → the framebuffer point it shows
 * (normalized), and whether it's on the screen at all. Off every piece
 * it's clamped onto the first, so a drag that leaves the screen keeps a
 * position.
 */
export function locate(maps, x, y) {
  let fallback = null;
  for (const { piece, fromStage } of maps) {
    const [u, v, w] = apply(fromStage, [x, y]);
    const eps = 0.001;
    const inside = w > 0 && u >= piece.u[0] - eps && u <= piece.u[1] + eps && v >= piece.v[0] - eps && v <= piece.v[1] + eps;
    const clamp = (t, [lo, hi]) => Math.max(lo, Math.min(hi, t));
    const placed = { u: clamp(u, piece.u), v: clamp(v, piece.v), inside };
    if (inside) return placed;
    fallback ??= placed;
  }
  return fallback ?? { u: 0, v: 0, inside: false };
}

/** Where a framebuffer point (normalized) is on the stage, through the piece showing it; null off them. */
export function project(maps, u, v) {
  const eps = 1e-6;
  const map = maps.find(({ piece }) => u >= piece.u[0] - eps && u <= piece.u[1] + eps && v >= piece.v[0] - eps && v <= piece.v[1] + eps);
  if (!map) return null;
  const [x, y] = apply(map.toStage, [u, v]);
  return { x, y };
}

/**
 * The angle (degrees, clockwise) at which a line from a framebuffer point
 * runs on the stage, going (du, dv) in the framebuffer: how the screen's
 * text leans there, for a label laid flat beside it.
 */
export function angleAt(maps, u, v, du, dv) {
  const at = project(maps, u, v);
  if (!at) return 0;
  const ahead = project(maps, u + du, v + dv);
  const [from, to] = ahead ? [at, ahead] : [project(maps, u - du, v - dv), at];
  return from ? (Math.atan2(to.y - from.y, to.x - from.x) * 180) / Math.PI : 0;
}

/** How squarely a piece faces the camera, 1 head-on (the host's cosine). */
export const facing = ({ piece }) => piece.facing ?? 1;

/**
 * The CSS that lays a layer of framebuffer coordinates, `size` px, onto
 * one piece: its `matrix3d` (with `transform-origin: 0 0`), and a clip
 * along the hinge only, so what crosses it is cut there while labels may
 * still stand past the screen's outer edges.
 */
export function layerStyle({ piece, toStage }, size) {
  const scale = [1 / size.width, 0, 0, 0, 1 / size.height, 0, 0, 0, 1];
  const [a, b, c, d, e, f, g, h, i] = multiply(toStage, scale);
  const transform = `matrix3d(${[a, d, 0, g, b, e, 0, h, 0, 0, 1, 0, c, f, 0, i].join(',')})`;
  const edge = (t, outer) => (t > 0.0001 && t < 0.9999 ? `${t * 100}%` : outer);
  const [l, r] = [edge(piece.u[0], '-100%'), edge(piece.u[1], '200%')];
  const [t, bottom] = [edge(piece.v[0], '-100%'), edge(piece.v[1], '200%')];
  return { transform, clip: `polygon(${l} ${t}, ${r} ${t}, ${r} ${bottom}, ${l} ${bottom})` };
}

function multiply(m, n) {
  const out = [];
  for (let r = 0; r < 3; r++) for (let c = 0; c < 3; c++) out.push(m[r * 3] * n[c] + m[r * 3 + 1] * n[3 + c] + m[r * 3 + 2] * n[6 + c]);
  return out;
}

/**
 * About how many CSS px the framebuffer spans on the stage, across and
 * down: the size to give its layers, so their outlines and labels come
 * out near the flat screen's size.
 */
export function layerSize(maps) {
  const { piece, toStage } = maps[0];
  const [tl, tr, , bl] = region(piece).map((p) => apply(toStage, p));
  const across = Math.hypot(tr[0] - tl[0], tr[1] - tl[1]) / (piece.u[1] - piece.u[0]);
  const down = Math.hypot(bl[0] - tl[0], bl[1] - tl[1]) / (piece.v[1] - piece.v[0]);
  return { width: Math.max(1, across), height: Math.max(1, down) };
}

/**
 * The stage box (CSS px) around a framebuffer rect (normalized), through
 * whichever pieces it lies on: where the composer goes beside it.
 */
export function stageBox(maps, { x, y, width, height }) {
  const xs = [], ys = [];
  for (const { piece, toStage } of maps) {
    const u0 = Math.max(x, piece.u[0]), u1 = Math.min(x + width, piece.u[1]);
    const v0 = Math.max(y, piece.v[0]), v1 = Math.min(y + height, piece.v[1]);
    if (u0 > u1 || v0 > v1) continue;
    for (const p of [[u0, v0], [u1, v0], [u1, v1], [u0, v1]]) {
      const [sx, sy] = apply(toStage, p);
      xs.push(sx);
      ys.push(sy);
    }
  }
  if (!xs.length) return null;
  return { left: Math.min(...xs), right: Math.max(...xs), top: Math.min(...ys), bottom: Math.max(...ys) };
}
