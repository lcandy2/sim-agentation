<script>
  import { icon as glyph } from '../lib/icons.js';

  // An icon button that opens a menu under it; outside clicks and Esc close it.
  // The menu goes in the top layer, above everything on the page however it
  // stacks, placed under the button.
  let { icon, title, align = 'right', disabled = false, children } = $props();

  let open = $state(false);
  let root = $state(null);
  let button = $state(null);
  let panel = $state(null);
  let place = $state('');
  const close = () => (open = false);

  function position() {
    const r = button.getBoundingClientRect();
    place = align === 'left'
      ? `top:${r.bottom + 8}px;left:${r.left - 4}px`
      : `top:${r.bottom + 8}px;right:${innerWidth - r.right - 4}px`;
  }
  function toggle() {
    if (!open) position();
    open = !open;
  }
  $effect(() => panel?.showPopover());
</script>

<svelte:window
  onpointerdown={(e) => open && !root.contains(e.target) && close()}
  onkeydown={(e) => open && e.key === 'Escape' && close()}
  onresize={() => open && position()}
/>

<div class="popover-anchor" bind:this={root}>
  <button bind:this={button} class="icon-btn" class:open {title} aria-label={title} aria-expanded={open} {disabled} onclick={toggle}>
    {@html glyph(icon)}
  </button>
  {#if open}
    <div class="popover" popover="manual" bind:this={panel} style={place} role="dialog" aria-label={title}>
      {@render children(close)}
    </div>
  {/if}
</div>
