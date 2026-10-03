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
  'zoom-actual': '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/><path d="M10 9.2 11.4 8v6.2"/>',
  home: '<circle cx="6" cy="6" r="1.4"/><circle cx="12" cy="6" r="1.4"/><circle cx="18" cy="6" r="1.4"/><circle cx="6" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="18" cy="12" r="1.4"/><circle cx="6" cy="18" r="1.4"/><circle cx="12" cy="18" r="1.4"/><circle cx="18" cy="18" r="1.4"/>',
  screenshot: '<path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2"/><circle cx="12" cy="12" r="3"/>',
  lock: '<rect x="5" y="11" width="14" height="10" rx="2.5"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  'app-switcher': '<rect x="3" y="7" width="7" height="12" rx="2"/><rect x="14" y="7" width="7" height="12" rx="2"/><path d="M10 13h4"/>',
  copy: '<rect x="8" y="8" width="12" height="13" rx="2.5"/><path d="M16 8V5.5A2.5 2.5 0 0 0 13.5 3h-7A2.5 2.5 0 0 0 4 5.5v9A2.5 2.5 0 0 0 6.5 17H8"/>',
  'clear-done': '<path d="M3 12.5 7.5 17 15 8"/><path d="m12 16 1 1 8-9"/>',
  annotations: '<path d="M5 4h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-6l-5 4v-4H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z"/><path d="M8 9h8M8 12.5h5"/>',
};

export function icon(name) {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] ?? ''}</svg>`;
}

export function hydrateIcons(root = document) {
  for (const el of root.querySelectorAll('[data-icon]')) el.innerHTML = icon(el.dataset.icon);
}
