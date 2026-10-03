<script>
  import { ui, copyPending, clearDone } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import AnnotationCard from './AnnotationCard.svelte';

  const open = $derived(ui.annotations.filter((a) => a.status === 'pending' || a.status === 'acknowledged').length);
  const newestFirst = $derived(ui.annotations.toReversed());
</script>

<aside class="inspector" id="inspector">
  <header class="inspector-top">
    <h2>Annotations <span class="count">{open || ''}</span></h2>
    <div class="pill" role="group" aria-label="Annotations">
      <button class="icon-btn" title="Copy pending annotations as Markdown" data-icon="copy" onclick={copyPending}>{@html icon('copy')}</button>
      <button class="icon-btn" title="Remove resolved and dismissed" data-icon="clear-done" onclick={clearDone}>{@html icon('clear-done')}</button>
    </div>
  </header>
  {#if newestFirst.length}
    <ol class="list">
      {#each newestFirst as annotation (annotation.id)}
        <AnnotationCard {annotation} />
      {/each}
    </ol>
  {:else}
    <div class="empty">
      <span class="empty-icon" data-icon="annotations">{@html icon('annotations')}</span>
      <p>Press <kbd>A</kbd> to freeze the screen, then click an element or drag a box around anything.</p>
    </div>
  {/if}
</aside>
