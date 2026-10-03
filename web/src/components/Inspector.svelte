<script>
  import { ui, setInspectorTab } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import AnnotationsPane from './AnnotationsPane.svelte';
  import InfoPane from './InfoPane.svelte';
  import SettingsPane from './SettingsPane.svelte';

  // Device Hub's inspector: three tabs in a pill at the top right.
  const TABS = [
    { id: 'settings', icon: 'sliders', title: 'Settings' },
    { id: 'annotations', icon: 'doc', title: 'Annotations' },
    { id: 'info', icon: 'info', title: 'Info' },
  ];
  const open = $derived(ui.annotations.filter((a) => a.status === 'pending' || a.status === 'acknowledged').length);
</script>

<aside class="inspector" id="inspector">
  <header class="inspector-top">
    <div class="pill tabs" role="tablist" aria-label="Inspector">
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
  {#if ui.panels.tab === 'settings'}
    <SettingsPane />
  {:else if ui.panels.tab === 'info'}
    <InfoPane />
  {:else}
    <AnnotationsPane />
  {/if}
</aside>
