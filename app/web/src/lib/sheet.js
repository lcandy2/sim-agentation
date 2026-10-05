// macOS's own sheet, measured from a 60 fps recording on macOS 26: it
// slides 32 pt down into place (ease-in-out, 260 ms) while fading in over
// the first 140 ms, and leaves 30 pt up, fading (ease-in, 230 ms); the
// window behind dims and clears over 270 ms. For every dialog in macOS
// 27's Alert (Figma, Alerts page): New Simulator, the device sheets, and
// confirmations.
const still = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
const DIM = 'rgba(0, 0, 0, 0.2)';

/** Shows a <dialog> as a sheet. */
export function showSheet(dialog) {
  dialog.showModal();
  if (still()) return;
  dialog.animate([{ transform: 'translateY(-32px)' }, { transform: 'none' }], { duration: 260, easing: 'cubic-bezier(0.42, 0, 0.58, 1)' });
  dialog.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 140 });
  dialog.animate([{ background: 'transparent' }, { background: DIM }], { duration: 270, pseudoElement: '::backdrop' });
}

/** A dismiss for a sheet: plays it out once, then closes the dialog. */
export function sheetDismiss(getDialog) {
  let closing = false;
  return async () => {
    if (closing) return;
    closing = true;
    const dialog = getDialog();
    if (!still()) {
      const out = { duration: 230, fill: 'forwards' };
      await Promise.all([
        dialog.animate([{ transform: 'none' }, { transform: 'translateY(-30px)' }], { ...out, easing: 'cubic-bezier(0.42, 0, 1, 1)' }).finished,
        dialog.animate([{ opacity: 1 }, { opacity: 0 }], out).finished,
        dialog.animate([{ background: DIM }, { background: 'transparent' }], { duration: 270, fill: 'forwards', pseudoElement: '::backdrop' }).finished,
      ]);
    }
    dialog.close();
  };
}
