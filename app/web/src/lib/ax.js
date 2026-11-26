// Accessibility-tree helpers shared by the browser UI and the server.
// Frames are in device points, the same space as describe_ui output.

// Trees never change once fetched, so flatten each one once.
const flattened = new WeakMap();

export function flatten(tree) {
  if (tree && flattened.has(tree)) return flattened.get(tree);
  const out = [];
  const walk = (node, depth, path) => {
    const here = [...path, describe(node)];
    out.push({ node, depth, path: here });
    for (const child of node.children || []) walk(child, depth + 1, here);
  };
  if (tree) {
    walk(tree, 0, []);
    flattened.set(tree, out);
  }
  return out;
}

export function describe(node) {
  const role = (node.role || 'AXElement').replace(/^AX/, '');
  const name = node.label?.trim() || node.title?.trim() || node.identifier || '';
  return name ? `${role} "${name}"` : role;
}

export function area(f) {
  return f.width * f.height;
}

export function contains(f, x, y) {
  return x >= f.x && y >= f.y && x <= f.x + f.width && y <= f.y + f.height;
}

export function intersection(a, b) {
  const x = Math.max(a.x, b.x);
  const y = Math.max(a.y, b.y);
  const w = Math.min(a.x + a.width, b.x + b.width) - x;
  const h = Math.min(a.y + a.height, b.y + b.height) - y;
  return w > 0 && h > 0 ? w * h : 0;
}

function visible(entry) {
  const { node } = entry;
  return entry.depth > 0 && !node.hidden && node.frame && area(node.frame) > 0;
}

/**
 * Whether the tree is SpringBoard's (the home screen and its other
 * screens): its application element has no name, where an app's carries
 * the app's.
 */
export function isSpringBoard(tree) {
  return tree?.role === 'AXApplication' && !tree.label?.trim();
}

/** A home-screen widget, one element over its whole card: its value says "Widget" ("Widget, Stack" in a Smart Stack). */
export const isWidget = (node) => typeof node?.value === 'string' && node.value.split(/,\s*/).includes('Widget');

// Roles a person would call a control. The full tree draws a control's text
// and icon as children of it, and a click on them means the control.
const CONTROLS = new Set([
  'AXButton', 'AXPopUpButton', 'AXMenuButton', 'AXRadioButton', 'AXCheckBox', 'AXSwitch', 'AXToggle',
  'AXLink', 'AXMenuItem', 'AXTab', 'AXCell', 'AXSlider', 'AXIncrementor', 'AXTextField', 'AXSecureTextField',
  'AXTextArea', 'AXSearchField', 'AXComboBox', 'AXDisclosureTriangle',
]);
const isControl = (node) => CONTROLS.has(node.role) || isWidget(node);
const named = (node) => !!(node.label?.trim() || node.title?.trim() || node.identifier);

// What a click targets: the smallest visible node under a point, or, when
// that is the text or icon inside a control, the nearest control around it.
// An unnamed control right inside another is the outer one's part (a
// pop-up button's button), so the outer one is named. Plain text outside
// any control stays the text. Nodes that cover most of the screen are
// window-level wrappers, not targets. `screen` is the screen size in
// points; the tree's root can't be trusted for it, because the simulator
// now reports the application element as 0×0.
export function hitTest(tree, x, y, screen = tree.frame) {
  const limit = screen && area(screen) > 0 ? area(screen) * 0.6 : Infinity;
  const entries = flatten(tree);
  const target = (e) => visible(e) && area(e.node.frame) <= limit;
  let best = -1;
  entries.forEach((entry, i) => {
    if (!target(entry) || !contains(entry.node.frame, x, y)) return;
    if (best < 0 || area(entry.node.frame) <= area(entries[best].node.frame)) best = i;
  });
  if (best < 0) return null;
  // The hit and its ancestors, innermost first: in the depth-first list each
  // ancestor is the nearest entry before it one level up.
  const chain = [entries[best]];
  for (let i = best - 1; i >= 0 && chain.at(-1).depth > 1; i--) {
    if (entries[i].depth === chain.at(-1).depth - 1) chain.push(entries[i]);
  }
  let at = chain.findIndex((e) => target(e) && isControl(e.node));
  if (at < 0) return chain[0];
  while (!named(chain[at].node) && chain[at + 1] && target(chain[at + 1]) && isControl(chain[at + 1].node)) at++;
  return chain[at];
}

// Nodes that sit mostly inside a box, smallest first.
export function nodesInRect(tree, rect) {
  return flatten(tree)
    .filter(visible)
    .filter((e) => intersection(e.node.frame, rect) >= area(e.node.frame) * 0.6)
    .sort((a, b) => area(a.node.frame) - area(b.node.frame));
}

const STATUS_BAR = 54; // pt; clock, battery and signal live above this

// Best guess at which screen this is: app name plus headings and
// navigation titles near the top.
export function screenContext(tree) {
  if (!tree) return { app: null, headings: [] };
  const app = tree.label?.trim() || tree.title?.trim() || null;
  const headings = flatten(tree)
    .filter(visible)
    .filter(({ node }) => node.frame.y >= STATUS_BAR)
    .filter(({ node }) =>
      node.role === 'AXHeading' ||
      /Header|NavigationBar|Heading/i.test(node.subrole || '') ||
      (node.role === 'AXStaticText' && node.frame.y < 140),
    )
    .map(({ node }) => node.label?.trim() || node.title?.trim())
    .filter((text) => text && text.length <= 40);
  return { app, headings: [...new Set(headings)].slice(0, 5) };
}

export function summarize(node) {
  const f = node.frame;
  return {
    role: node.role,
    label: node.label ?? null,
    identifier: node.identifier ?? null,
    value: node.value ?? null,
    title: node.title ?? null,
    frame: { x: round(f.x), y: round(f.y), width: round(f.width), height: round(f.height) },
  };
}

const round = (n) => Math.round(n * 10) / 10;
