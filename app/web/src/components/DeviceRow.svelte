<script>
  import { ui, chromeOf, selectDevice, startDevice, shutdownDevice, openDevice } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import { thumbnail } from '../lib/thumbnail.js';
  import ContextMenu from './ContextMenu.svelte';

  // pick: the list's click (⌘ and ⇧ select several, components/Sidebar.svelte).
  // joinAbove, joinBelow: the rows next to it are selected too (one block).
  let { sim, version, pick = (s) => selectDevice(s), joinAbove = false, joinBelow = false } = $props();

  // The device picture inside a 32 px circle, as in Device Hub: lit when
  // the simulator runs, grayed out when it's shut down.
  const THUMB_HEIGHT = 24;

  let row = $state(null);
  const shown = $derived(sim.udid === ui.udid);
  const selected = $derived(ui.picked.length ? ui.picked.includes(sim.udid) : shown);
  // Busy, its line says with what in place of "Simulator": what this page is
  // doing to it, else what CoreSimulator says (Xcode or simctl at work).
  const STATES = { Booting: 'Starting…', 'Shutting Down': 'Shutting Down…', Creating: 'Creating…' };
  const busy = $derived(ui.busy[sim.udid] ?? STATES[sim.state]);
  $effect(() => {
    if (shown) row?.scrollIntoView({ block: 'nearest' });
  });

  // Right-clicked, this device's actions at the pointer, as Device Hub's
  // list has them, the row ringed in the accent meanwhile (macOS's mark for
  // what a context menu is for). They act on this device, selected or not;
  // right-clicked among several selected, on all of them.
  let menuAt = $state(null);
  const group = $derived(ui.picked.length > 1 && ui.picked.includes(sim.udid) ? ui.sims.filter((s) => ui.picked.includes(s.udid)) : null);
  const menu = $derived(group ? groupMenu(group) : [
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
  // Several: start those shut down, shut down those running, reset or remove
  // them all, one dialog for all; renaming and opening are one device's.
  function groupMenu(sims) {
    const off = sims.filter((s) => s.state === 'Shutdown');
    const on = sims.filter((s) => s.state === 'Booted');
    return [
      [
        ...(off.length ? [{ label: 'Start', icon: 'play', run: () => off.forEach((s) => startDevice(s.udid)) }] : []),
        ...(on.length ? [{ label: 'Shut Down', icon: 'power', run: () => on.forEach((s) => shutdownDevice(s.udid)) }] : []),
      ],
      [{ label: 'Reset Content and Settings…', icon: 'erase', run: () => sheet('erase', sims.map((s) => s.udid)) }],
      [{ label: 'Remove…', icon: 'trash', run: () => sheet('remove', sims.map((s) => s.udid)) }],
    ].filter((g) => g.length);
  }
  function sheet(kind, udids = null) {
    ui.sheetFor = udids ?? (sim.udid === ui.udid ? null : sim.udid);
    ui.sheet = kind;
  }
  function contextMenu(e) {
    e.preventDefault();
    // From the keyboard (the menu key, ⇧F10) there's no pointer: under the row.
    const r = row.getBoundingClientRect();
    menuAt = e.clientX || e.clientY ? { x: e.clientX, y: e.clientY } : { x: r.left + 16, y: r.bottom };
    ui.contextFor = group ? group.map((s) => s.udid) : [sim.udid];
  }
  function closeMenu() {
    menuAt = null;
    ui.contextFor = [];
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
  class:join-above={joinAbove}
  class:join-below={joinBelow}
  class:context-target={ui.contextFor.includes(sim.udid)}
  class:removing={busy === 'Removing…'}
  aria-busy={!!busy}
  title="{sim.name}, {sim.runtime}{sim.state === 'Booted' ? ', running' : ''}"
  onclick={(e) => pick(sim, e)}
  oncontextmenu={contextMenu}
>
  <span class="thumb">
    {#if picture}<img src={picture} alt="">{:else}{@html icon('phone')}{/if}
  </span>
  <span class="text">
    <span class="name">{sim.name}</span>
    <span class="kind">{#if busy}<span class="spinner" aria-hidden="true">{@html icon('progress')}</span>{busy}{:else}Simulator{/if}</span>
  </span>
  <span class="version">{version}</span>
</button>
{#if menuAt}
  <ContextMenu x={menuAt.x} y={menuAt.y} groups={menu} close={closeMenu} />
{/if}
