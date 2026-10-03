<script>
  import { onMount } from 'svelte';
  import { ui, renameDevice, eraseDevice, removeDevice, chromeOf } from '../lib/app.svelte.js';
  import { thumbnail } from '../lib/thumbnail.js';

  // The … menu's dialogs, as macOS's sheet (see NewSimulator for the
  // measured motion): Rename asks for a name in the small dialog; Reset and
  // Remove confirm in macOS 27's Alert (Figma, Alerts page), the device's
  // picture as its icon.
  let { kind, close } = $props();

  let dialog = $state(null);
  let field = $state(null);
  let closing = false;
  const still = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  const DIM = 'rgba(0, 0, 0, 0.2)';
  onMount(() => {
    dialog.showModal();
    field?.select();
    if (still()) return;
    dialog.animate([{ transform: 'translateY(-32px)' }, { transform: 'none' }], { duration: 260, easing: 'cubic-bezier(0.42, 0, 0.58, 1)' });
    dialog.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 140 });
    dialog.animate([{ background: 'transparent' }, { background: DIM }], { duration: 270, pseudoElement: '::backdrop' });
  });
  async function dismiss() {
    if (closing) return;
    closing = true;
    if (!still()) {
      const out = { duration: 230, fill: 'forwards' };
      await Promise.all([
        dialog.animate([{ transform: 'none' }, { transform: 'translateY(-30px)' }], { ...out, easing: 'cubic-bezier(0.42, 0, 1, 1)' }).finished,
        dialog.animate([{ opacity: 1 }, { opacity: 0 }], out).finished,
        dialog.animate([{ background: DIM }, { background: 'transparent' }], { duration: 270, fill: 'forwards', pseudoElement: '::backdrop' }).finished,
      ]);
    }
    dialog.close();
  }

  const name = ui.simName;
  let picture = $state(null);
  $effect(() => {
    if (kind === 'rename') return;
    chromeOf(ui.udid).then((c) => c && thumbnail(c, 64)).then((url) => (picture = url));
  });
  let newName = $state(name);
  let busy = $state(false);

  const copy = {
    rename: { title: `Rename “${name}”`, text: 'The new name shows in the device list and to tools that list simulators.', action: 'Rename' },
    erase: {
      title: `Reset Content and Settings of “${name}”?`,
      text: 'All of its apps, data and settings are erased, as on a new device. A running simulator restarts.',
      action: 'Reset',
    },
    remove: { title: `Remove “${name}”?`, text: 'The simulator and everything on it are deleted. This can’t be undone.', action: 'Remove' },
  }[kind];

  async function submit(e) {
    e.preventDefault();
    busy = true;
    // Close first for the long ones; their progress shows in the status line.
    if (kind === 'rename') {
      if (await renameDevice(newName.trim())) dismiss();
    } else {
      dismiss();
      await (kind === 'erase' ? eraseDevice() : removeDevice());
    }
    busy = false;
  }
</script>

<dialog class="sheet" class:alert={kind !== 'rename'} bind:this={dialog} onclose={close} oncancel={(e) => { e.preventDefault(); dismiss(); }} aria-labelledby="device-sheet-title">
  {#if kind !== 'rename'}
    <form class="alert-body" onsubmit={submit}>
      <div class="alert-icon">{#if picture}<img src={picture} alt="">{/if}</div>
      <div class="alert-text">
        <h2 id="device-sheet-title">{copy.title}</h2>
        <p>{copy.text}</p>
      </div>
      <div class="alert-buttons">
        <button type="button" class="alert-btn" onclick={dismiss}>Cancel</button>
        <button type="submit" class="alert-btn destructive" disabled={busy}>{copy.action}</button>
      </div>
    </form>
  {:else}
  <form onsubmit={submit}>
    <div class="sheet-grid">
      <div class="sheet-message">
        <h2 id="device-sheet-title">{copy.title}</h2>
        <p>{copy.text}</p>
      </div>
      {#if kind === 'rename'}
        <label for="device-sheet-name">Name:</label>
        <input id="device-sheet-name" class="field" bind:this={field} bind:value={newName} spellcheck="false" autocomplete="off">
      {/if}
    </div>
    <div class="sheet-buttons">
      <button type="button" class="push-btn" onclick={dismiss}>Cancel</button>
      <button
        type="submit"
        class="push-btn default"
        class:destructive={kind !== 'rename'}
        disabled={busy || (kind === 'rename' && (!newName.trim() || newName.trim() === name))}
      >{copy.action}</button>
    </div>
  </form>
  {/if}
</dialog>
