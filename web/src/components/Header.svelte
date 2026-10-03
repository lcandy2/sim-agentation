<script>
  import { ui, setMode, toggleSdk, setZoom, zoomIn, zoomOut, togglePanel } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';

  const status = $derived(ui.flash ?? ui.status);
</script>

<header class="canvas-top">
  <button
    id="toggle-sidebar"
    class="icon-btn"
    class:on={ui.panels.sidebar}
    title="Show or hide the device list"
    data-icon="sidebar"
    onclick={() => togglePanel('sidebar')}
  >{@html icon('sidebar')}</button>
  <div class="title">
    <div class="title-name">{ui.simName}</div>
    <div class="title-sub"><span>{ui.runtime}</span><span class="status">{status}</span></div>
  </div>
  <div class="toolbar">
    <div class="pill seg" role="group" aria-label="Mode">
      <button
        id="mode-interact"
        class="icon-btn"
        class:on={ui.mode === 'interact'}
        title="Interact: use the app (I)"
        data-icon="pointer"
        onclick={() => setMode('interact')}
      >{@html icon('pointer')}</button>
      <button
        id="mode-annotate"
        class="icon-btn"
        class:on={ui.mode === 'annotate'}
        title="Annotate: freeze the screen and mark things up (A)"
        data-icon="annotate"
        onclick={() => setMode('annotate')}
      >{@html icon('annotate')}</button>
    </div>
    {#if ui.sdkAvailable}
      <button class="pill sdk" class:on={ui.sdkEnabled} title="Use SimAgentationPlus data from the app (S)" onclick={toggleSdk}>
        <span class="dot"></span>SDK
      </button>
    {/if}
    <div class="pill" role="group" aria-label="Zoom">
      <button id="zoom-out" class="icon-btn" title="Zoom out (⌘−)" data-icon="zoom-out" onclick={zoomOut}>{@html icon('zoom-out')}</button>
      <button
        id="zoom-fit"
        class="icon-btn"
        class:on={ui.zoom === 'fit'}
        title="Fit to window (⌘9)"
        data-icon="zoom-fit"
        onclick={() => setZoom('fit')}
      >{@html icon('zoom-fit')}</button>
      <button
        id="zoom-actual"
        class="icon-btn"
        class:on={ui.zoom !== 'fit' && Number(ui.zoom) === 1}
        title="Actual size, 1 point per pixel (⌘0)"
        data-icon="zoom-actual"
        onclick={() => setZoom(1)}
      >{@html icon('zoom-actual')}</button>
      <button id="zoom-in" class="icon-btn" title="Zoom in (⌘+)" data-icon="zoom-in" onclick={zoomIn}>{@html icon('zoom-in')}</button>
    </div>
  </div>
  <button
    id="toggle-inspector"
    class="icon-btn"
    class:on={ui.panels.inspector}
    title="Show or hide annotations"
    data-icon="inspector"
    onclick={() => togglePanel('inspector')}
  >{@html icon('inspector')}</button>
</header>
