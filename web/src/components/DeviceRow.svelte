<script>
  import { ui, chromeOf, selectDevice, startDevice, shutdownDevice, openDevice } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import { thumbnail } from '../lib/thumbnail.js';
  import ContextMenu from './ContextMenu.svelte';

  let { sim, version } = $props();

  // The device picture inside a 32 px circle, as in Device Hub: lit when
  // the simulator runs, grayed out when it's shut down.
  const THUMB_HEIGHT = 24;

  let row = $state(null);
  const selected = $derived(sim.udid === ui.udid);
  $effect(() => {
    if (selected) row?.scrollIntoView({ block: 'nearest' });
  });

  // Right-clicked, this device's actions at the pointer, as Device Hub's
  // list has them, the row ringed in the accent meanwhile (macOS's mark for
  // what a context menu is for). They act on this device, selected or not.
  let menuAt = $state(null);
  const menu = $derived([
    [sim.state === 'Booted'
      ? { label: 'Shut Down', icon: 'power', run: () => shutdownDevice(sim.udid) }
      : { label: 'Start', icon: 'play', run: () => startDevice(sim.udid) }],
    [
      { label: 'Open in New Tab', icon: 'new-tab', run: () => openDevice(sim.udid) },
      { label: 'Open in New Window', icon: 'new-window', run: () => openDevice(sim.udid, { window: true }) },
    ],
    [{ label: 'Rename…', icon: 'rename', run: () => sheet('rename') }],
    [{ label: 'Reset Content and Settings…', icon: 'erase', run: () => sheet('erase') }],
    [{ label: 'Remove…', icon: 'trash', run: () => sheet('remove') }],
  ]);
  function sheet(kind) {
    ui.sheetFor = sim.udid === ui.udid ? null : sim.udid;
    ui.sheet = kind;
  }
  function contextMenu(e) {
    e.preventDefault();
    // From the keyboard (the menu key, ⇧F10) there's no pointer: under the row.
    const r = row.getBoundingClientRect();
    menuAt = e.clientX || e.clientY ? { x: e.clientX, y: e.clientY } : { x: r.left + 16, y: r.bottom };
  }

  let picture = $state(null);
  $effect(() => {
    let current = true;
    chromeOf(sim.udid)
      .then((c) => c && thumbnail(c, THUMB_HEIGHT))
      .then((url) => current && (picture = url));
    return () => (current = false);
  });
</script>

<button
  bind:this={row}
  class="device-row"
  class:booted={sim.state === 'Booted'}
  class:selected
  class:context-target={menuAt}
  title="{sim.name}, {sim.runtime}{sim.state === 'Booted' ? ', running' : ''}"
  onclick={() => selectDevice(sim)}
  oncontextmenu={contextMenu}
>
  <span class="thumb">
    {#if picture}<img src={picture} alt="">{:else}{@html icon('phone')}{/if}
  </span>
  <span class="text">
    <span class="name">{sim.name}</span>
    <span class="kind">Simulator</span>
  </span>
  <span class="version">{version}</span>
</button>
{#if menuAt}
  <ContextMenu x={menuAt.x} y={menuAt.y} groups={menu} close={() => (menuAt = null)} />
{/if}
