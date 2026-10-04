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
    if (swiped) return (swiped = false);
    b.action?.();
    dismiss(b.id);
  }

  // Swiped right, a banner goes, as macOS's do: it follows the pointer to
  // the right (and resists to the left); let go past 100 px or flicked,
  // it slides on out, else it springs back. A swipe isn't a click.
  let drag = null;
  let swiped = false;
  function down(e) {
    if (e.button !== 0) return;
    drag = { x0: e.clientX, dx: 0, moved: false, last: [e.timeStamp, e.clientX], speed: 0 };
    e.currentTarget.setPointerCapture(e.pointerId);
  }
  function move(e) {
    if (!drag) return;
    const dx = e.clientX - drag.x0;
    if (!drag.moved && Math.abs(dx) < 4) return;
    drag.moved = true;
    const [t, x] = drag.last;
    if (e.timeStamp > t) drag.speed = (e.clientX - x) / (e.timeStamp - t); // px per ms
    drag.last = [e.timeStamp, e.clientX];
    drag.dx = dx > 0 ? dx : dx / 4;
    e.currentTarget.style.transition = 'none';
    e.currentTarget.style.transform = `translateX(${drag.dx}px)`;
  }
  function up(e, b) {
    if (!drag) return;
    const { moved, dx, speed } = drag;
    drag = null;
    if (!moved) return;
    swiped = true;
    setTimeout(() => (swiped = false)); // the click that follows, if any
    if (dx > 100 || speed > 0.5) return dismiss(b.id);
    e.currentTarget.style.transition = 'transform 300ms cubic-bezier(0.2, 0.9, 0.3, 1)';
    e.currentTarget.style.transform = '';
  }
</script>

<div class="banners">
  {#each banners as b (b.id)}
    <button
      class="notice banner"
      onclick={() => open(b)}
      onmouseenter={() => hold(b.id)}
      onmouseleave={() => release(b.id)}
      onpointerdown={down}
      onpointermove={move}
      onpointerup={(e) => up(e, b)}
      onpointercancel={(e) => up(e, b)}
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
