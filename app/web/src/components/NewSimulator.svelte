<script>
  import { onMount } from 'svelte';
  import { ui, simulatorOptions, createSimulator, chromeOf } from '../lib/app.svelte.js';
  import { thumbnail } from '../lib/thumbnail.js';
  import { showSheet, sheetDismiss } from '../lib/sheet.js';
  import { icon } from '../lib/icons.js';

  // `simctl create` from the sidebar's + button, as macOS 27's Alert (Figma,
  // Alerts page) with its fields below the message. Esc cancels.
  let { close } = $props();

  let dialog = $state(null);

  // As macOS's sheet (lib/sheet.js).
  onMount(() => showSheet(dialog));
  const dismiss = sheetDismiss(() => dialog);

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

  // The alert's icon: the chosen device type's picture, from a simulator of
  // that type if there is one.
  let picture = $state(null);
  $effect(() => {
    const sim = ui.sims.find((s) => s.deviceType === deviceType);
    picture = null;
    if (!sim) return;
    let current = true;
    chromeOf(sim.udid).then((c) => c && thumbnail(c, 64)).then((url) => current && (picture = url));
    return () => (current = false);
  });

  async function submit(e) {
    e.preventDefault();
    busy = true;
    if (await createSimulator({ name: name.trim(), deviceType, runtime })) dismiss();
    busy = false;
  }
</script>

<dialog class="sheet" bind:this={dialog} onclose={close} oncancel={(e) => { e.preventDefault(); dismiss(); }} aria-labelledby="new-sim-title">
  <form class="alert-body" onsubmit={submit}>
    <div class="alert-icon">{#if picture}<img src={picture} alt="">{:else}{@html icon('devices')}{/if}</div>
    <div class="alert-text">
      <h2 id="new-sim-title">New Simulator</h2>
      <p>Choose an OS and a device. The simulator shows up in the device list, ready to start.</p>
    </div>
    <div class="alert-fields">
      <select class="popup" aria-label="OS" bind:value={runtime} disabled={!options}>
        {#if !options}<option value="">Loading…</option>{/if}
        {#each runtimes as r (r.identifier)}<option value={r.identifier}>{r.name}</option>{/each}
      </select>
      <select class="popup" aria-label="Device" bind:value={deviceType} disabled={!options}>
        {#if !options}<option value="">Loading…</option>{/if}
        {#each types as t (t.identifier)}<option value={t.identifier}>{t.name}</option>{/each}
      </select>
      <input class="field" aria-label="Name" placeholder="Name" bind:value={name} oninput={() => (named = true)} spellcheck="false" autocomplete="off">
    </div>
    <div class="alert-buttons">
      <button type="button" class="alert-btn" onclick={dismiss}>Cancel</button>
      <button type="submit" class="alert-btn default" disabled={busy || !deviceType || !name.trim()}>{busy ? 'Creating…' : 'Create'}</button>
    </div>
  </form>
</dialog>
