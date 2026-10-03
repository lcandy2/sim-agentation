<script>
  import { ui, chromeOf, selectDevice } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import { thumbnail } from '../lib/thumbnail.js';

  let { sim, version } = $props();

  // The device picture inside a 32 px circle, as in Device Hub: lit when
  // the simulator runs, grayed out when it's shut down.
  const THUMB_HEIGHT = 24;

  let row = $state(null);
  const selected = $derived(sim.udid === ui.udid);
  $effect(() => {
    if (selected) row?.scrollIntoView({ block: 'nearest' });
  });

  let picture = $state(null);
  $effect(() => {
    let current = true;
    chromeOf(sim.udid)
      .then((c) => c && thumbnail(c, THUMB_HEIGHT))
      .then((url) => current && (picture = url));
    return () => (current = false);
  });
</script>

<button
  bind:this={row}
  class="device-row"
  class:booted={sim.state === 'Booted'}
  class:selected
  title="{sim.name}, {sim.runtime}{sim.state === 'Booted' ? ', running' : ''}"
  onclick={() => selectDevice(sim)}
>
  <span class="thumb">
    {#if picture}<img src={picture} alt="">{:else}{@html icon('phone')}{/if}
  </span>
  <span class="text">
    <span class="name">{sim.name}</span>
    <span class="kind">Simulator</span>
  </span>
  <span class="version">{version}</span>
</button>
