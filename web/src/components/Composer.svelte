<script>
  import { tick, untrack } from 'svelte';
  import { ui, submitComposer, cancelComposer, removePick } from '../lib/app.svelte.js';
  import { POINTER, outlinePath } from '../lib/glass.js';
  import { icon } from '../lib/icons.js';

  let form = $state(null);
  let text = $state(null);
  let comment = $state('');
  let place = $state(null);

  // macOS's popover: beside the selection, centered on it where the window
  // allows, its pointer at the selection's middle and clear of the corners;
  // too short for a pointer on its side (one line of note), below the
  // selection instead (above, without room), the pointer on that edge. The
  // pointer belongs to the composer's own box, so one glass, one outline and
  // one shadow cover both, as in Figma.
  const BODY = 360;
  const RADIUS = 24;                       // concentric with the note's field, 8 in (style.css)
  const GAP = 12;                          // from the selection to the pointer's tip
  const CLEAR = RADIUS + POINTER.span / 2; // the corner radius plus half the pointer
  const SHADOW_PAD = 80;                   // room around the outline for the shadow
  const across = (side) => side === 'left' || side === 'right';
  const widthFor = (side) => (across(side) ? BODY + POINTER.depth : BODY);
  const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
  // The pointer at the selection's middle, clear of the corners, and the outline.
  function settle(p, h) {
    const at = Math.round(across(p.side) ? clamp(p.cy - p.top, CLEAR, h - CLEAR) : clamp(p.cx - p.left, CLEAR, BODY - CLEAR));
    const pointer = { side: p.side, at };
    return { ...p, h, w: widthFor(p.side), pointer, outline: outlinePath(widthFor(p.side), h, RADIUS, pointer) };
  }
  $effect(() => {
    const { box } = ui.draft;
    const was = untrack(() => place); // only the selection places it anew
    const body = form.offsetHeight - (was && !across(was.side) ? POINTER.depth : 0);
    const cx = (box.left + box.right) / 2;
    const cy = (box.top + box.bottom) / 2;
    let p, h;
    if (body >= 2 * CLEAR) {
      const w = widthFor('left');
      const right = box.right + GAP + w + 12 <= innerWidth || box.left - GAP - w < 12;
      // A composer right of the selection points left, and the other way round.
      h = body;
      p = { side: right ? 'left' : 'right', left: right ? Math.min(box.right + GAP, innerWidth - w - 12) : box.left - GAP - w, top: clamp(cy - h / 2, 12, innerHeight - h - 12) };
    } else {
      h = body + POINTER.depth;
      const below = box.bottom + GAP + h + 12 <= innerHeight || box.top - GAP - h < 12;
      p = { side: below ? 'top' : 'bottom', left: clamp(cx - BODY / 2, 12, innerWidth - BODY - 12), top: below ? box.bottom + GAP : box.top - GAP - h };
    }
    place = settle({ ...p, cx, cy }, h);
    // Once it's shown: hidden until placed, the field can't take focus.
    tick().then(() => text?.focus());
  });
  // As the note grows (or shrinks) the composer keeps its place and its
  // edge, growing up when it's above the selection, moving only to stay in
  // the window, and its outline and pointer follow.
  $effect(() => {
    const sizes = new ResizeObserver(() => {
      if (!place || form.offsetHeight === place.h) return;
      const h = form.offsetHeight;
      const top = place.side === 'bottom' ? place.top - (h - place.h) : clamp(place.top, 12, innerHeight - h - 12);
      place = settle({ ...place, top }, h);
    });
    sizes.observe(form);
    return () => sizes.disconnect();
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

  // The selections as chips at the start of the note, each in its color;
  // hovered, a chip's symbol turns to an x that takes that selection away.
  // The note goes on after the last chip, on its line if there's room
  // (its first line indented to there), else on the next.
  let chips = $state(null);
  let start = $state({ top: 0, indent: 0 });
  $effect(() => {
    ui.draft.picks;
    tick().then(() => {
      const last = chips?.lastElementChild;
      if (!last) return (start = { top: 0, indent: 0 });
      const right = last.offsetLeft + last.offsetWidth + 6;
      start = chips.clientWidth - right < 64 ? { top: last.offsetTop + last.offsetHeight, indent: 0 } : { top: last.offsetTop, indent: right };
      // Chrome leaves a focused field's caret where the old indent put it.
      tick().then(() => {
        if (document.activeElement !== text) return;
        const [from, to] = [text.selectionStart, text.selectionEnd];
        text.setSelectionRange(0, 0);
        text.setSelectionRange(from, to);
      });
    });
  });

  function submit(e) {
    e.preventDefault();
    const value = comment.trim();
    if (value) submitComposer(value);
  }

  // Pressed and dragged as macOS 27's glass buttons answer a mouse (measured
  // on one, real events, 60 fps): pressed it darkens (8%) while the pointer
  // is over it and clears once it's off; it leans toward the pointer only
  // as the traffic lights do, up to 4% of its size, and settles back in
  // 100 ms when let go. Let go off it, it isn't a click.
  let pull = null;
  let pulled = false;
  function grab(e) {
    if (e.button !== 0) return;
    const r = e.currentTarget.getBoundingClientRect();
    pull = { x: e.clientX, y: e.clientY, cx: r.left + r.width / 2, cy: r.top + r.height / 2, size: r.width, over: true };
    e.currentTarget.setPointerCapture(e.pointerId);
    e.currentTarget.classList.add('pressed');
  }
  function drag(e) {
    if (!pull) return;
    const el = e.currentTarget;
    pull.over = Math.hypot(e.clientX - pull.cx, e.clientY - pull.cy) <= pull.size / 2;
    el.classList.toggle('pressed', pull.over);
    const dx = e.clientX - pull.x;
    const dy = e.clientY - pull.y;
    const d = Math.hypot(dx, dy);
    if (!d) return;
    const k = (0.04 * pull.size * (1 - Math.exp(-d / 60))) / d;
    el.style.transition = 'none';
    el.style.transform = `translate(${dx * k}px, ${dy * k}px)`;
  }
  function letGo(e) {
    if (!pull) return;
    pulled = !pull.over;
    pull = null;
    const el = e.currentTarget;
    el.classList.remove('pressed');
    el.style.transition = '';
    el.style.transform = '';
    setTimeout(() => (pulled = false)); // after the click that follows
  }
  function press(e) {
    if (pulled) e.preventDefault();
  }

  // Backspace at the note's very start takes the last chip away as a macOS
  // token field does: the first marks it (its x showing), the second takes
  // it. Anything else unmarks it.
  let armed = $state(null);
  function keydown(e) {
    if (e.key === 'Backspace' && text.selectionStart === 0 && text.selectionEnd === 0 && ui.draft.picks.length) {
      e.preventDefault();
      const last = ui.draft.picks.at(-1);
      if (armed === last.id) {
        armed = null;
        removePick(last.id);
      } else armed = last.id;
      return;
    }
    armed = null;
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) form.requestSubmit();
    // An empty note has no line to break, and Chrome would draw the caret on
    // the next line at the chips' indent.
    else if (e.key === 'Enter' && !comment) e.preventDefault();
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
  style:transform-origin={place ? { left: `0 ${place.pointer.at}px`, right: `${place.w}px ${place.pointer.at}px`, top: `${place.pointer.at}px 0`, bottom: `${place.pointer.at}px ${place.h}px` }[place.side] : null}
  in:popIn|global
  out:popOut|global
>
  <form
    id="composer-form"
    class="composer pointer-{place?.side ?? 'left'}"
    bind:this={form}
    data-pointer={place ? `${place.side} ${place.pointer.at}` : null}
    style:clip-path={place ? `path('${place.outline}')` : null}
    onsubmit={submit}
  >
    <div class="field note">
      <div class="note-chips" bind:this={chips}>
        {#each ui.draft.picks as pick (pick.id)}
          <button type="button" class="chip" class:armed={armed === pick.id} style:--pick="var(--pick-{pick.color})" title="{pick.label}, click to take away" aria-label="Take away {pick.label}" onclick={() => removePick(pick.id)}>
            <span class="chip-icon">{@html icon(pick.type)}</span><span class="chip-x">{@html icon('xmark')}</span>{pick.short}
          </button>
        {/each}
      </div>
      <textarea
        class="note-text"
        rows="1"
        placeholder="What should change?"
        style:padding-top="{8 + start.top}px"
        style:text-indent="{start.indent}px"
        style:min-height="{8 + start.top + 16 + 8}px"
        style:max-height="{8 + start.top + 10 * 16 + 8}px"
        onscroll={() => (chips.style.transform = `translateY(${-text.scrollTop}px)`)}
        bind:this={text}
        bind:value={comment}
        onkeydown={keydown}
        onpointerdown={() => (armed = null)}
      ></textarea>
    </div>
  </form>
  {#if place}
    <!-- The outline's shadow, only outside it, drawn after the glass so the
         glass doesn't blur it in. -->
    <svg class="composer-shadow" width={place.w + 2 * SHADOW_PAD} height={place.h + 2 * SHADOW_PAD} style:left="-{SHADOW_PAD}px" style:top="-{SHADOW_PAD}px" aria-hidden="true">
      <!-- Its region is in the outline's own space, which the translate below
           moves in by the padding: so it starts that far out, or the shadow
           above and left of the outline is cut off. -->
      <filter id="composer-shadow" filterUnits="userSpaceOnUse" x={-SHADOW_PAD} y={-SHADOW_PAD} width={place.w + 2 * SHADOW_PAD} height={place.h + 2 * SHADOW_PAD}>
        <feGaussianBlur in="SourceAlpha" stdDeviation="19" />
        <feOffset dy="8" />
        <feComponentTransfer><feFuncA type="linear" slope="0.25" /></feComponentTransfer>
        <feComposite in2="SourceAlpha" operator="out" />
      </filter>
      <path filter="url(#composer-shadow)" transform="translate({SHADOW_PAD} {SHADOW_PAD})" d={place.outline} />
    </svg>
  {/if}
  <!-- In the text field's bottom right corner, but over the form rather
       than in it: the form's outline clips what's inside, and a pulled button
       reaches past it. -->
  <button
    type="submit"
    form="composer-form"
    class="glass-btn prominent composer-send"
    style:right={place?.side === 'right' ? '22.5px' : '12px'}
    style:bottom={place?.side === 'bottom' ? '22.5px' : '12px'}
    title="Add (⌘↩)"
    aria-label="Add"
    disabled={!comment.trim()}
    onpointerdown={grab}
    onpointermove={drag}
    onpointerup={letGo}
    onpointercancel={letGo}
    onclick={press}
  >{@html icon('arrow-up')}</button>
</div>
