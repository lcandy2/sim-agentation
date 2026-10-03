<script>
  import { ui } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import DeviceRow from './DeviceRow.svelte';

  const version = (runtime) => runtime.replace(/^\D+/, '');
  const byVersionThenName = (a, b) =>
    version(b.runtime).localeCompare(version(a.runtime), undefined, { numeric: true }) || a.name.localeCompare(b.name);

  const sections = $derived.by(() => {
    const query = ui.query.trim().toLowerCase();
    const shown = ui.sims.filter((s) => !query || `${s.name} ${s.runtime}`.toLowerCase().includes(query));
    return [
      ['Running', shown.filter((s) => s.state === 'Booted').sort(byVersionThenName)],
      ['Available', shown.filter((s) => s.state !== 'Booted').sort(byVersionThenName)],
    ].filter(([, list]) => list.length);
  });
</script>

<aside class="sidebar" id="sidebar">
  <div class="sidebar-top">
    <span class="brand">Sim Agentation</span>
  </div>
  <label class="search">
    <span data-icon="search">{@html icon('search')}</span>
    <input type="search" placeholder="Search" autocomplete="off" spellcheck="false" bind:value={ui.query}>
  </label>
  <nav class="devices" aria-label="Simulators">
    {#each sections as [title, list] (title)}
      <h3>{title}</h3>
      {#each list as sim (sim.udid)}
        <DeviceRow {sim} version={version(sim.runtime)} />
      {/each}
    {:else}
      <p class="none">No simulators match.</p>
    {/each}
  </nav>
</aside>
