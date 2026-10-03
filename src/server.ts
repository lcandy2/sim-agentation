import { join } from 'node:path';
import type { ServerWebSocket } from 'bun';
import { PORT } from './config';
import * as store from './store';
import { toMarkdown } from './format';
import { chromeFor, chromeImage, maskImage } from './chrome';
import { hitTest, nodesInRect, screenContext, summarize } from '../web/ax.js';

// The native host (host/, Swift) drives the simulators: device list, boot,
// and the screen/input/accessibility socket.
const HOST = process.env.SIM_AGENTATION_HOST_URL || 'http://127.0.0.1:38472';
const HOST_BINARY = process.env.SIM_AGENTATION_HOST_BIN || join(import.meta.dir, '..', 'host', '.build', 'debug', 'sim-agentation');
const SDK = process.env.SIM_AGENTATION_SDK_URL || 'http://127.0.0.1:38471';
const WEB = join(import.meta.dir, '..', 'web');

async function hostUp() {
  try {
    const res = await fetch(`${HOST}/health`, { signal: AbortSignal.timeout(800) });
    return res.ok;
  } catch {
    return false;
  }
}

async function ensureHost() {
  if (await hostUp()) return;
  const port = new URL(HOST).port || '38472';
  Bun.spawn([HOST_BINARY, '--port', port], { stdout: 'ignore', stderr: 'inherit' }).unref();
  for (let i = 0; i < 40; i++) {
    await Bun.sleep(250);
    if (await hostUp()) return;
  }
  throw new Error(`sim-agentation host did not come up on ${HOST} (built with \`swift build\` in host/?)`);
}

async function host(path: string, init?: RequestInit) {
  const res = await fetch(`${HOST}${path}`, init);
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || `host ${path} returned ${res.status}`);
  return body;
}

const devices = () => host('/api/devices');

const json = (data: unknown, status = 200) => Response.json(data, { status });

// Only this UI may talk to us. Host stops DNS rebinding; Origin stops other
// pages in the user's browser (WebSockets and "simple" POSTs skip CORS).
// Non-browser clients such as the MCP server send no Origin and are allowed.
const LOCAL_HOSTS = new Set([`localhost:${PORT}`, `127.0.0.1:${PORT}`]);
const LOCAL_ORIGINS = new Set([...LOCAL_HOSTS].map((h) => `http://${h}`));

function rejectForeign(req: Request) {
  if (!LOCAL_HOSTS.has(req.headers.get('host') ?? '')) return new Response('forbidden host', { status: 403 });
  const origin = req.headers.get('origin');
  if (origin && !LOCAL_ORIGINS.has(origin)) return new Response('forbidden origin', { status: 403 });
  const writes = req.method === 'POST' || req.method === 'PATCH';
  if (writes && !req.headers.get('content-type')?.startsWith('application/json')) {
    return new Response('expected application/json', { status: 415 });
  }
  return null;
}

async function file(path: string, headers: HeadersInit) {
  const f = Bun.file(path);
  return (await f.exists()) ? new Response(f, { headers }) : new Response('not found', { status: 404 });
}

class BadRequest extends Error {}

const isObject = (v: unknown): v is Record<string, any> => typeof v === 'object' && v !== null && !Array.isArray(v);
const isRect = (r: any) => isObject(r) && ['x', 'y', 'width', 'height'].every((k) => Number.isFinite(r[k]));

interface CreateBody {
  udid: string;
  comment: string;
  kind: 'element' | 'area';
  rect: { x: number; y: number; width: number; height: number };
  point?: { x: number; y: number };
  tree: any;
  full: string; // base64 JPEG with the box drawn
  crop: string; // base64 JPEG of the box
  app?: { bundleId: string | null; name: string | null };
  source?: store.SourceRef[];
  views?: string[];
  controller?: string | null;
}

