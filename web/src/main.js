import { mount } from 'svelte';
import './style.css';

// Hot reload on the host's page (38470) too. While `pnpm dev` runs, the
// host tells a built page where the Vite dev server is and the token it left
// (/api/dev); if the server there answers that token, the page loads Vite's
// HMR client and the source entry from it, staying on the host and talking
// to its API and WebSocket. Anything else on that port can't answer the
// token, so it can't get code into the page (see vite.config.js).
async function handOverToDevServer() {
  if (!import.meta.env.PROD) return false; // already the dev server's page
  try {
    const dev = await fetch('/api/dev', { cache: 'no-store' }).then((r) => (r.status === 200 ? r.json() : null));
    if (!dev?.url || !dev.token) return false;
    const answer = await fetch(`${dev.url}/__dev-token`, { cache: 'no-store' }).then((r) => r.text());
    if (answer !== dev.token) return false;
    for (const link of document.querySelectorAll('link[rel="stylesheet"]')) link.remove(); // the source's CSS replaces it
    await import(/* @vite-ignore */ `${dev.url}/@vite/client`);
    await import(/* @vite-ignore */ `${dev.url}/src/main.js`);
    return true;
  } catch {
    return false; // no dev server: run the build
  }
}

if (!(await handOverToDevServer())) {
  const { default: App } = await import('./App.svelte');
  mount(App, { target: document.body });
}
