<script>
  import { icon } from '../lib/icons.js';
  import { glyphs } from '../lib/keys.js';
  import { blink } from '../lib/blink.js';
  import Menu from './Menu.svelte';

  // macOS 27's menu (Figma, nodes 4370:42750 and 4370:42756): groups of items
  // with a symbol, a title and their shortcut; an item with a submenu shows a
  // chevron and opens it beside itself while the pointer is on it.
  let { groups, close } = $props();

  let open = $state(null); // the item whose submenu shows
  let panel = $state(null);
  let place = $state('');

  function openSubmenu(item, row) {
    if (open === item) return;
    const r = row.getBoundingClientRect();
    place = `top:${r.top - 5}px;left:${r.right + 5}px`;
    open = item;
  }
  $effect(() => {
    if (!panel) return;
    panel.showPopover();
    // Where the window ends on the right, open it to the left instead.
    const r = panel.getBoundingClientRect();
    if (r.right > innerWidth - 8) panel.style.left = `${Math.max(8, r.left - r.width - (r.left - parseFloat(place.split('left:')[1])) - 10)}px`;
  });
</script>

<div class="menu" role="menu">
  {#each groups as group, i (i)}
    {#if i}<hr>{/if}
    {#each group as item (item.label)}
      {#if item.submenu}
        <button
          class="menu-item"
          class:opened={open === item}
          role="menuitem"
          aria-haspopup="menu"
          aria-expanded={open === item}
          disabled={item.disabled}
          onpointerenter={(e) => openSubmenu(item, e.currentTarget)}
          onclick={(e) => openSubmenu(item, e.currentTarget)}
        >
          {#if item.icon}{@html icon(item.icon)}{/if}<span class="menu-title">{item.label}</span><span class="menu-chevron" aria-hidden="true">›</span>
        </button>
      {:else}
        <button
          class="menu-item"
          role="menuitem"
          disabled={item.disabled}
          onpointerenter={() => (open = null)}
          onclick={async (e) => { if (!(await blink(e.currentTarget))) return; close(); item.run(); }}
        >
          {#if item.icon}{@html icon(item.icon)}{/if}<span class="menu-title">{item.label}</span>
          {#if item.keys}<span class="shortcut" aria-label="Shortcut {glyphs(item.keys).join('')}">{#each glyphs(item.keys) as g, k (k)}<span>{g}</span>{/each}</span>{/if}
        </button>
      {/if}
    {/each}
  {/each}
</div>
{#if open}
  <div class="popover submenu" popover="manual" bind:this={panel} style={place} role="dialog" aria-label={open.label}>
    <Menu groups={open.submenu} {close} />
  </div>
{/if}
