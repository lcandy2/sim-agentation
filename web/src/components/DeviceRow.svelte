<script>
  import { ui, chromeOf, selectDevice } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import { thumbnail } from '../lib/thumbnail.js';

  let { sim, version } = $props();

  // Sits in a 34 px circle with room around it, as in Device Hub.
  const THUMB_HEIGHT = 20;

  // A picture of the device once its chrome loads; a generic glyph until then.
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
  class="device-row"
  class:booted={sim.state === 'Booted'}
  class:selected={sim.udid === ui.udid}
  title="{sim.name}, {sim.runtime}"
  onclick={() => selectDevice(sim)}
>
  <span class="glyph">
    {#if picture}<img src={picture} alt="">{:else}{@html icon('phone')}{/if}
  </span>
  <span class="text">
    <div class="name">{sim.name}</div>
    <div class="kind">Simulator</div>
  </span>
  <span class="version">{version}</span>
</button>
