<script>
  import { ui, copyPending, clearDone } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import AnnotationCard from './AnnotationCard.svelte';

  const open = $derived(ui.annotations.filter((a) => a.status === 'pending' || a.status === 'acknowledged').length);
  const newestFirst = $derived(ui.annotations.toReversed());
</script>

<!-- How Design Mode works, where its annotations land, while it's on. -->
{#if ui.frozen}
  <div class="design-help">
    <h3>Design Mode</h3>
    <p>Click an element or drag a box around anything, then write what should change.</p>
    <p class="keys"><kbd>↑</kbd> parent <kbd>↓</kbd> back <kbd>esc</kbd> leave</p>
  </div>
{/if}
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
    <p>{#if ui.frozen}No annotations yet.{:else}No annotations. Press <kbd>A</kbd> for Design Mode, then click an element or drag a box around anything.{/if}</p>
  </div>
{/if}
