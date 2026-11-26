// Accessibility-tree helpers for the browser UI. Frames are in device
// points, the same space as describe_ui output. Clicks are picked here
// alone: a saved note names each picked node by its position in
// `flatten(tree)` (`refs`), and the server finds it there in the tree the
// page sends, its AX.flatten walking the tree in the same order.

// Trees never change once fetched, so flatten each one once.
const flattened = new WeakMap();

export function flatten(tree) {
  if (tree && flattened.has(tree)) return flattened.get(tree);
  const out = [];
  const walk = (node, depth, path, parent) => {
    const here = [...path, describe(node)];
    const at = out.length;
    out.push({ node, depth, path: here, parent });
    for (const child of node.children || []) walk(child, depth + 1, here, at);
  };
  if (tree) {
    walk(tree, 0, [], -1);
    flattened.set(tree, out);
  }
  return out;
}

// What a node is called: its label, else its title, else its identifier.
const nameOf = (node) => node.label?.trim() || node.title?.trim() || node.identifier || '';

export function describe(node) {
  const role = (node.role || 'AXElement').replace(/^AX/, '');
  const name = nameOf(node);
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
// AX.swift keeps the same set to rank a box note's nodes, controls first.
const CONTROLS = new Set([
  'AXButton', 'AXPopUpButton', 'AXMenuButton', 'AXRadioButton', 'AXCheckBox', 'AXSwitch', 'AXToggle',
  'AXLink', 'AXMenuItem', 'AXTab', 'AXCell', 'AXSlider', 'AXIncrementor', 'AXTextField', 'AXSecureTextField',
  'AXTextArea', 'AXSearchField', 'AXComboBox', 'AXDisclosureTriangle',
]);
const isControl = (node) => CONTROLS.has(node.role) || isWidget(node);
const named = (node) => !!nameOf(node);

// Frames that are the same to within half a point.
const sameFrame = (a, b) => ['x', 'y', 'width', 'height'].every((k) => Math.abs(a[k] - b[k]) <= 0.5);

// What a click targets: the smallest visible node under a point, or, when
// that is the text or icon inside a control, the nearest control around it.
// An unnamed control right inside another is the outer one's part (a
// pop-up button's button), so the outer one is named. SwiftUI can also put
// a control's text and icon in an element beside the control, with exactly
// its frame (Peri's Scroll strip: a StaticText holding the arrow and the
// label, next to its Slider); with no control around the hit, the control
// beside the nearest such element is named. Plain text outside any control
// stays the text. `index` is the target's position in
// `flatten(tree)`, and `leaf` the smallest node itself, for the SDK's tags
// on the text or icon inside a control. Nodes that cover most of the screen
// are window-level wrappers, not targets. `screen` is the screen size in
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
  // The hit and its ancestors below the root, innermost first, as positions in `entries`.
  const chain = [best];
  for (let p = entries[best].parent; p >= 0 && entries[p].depth > 0; p = entries[p].parent) chain.push(p);
  const control = (i) => target(entries[i]) && isControl(entries[i].node);
  const picked = (index) => ({ ...entries[index], index, leaf: entries[best] });
  let at = chain.findIndex(control);
  if (at < 0) {
    for (const i of chain) {
      const { parent, node } = entries[i];
      const twin = entries.findIndex((e, j) => j !== i && e.parent === parent && control(j) && sameFrame(e.node.frame, node.frame));
      if (twin >= 0) return picked(twin);
    }
    at = 0;
  }
  while (!named(entries[chain[at]].node) && at + 1 < chain.length && control(chain[at + 1])) at++;
  return picked(chain[at]);
}

/**
 * What a pick sends the server to name its node by, a position in
 * `flatten(tree)`: an element pick's own node (`target`, the `index` its
 * hitTest gave), else the node a click at the centre of its box picks
 * (`within`), so the agent knows where to look. Without a tree, or with
 * nothing there, `within` is null: the page always sends one of the two,
 * and the server turns away a pick with neither as an out-of-date page's.
 */
export function refs(tree, screen, { kind, rect, target }) {
  if (kind === 'element') return { target };
  const hit = tree ? hitTest(tree, rect.x + rect.width / 2, rect.y + rect.height / 2, screen) : null;
  return { within: hit?.index ?? null };
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
