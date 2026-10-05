<script>
  import { onMount } from 'svelte';
  import { showSheet, sheetDismiss } from '../lib/sheet.js';

  // A question before something that can't be undone, as macOS 27's Alert
  // (Figma, Alerts page) with the app's icon: Cancel, and the action.
  let { title, text, action, run, close } = $props();

  let dialog = $state(null);
  onMount(() => showSheet(dialog));
  const dismiss = sheetDismiss(() => dialog);

  function submit(e) {
    e.preventDefault();
    dismiss();
    run();
  }
</script>

<dialog class="sheet" bind:this={dialog} onclose={close} oncancel={(e) => { e.preventDefault(); dismiss(); }} aria-labelledby="confirm-sheet-title">
  <form class="alert-body" onsubmit={submit}>
    <div class="alert-icon"><img src="/icon.svg" alt=""></div>
    <div class="alert-text">
      <h2 id="confirm-sheet-title">{title}</h2>
      <p>{text}</p>
    </div>
    <div class="alert-buttons">
      <button type="button" class="alert-btn" onclick={dismiss}>Cancel</button>
      <button type="submit" class="alert-btn default">{action}</button>
    </div>
  </form>
</dialog>
