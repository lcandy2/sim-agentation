<script>
  import { ui } from '../lib/app.svelte.js';
  import AnnotationsPane from './AnnotationsPane.svelte';
  import InfoPane from './InfoPane.svelte';
  import InspectorTabs from './InspectorTabs.svelte';
  import SettingsPane from './SettingsPane.svelte';

  // The inspector: two tabs at the top right, the device's info with the
  // stream settings, and the annotations.
</script>

<aside class="inspector" id="inspector">
  <header class="inspector-top">
    {#if ui.panels.inspector}<InspectorTabs />{/if}
  </header>
  {#if ui.panels.tab === 'info'}
    <div class="pane">
      <InfoPane />
      <SettingsPane />
    </div>
  {:else}
    <AnnotationsPane />
  {/if}
</aside>
