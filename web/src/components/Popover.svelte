<script>
  import { icon as glyph } from '../lib/icons.js';

  // An icon button that opens a panel under it; outside clicks and Esc close it.
  let { icon, title, align = 'right', disabled = false, children } = $props();

  let open = $state(false);
  let root = $state(null);
  const close = () => (open = false);
</script>

<svelte:window
  onpointerdown={(e) => open && !root.contains(e.target) && close()}
  onkeydown={(e) => open && e.key === 'Escape' && close()}
/>

<div class="popover-anchor" bind:this={root}>
  <button class="icon-btn" class:open {title} aria-label={title} aria-expanded={open} {disabled} onclick={() => (open = !open)}>
    {@html glyph(icon)}
  </button>
  {#if open}
    <div class="popover" class:align-left={align === 'left'} role="dialog" aria-label={title}>
      {@render children(close)}
    </div>
  {/if}
</div>
