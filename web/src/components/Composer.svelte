<script>
  import { ui, submitComposer, cancelComposer } from '../lib/app.svelte.js';

  let form = $state(null);
  let text = $state(null);
  let comment = $state('');
  let position = $state({ left: 0, top: 0 });

  // Beside the selection, kept inside the window.
  $effect(() => {
    const { x, y } = ui.draft;
    position = {
      left: Math.min(x, innerWidth - form.offsetWidth - 12),
      top: Math.min(Math.max(y, 12), innerHeight - form.offsetHeight - 12),
    };
    text.focus();
  });

  function submit(e) {
    e.preventDefault();
    const value = comment.trim();
    if (value) submitComposer(value);
  }

  function keydown(e) {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) form.requestSubmit();
    if (e.key === 'Escape') {
      e.stopPropagation();
      cancelComposer();
    }
  }
</script>

<form class="composer" bind:this={form} style:left="{position.left}px" style:top="{position.top}px" onsubmit={submit}>
  <div class="composer-target">{ui.draft.label}</div>
  <textarea class="field" rows="3" placeholder="What should change?" bind:this={text} bind:value={comment} onkeydown={keydown}></textarea>
  <div class="composer-row">
    <span class="hint">⌘↩ to add · Esc to cancel</span>
    <button type="button" class="push-btn" onclick={cancelComposer}>Cancel</button>
    <button type="submit" class="push-btn default">Add</button>
  </div>
</form>