async function createAnnotation(body: CreateBody) {
  if (!isObject(body)) throw new BadRequest('expected a JSON object');
  if (typeof body.comment !== 'string' || !body.comment.trim()) throw new BadRequest('comment is required');
  if (typeof body.udid !== 'string' || !isRect(body.rect)) throw new BadRequest('udid and rect are required');
  if (typeof body.full !== 'string' || typeof body.crop !== 'string') throw new BadRequest('full and crop images are required');
  const tree = isObject(body.tree) ? body.tree : null;
  const point = isObject(body.point) && Number.isFinite(body.point.x) && Number.isFinite(body.point.y) ? body.point : null;

  const hit = body.kind === 'element' && point && tree ? hitTest(tree, point.x, point.y) : null;
  const device = (await devices().catch(() => [])).find((d: any) => d.udid === body.udid);
  const id = store.newId();
  const now = new Date().toISOString();
  const annotation: store.Annotation = {
    id,
    createdAt: now,
    updatedAt: now,
    status: 'pending',
    comment: body.comment.trim(),
    kind: hit ? 'element' : 'area',
    device: { udid: body.udid, name: device?.name ?? null, runtime: device?.runtime ?? null },
    rect: body.rect,
    target: hit ? summarize(hit.node) : null,
    targetPath: hit ? hit.path.slice(1) : [],
    inside: tree ? nodesInRect(tree, body.rect).slice(0, 20).map((e: any) => summarize(e.node)) : [],
    screen: screenContext(tree),
    app: isObject(body.app) ? body.app as store.Annotation['app'] : { bundleId: null, name: tree?.label?.trim() || null },
    source: Array.isArray(body.source) ? body.source : [],
    views: Array.isArray(body.views) ? body.views : [],
    controller: typeof body.controller === 'string' ? body.controller : null,
    images: { full: join(store.IMAGES, `${id}-full.jpg`), crop: join(store.IMAGES, `${id}-crop.jpg`) },
    replies: [],
    resolution: null,
  };
  // Images last, so a rejected request leaves nothing behind.
  await Bun.write(annotation.images.full, Buffer.from(body.full, 'base64'));
  await Bun.write(annotation.images.crop, Buffer.from(body.crop, 'base64'));
  return store.add(annotation);
}

function parsePatch(body: unknown) {
  if (!isObject(body)) throw new BadRequest('expected a JSON object');
  const patch: Partial<store.Annotation> = {};
  if (body.status !== undefined) {
    if (!store.STATUSES.includes(body.status)) throw new BadRequest(`bad status ${body.status}`);
    patch.status = body.status;
  }
  if (body.resolution !== undefined) {
    if (body.resolution !== null && typeof body.resolution !== 'string') throw new BadRequest('resolution must be a string or null');
    patch.resolution = body.resolution;
  }
  let reply: store.Reply | undefined;
  if (body.reply !== undefined) {
    const r = body.reply;
    if (!isObject(r) || (r.from !== 'agent' && r.from !== 'human') || typeof r.message !== 'string' || !r.message.trim()) {
      throw new BadRequest('reply must be { from: "agent" | "human", message: string }');
    }
    reply = { from: r.from, message: r.message.trim(), at: new Date().toISOString() };
  }
  return { patch, reply };
}

// Resolves on the next store change or after the timeout.
function nextChange(timeoutMs: number) {
  return new Promise<void>((resolve) => {
    const off = store.onChange(done);
    const timer = setTimeout(done, timeoutMs);
    function done() {
      off();
      clearTimeout(timer);
      resolve();
    }
  });
}

type Proxy = { udid: string; upstream?: WebSocket; queue: (string | ArrayBuffer)[] };

