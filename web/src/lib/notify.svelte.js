// macOS-style notification banners: one at a time, gone after a few seconds
// unless the pointer rests on it.

export const banner = $state({ current: null });

const SHOWN_FOR = 5000;
let timer = null;
let held = false;

/** Shows { title, message, image?, action? } as a banner; action runs on click. */
export function notify(note) {
  if (banner.current?.image?.startsWith('blob:')) URL.revokeObjectURL(banner.current.image);
  banner.current = { ...note, id: (banner.current?.id ?? 0) + 1 };
  restart();
}

export function dismiss() {
  clearTimeout(timer);
  if (banner.current?.image?.startsWith('blob:')) {
    const url = banner.current.image;
    setTimeout(() => URL.revokeObjectURL(url), 1000); // after it has slid out
  }
  banner.current = null;
}

export function hold() {
  held = true;
  clearTimeout(timer);
}

export function release() {
  held = false;
  restart();
}

function restart() {
  clearTimeout(timer);
  if (!held) timer = setTimeout(dismiss, SHOWN_FOR);
}
