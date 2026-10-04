<script>
  import { tick } from 'svelte';
  import { ui, submitComposer, cancelComposer } from '../lib/app.svelte.js';
  import { POINTER, outlinePath } from '../lib/glass.js';

  let form = $state(null);
  let text = $state(null);
  let comment = $state('');
  let place = $state(null);

  // macOS's popover: beside the selection, centered on it where the window
  // allows, its pointer at the selection's middle and clear of the corners.
  // The pointer belongs to the composer's own box, so one glass, one outline
  // and one shadow cover both, as in Figma.
  const BODY = 360;
  const WIDTH = BODY + POINTER.depth;
  const RADIUS = 28;                       // concentric with the capsule buttons, 12 in (style.css)
  const GAP = 12;                          // from the selection to the pointer's tip
  const CLEAR = RADIUS + POINTER.span / 2; // the corner radius plus half the pointer
  const SHADOW_PAD = 80;                   // room around the outline for the shadow
  $effect(() => {
    const { box } = ui.draft;
    const h = form.offsetHeight;
    const side = box.right + GAP + WIDTH + 12 <= innerWidth || box.left - GAP - WIDTH < 12 ? 'right' : 'left';
    const left = side === 'right' ? Math.min(box.right + GAP, innerWidth - WIDTH - 12) : box.left - GAP - WIDTH;
    const middle = (box.top + box.bottom) / 2;
    const top = Math.min(Math.max(middle - h / 2, 12), innerHeight - h - 12);
    // A composer right of the selection points left, and the other way round.
    const pointer = { side: side === 'right' ? 'left' : 'right', y: Math.round(Math.min(Math.max(middle - top, CLEAR), h - CLEAR)) };
    place = { left, top, h, pointer, outline: outlinePath(WIDTH, h, RADIUS, pointer) };
    // Once it's shown: hidden until placed, the field can't take focus.
    tick().then(() => text?.focus());
  });

  // NSPopover's motion, measured from a 60 fps recording on macOS 26: it
  // grows out of its pointer's tip on a spring (damping ratio 0.8 at 19.5
  // rad/s: settled in about 0.37 s, overshooting 1.5%), its opacity
  // following the scale; closing, it shrinks back into the tip on a quicker
  // one and is gone at about a tenth of its size, 175 ms in.
  const OPEN = { zeta: 0.8, omega: 19.5, duration: 0.4 };
  const CLOSE = { zeta: 0.78, omega: 16.5, duration: 0.175 };
  const still = () => matchMedia('(prefers-reduced-motion: reduce)').matches;
  function spring({ zeta, omega }, s) {
    const wd = omega * Math.sqrt(1 - zeta * zeta);
    return 1 - Math.exp(-zeta * omega * s) * (Math.cos(wd * s) + ((zeta * omega) / wd) * Math.sin(wd * s));
  }
  // The fade goes through --pop to the composer and its shadow (style.css).
  const pose = (k) => `transform: scale(${k}); --pop: ${Math.min(1, k)}`;
  // Svelte runs t from 0 to 1 coming in and from 1 to 0 going out, evenly.
  const popIn = () => ({ duration: still() ? 0 : OPEN.duration * 1000, css: (t) => pose(spring(OPEN, t * OPEN.duration)) });
  const popOut = () => ({ duration: still() ? 0 : CLOSE.duration * 1000, css: (t) => pose(1 - spring(CLOSE, (1 - t) * CLOSE.duration)) });

  function submit(e) {
    e.preventDefault();
    const value = comment.trim();
    if (value) submitComposer(value);
  }

  function keydown(e) {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) form.requestSubmit();
    if (e.key === 'Escape') {
      e.stopPropagation();
      cancelComposer();
    }
  }
</script>

<div
  class="composer-at"
  style:left="{place?.left ?? 0}px"
  style:top="{place?.top ?? 0}px"
  style:visibility={place ? null : 'hidden'}
  style:transform-origin={place ? `${place.pointer.side === 'left' ? 0 : WIDTH}px ${place.pointer.y}px` : null}
  in:popIn|global
  out:popOut|global
>
  <form
    class="composer pointer-{place?.pointer.side ?? 'left'}"
    bind:this={form}
    data-pointer={place ? `${place.pointer.side} ${place.pointer.y}` : null}
    style:clip-path={place ? `path('${place.outline}')` : null}
    onsubmit={submit}
  >
    <div class="composer-target">{ui.draft.label}</div>
    <textarea class="field" rows="3" placeholder="What should change?" bind:this={text} bind:value={comment} onkeydown={keydown}></textarea>
    <div class="composer-row">
      <span class="hint">⌘↩ to add · Esc to cancel</span>
      <button type="button" class="alert-btn" onclick={cancelComposer}>Cancel</button>
      <button type="submit" class="alert-btn default">Add</button>
    </div>
  </form>
  {#if place}
    <!-- The outline's shadow, only outside it, drawn after the glass so the
         glass doesn't blur it in. -->
    <svg class="composer-shadow" width={WIDTH + 2 * SHADOW_PAD} height={place.h + 2 * SHADOW_PAD} style:left="-{SHADOW_PAD}px" style:top="-{SHADOW_PAD}px" aria-hidden="true">
      <!-- Its region is in the outline's own space, which the translate below
           moves in by the padding: so it starts that far out, or the shadow
           above and left of the outline is cut off. -->
      <filter id="composer-shadow" filterUnits="userSpaceOnUse" x={-SHADOW_PAD} y={-SHADOW_PAD} width={WIDTH + 2 * SHADOW_PAD} height={place.h + 2 * SHADOW_PAD}>
        <feGaussianBlur in="SourceAlpha" stdDeviation="19" />
        <feOffset dy="8" />
        <feComponentTransfer><feFuncA type="linear" slope="0.25" /></feComponentTransfer>
        <feComposite in2="SourceAlpha" operator="out" />
      </filter>
      <path filter="url(#composer-shadow)" transform="translate({SHADOW_PAD} {SHADOW_PAD})" d={place.outline} />
    </svg>
  {/if}
</div>
