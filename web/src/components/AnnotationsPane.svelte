<script>
  import { ui, copyPending, clearDone } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import AnnotationCard from './AnnotationCard.svelte';

  const open = $derived(ui.annotations.filter((a) => a.status === 'pending' || a.status === 'acknowledged').length);
  const newestFirst = $derived(ui.annotations.toReversed());
</script>

{#if newestFirst.length}
  <div class="pane-head">
    <h3>Annotations{#if open}<span class="count">{open} open</span>{/if}</h3>
    <button class="icon-btn small" title="Copy pending annotations as Markdown" data-icon="copy" onclick={copyPending}>{@html icon('copy')}</button>
    <button class="icon-btn small" title="Remove resolved and dismissed" data-icon="clear-done" onclick={clearDone}>{@html icon('clear-done')}</button>
  </div>
  <ol class="list">
    {#each newestFirst as annotation (annotation.id)}
      <AnnotationCard {annotation} />
    {/each}
  </ol>
{:else}
  <div class="empty">
    <span class="empty-icon" data-icon="doc">{@html icon('doc')}</span>
    <p>No annotations. Press <kbd>A</kbd> to freeze the screen, then click an element or drag a box around anything.</p>
  </div>
{/if}
