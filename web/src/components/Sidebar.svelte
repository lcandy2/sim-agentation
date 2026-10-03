<script>
  import { ui, setFilter } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import DeviceRow from './DeviceRow.svelte';
  import NewSimulator from './NewSimulator.svelte';
  import Popover from './Popover.svelte';

  const FILTERS = [
    { id: 'all', label: 'All Simulators', heading: 'Available' },
    { id: 'running', label: 'Running', heading: 'Running' },
    { id: 'iphone', label: 'iPhone', heading: 'iPhone' },
    { id: 'ipad', label: 'iPad', heading: 'iPad' },
  ];
  const matches = {
    all: () => true,
    running: (s) => s.state === 'Booted',
    iphone: (s) => s.deviceType.includes('iPhone'),
    ipad: (s) => s.deviceType.includes('iPad'),
  };

  let creating = $state(false);

  const version = (runtime) => runtime.replace(/^\D+/, '');
  const byVersionThenName = (a, b) =>
    version(b.runtime).localeCompare(version(a.runtime), undefined, { numeric: true }) || a.name.localeCompare(b.name);

  // One list, as in Device Hub: a running device shows by its lit picture.
  const filter = $derived(FILTERS.find((f) => f.id === ui.filter) ?? FILTERS[0]);
  const list = $derived.by(() => {
    const query = ui.query.trim().toLowerCase();
    return ui.sims
      .filter((s) => (matches[filter.id] ?? matches.all)(s))
      .filter((s) => !query || `${s.name} ${s.runtime}`.toLowerCase().includes(query))
      .sort(byVersionThenName);
  });
</script>

<aside class="sidebar" id="sidebar">
  <div class="sidebar-top">
    <span class="brand">SimAgentation</span>
    <div class="pill bar-pill" role="group" aria-label="Simulators">
      <button class="icon-btn" title="New simulator" aria-label="New simulator" onclick={() => (creating = true)}>{@html icon('plus')}</button>
      <Popover icon="filter" title="Filter simulators" align="left">
        {#snippet children(close)}
          <div class="menu" role="menu">
            {#each FILTERS as f (f.id)}
              <button class="menu-item" role="menuitemradio" aria-checked={ui.filter === f.id} onclick={() => { setFilter(f.id); close(); }}>
                <span class="check">{ui.filter === f.id ? '✓' : ''}</span>{f.label}
              </button>
            {/each}
          </div>
        {/snippet}
      </Popover>
    </div>
  </div>
  <label class="search">
    <span data-icon="search">{@html icon('search')}</span>
    <input type="search" placeholder="Search" autocomplete="off" spellcheck="false" bind:value={ui.query}>
  </label>
  <nav class="devices" aria-label="Simulators">
    <h3>{filter.heading}</h3>
    {#each list as sim (sim.udid)}
      <DeviceRow {sim} version={version(sim.runtime)} />
    {:else}
      <p class="none">No simulators match.</p>
    {/each}
  </nav>
  {#if creating}<NewSimulator close={() => (creating = false)} />{/if}
</aside>
