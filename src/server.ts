import { join } from 'node:path';
import type { ServerWebSocket } from 'bun';
import * as store from './store';
import { toMarkdown } from './format';
import { hitTest, nodesInRect, screenContext, summarize } from '../web/ax.js';

export const PORT = Number(process.env.SIM_AGENTATION_PORT || 4848);
const BAGUETTE = process.env.BAGUETTE_URL || 'http://127.0.0.1:8421';
const SDK = process.env.SIM_AGENTATION_SDK_URL || 'http://127.0.0.1:4850';
const WEB = join(import.meta.dir, '..', 'web');

async function baguetteUp() {
  try {
    const res = await fetch(`${BAGUETTE}/simulators`, { signal: AbortSignal.timeout(800) });
    return res.ok;
  } catch {
    return false;
  }
}

async function ensureBaguette() {
  if (await baguetteUp()) return;
  const port = new URL(BAGUETTE).port || '8421';
  Bun.spawn(['baguette', 'serve', '--port', port], { stdout: 'ignore', stderr: 'ignore' }).unref();
  for (let i = 0; i < 40; i++) {
    await Bun.sleep(250);
    if (await baguetteUp()) return;
  }
  throw new Error(`baguette serve did not come up on ${BAGUETTE}`);
}

async function baguette(...args: string[]) {
  const proc = Bun.spawn(['baguette', ...args], { stdout: 'pipe', stderr: 'pipe' });
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (code !== 0) throw new Error(err.trim() || `baguette ${args[0]} exited ${code}`);
  return out;
}

async function devices() {
  const data = JSON.parse(await baguette('list', '--json'));
  return [...(data.running ?? []), ...(data.available ?? [])];
}

const json = (data: unknown, status = 200) => Response.json(data, { status });

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
  if (!body.comment?.trim()) throw new Error('comment is required');
  const id = store.newId();
  const full = join(store.IMAGES, `${id}-full.jpg`);
  const crop = join(store.IMAGES, `${id}-crop.jpg`);
  await Bun.write(full, Buffer.from(body.full, 'base64'));
  await Bun.write(crop, Buffer.from(body.crop, 'base64'));

  const hit = body.kind === 'element' && body.point ? hitTest(body.tree, body.point.x, body.point.y) : null;
  const device = (await devices().catch(() => [])).find((d: any) => d.udid === body.udid);
  const now = new Date().toISOString();
  return store.add({
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
    inside: nodesInRect(body.tree, body.rect).slice(0, 20).map((e: any) => summarize(e.node)),
    screen: screenContext(body.tree),
    app: body.app ?? { bundleId: null, name: body.tree?.label?.trim() || null },
    source: body.source ?? [],
    views: body.views ?? [],
    controller: body.controller ?? null,
    images: { full, crop },
    replies: [],
    resolution: null,
  });
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
  await ensureBaguette();

  const server = Bun.serve<Proxy, {}>({
    port: PORT,
    hostname: '127.0.0.1',
    idleTimeout: 120,

    async fetch(req, server) {
      const url = new URL(req.url);
      const path = url.pathname;
      const parts = path.split('/').filter(Boolean);

      try {
        // no-store: the UI changes often during development and stale modules break it silently.
        const fresh = { headers: { 'cache-control': 'no-store' } };
        if (path === '/' || path === '/index.html') return new Response(Bun.file(join(WEB, 'index.html')), fresh);
        if (parts[0] === 'web' && parts.length === 2) return new Response(Bun.file(join(WEB, parts[1])), fresh);
        if (parts[0] === 'images' && parts.length === 2) return new Response(Bun.file(join(store.IMAGES, parts[1])));

        // Stream proxy. baguette refuses cross-origin sockets, so the
        // browser talks to us and we talk to baguette.
        if (parts[0] === 'ws' && parts[1]) {
          const ok = server.upgrade(req, { data: { udid: parts[1], queue: [] } });
          return ok ? undefined : new Response('upgrade failed', { status: 400 });
        }

        if (path === '/api/sims') return json(await devices());
        if (parts[0] === 'api' && parts[1] === 'sims' && parts[3] === 'layout') {
          return json(JSON.parse(await baguette('chrome', 'layout', '--udid', parts[2])));
        }
        if (parts[0] === 'api' && parts[1] === 'sims' && parts[3] === 'boot' && req.method === 'POST') {
          await baguette('boot', '--udid', parts[2]);
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
          const timeout = Math.min(Number(url.searchParams.get('timeout') || 60), 110) * 1000;
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
            const body = await req.json();
            const patch: Partial<store.Annotation> = {};
            if (body.status) {
              if (!['pending', 'acknowledged', 'resolved', 'dismissed'].includes(body.status)) {
                return json({ error: `bad status ${body.status}` }, 400);
              }
              patch.status = body.status;
            }
            if (body.resolution !== undefined) patch.resolution = body.resolution;
            const reply = body.reply ? { ...body.reply, at: new Date().toISOString() } : undefined;
            return json(store.update(a.id, patch, reply));
          }
        }
        return new Response('not found', { status: 404 });
      } catch (err) {
        return json({ error: (err as Error).message }, 500);
      }
    },

    websocket: {
      open(ws: ServerWebSocket<Proxy>) {
        const target = `${BAGUETTE.replace(/^http/, 'ws')}/simulators/${encodeURIComponent(ws.data.udid)}/stream?format=mjpeg&version=v2`;
        const upstream = new WebSocket(target);
        upstream.binaryType = 'arraybuffer';
        ws.data.upstream = upstream;
        upstream.onopen = () => {
          for (const msg of ws.data.queue) upstream.send(msg);
          ws.data.queue = [];
        };
        upstream.onmessage = (e) => ws.send(e.data as any);
        upstream.onclose = () => ws.close();
        upstream.onerror = () => ws.close(1011, 'baguette stream error');
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
