<script>
  import { ui, setInspectorTab } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';

  // The inspector's tabs, which also open and close it: a tab opens the
  // inspector on it, and the open tab closes it. In the inspector while it's
  // open, at the end of the canvas's top bar while it's closed.
  const TABS = [
    { id: 'info', icon: 'info', title: 'Info and Settings' },
    { id: 'annotations', icon: 'doc', title: 'Annotations' },
  ];
  const open = $derived(ui.annotations.filter((a) => a.status === 'pending' || a.status === 'acknowledged').length);
  const active = $derived(ui.panels.inspector ? ui.panels.tab : null);
</script>

<div class="pill segmented" role="tablist" aria-label="Inspector">
  {#each TABS as tab (tab.id)}
    <button
      class="icon-btn"
      class:on={active === tab.id}
      role="tab"
      aria-selected={active === tab.id}
      title={active === tab.id ? `Hide ${tab.title}` : tab.id === 'annotations' && open ? `${tab.title} (${open} open)` : tab.title}
      aria-label={tab.title}
      onclick={() => setInspectorTab(tab.id)}
    >
      {@html icon(tab.icon)}
      {#if tab.id === 'annotations' && open}<span class="tab-badge">{open}</span>{/if}
    </button>
  {/each}
</div>
