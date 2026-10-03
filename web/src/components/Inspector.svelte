<script>
  import { ui, setInspectorTab } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import AnnotationsPane from './AnnotationsPane.svelte';
  import InfoPane from './InfoPane.svelte';
  import SettingsPane from './SettingsPane.svelte';

  // The inspector: two tabs at the top right, the device's info with the
  // stream settings, and the annotations.
  const TABS = [
    { id: 'info', icon: 'info', title: 'Info and Settings' },
    { id: 'annotations', icon: 'doc', title: 'Annotations' },
  ];
  const open = $derived(ui.annotations.filter((a) => a.status === 'pending' || a.status === 'acknowledged').length);
</script>

<aside class="inspector" id="inspector">
  <header class="inspector-top">
    <div class="pill segmented" role="tablist" aria-label="Inspector">
      {#each TABS as tab (tab.id)}
        <button
          class="icon-btn"
          class:on={ui.panels.tab === tab.id}
          role="tab"
          aria-selected={ui.panels.tab === tab.id}
          title={tab.id === 'annotations' && open ? `${tab.title} (${open} open)` : tab.title}
          aria-label={tab.title}
          onclick={() => setInspectorTab(tab.id)}
        >
          {@html icon(tab.icon)}
          {#if tab.id === 'annotations' && open}<span class="tab-badge">{open}</span>{/if}
        </button>
      {/each}
    </div>
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
