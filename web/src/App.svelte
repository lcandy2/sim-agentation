<script>
  import { onMount } from 'svelte';
  import { ui, start, onWindowKey, fitPanels } from './lib/app.svelte.js';
  import { attachGlass } from './lib/glass.js';
  import Sidebar from './components/Sidebar.svelte';
  import Header from './components/Header.svelte';
  import DeviceStage from './components/DeviceStage.svelte';
  import Inspector from './components/Inspector.svelte';
  import InspectorTabs from './components/InspectorTabs.svelte';
  import Composer from './components/Composer.svelte';
  import Notification from './components/Notification.svelte';
  import DeviceSheet from './components/DeviceSheet.svelte';

  // Before the first paint, so a narrow window opens without its panels
  // sliding away.
  fitPanels();

  onMount(() => {
    start();
    attachGlass();
  });
</script>

<svelte:window onkeydown={onWindowKey} />

<div class="window" class:no-sidebar={!ui.panels.sidebar} class:no-inspector={!ui.panels.inspector}>
  <Sidebar />
  <main class="canvas" class:offline={!ui.running}>
    <Header />
    <DeviceStage />
  </main>
  <Inspector />
  <!-- The inspector's tabs stay at the window's top right whether it's open
       or closed; closing takes only the panel away. -->
  <div class="inspector-tabs"><InspectorTabs /></div>
</div>

{#if ui.sheet}
  <DeviceSheet kind={ui.sheet} close={() => (ui.sheet = null)} />
{/if}
{#if ui.draft}
  <Composer />
{/if}
<Notification />
