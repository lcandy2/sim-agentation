<script>
  import { onMount } from 'svelte';
  import { ui, start, onWindowKey } from './lib/app.svelte.js';
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
  <main class="canvas" class:offline={!ui.running}>
    <Header />
    <DeviceStage />
  </main>
  <Inspector />
</div>

{#if ui.draft}
  <Composer />
{/if}
