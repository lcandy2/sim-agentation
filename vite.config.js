import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

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

export default defineConfig({
  root: 'web',
  plugins: [svelte()],
  server: {
    port: DEV_PORT,
    strictPort: true,
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
