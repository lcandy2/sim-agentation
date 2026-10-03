import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// The UI is built to static files the Swift host serves; there is no dev
// server — `pnpm dev` rebuilds on change and you reload the page.
export default defineConfig({
  root: 'web',
  plugins: [svelte()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    target: 'es2023',
  },
});
