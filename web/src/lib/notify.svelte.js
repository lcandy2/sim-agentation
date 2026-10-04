// macOS-style notification banners, stacked at the top right with the
// newest on top; each goes after a few seconds unless the pointer rests on it.

export const banners = $state([]);

const SHOWN_FOR = 5000;
const MOST = 4; // past this many, the oldest goes
const timers = new Map();
let next = 1;

/** Shows { title, message, image?, action? } as a banner; action runs on click. */
export function notify(note) {
  const id = next++;
  banners.unshift({ ...note, id });
  while (banners.length > MOST) dismiss(banners.at(-1).id);
  restart(id);
  return id;
}

export function dismiss(id) {
  hold(id);
  const i = banners.findIndex((b) => b.id === id);
  if (i < 0) return;
  const [gone] = banners.splice(i, 1);
  if (gone.image?.startsWith('blob:')) setTimeout(() => URL.revokeObjectURL(gone.image), 1000); // after it has slid out
}

export function hold(id) {
  clearTimeout(timers.get(id));
  timers.delete(id);
}

export const release = (id) => restart(id);

function restart(id) {
  clearTimeout(timers.get(id));
  timers.set(id, setTimeout(() => dismiss(id), SHOWN_FOR));
}