export async function serve() {
  await ensureHost();

  const server = Bun.serve<Proxy, {}>({
    port: PORT,
    hostname: '127.0.0.1',
    idleTimeout: 120,
    development: false, // no error pages with stack traces and local paths

    async fetch(req, server) {
      const forbidden = rejectForeign(req);
      if (forbidden) return forbidden;
      const url = new URL(req.url);
      const path = url.pathname;
      const parts = path.split('/').filter(Boolean);

      try {
        // no-store: the UI changes often during development and stale modules break it silently.
        const fresh = { 'cache-control': 'no-store' };
        if (path === '/' || path === '/index.html') return file(join(WEB, 'index.html'), fresh);
        if (parts[0] === 'web' && parts.length === 2) return file(join(WEB, parts[1]), fresh);
        // Image names carry the annotation id and never change.
        if (parts[0] === 'images' && parts.length === 2) {
          return file(join(store.IMAGES, parts[1]), { 'cache-control': 'private, max-age=31536000, immutable' });
        }

        // Stream proxy: the browser talks to us, we talk to the native host.
        if (parts[0] === 'ws' && parts[1]) {
          const ok = server.upgrade(req, { data: { udid: parts[1], queue: [] } });
          return ok ? undefined : new Response('upgrade failed', { status: 400 });
        }

        // Device chrome artwork: rasterized once, then immutable.
        const forever = { 'cache-control': 'public, max-age=31536000, immutable' };
        if (parts[0] === 'chrome' && parts.length === 3 && parts[2].endsWith('.png')) {
          const png = await chromeImage(parts[1], decodeURIComponent(parts[2].slice(0, -4)));
          return png ? file(png, forever) : new Response('not found', { status: 404 });
        }

        if (path === '/api/sims') return json(await devices());
        if (parts[0] === 'api' && parts[1] === 'sims' && parts[3] === 'chrome') return json(await chromeFor(parts[2]));
        if (parts[0] === 'api' && parts[1] === 'sims' && parts[3] === 'mask.png') {
          const png = await maskImage(parts[2]);
          return png ? file(png, forever) : new Response('not found', { status: 404 });
        }
        if (parts[0] === 'api' && parts[1] === 'sims' && parts[3] === 'boot' && req.method === 'POST') {
          await host(`/api/devices/${encodeURIComponent(parts[2])}/boot`, { method: 'POST' });
          return json({ ok: true });
        }

        // SimAgentationPlus runs inside the app; the simulator shares our loopback.
        if (path === '/api/sdk') {
          try {
            const res = await fetch(`${SDK}/snapshot`, { signal: AbortSignal.timeout(800) });
            return res.ok ? json(await res.json()) : new Response(null, { status: 204 });
          } catch {
            return new Response(null, { status: 204 });
          }
        }
        if (path === '/api/annotations' && req.method === 'GET') {
          const status = url.searchParams.get('status') as store.Status | null;
          return json(store.list(status ?? undefined));
        }
        if (path === '/api/annotations' && req.method === 'POST') {
          return json(await createAnnotation(await req.json()), 201);
        }
        if (path === '/api/annotations/finished' && req.method === 'DELETE') {
          store.clearFinished();
          return json({ ok: true });
        }
        if (path === '/api/wait') {
          const requested = Number(url.searchParams.get('timeout'));
          const timeout = Math.min(requested > 0 ? requested : 60, 110) * 1000;
          const deadline = Date.now() + timeout;
          while (!store.list('pending').length && Date.now() < deadline) {
            await nextChange(deadline - Date.now());
          }
          return json(store.list('pending'));
        }
        if (parts[0] === 'api' && parts[1] === 'annotations' && parts[2]) {
          const a = store.get(parts[2]);
          if (!a) return json({ error: 'not found' }, 404);
          if (req.method === 'GET') return json({ ...a, markdown: toMarkdown(a) });
          if (req.method === 'PATCH') {
            const { patch, reply } = parsePatch(await req.json());
            return json(store.update(a.id, patch, reply));
          }
        }
        return new Response('not found', { status: 404 });
      } catch (err) {
        const bad = err instanceof BadRequest || err instanceof SyntaxError; // SyntaxError: body isn't JSON
        return json({ error: (err as Error).message }, bad ? 400 : 500);
      }
    },

    websocket: {
      open(ws: ServerWebSocket<Proxy>) {
        const target = `${HOST.replace(/^http/, 'ws')}/simulators/${encodeURIComponent(ws.data.udid)}/stream`;
        const upstream = new WebSocket(target);
        upstream.binaryType = 'arraybuffer';
        ws.data.upstream = upstream;
        upstream.onopen = () => {
          for (const msg of ws.data.queue) upstream.send(msg);
          ws.data.queue = [];
        };
        upstream.onmessage = (e) => ws.send(e.data as any);
        upstream.onclose = () => ws.close();
        upstream.onerror = () => ws.close(1011, 'host stream error');
      },
      message(ws: ServerWebSocket<Proxy>, msg) {
        const up = ws.data.upstream;
        if (up?.readyState === WebSocket.OPEN) up.send(msg as any);
        else ws.data.queue.push(msg as any);
      },
      close(ws: ServerWebSocket<Proxy>) {
        ws.data.upstream?.close();
      },
    },
  });

  console.error(`sim-agentation: http://localhost:${server.port}  (data in ${store.HOME})`);
  return server;
}
