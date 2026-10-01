// Targets from SimAgentationPlus, the optional in-app SDK. It reports the
// real view/layer tree plus `.simTag()` views with their source location.

const SNAP = 2; // pt; a tag and the layer it paints count as the same box within this

const area = (r) => r.width * r.height;
const contains = (r, x, y) => x >= r.x && y >= r.y && x <= r.x + r.width && y <= r.y + r.height;
const encloses = (outer, inner) =>
  outer.x - SNAP <= inner.x &&
  outer.y - SNAP <= inner.y &&
  outer.x + outer.width + SNAP >= inner.x + inner.width &&
  outer.y + outer.height + SNAP >= inner.y + inner.height;
const same = (a, b) => encloses(a, b) && encloses(b, a);

const fileName = (file) => file.split('/').pop();

// The SDK may belong to an app that isn't in front; only trust it when the
// accessibility tree names the same app.
export function matchesFrontApp(sdk, tree) {
  if (!sdk) return false;
  const front = tree?.label?.trim();
  return !front || front === sdk.appName;
}

// Every node with the view controller that owns it. Cached per snapshot.
const flattened = new WeakMap();

function flatten(sdk) {
  if (flattened.has(sdk)) return flattened.get(sdk);
  const out = [];
  const walk = (node, controller) => {
    const owner = node.controller ?? controller;
    out.push({ node, controller: owner });
    node.children.forEach((child) => walk(child, owner));
  };
  sdk.windows.forEach((w) => walk(w, null));
  flattened.set(sdk, out);
  return out;
}

// Worth selecting: anything that paints a background, and every view class the app defines.
const selectable = (node) => node.background || node.cornerRadius || node.custom || node.hosts;

const nodeLabel = (node) =>
  node.hosts ? `${node.hosts} (SwiftUI)` : node.custom ? node.type : node.kind === 'layer' ? 'Background' : node.type;

// Containers under a point that are larger than `minRect`, innermost first.
export function sdkContainers(sdk, p, minRect) {
  const screen = area(sdk.screen);
  const fits = (r) => contains(r, p.x, p.y) && area(r) < screen * 0.6 && (!minRect || (encloses(r, minRect) && !same(r, minRect)));

  const items = sdk.tags
    .filter((t) => fits(t.frame))
    .map((t) => ({ rect: t.frame, label: `${t.name} · ${fileName(t.file)}:${t.line}`, tag: t }));
  for (const { node } of flatten(sdk)) {
    if (!selectable(node) || !fits(node.frame) || items.some((i) => same(i.rect, node.frame))) continue;
    items.push({ rect: node.frame, label: nodeLabel(node) });
  }
  return items.sort((a, b) => area(a.rect) - area(b.rect));
}

// App-defined view classes and hosted SwiftUI views around a rect,
// innermost first, and the view controller that owns the innermost view.
export function viewContext(sdk, rect) {
  const around = flatten(sdk)
    .filter(({ node }) => node.kind === 'view' && encloses(node.frame, rect))
    .sort((a, b) => area(a.node.frame) - area(b.node.frame));
  const views = [
    ...new Set(around.filter(({ node }) => node.custom || node.hosts).map(({ node }) => (node.hosts ? `${node.hosts} (SwiftUI)` : node.type))),
  ];
  return { views: views.slice(0, 4), controller: around.find((e) => e.controller)?.controller ?? null };
}

// Tagged views that enclose a rect, innermost first.
export function sourceFor(sdk, rect) {
  return sdk.tags
    .filter((t) => encloses(t.frame, rect))
    .sort((a, b) => area(a.frame) - area(b.frame))
    .map(({ name, file, line }) => ({ name, file, line }));
}
