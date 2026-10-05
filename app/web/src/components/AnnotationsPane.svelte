<script>
  import { ui, copyPending, clearDone, deleteAllAnnotations } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import AnnotationCard from './AnnotationCard.svelte';
  import ConfirmSheet from './ConfirmSheet.svelte';

  // Delete All asks first: it takes the open ones too, and can't be undone.
  let confirming = $state(false);
  const all = $derived(ui.annotations.length === 1 ? 'the annotation' : `all ${ui.annotations.length} annotations`);

  const open = $derived(ui.annotations.filter((a) => a.status === 'pending' || a.status === 'acknowledged').length);
  const newestFirst = $derived(ui.annotations.toReversed());
</script>

<!-- How Design Mode works, where its annotations land, while it's on. -->
{#if ui.frozen}
  <div class="design-help">
    <h3>Design Mode</h3>
    <p>Click an element or drag a box around anything, then write what should change.</p>
    <p class="keys"><kbd>⇧</kbd> add <kbd>↑</kbd> parent <kbd>↓</kbd> back <kbd>esc</kbd> leave</p>
  </div>
{/if}
{#if newestFirst.length}
  <div class="pane-head">
    <h3>Annotations{#if open}<span class="count">{open} open</span>{/if}</h3>
    <button class="icon-btn small" title="Copy pending annotations as Markdown" data-icon="copy" onclick={copyPending}>{@html icon('copy')}</button>
    <button class="icon-btn small" title="Remove resolved and dismissed" data-icon="clear-done" onclick={clearDone}>{@html icon('clear-done')}</button>
    <button class="icon-btn small" title="Delete All Annotations…" data-icon="trash" onclick={() => (confirming = true)}>{@html icon('trash')}</button>
  </div>
  <ol class="list">
    {#each newestFirst as annotation (annotation.id)}
      <AnnotationCard {annotation} />
    {/each}
  </ol>
{:else}
  <div class="empty">
    <span class="empty-icon" data-icon="doc">{@html icon('doc')}</span>
    <p>{#if ui.frozen}No annotations yet.{:else}No annotations. Press <kbd>⇧⌘D</kbd> for Design Mode, then click an element or drag a box around anything.{/if}</p>
  </div>
{/if}
{#if confirming}
  <ConfirmSheet
    title={ui.annotations.length === 1 ? 'Delete the Annotation?' : `Delete All ${ui.annotations.length} Annotations?`}
    text="{all[0].toUpperCase() + all.slice(1)} and {ui.annotations.length === 1 ? 'its screenshots are' : 'their screenshots are'} deleted, open or not. This can’t be undone."
    action="Delete"
    run={deleteAllAnnotations}
    close={() => (confirming = false)}
  />
{/if}
