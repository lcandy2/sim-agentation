<script>
  import { ui, setFilter, refreshDevices, selectDevice } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import { blink } from '../lib/blink.js';
  import DeviceRow from './DeviceRow.svelte';
  import NewSimulator from './NewSimulator.svelte';
  import Popover from './Popover.svelte';
  import ContextMenu from './ContextMenu.svelte';

  const FILTERS = [
    { id: 'all', label: 'All Simulators', heading: 'Available', icon: 'devices' },
    { id: 'running', label: 'Running', heading: 'Running', icon: 'running' },
    { id: 'iphone', label: 'iPhone', heading: 'iPhone', icon: 'phone' },
    { id: 'ipad', label: 'iPad', heading: 'iPad', icon: 'ipad' },
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

  // As a Mac list: a click selects one device and shows it; ⌘-click adds or
  // takes away one, ⇧-click selects the range from the last clicked (⌘⇧ adds
  // it), neither changing the device shown. ⌘⌫ removes what's selected.
  let anchor = null;
  function pick(sim, e) {
    const order = list.map((s) => s.udid);
    const current = ui.picked.length ? ui.picked : ui.udid ? [ui.udid] : [];
    const from = order.indexOf(anchor ?? ui.udid);
    if (e.shiftKey && from >= 0) {
      const to = order.indexOf(sim.udid);
      const range = order.slice(Math.min(from, to), Math.max(from, to) + 1);
      ui.picked = e.metaKey ? [...new Set([...current, ...range])] : range;
      return;
    }
    anchor = sim.udid;
    if (e.metaKey) {
      ui.picked = current.includes(sim.udid) ? current.filter((u) => u !== sim.udid) : [...current, sim.udid];
      return;
    }
    selectDevice(sim);
  }
  function listKeys(e) {
    if (!(e.metaKey && e.key === 'Backspace')) return;
    const picked = (ui.picked.length ? ui.picked : [ui.udid]).filter((u) => ui.sims.some((s) => s.udid === u));
    if (!picked.length) return;
    e.preventDefault();
    ui.sheetFor = picked.length > 1 ? picked : picked[0] === ui.udid ? null : picked[0];
    ui.sheet = 'remove';
  }

  let listAt = $state(null);
  function listMenu(e) {
    if (e.target.closest('.device-row')) return;
    e.preventDefault();
    listAt = { x: e.clientX, y: e.clientY };
  }
</script>

<aside class="sidebar" id="sidebar">
  <div class="sidebar-top">
    <img class="brand-icon" src="/icon.svg" alt="" width="24" height="24">
    <span class="brand">SimAgentation</span>
    <div class="pill bar-pill" role="group" aria-label="Simulators">
      <button class="icon-btn" title="New simulator" aria-label="New simulator" onclick={() => (creating = true)}>{@html icon('plus')}</button>
      <Popover icon="filter" title="Filter simulators" align="left">
        {#snippet children(close)}
          <div class="menu" role="menu">
            {#each FILTERS as f (f.id)}
              <button class="menu-item" role="menuitemradio" aria-checked={ui.filter === f.id} onclick={async (e) => { if (!(await blink(e.currentTarget))) return; close(); setFilter(f.id); }}>
                <span class="check">{ui.filter === f.id ? '✓' : ''}</span>{@html icon(f.icon)}{f.label}
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
  <!-- Right-clicked outside a row (rows have their own), the list's menu. -->
  <nav class="devices" aria-label="Simulators" oncontextmenu={listMenu} onkeydown={listKeys}>
    <h3>{filter.heading}</h3>
    {#each list as sim (sim.udid)}
      <DeviceRow {sim} version={version(sim.runtime)} {pick} />
    {:else}
      {#if !ui.creating}<p class="none">No simulators match.</p>{/if}
    {/each}
    {#if ui.creating}
      <!-- The simulator being created, until it's in the list. -->
      <div class="device-row creating" aria-busy="true">
        <span class="thumb">{@html icon('phone')}</span>
        <span class="text">
          <span class="name">{ui.creating.name}</span>
          <span class="kind"><span class="spinner" aria-hidden="true">{@html icon('progress')}</span>Creating…</span>
        </span>
        <span class="version">{version(ui.creating.runtime)}</span>
      </div>
    {/if}
  </nav>
  {#if listAt}<ContextMenu x={listAt.x} y={listAt.y} groups={[[{ label: 'Refresh', icon: 'refresh', run: refreshDevices }]]} close={() => (listAt = null)} />{/if}
  {#if creating}<NewSimulator close={() => (creating = false)} />{/if}
</aside>
