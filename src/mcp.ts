// Minimal MCP stdio server. Every tool is a thin call into the HTTP API,
// so the browser UI and the agent always see the same store.
import { PORT } from './server';
import { toMarkdown } from './format';
import type { Annotation } from './store';

const API = `http://127.0.0.1:${PORT}`;

async function api(path: string, init?: RequestInit) {
  const res = await fetch(API + path, init);
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || `HTTP ${res.status}`);
  return body;
}

async function ensureServer() {
  try {
    await fetch(`${API}/api/annotations?status=pending`, { signal: AbortSignal.timeout(800) });
  } catch {
    Bun.spawn(['bun', import.meta.dir + '/cli.ts', 'serve'], { stdout: 'ignore', stderr: 'ignore' }).unref();
    for (let i = 0; i < 40; i++) {
      await Bun.sleep(250);
      try {
        await fetch(`${API}/api/annotations`);
        return;
      } catch {}
    }
  }
}

function render(list: Annotation[], empty: string) {
  if (!list.length) return empty;
  const header =
    `${list.length} annotation(s). Each has a screenshot path you can Read to see the UI.\n` +
    'Acknowledge one when you start on it, resolve it with a short summary when done.';
  return [header, ...list.map(toMarkdown)].join('\n\n');
}

const patch = (id: string, body: object) =>
  api(`/api/annotations/${id}`, { method: 'PATCH', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });

const idArg = { id: { type: 'string', description: 'Annotation id (prefix is fine)' } };

const tools: Record<string, { description: string; properties: object; required?: string[]; run: (a: any) => Promise<string> }> = {
  sim_get_pending: {
    description: 'List pending UI annotations the user drew on the iOS simulator, with element info and screenshot paths.',
    properties: {},
    run: async () => render(await api('/api/annotations?status=pending'), 'No pending annotations.'),
  },
  sim_get_all: {
    description: 'List every annotation, including acknowledged, resolved and dismissed ones.',
    properties: {},
    run: async () => render(await api('/api/annotations'), 'No annotations yet.'),
  },
  sim_watch: {
    description: 'Wait until the user submits at least one annotation, then return the pending list. Use in a loop for hands-free mode.',
    properties: { timeout_seconds: { type: 'number', description: 'Max wait, default 100, max 110' } },
    run: async (a) =>
      render(await api(`/api/wait?timeout=${a.timeout_seconds ?? 100}`), 'Nothing new yet; call sim_watch again to keep waiting.'),
  },
  sim_acknowledge: {
    description: 'Mark an annotation as being worked on. The user sees this in the browser.',
    properties: idArg,
    required: ['id'],
    run: async (a) => (await patch(a.id, { status: 'acknowledged' }), `Acknowledged ${a.id}.`),
  },
  sim_resolve: {
    description: 'Mark an annotation as fixed, with a one-line summary of the change.',
    properties: { ...idArg, summary: { type: 'string' } },
    required: ['id', 'summary'],
    run: async (a) => (await patch(a.id, { status: 'resolved', resolution: a.summary }), `Resolved ${a.id}.`),
  },
  sim_dismiss: {
    description: 'Decline an annotation, with the reason.',
    properties: { ...idArg, reason: { type: 'string' } },
    required: ['id', 'reason'],
    run: async (a) => (await patch(a.id, { status: 'dismissed', resolution: a.reason }), `Dismissed ${a.id}.`),
  },
  sim_reply: {
    description: 'Post a message on an annotation, e.g. a question for the user.',
    properties: { ...idArg, message: { type: 'string' } },
    required: ['id', 'message'],
    run: async (a) => (await patch(a.id, { reply: { from: 'agent', message: a.message } }), `Replied on ${a.id}.`),
  },
};

function send(msg: object) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

async function handle(msg: any) {
  const { id, method, params } = msg;
  if (id === undefined) return; // notification
  try {
    if (method === 'initialize') {
      return send({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: params?.protocolVersion ?? '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: 'sim-agentation', version: '0.1.0' },
          instructions:
            'The user annotates a running iOS simulator in the browser (http://localhost:' + PORT + '). ' +
            'Fetch annotations with sim_get_pending, Read the screenshot paths to see the UI, find the SwiftUI/UIKit code, fix it, then sim_resolve.',
        },
      });
    }
    if (method === 'ping') return send({ jsonrpc: '2.0', id, result: {} });
    if (method === 'tools/list') {
      return send({
        jsonrpc: '2.0',
        id,
        result: {
          tools: Object.entries(tools).map(([name, t]) => ({
            name,
            description: t.description,
            inputSchema: { type: 'object', properties: t.properties, required: t.required ?? [] },
          })),
        },
      });
    }
    if (method === 'tools/call') {
      const tool = tools[params.name];
      if (!tool) throw new Error(`unknown tool ${params.name}`);
      await ensureServer();
      try {
        const text = await tool.run(params.arguments ?? {});
        return send({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text }] } });
      } catch (err) {
        return send({ jsonrpc: '2.0', id, result: { isError: true, content: [{ type: 'text', text: (err as Error).message }] } });
      }
    }
    send({ jsonrpc: '2.0', id, error: { code: -32601, message: `method not found: ${method}` } });
  } catch (err) {
    send({ jsonrpc: '2.0', id, error: { code: -32603, message: (err as Error).message } });
  }
}

export async function mcp() {
  let buffer = '';
  const decoder = new TextDecoder();
  for await (const chunk of Bun.stdin.stream()) {
    buffer += decoder.decode(chunk, { stream: true });
    let nl;
    while ((nl = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, nl).trim();
      buffer = buffer.slice(nl + 1);
      if (line) handle(JSON.parse(line));
    }
  }
}
