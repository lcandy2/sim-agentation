// Line icons in the spirit of SF Symbols, drawn on a 24×24 grid.
// Usage: <span data-icon="search"></span>, then hydrateIcons().

const paths = {
  search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
  sidebar: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 4v16"/>',
  inspector: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M15 4v16"/>',
  phone: '<rect x="6.5" y="2.5" width="11" height="19" rx="2.5"/><path d="M10.5 5h3"/>',
  pointer: '<path d="M5 3.5 18.5 10l-6 1.8-2.4 6.2z"/><path d="m12.5 11.8 5 5"/>',
  annotate: '<path d="M4 20h4L19 9a2.8 2.8 0 0 0-4-4L4 16z"/><path d="m13.5 6.5 4 4"/><path d="M14 20h6"/>',
  'zoom-out': '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5M8 11h6"/>',
  'zoom-in': '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5M8 11h6M11 8v6"/>',
  'zoom-fit': '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/><path d="M8 9.5V8h1.5M14 9.5V8h-1.5M8 12.5V14h1.5M14 12.5V14h-1.5"/>',
  home: '<rect x="4" y="4" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/><rect x="10" y="4" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/><rect x="16" y="4" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/><rect x="4" y="10" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/><rect x="10" y="10" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/><rect x="16" y="10" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/><rect x="4" y="16" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/><rect x="10" y="16" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/><rect x="16" y="16" width="4" height="4" rx="0.9" fill="currentColor" stroke="none"/>',
  screenshot: '<path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2"/><path fill="currentColor" stroke="none" fill-rule="evenodd" d="M9.4 8.6h1.2l.7-1h1.4l.7 1h1.2A1.4 1.4 0 0 1 16 10v4.2a1.4 1.4 0 0 1-1.4 1.4H9.4A1.4 1.4 0 0 1 8 14.2V10a1.4 1.4 0 0 1 1.4-1.4zm2.6 1.9a1.7 1.7 0 1 0 0 3.4 1.7 1.7 0 0 0 0-3.4z"/>',
  lock: '<rect x="5" y="11" width="14" height="10" rx="2.5"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  'app-switcher': '<rect x="3" y="7" width="7" height="12" rx="2"/><rect x="14" y="7" width="7" height="12" rx="2"/><path d="M10 13h4"/>',
  copy: '<rect x="8" y="8" width="12" height="13" rx="2.5"/><path d="M16 8V5.5A2.5 2.5 0 0 0 13.5 3h-7A2.5 2.5 0 0 0 4 5.5v9A2.5 2.5 0 0 0 6.5 17H8"/>',
  trash: '<path d="M4 7h16M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/><path d="M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12"/><path d="M10 11v6M14 11v6"/>',
  'clear-done': '<path d="M3 12.5 7.5 17 15 8"/><path d="m12 16 1 1 8-9"/>',
  annotations: '<path d="M5 4h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-6l-5 4v-4H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z"/><path d="M8 9h8M8 12.5h5"/>',
  // Device Hub's toolbar, sidebar and inspector glyphs.
  plus: '<path d="M12 5v14M5 12h14"/>',
  filter: '<path d="M4 7h16M7 12h10M10 17h4"/>',
  sliders: '<path d="M4 7h8M16 7h4M4 12h2M10 12h10M4 17h10M18 17h2"/><circle cx="14" cy="7" r="2"/><circle cx="8" cy="12" r="2"/><circle cx="16" cy="17" r="2"/>',
  doc: '<path d="M7 3h7l5 5v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/><path d="M14 3v5h5M9 13h6M9 17h4"/>',
  info: '<path d="M10 10.5h2.4V18M9.6 18h5.4"/><circle cx="12.2" cy="6.2" r="1.15" fill="currentColor" stroke="none"/>',
  focus: '<path d="M20 4l-6 6M14 5.5V10h4.5M4 20l6-6M10 18.5V14H5.5"/>',
  more: '<circle cx="5.5" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/><circle cx="18.5" cy="12" r="1.4" fill="currentColor" stroke="none"/>',
  record: '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3.6" fill="currentColor" stroke="none"/>',
  'record-stop': '<circle cx="12" cy="12" r="8"/><rect x="9" y="9" width="6" height="6" rx="1.2" fill="currentColor" stroke="none"/>',
  rotate: '<rect x="7" y="8" width="10" height="10" rx="2"/><path d="M14 3.5h1.5a4 4 0 0 1 4 4V9"/><path d="m17.5 7.2 2 2 2-2"/><path d="M10 22.5H8.5a4 4 0 0 1-4-4V17"/><path d="m6.5 18.8-2-2-2 2"/>',
  'empty-doc': '<path d="M7 3h7l5 5v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/><path d="M14 3v5h5M9 13h6M9 17h4M4 4l16 17"/>',
};

export function icon(name) {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] ?? ''}</svg>`;
}

export function hydrateIcons(root = document) {
  for (const el of root.querySelectorAll('[data-icon]')) el.innerHTML = icon(el.dataset.icon);
}
