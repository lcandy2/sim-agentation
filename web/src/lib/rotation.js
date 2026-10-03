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

/** The accessibility tree in framebuffer points. A portrait root (an app
 *  or home screen that doesn't rotate) is already there. */
export function treeToPortrait(tree, orientation, screen) {
  const rotate = toPortrait(orientation, screen);
  const root = tree?.frame;
  if (!rotate || !root || root.width <= root.height) return tree;
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
