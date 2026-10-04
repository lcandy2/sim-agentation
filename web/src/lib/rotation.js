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
// Measured on iOS 27.1 (iPhone Duo's unfolded panel, Settings): the root
// frame keeps the panel's portrait size, 669 × 951, while everything in it
// is in the landscape interface's own points, unscaled (About at x 515,
// 351 wide).

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
function landscapeRoot(tree, foldable) {
  const root = tree?.frame;
  if (!isRect(root)) return null;
  if (root.width > root.height) return root;
  if (!foldable) return null;
  // The Duo's: past the portrait root's width, below the root's own size
  // (the app keeps it too), is the landscape interface.
  let right = 0;
  (function walk(node) {
    const f = node?.frame;
    if (isRect(f) && !(f.width === root.width && f.height === root.height)) right = Math.max(right, f.x + f.width);
    node?.children?.forEach(walk);
  })(tree);
  return right > root.width * 1.05 ? { x: 0, y: 0, width: root.height, height: root.width } : null;
}

/** Whether the tree describes a turned (landscape) interface; `foldable`
 *  for iPhone Duo's way of saying so. */
export const isTurned = (tree, foldable = false) => !!landscapeRoot(tree, foldable);

/** The accessibility tree in framebuffer points. A portrait root (an app
 *  or home screen that doesn't rotate) is already there. */
export function treeToPortrait(tree, orientation, screen, foldable = false) {
  const rotate = toPortrait(orientation, screen);
  const root = rotate && landscapeRoot(tree, foldable);
  if (!rotate || !root) return tree;
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
