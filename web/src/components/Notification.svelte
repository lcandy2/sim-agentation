<script>
  import { fly } from 'svelte/transition';
  import { flip } from 'svelte/animate';
  import { cubicOut, cubicIn } from 'svelte/easing';
  import { banners, dismiss, hold, release } from '../lib/notify.svelte.js';

  // macOS 27's notification banners (Figma, Notifications page), stacked at
  // the top right, the newest on top. Each slides in from beyond the window's
  // right edge and back out as macOS's do, without fading, and the others
  // glide to make or close the room. Global: the first banner and the last
  // come and go with the list, which local transitions don't play for. A
  // click runs its action and closes it.
  function open(b) {
    b.action?.();
    dismiss(b.id);
  }
</script>

<div class="banners">
  {#each banners as b (b.id)}
    <button
      class="notice banner"
      onclick={() => open(b)}
      onmouseenter={() => hold(b.id)}
      onmouseleave={() => release(b.id)}
      in:fly|global={{ x: 380, opacity: 1, duration: 380, easing: cubicOut }}
      out:fly|global={{ x: 380, opacity: 1, duration: 240, easing: cubicIn }}
      animate:flip={{ duration: 320, easing: cubicOut }}
    >
      {#if b.image}<img class="banner-image" src={b.image} alt="">{/if}
      <span class="banner-text">
        <strong>{b.title}</strong>
        {#if b.message}<span>{b.message}</span>{/if}
      </span>
      <span class="banner-time">now</span>
    </button>
  {/each}
</div>
