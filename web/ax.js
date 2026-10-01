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

// Smallest visible node under a point: what a click targets. Nodes that
// cover most of the screen are window-level wrappers, not targets.
export function hitTest(tree, x, y) {
  const screen = tree.frame ? area(tree.frame) : Infinity;
  let best = null;
  for (const entry of flatten(tree)) {
    if (!visible(entry) || !contains(entry.node.frame, x, y)) continue;
    if (area(entry.node.frame) > screen * 0.6) continue;
    if (!best || area(entry.node.frame) <= area(best.node.frame)) best = entry;
  }
  return best;
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
