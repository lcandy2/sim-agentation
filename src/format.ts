import type { Annotation, NodeSummary } from './store';

function node(n: NodeSummary) {
  const role = n.role.replace(/^AX/, '');
  const parts = [role];
  if (n.label?.trim()) parts.push(`"${n.label.trim()}"`);
  if (n.identifier && n.identifier !== n.label) parts.push(`id=${n.identifier}`);
  if (n.value) parts.push(`value="${n.value}"`);
  return parts.join(' ');
}

function frame(f: { x: number; y: number; width: number; height: number }) {
  return `(${Math.round(f.x)}, ${Math.round(f.y)}) ${Math.round(f.width)}×${Math.round(f.height)}pt`;
}

// Strings worth grepping the Swift sources for.
function searchTerms(a: Annotation) {
  const terms = new Set<string>();
  for (const n of [a.target, ...a.inside].filter(Boolean) as NodeSummary[]) {
    for (const s of [n.identifier, n.label, n.title]) {
      const t = s?.trim();
      if (t && t.length > 1 && t.length < 60) terms.add(t);
    }
  }
  return [...terms].slice(0, 8);
}

export function toMarkdown(a: Annotation) {
  const lines = [`## ${a.id} [${a.status}]`, '', `> ${a.comment.replace(/\n/g, '\n> ')}`, ''];
  const where = a.screen.headings.join(' › ');
  lines.push(`- **Device**: ${a.device.name ?? a.device.udid}${a.device.runtime ? ` (${a.device.runtime})` : ''}`);
  const app = a.app ?? { bundleId: null, name: a.screen.app };
  if (app.name || app.bundleId) {
    lines.push(`- **App**: ${[app.name, app.bundleId && `(${app.bundleId})`].filter(Boolean).join(' ')}`);
  }
  if (where) lines.push(`- **Screen**: ${where}`);
  const [inner, ...outer] = a.source ?? [];
  if (inner) {
    lines.push(`- **Source**: \`${inner.name}\` at ${inner.file}:${inner.line}`);
    for (const s of outer) lines.push(`  - inside \`${s.name}\` at ${s.file}:${s.line}`);
  }
  if (a.controller) lines.push(`- **View controller**: \`${a.controller}\``);
  if (a.views?.length) lines.push(`- **Views** (innermost first): ${a.views.map((v) => `\`${v}\``).join(' › ')}`);
  if (a.kind === 'element' && a.target) {
    lines.push(`- **Element**: ${node(a.target)} at ${frame(a.target.frame)}`);
    if (a.targetPath.length > 1) lines.push(`- **Path**: ${a.targetPath.join(' › ')}`);
  } else {
    lines.push(`- **Area**: ${frame(a.rect)}`);
  }
  const inside = a.inside.filter((n) => n !== a.target).slice(0, 12);
  if (inside.length) {
    lines.push('- **Inside the box**:');
    for (const n of inside) lines.push(`  - ${node(n)} at ${frame(n.frame)}`);
  }
  const terms = searchTerms(a);
  if (terms.length) lines.push(`- **Search the source for**: ${terms.map((t) => `\`${t}\``).join(', ')}`);
  lines.push(`- **Screenshot (box drawn in red)**: ${a.images.full}`);
  lines.push(`- **Close-up of the box**: ${a.images.crop}`);
  for (const r of a.replies) lines.push(`- **${r.from}**: ${r.message}`);
  if (a.resolution) lines.push(`- **Resolution**: ${a.resolution}`);
  return lines.join('\n');
}
