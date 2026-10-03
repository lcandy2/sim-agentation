<script>
  import { ui, simulatorOptions, createSimulator } from '../lib/app.svelte.js';

  // `simctl create` from the sidebar's + button.
  let { close } = $props();

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
    if (await createSimulator({ name: name.trim(), deviceType, runtime })) close();
    busy = false;
  }
</script>

<form class="new-sim" onsubmit={submit}>
  <h4>New Simulator</h4>
  {#if !options}
    <p class="hint">Loading device types…</p>
  {:else}
    <label><span>OS</span>
      <select bind:value={runtime}>
        {#each runtimes as r (r.identifier)}<option value={r.identifier}>{r.name}</option>{/each}
      </select>
    </label>
    <label><span>Device</span>
      <select bind:value={deviceType}>
        {#each types as t (t.identifier)}<option value={t.identifier}>{t.name}</option>{/each}
      </select>
    </label>
    <label><span>Name</span>
      <input bind:value={name} oninput={() => (named = true)} spellcheck="false" autocomplete="off">
    </label>
  {/if}
  <div class="form-row">
    <button type="button" class="text-btn" onclick={close}>Cancel</button>
    <button type="submit" class="text-btn primary" disabled={busy || !deviceType || !name.trim()}>{busy ? 'Creating…' : 'Create'}</button>
  </div>
</form>
