import { mount } from 'svelte';
import './style.css';

// Hot reload on the host's page (38470) too. `pnpm dev` first builds a copy
// of the UI in the "handoff" mode, and only that copy, on finding the Vite
// dev server, hands over to it: its HMR client and the source entry load
// from there, while the page stays on the host, whose API and WebSocket it
// keeps talking to. A production build has none of this, so it never runs
// code from another port. Keep DEV in step with vite.config.js.
const DEV = 'http://localhost:38472';

async function handOverToDevServer() {
  if (import.meta.env.MODE !== 'handoff') return false;
  try {
    if (!(await fetch(`${DEV}/@vite/client`, { cache: 'no-store' })).ok) return false;
  } catch {
    return false; // no dev server: run the build
  }
  for (const link of document.querySelectorAll('link[rel="stylesheet"]')) link.remove(); // the source's CSS replaces it
  await import(/* @vite-ignore */ `${DEV}/@vite/client`);
  await import(/* @vite-ignore */ `${DEV}/src/main.js`);
  return true;
}

if (!(await handOverToDevServer())) {
  const { default: App } = await import('./App.svelte');
  mount(App, { target: document.body });
}
