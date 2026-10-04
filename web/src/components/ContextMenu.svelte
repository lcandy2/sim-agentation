<script>
  import Menu from './Menu.svelte';

  // A menu at the pointer, as macOS opens a context menu: in the top layer,
  // just right of and below where it was asked for, kept in the window.
  // Outside clicks, Esc and the window losing focus close it.
  let { x, y, groups, close } = $props();

  let panel = $state(null);
  $effect(() => {
    panel.showPopover();
    const r = panel.getBoundingClientRect();
    panel.style.left = `${Math.max(8, x + r.width + 8 > innerWidth ? x - r.width : x)}px`;
    panel.style.top = `${Math.max(8, y + r.height + 8 > innerHeight ? y - r.height : y)}px`;
  });
</script>

<svelte:window
  onpointerdown={(e) => !panel?.contains(e.target) && close()}
  onkeydown={(e) => e.key === 'Escape' && close()}
  onblur={close}
  onresize={close}
/>

<div class="popover context-menu" popover="manual" bind:this={panel} style:left="{x}px" style:top="{y}px" role="dialog" aria-label="Actions">
  <Menu {groups} {close} />
</div>
