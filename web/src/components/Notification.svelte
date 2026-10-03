<script>
  import { fly } from 'svelte/transition';
  import { cubicOut, cubicIn } from 'svelte/easing';
  import { banner, dismiss, hold, release } from '../lib/notify.svelte.js';

  // macOS 27's notification banner (Figma, Notifications page), sliding in
  // from the right as macOS's do. A click runs its action and closes it.
  function open() {
    banner.current?.action?.();
    dismiss();
  }
</script>

{#if banner.current}
  {#key banner.current.id}
    <button
      class="notice banner"
      onclick={open}
      onmouseenter={hold}
      onmouseleave={release}
      in:fly={{ x: 380, duration: 380, easing: cubicOut }}
      out:fly={{ x: 380, duration: 240, easing: cubicIn }}
    >
      {#if banner.current.image}<img class="banner-image" src={banner.current.image} alt="">{/if}
      <span class="banner-text">
        <strong>{banner.current.title}</strong>
        {#if banner.current.message}<span>{banner.current.message}</span>{/if}
      </span>
      <span class="banner-time">now</span>
    </button>
  {/key}
{/if}
