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

// Hot reload on the host's page: while the dev server runs it leaves its
// address and a fresh token in web/.dev-server.json, which the host hands the
// page (/api/dev), and answers the token at /__dev-token. A built page loads
// the source from here only when the two agree (web/src/main.js), so nothing
// else listening on this port can slip code into it.
function devServerNote() {
  const file = new URL('./web/.dev-server.json', import.meta.url);
  const token = randomBytes(24).toString('hex');
  return {
    name: 'sim-agentation-dev-server-note',
    configureServer(server) {
      writeFileSync(file, JSON.stringify({ url: `http://localhost:${DEV_PORT}`, token }));
      const remove = () => rmSync(file, { force: true });
      server.httpServer?.once('close', remove);
      process.once('exit', remove);
      for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => { remove(); process.exit(); });
      server.middlewares.use('/__dev-token', (req, res) => {
        const origin = req.headers.origin;
        if (origin && /^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(origin)) res.setHeader('access-control-allow-origin', origin);
        res.setHeader('cache-control', 'no-store');
        res.end(token);
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
    // so the dev server's URLs are absolute to it.
    origin: `http://localhost:${DEV_PORT}`,
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
