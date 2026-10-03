<script>
  import { onMount } from 'svelte';
  import { ui, simulatorOptions, createSimulator } from '../lib/app.svelte.js';

  // `simctl create` from the sidebar's + button, as macOS 27's small dialog
  // (Figma, macOS 27 Community, node 690:10197). Esc cancels.
  let { close } = $props();

  let dialog = $state(null);
  let closing = false;

  // macOS's own sheet, measured from a 60 fps recording on macOS 26: it
  // slides 32 pt down into place (ease-in-out, 260 ms) while fading in over
  // the first 140 ms, and leaves 30 pt up, fading (ease-in, 230 ms); the
  // window behind dims and clears over 270 ms.
  const still = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  const DIM = 'rgba(0, 0, 0, 0.2)';
  onMount(() => {
    dialog.showModal();
    if (still()) return;
    dialog.animate([{ transform: 'translateY(-32px)' }, { transform: 'none' }], { duration: 260, easing: 'cubic-bezier(0.42, 0, 0.58, 1)' });
    dialog.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 140 });
    dialog.animate([{ background: 'transparent' }, { background: DIM }], { duration: 270, pseudoElement: '::backdrop' });
  });
  async function dismiss() {
    if (closing) return;
    closing = true;
    if (!still()) {
      const out = { duration: 230, fill: 'forwards' };
      await Promise.all([
        dialog.animate([{ transform: 'none' }, { transform: 'translateY(-30px)' }], { ...out, easing: 'cubic-bezier(0.42, 0, 1, 1)' }).finished,
        dialog.animate([{ opacity: 1 }, { opacity: 0 }], out).finished,
        dialog.animate([{ background: DIM }, { background: 'transparent' }], { duration: 270, fill: 'forwards', pseudoElement: '::backdrop' }).finished,
      ]);
    }
    dialog.close();
  }

  let options = $state(null);
  let runtime = $state('');
  let deviceType = $state('');
  let name = $state('');
  let named = $state(false); // the user typed a name; stop following the device type
  let busy = $state(false);

  const version = (r) => r.name.replace(/^\D+/, '');
  const runtimes = $derived(
    (options?.runtimes ?? []).toSorted((a, b) => a.platform?.localeCompare(b.platform) || version(b).localeCompare(version(a), undefined, { numeric: true })),
  );
  const types = $derived.by(() => {
    const supported = new Set(options?.runtimes.find((r) => r.identifier === runtime)?.deviceTypes ?? []);
    return (options?.deviceTypes ?? []).filter((t) => supported.has(t.identifier));
  });

  simulatorOptions().then((o) => {
    options = o;
    runtime = runtimes.find((r) => r.platform === 'iOS')?.identifier ?? runtimes[0]?.identifier ?? '';
  });

  // Keep a device type the runtime supports: the selected simulator's model,
  // else the newest iPhone, a Pro before the others.
  const generation = (t) => parseFloat(t.name.match(/\d+/)?.[0] ?? '0');
  $effect(() => {
    if (types.some((t) => t.identifier === deviceType)) return;
    const current = ui.sims.find((s) => s.udid === ui.udid)?.deviceType;
    const newest = types
      .filter((t) => t.name.startsWith('iPhone'))
      .toSorted((a, b) => generation(b) - generation(a) || b.name.endsWith(' Pro') - a.name.endsWith(' Pro'))[0];
    deviceType = (types.find((t) => t.identifier === current) ?? newest ?? types[0])?.identifier ?? '';
  });
  $effect(() => {
    if (!named) name = types.find((t) => t.identifier === deviceType)?.name ?? '';
  });

  async function submit(e) {
    e.preventDefault();
    busy = true;
    if (await createSimulator({ name: name.trim(), deviceType, runtime })) dismiss();
    busy = false;
  }
</script>

<dialog class="sheet" bind:this={dialog} onclose={close} oncancel={(e) => { e.preventDefault(); dismiss(); }} aria-labelledby="new-sim-title">
  <form onsubmit={submit}>
    <div class="sheet-grid">
      <div class="sheet-message">
        <h2 id="new-sim-title">New Simulator</h2>
        <p>Choose an OS and a device. The simulator shows up in the device list, ready to start.</p>
      </div>
      <label for="new-sim-os">OS:</label>
      <select id="new-sim-os" class="popup" bind:value={runtime} disabled={!options}>
        {#if !options}<option value="">Loading…</option>{/if}
        {#each runtimes as r (r.identifier)}<option value={r.identifier}>{r.name}</option>{/each}
      </select>
      <label for="new-sim-device">Device:</label>
      <select id="new-sim-device" class="popup" bind:value={deviceType} disabled={!options}>
        {#if !options}<option value="">Loading…</option>{/if}
        {#each types as t (t.identifier)}<option value={t.identifier}>{t.name}</option>{/each}
      </select>
      <label for="new-sim-name">Name:</label>
      <input id="new-sim-name" class="field" bind:value={name} oninput={() => (named = true)} spellcheck="false" autocomplete="off">
    </div>
    <div class="sheet-buttons">
      <button type="button" class="push-btn" onclick={dismiss}>Cancel</button>
      <button type="submit" class="push-btn default" disabled={busy || !deviceType || !name.trim()}>{busy ? 'Creating…' : 'Create'}</button>
    </div>
  </form>
</dialog>
