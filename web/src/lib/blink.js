// macOS confirms a menu choice by blinking the item once before the menu
// closes: its highlight off, then back on, 90 ms each. Menus take no pointer
// input meanwhile, so the highlight stays on the chosen item.

const STEP = 90;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let blinking = false;

/** Blinks a menu item; false if another is already blinking (ignore the click). */
export async function blink(item) {
  if (blinking) return false;
  blinking = true;
  const root = document.documentElement;
  root.classList.add('menu-blinking');
  item.classList.add('blink-off');
  await wait(STEP);
  item.classList.replace('blink-off', 'blink-on');
  await wait(STEP);
  item.classList.remove('blink-on');
  root.classList.remove('menu-blinking');
  blinking = false;
  return true;
}
