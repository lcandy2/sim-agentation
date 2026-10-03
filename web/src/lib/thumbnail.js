// Small device pictures for the list: nine-slice bezel with a blue screen.

const thumbnails = new Map(); // chrome id + screen size + height → Promise<object URL | null>

export function thumbnail(chrome, height) {
  const key = `${chrome.id}:${chrome.screen.width}x${chrome.screen.height}:${height}`;
  if (!thumbnails.has(key)) thumbnails.set(key, drawThumbnail(chrome, height).catch(() => null));
  return thumbnails.get(key);
}

async function drawThumbnail(chrome, height) {
  const load = (url) => fetch(url).then((r) => r.blob()).then((b) => createImageBitmap(b));
  const dpr = 3;
  const k = (height / chrome.size.height) * dpr;
  const { size, screen, slices } = chrome;
  const canvas = new OffscreenCanvas(Math.ceil(size.width * k), Math.ceil(size.height * k));
  const g = canvas.getContext('2d');
  const s = Object.fromEntries(await Promise.all(Object.entries(slices).map(async ([key, v]) => [key, await load(v.url)])));
  const L = slices.topLeft.width, T = slices.topLeft.height, R = slices.topRight.width, B = slices.bottomLeft.height;
  const W = size.width, H = size.height;
  const draw = (img, x, y, w, h) => g.drawImage(img, x * k, y * k, w * k, h * k);
  draw(s.topLeft, 0, 0, L, T);
  draw(s.top, L, 0, W - L - R, T);
  draw(s.topRight, W - R, 0, R, T);
  draw(s.left, 0, T, L, H - T - B);
  draw(s.right, W - R, T, R, H - T - B);
  draw(s.bottomLeft, 0, H - B, L, B);
  draw(s.bottom, L, H - B, W - L - R, B);
  draw(s.bottomRight, W - R, H - B, R, B);
  // Screen: gradient, cut to the device's real screen shape.
  const sc = new OffscreenCanvas(Math.ceil(screen.width * k), Math.ceil(screen.height * k));
  const sg = sc.getContext('2d');
  const grad = sg.createLinearGradient(0, 0, 0, sc.height);
  grad.addColorStop(0, '#3b8ed0'); // --preview-screen
  grad.addColorStop(1, '#5aaced');
  sg.fillStyle = grad;
  sg.fillRect(0, 0, sc.width, sc.height);
  if (chrome.mask) {
    sg.globalCompositeOperation = 'destination-in';
    sg.drawImage(await load(chrome.mask), 0, 0, sc.width, sc.height);
  }
  g.drawImage(sc, screen.x * k, screen.y * k);
  const blob = await canvas.convertToBlob({ type: 'image/png' });
  return URL.createObjectURL(blob);
}
