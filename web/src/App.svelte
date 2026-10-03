<script>
  import { onMount } from 'svelte';
  import { ui, start, onWindowKey, togglePanel } from './lib/app.svelte.js';
  import { icon } from './lib/icons.js';
  import Sidebar from './components/Sidebar.svelte';
  import Header from './components/Header.svelte';
  import DeviceStage from './components/DeviceStage.svelte';
  import Inspector from './components/Inspector.svelte';
  import Composer from './components/Composer.svelte';

  onMount(start);
</script>

<svelte:window onkeydown={onWindowKey} />

<div class="window" class:no-sidebar={!ui.panels.sidebar} class:no-inspector={!ui.panels.inspector}>
  <Sidebar />
  <!-- One sidebar button for both states: it rides along with the slide, from
       the sidebar's top bar to the left of the title and back. -->
  <button
    id="toggle-sidebar"
    class="icon-btn circle-btn sidebar-toggle"
    title={ui.panels.sidebar ? 'Hide the device list' : 'Show the device list'}
    aria-label={ui.panels.sidebar ? 'Hide the device list' : 'Show the device list'}
    onclick={() => togglePanel('sidebar')}
  >{@html icon('sidebar')}</button>
  <main class="canvas" class:offline={!ui.running}>
    <Header />
    <DeviceStage />
  </main>
  <Inspector />
</div>

{#if ui.draft}
  <Composer />
{/if}
