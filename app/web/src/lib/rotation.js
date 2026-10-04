// Turned devices. The framebuffer, touches and the page's overlay stay
// portrait; what iOS reports in landscape doesn't, so it is brought into
// framebuffer points (portrait, `screen` = { width, height }) at freeze time.
//
// Measured on iOS 26 (iPhone 17 Pro, Safari):
// - The accessibility tree describes the landscape interface scaled down to
//   the portrait width and centered: root frame 402 × 184.9 at y 344.5.
// - landscape-right (UIDeviceOrientation 4, turned clockwise): the
//   interface's top runs along the framebuffer's left edge.
// - landscape-left (3, counterclockwise): its top runs along the right edge.
// - The SDK reports window coordinates, i.e. the interface's own points.
//
// Measured on iOS 27.1, iPhone Duo's unfolded panel (669 × 951 points),
// whose root says nothing to go by:
// - Settings: a root of the panel's portrait size, 669 × 951, around the
//   landscape interface in its own points, unscaled (About at x 515, 351
//   wide).
// - SpringBoard: a root of the cover's size, 466 × 678, around the panel's
//   portrait points (Batteries at y 720).

/** Interface point → framebuffer point. */
function toPortrait(orientation, screen) {
  const { width: W, height: H } = screen;
  if (orientation === 'landscape-right') return (x, y) => [y, H - x];
  if (orientation === 'landscape-left') return (x, y) => [W - y, x];
  return null;
}

function mapRect(r, point) {
  const [ax, ay] = point(r.x, r.y);
  const [bx, by] = point(r.x + r.width, r.y + r.height);
  return { ...r, x: Math.min(ax, bx), y: Math.min(ay, by), width: Math.abs(bx - ax), height: Math.abs(by - ay) };
}

const isRect = (v) => v && typeof v === 'object' && ['x', 'y', 'width', 'height'].every((k) => typeof v[k] === 'number');

/** A deep copy with every `frame` mapped. */
function mapFrames(value, point) {
  if (Array.isArray(value)) return value.map((v) => mapFrames(v, point));
  if (!value || typeof value !== 'object') return value;
  const out = {};
  for (const [k, v] of Object.entries(value)) out[k] = k === 'frame' && isRect(v) ? mapRect(v, point) : mapFrames(v, point);
  return out;
}

/**
 * The landscape interface the tree's points describe: its root, or for
 * iPhone Duo's root (portrait, around a landscape interface) the interface
 * it stands for; null when the points are portrait already (an app or home
 * screen that doesn't rotate).
 */
function landscapeRoot(tree, screen, foldable) {
  const root = tree?.frame;
  if (!isRect(root)) return null;
  if (root.width > root.height) return root;
  if (!foldable) return null;
  // The Duo's root can't be trusted (see above), so its elements vote: one
  // that fits only the landscape interface, or only the portrait panel.
  const { width: W, height: H } = screen;
  const fits = (f, w, h) => f.x >= -1 && f.y >= -1 && f.x + f.width <= w + 1 && f.y + f.height <= h + 1;
  let votes = 0;
  (function walk(node) {
    const f = node?.frame;
    if (isRect(f)) votes += (fits(f, H, W) ? 1 : 0) - (fits(f, W, H) ? 1 : 0);
    node?.children?.forEach(walk);
  })(tree);
  return votes > 0 ? { x: 0, y: 0, width: H, height: W } : null;
}

/** Whether the tree describes a turned (landscape) interface; `foldable`
 *  for iPhone Duo's ways of saying so. */
export const isTurned = (tree, screen, foldable = false) => !!landscapeRoot(tree, screen, foldable);

/** The accessibility tree in framebuffer points. A portrait root (an app
 *  or home screen that doesn't rotate) is already there; a foldable's is
 *  the panel's size, whatever its root says. */
export function treeToPortrait(tree, orientation, screen, foldable = false) {
  const rotate = toPortrait(orientation, screen);
  const root = rotate && landscapeRoot(tree, screen, foldable);
  if (!rotate || !root) return foldable && tree?.frame ? { ...tree, frame: { ...tree.frame, x: 0, y: 0, width: screen.width, height: screen.height } } : tree;
  const k = root.width / screen.height; // the letterbox scale
  const point = (x, y) => rotate((x - root.x) / k, (y - root.y) / k);
  const mapped = mapFrames(tree, point);
  mapped.frame = { ...mapped.frame, x: 0, y: 0, width: screen.width, height: screen.height };
  return mapped;
}

/** The SDK snapshot in framebuffer points, when its screen is landscape. */
export function sdkToPortrait(sdk, orientation, screen) {
  const rotate = toPortrait(orientation, screen);
  if (!rotate || !sdk?.screen || sdk.screen.width <= sdk.screen.height) return sdk;
  const mapped = mapFrames(sdk, rotate);
  mapped.screen = { ...mapped.screen, width: screen.width, height: screen.height };
  return mapped;
}

/** Degrees that turn a framebuffer image upright for this orientation. */
export const uprightDegrees = (orientation) => ({ 'landscape-right': 90, 'landscape-left': -90 })[orientation] ?? 0;
