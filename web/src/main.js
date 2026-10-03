import { mount } from 'svelte';
import './style.css';

// Hot reload on the host's page (38470) too. While `pnpm dev` runs, the
// host gives a built page the token the Vite dev server left (/api/dev); if
// the server on DEV answers that token, the page loads Vite's HMR client and
// the source entry from it, staying on the host and talking to its API and
// WebSocket. Only DEV, a fixed loopback address, is ever loaded from, and
// anything else there can't answer the token (see vite.config.js). Keep DEV
// in step with vite.config.js.
const DEV = 'http://localhost:38472';

async function handOverToDevServer() {
  if (!import.meta.env.PROD) return false; // already the dev server's page
  try {
    const dev = await fetch('/api/dev', { cache: 'no-store' }).then((r) => (r.status === 200 ? r.json() : null));
    if (typeof dev?.token !== 'string' || dev.token.length < 32) return false;
    const answer = await fetch(`${DEV}/__dev-token`, { cache: 'no-store' }).then((r) => r.text());
    if (answer !== dev.token) return false;
    for (const link of document.querySelectorAll('link[rel="stylesheet"]')) link.remove(); // the source's CSS replaces it
    await import(/* @vite-ignore */ `${DEV}/@vite/client`);
    await import(/* @vite-ignore */ `${DEV}/src/main.js`);
    return true;
  } catch {
    return false; // no dev server: run the build
  }
}

if (!(await handOverToDevServer())) {
  const { default: App } = await import('./App.svelte');
  mount(App, { target: document.body });
}
