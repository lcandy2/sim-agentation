// A shortcut's key combo (as SHORTCUTS in app.svelte.js names them:
// "shift+meta+KeyH") drawn as macOS menus draw it: ⌃ ⌥ ⇧ ⌘, then the key.
const MODIFIERS = { ctrl: '⌃', alt: '⌥', shift: '⇧', meta: '⌘' };
const KEYS = { ArrowLeft: '←', ArrowRight: '→', ArrowUp: '↑', ArrowDown: '↓', Equal: '+', Minus: '−', Escape: '⎋', Enter: '↩' };

export function glyphs(combo) {
  const parts = combo.split('+');
  const code = parts.pop();
  return [...parts.map((m) => MODIFIERS[m]), KEYS[code] ?? code.replace(/^(Key|Digit)/, '')];
}
