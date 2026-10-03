// Device chrome (the bezel and hardware buttons) the way Xcode's Device Hub
// and Simulator find it: simulator → device type → profile.plist's
// chromeIdentifier → /Library/Developer/DeviceKit/Chrome/<id>.devicechrome.
// Artwork ships as PDFs; we rasterize them at 3× with `sips` and cache the PNGs.

import { existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { HOME } from './store';

const CHROME_ROOT = '/Library/Developer/DeviceKit/Chrome';
const CACHE = join(HOME, 'chrome');
const SCALE = 3; // pixels per point in the rasterized artwork
const SAFE_NAME = /^[A-Za-z0-9 _-]+$/;

async function run(cmd: string[]) {
  const proc = Bun.spawn(cmd, { stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw new Error(err.trim() || `${cmd[0]} exited ${code}`);
  return out;
}

// Files under /Library don't change while we run, so read each one once.
function memo<T>(fn: (path: string) => Promise<T>) {
  const cache = new Map<string, Promise<T>>();
  return (path: string) => {
    if (!cache.has(path)) cache.set(path, fn(path));
    return cache.get(path)!;
  };
}

const plist = memo(async (path) => JSON.parse(await run(['plutil', '-convert', 'json', '-o', '-', path])));

// PDF page size in points (sips reports it as pixels at 72 dpi).
const pdfSize = memo(async (path) => {
  const out = await run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', path]);
  const num = (key: string) => Number(out.match(new RegExp(`${key}: ([\\d.]+)`))?.[1]);
  return { width: num('pixelWidth'), height: num('pixelHeight') };
});

let deviceTypes: Promise<Map<string, string>> | null = null; // identifier → bundle path
let deviceTypeOf: { at: number; map: Promise<Map<string, string>> } | null = null; // udid → identifier

function bundlePaths() {
  deviceTypes ??= run(['xcrun', 'simctl', 'list', 'devicetypes', '-j']).then(
    (out) => new Map(JSON.parse(out).devicetypes.map((t: any) => [t.identifier, t.bundlePath])),
  );
  return deviceTypes;
}

function deviceTypeIds() {
  // Devices come and go; refresh the list every 30 s.
  if (!deviceTypeOf || Date.now() - deviceTypeOf.at > 30_000) {
    const map = run(['xcrun', 'simctl', 'list', 'devices', '-j']).then((out) => {
      const result = new Map<string, string>();
      for (const list of Object.values(JSON.parse(out).devices) as any[]) {
        for (const d of list) result.set(d.udid, d.deviceTypeIdentifier);
      }
      return result;
    });
    deviceTypeOf = { at: Date.now(), map };
  }
  return deviceTypeOf.map;
}

type Point = { x: number; y: number };

type Slice = { url: string; width: number; height: number };
const SLICES = ['topLeft', 'top', 'topRight', 'right', 'bottomRight', 'bottom', 'bottomLeft', 'left'] as const;

export interface Chrome {
  id: string;
  size: { width: number; height: number }; // device body, in points
  screen: { x: number; y: number; width: number; height: number }; // in points, inside the body
  cornerRadius: number;
  slices: Record<(typeof SLICES)[number], Slice>; // nine-slice bezel; the centre is the screen
  mask: string | null;
  buttons: {
    name: string;
    anchor: 'left' | 'right' | 'top' | 'bottom';
    align: 'leading' | 'trailing';
    onTop: boolean;
    size: { width: number; height: number };
    normal: Point;
    rollover: Point;
    image: string;
    imageDown: string;
  }[];
}

const chromes = new Map<string, Promise<Chrome>>(); // by udid

export function chromeFor(udid: string) {
  if (!chromes.has(udid)) {
    const p = resolve(udid);
    p.catch(() => chromes.delete(udid)); // retry next time
    chromes.set(udid, p);
  }
  return chromes.get(udid)!;
}

async function resolve(udid: string): Promise<Chrome> {
  const typeId = (await deviceTypeIds()).get(udid);
  if (!typeId) throw new Error(`no simulator with udid ${udid}`);
  const bundle = (await bundlePaths()).get(typeId);
  if (!bundle) throw new Error(`no device type ${typeId}`);
  const profile = await plist(join(bundle, 'Contents/Resources/profile.plist'));
  const id = String(profile.chromeIdentifier ?? '').split('.').pop() ?? '';
  const dir = chromeDir(id);
  if (!dir) throw new Error(`no chrome bundle ${profile.chromeIdentifier}`);
  const def = await Bun.file(join(dir, 'chrome.json')).json();
  const images = def.images;
  const inset = images.sizing;

  // Screen size in points, from the device type.
  const caps = await plist(join(bundle, 'Contents/Resources/capabilities.plist'));
  const dims = caps.capabilities?.ScreenDimensionsCapability ?? {};
  const scale = Number(dims['main-screen-scale']) || 1;
  const screenWidth = Number(dims['main-screen-width']) / scale;
  const screenHeight = Number(dims['main-screen-height']) / scale;
  if (!screenWidth || !screenHeight) throw new Error(`no screen size for ${typeId}`);

  // The screen tucks 1 pt under the bezel on each side: iPhone 17 Pro's
  // 402 pt screen + 2 × 18 pt sizing - 2 = 436 pt, its composite artwork width.
  const size = {
    width: screenWidth + inset.leftWidth + inset.rightWidth - 2,
    height: screenHeight + inset.topHeight + inset.bottomHeight - 2,
  };

  const slices = Object.fromEntries(
    await Promise.all(
      SLICES.map(async (key) => {
        const name = images[key];
        const { width, height } = await pdfSize(join(dir, `${name}.pdf`));
        return [key, { url: `/chrome/${id}/${encodeURIComponent(name)}.png`, width, height }];
      }),
    ),
  ) as Chrome['slices'];

  const buttons = await Promise.all(
    (def.inputs ?? [])
      .filter((i: any) => i.type === 'button' && i.image && existsSync(join(dir, `${i.image}.pdf`)))
      .map(async (i: any) => ({
        name: i.name,
        anchor: i.anchor,
        align: i.align,
        onTop: !!i.onTop,
        size: await pdfSize(join(dir, `${i.image}.pdf`)),
        normal: i.offsets.normal,
        rollover: i.offsets.rollover ?? i.offsets.normal,
        image: `/chrome/${id}/${encodeURIComponent(i.image)}.png`,
        imageDown: `/chrome/${id}/${encodeURIComponent(i.imageDown ?? i.image)}.png`,
      })),
  );

  const maskName = profile.framebufferMask;
  return {
    id,
    size,
    screen: { x: inset.leftWidth - 1, y: inset.topHeight - 1, width: screenWidth, height: screenHeight },
    cornerRadius: def.paths?.simpleOutsideBorder?.cornerRadiusX ?? 0,
    slices,
    mask: maskName && existsSync(join(bundle, `Contents/Resources/${maskName}.pdf`)) ? `/api/sims/${udid}/mask.png` : null,
    buttons,
  };
}

function chromeDir(id: string) {
  if (!/^[a-z0-9]+$/.test(id)) return null;
  const dir = join(CHROME_ROOT, `${id}.devicechrome`, 'Contents/Resources');
  return existsSync(dir) ? dir : null;
}

// Rasterizes one PDF to a cached PNG at 3×. `name` must be a PDF in `dir`.
async function rasterize(dir: string, name: string, cacheKey: string) {
  if (!SAFE_NAME.test(name) || !readdirSync(dir).includes(`${name}.pdf`)) return null;
  const out = join(CACHE, cacheKey, `${name}@${SCALE}x.png`);
  if (!existsSync(out)) {
    mkdirSync(join(CACHE, cacheKey), { recursive: true });
    const pdf = join(dir, `${name}.pdf`);
    const { width, height } = await pdfSize(pdf);
    const longest = Math.round(Math.max(width, height) * SCALE);
    await run(['sips', '-s', 'format', 'png', '-Z', String(longest), pdf, '--out', out]);
  }
  return out;
}

export async function chromeImage(id: string, name: string) {
  const dir = chromeDir(id);
  return dir ? rasterize(dir, name, id) : null;
}

export async function maskImage(udid: string) {
  const typeId = (await deviceTypeIds()).get(udid);
  const bundle = typeId && (await bundlePaths()).get(typeId);
  if (!bundle) return null;
  const profile = await plist(join(bundle, 'Contents/Resources/profile.plist'));
  const name = String(profile.framebufferMask ?? '');
  // The mask is already at device pixels, so 1× of its page size is native resolution.
  const dir = join(bundle, 'Contents/Resources');
  if (!SAFE_NAME.test(name) || !existsSync(join(dir, `${name}.pdf`))) return null;
  const out = join(CACHE, 'masks', `${name}.png`);
  if (!existsSync(out)) {
    mkdirSync(join(CACHE, 'masks'), { recursive: true });
    await run(['sips', '-s', 'format', 'png', join(dir, `${name}.pdf`), '--out', out]);
  }
  return out;
}
