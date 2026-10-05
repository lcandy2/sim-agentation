<script>
  import { onMount } from 'svelte';
  import { ui, renameDevice, eraseDevice, removeDevice, chromeOf } from '../lib/app.svelte.js';
  import { thumbnail } from '../lib/thumbnail.js';
  import { showSheet, sheetDismiss } from '../lib/sheet.js';

  // The … menu's dialogs, as macOS's sheet (lib/sheet.js for the
  // measured motion), in macOS 27's Alert (Figma, Alerts page) with the
  // device's picture as its icon: Rename asks for a name, Reset and Remove
  // confirm.
  let { kind, close } = $props();

  let dialog = $state(null);
  let field = $state(null);
  onMount(() => {
    showSheet(dialog);
    field?.select();
  });
  const dismiss = sheetDismiss(() => dialog);

  // The selected device's, the one a row's context menu is for, or several
  // selected in the list (Reset and Remove).
  const udids = Array.isArray(ui.sheetFor) ? ui.sheetFor : [ui.sheetFor ?? ui.udid];
  const udid = udids[0];
  const name = ui.sims.find((s) => s.udid === udid)?.name ?? ui.simName;
  const many = udids.length > 1;
  const names = udids.map((u) => `“${ui.sims.find((s) => s.udid === u)?.name ?? u}”`);
  const listed = names.length > 3 ? `${names.slice(0, 3).join(', ')} and ${names.length - 3} more` : `${names.slice(0, -1).join(', ')} and ${names.at(-1)}`;
  let picture = $state(null);
  $effect(() => {
    chromeOf(udid).then((c) => c && thumbnail(c, 64)).then((url) => (picture = url));
  });
  let newName = $state(name);
  let busy = $state(false);

  const copy = {
    rename: { title: `Rename “${name}”`, text: 'The new name shows in the device list and to tools that list simulators.', action: 'Rename' },
    erase: many
      ? {
          title: `Reset Content and Settings of ${udids.length} Simulators?`,
          text: `All apps, data and settings on ${listed} are erased, as on new devices. Running ones restart.`,
          action: 'Reset',
        }
      : {
          title: `Reset Content and Settings of “${name}”?`,
          text: 'All of its apps, data and settings are erased, as on a new device. A running simulator restarts.',
          action: 'Reset',
        },
    remove: many
      ? { title: `Remove ${udids.length} Simulators?`, text: `${listed}, with everything on them, are deleted. This can’t be undone.`, action: 'Remove' }
      : { title: `Remove “${name}”?`, text: 'The simulator and everything on it are deleted. This can’t be undone.', action: 'Remove' },
  }[kind];

  async function submit(e) {
    e.preventDefault();
    busy = true;
    // Close first for the long ones; their progress shows in the status line.
    if (kind === 'rename') {
      if (await renameDevice(newName.trim(), udid)) dismiss();
    } else {
      dismiss();
      for (const u of udids) await (kind === 'erase' ? eraseDevice(u) : removeDevice(u));
    }
    busy = false;
  }
</script>

<dialog class="sheet" bind:this={dialog} onclose={close} oncancel={(e) => { e.preventDefault(); dismiss(); }} aria-labelledby="device-sheet-title">
  <form class="alert-body" onsubmit={submit}>
    <div class="alert-icon">{#if picture}<img src={picture} alt="">{/if}</div>
    <div class="alert-text">
      <h2 id="device-sheet-title">{copy.title}</h2>
      <p>{copy.text}</p>
    </div>
    {#if kind === 'rename'}
      <div class="alert-fields">
        <input class="field" aria-label="Name" bind:this={field} bind:value={newName} spellcheck="false" autocomplete="off">
      </div>
    {/if}
    <div class="alert-buttons">
      <button type="button" class="alert-btn" onclick={dismiss}>Cancel</button>
      <button
        type="submit"
        class="alert-btn default"
        disabled={busy || (kind === 'rename' && (!newName.trim() || newName.trim() === name))}
      >{copy.action}</button>
    </div>
  </form>
</dialog>
