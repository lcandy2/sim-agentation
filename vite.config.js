import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import { randomBytes } from 'node:crypto';
import { rmSync, writeFileSync } from 'node:fs';

// The UI is built to static files the Swift host serves. `pnpm dev` also
// serves it with hot reload on DEV_PORT, proxying everything else to the
// running host (`pnpm start`).
const HOST = `http://localhost:${process.env.SIM_AGENTATION_PORT ?? 38470}`;
const DEV_PORT = 38472;
const DEV_ORIGINS = new Set([`http://localhost:${DEV_PORT}`, `http://127.0.0.1:${DEV_PORT}`]);
const HOST_PORT = new URL(HOST).port;
const HOST_ORIGINS = [`http://localhost:${HOST_PORT}`, `http://127.0.0.1:${HOST_PORT}`];

// The host answers only its own Host and Origin. changeOrigin sets the Host;
// the page's own Origin is rewritten to the host's, while any other site's
// Origin passes through unchanged, so the host still refuses it.
function asHost(proxy) {
  const rewrite = (proxyReq, req) => {
    if (DEV_ORIGINS.has(req.headers.origin)) proxyReq.setHeader('origin', HOST);
  };
  proxy.on('proxyReq', rewrite);
  proxy.on('proxyReqWs', rewrite);
}
const toHost = { target: HOST, changeOrigin: true, configure: asHost };

// Hot reload on the host's page: while the dev server runs it leaves a fresh
// token and its process id in web/.dev-server.json, readable by this user
// alone, which the host hands the page (/api/dev) while that process lives;
// it answers the token at /__dev-token, to the host's page alone. A built
// page loads the source from DEV_PORT only when the two agree
// (web/src/main.js), so nothing else listening there can slip code in.
function devServerNote() {
  const file = new URL('./web/.dev-server.json', import.meta.url);
  const token = randomBytes(24).toString('hex');
  return {
    name: 'sim-agentation-dev-server-note',
    configureServer(server) {
      rmSync(file, { force: true }); // a new file, so the owner-only mode holds
      writeFileSync(file, JSON.stringify({ token, pid: process.pid }), { mode: 0o600, flag: 'wx' });
      const remove = () => rmSync(file, { force: true });
      server.httpServer?.once('close', remove);
      process.once('exit', remove);
      for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { remove(); process.exit(); });
      server.middlewares.use('/__dev-token', (req, res) => {
        res.setHeader('cache-control', 'no-store');
        res.end(token); // readable cross-origin by the host's page alone (server.cors)
      });
    },
  };
}

export default defineConfig({
  root: 'web',
  plugins: [svelte(), devServerNote()],
  server: {
    port: DEV_PORT,
    strictPort: true,
    // The host's built page loads the source from here (web/src/main.js),
    // so the dev server's URLs are absolute to it, and it alone may read
    // them across origins (Vite's default lets any localhost page).
    origin: `http://localhost:${DEV_PORT}`,
    cors: { origin: HOST_ORIGINS },
    proxy: {
      '/api': toHost,
      '/images': toHost,
      '/chrome': toHost,
      '/ws': { ...toHost, ws: true },
    },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'es2023',
  },
});
