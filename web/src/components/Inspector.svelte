<script>
  import { ui } from '../lib/app.svelte.js';
  import AnnotationsPane from './AnnotationsPane.svelte';
  import InfoPane from './InfoPane.svelte';
  import SettingsPane from './SettingsPane.svelte';

  // The inspector: the device's info with the stream settings, and the
  // annotations. Its tabs float at the window's top right (App.svelte).
</script>

<aside class="inspector" id="inspector">
  <header class="inspector-top"></header> <!-- under the tabs, which float (see App.svelte) -->
  {#if ui.panels.tab === 'info'}
    <div class="pane">
      <InfoPane />
      <SettingsPane />
    </div>
  {:else}
    <AnnotationsPane />
  {/if}
</aside>
