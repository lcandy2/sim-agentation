<script>
  import {
    ui, setMode, setZoom, zoomIn, zoomOut, togglePanel, toggleFocus, setInspectorTab,
    copyPending, clearDone, saveScreenshot, pressButton,
  } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import Popover from './Popover.svelte';

  const status = $derived(ui.flash ?? ui.status);

  // The … menu: what has no button of its own in Device Hub's toolbar.
  const menu = $derived([
    [
      { label: 'Copy Pending Annotations', icon: 'copy', run: copyPending },
      { label: 'Remove Resolved Annotations', icon: 'clear-done', run: clearDone },
    ],
    [
      { label: 'Save Screenshot', icon: 'screenshot', run: saveScreenshot, disabled: !ui.running },
      { label: 'Lock', icon: 'lock', run: () => pressButton('lock'), disabled: !ui.running },
      { label: 'App Switcher', icon: 'app-switcher', run: () => pressButton('app-switcher'), disabled: !ui.running },
    ],
    [
      { label: 'Stream Settings', icon: 'sliders', run: () => setInspectorTab('settings') },
      { label: 'Device Info', icon: 'info', run: () => setInspectorTab('info') },
    ],
    [
      { label: ui.panels.sidebar ? 'Hide Device List' : 'Show Device List', icon: 'sidebar', run: () => togglePanel('sidebar') },
      { label: ui.panels.inspector ? 'Hide Inspector' : 'Show Inspector', icon: 'inspector', run: () => togglePanel('inspector') },
    ],
  ]);
</script>

<header class="canvas-top">
  <div class="title">
    <div class="title-name">{ui.simName}</div>
    <div class="title-sub"><span>{ui.runtime}</span><span class="status">{status}</span></div>
  </div>
  <div class="toolbar">
    <div class="pill segmented" role="group" aria-label="Mode">
      <button
        id="mode-interact"
        class="icon-btn"
        class:on={ui.mode === 'interact' && ui.running}
        title="Interact: use the app (I)"
        data-icon="pointer"
        disabled={!ui.running}
        onclick={() => setMode('interact')}
      >{@html icon('pointer')}</button>
      <button
        id="mode-annotate"
        class="icon-btn"
        class:on={ui.mode === 'annotate'}
        title="Annotate: freeze the screen and mark things up (A)"
        data-icon="annotate"
        disabled={!ui.running}
        onclick={() => setMode('annotate')}
      >{@html icon('annotate')}</button>
    </div>
    <div class="pill" role="group" aria-label="Zoom">
      <button id="zoom-out" class="icon-btn" title="Zoom out (⌘−)" data-icon="zoom-out" onclick={zoomOut}>{@html icon('zoom-out')}</button>
      <button
        id="zoom-fit"
        class="icon-btn"
        class:on={ui.zoom === 'fit' && ui.running}
        title="Fit to window (⌘9)"
        data-icon="zoom-fit"
        onclick={() => setZoom('fit')}
      >{@html icon('zoom-fit')}</button>
      <button id="zoom-in" class="icon-btn" title="Zoom in (⌘+)" data-icon="zoom-in" onclick={zoomIn}>{@html icon('zoom-in')}</button>
    </div>
    <div class="pill" role="group" aria-label="View">
      <button
        id="toggle-focus"
        class="icon-btn"
        title={ui.panels.sidebar || ui.panels.inspector ? 'Show the device alone' : 'Show the device list and inspector'}
        data-icon="focus"
        onclick={toggleFocus}
      >{@html icon('focus')}</button>
      <Popover icon="more" title="More">
        {#snippet children(close)}
          <div class="menu" role="menu">
            {#each menu as group, i (i)}
              {#if i}<hr>{/if}
              {#each group as item (item.label)}
                <button class="menu-item" role="menuitem" disabled={item.disabled} onclick={() => { close(); item.run(); }}>{@html icon(item.icon)}{item.label}</button>
              {/each}
            {/each}
          </div>
        {/snippet}
      </Popover>
    </div>
  </div>
</header>
