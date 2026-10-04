<script>
  import { onMount, untrack } from 'svelte';
  import {
    ui, MARGIN, ROTATION, attachStage, onStageResize, startDevice, pressHome, reclaimInput, saveScreenshot, toggleRecording, rotate,
    onPointerDown, onPointerMove, onPointerUp, onWheel, onScreenKey,
  } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import SideButton from './SideButton.svelte';

  // The canvas and overlay stay mounted for the page's lifetime: the stream
  // and annotation code hold on to them.
  let stage = $state(null);
  let canvas = $state(null);
  let overlay = $state(null);
  let float = $state(null);
  let previewInfo = $state(null);

  $effect(() => {
    if (stage && canvas && overlay && float) attachStage({ canvas, overlay, float, stage, previewInfo });
  });

  onMount(() => {
    const observer = new ResizeObserver(onStageResize);
    observer.observe(stage);
    return () => observer.disconnect();
  });

  // Device Hub brings a running device in small and grows it to size: one
  // that appears grows in from 85%, and Start grows the picture from its
  // preview size to its running size. A device that isn't running just
  // appears, as does going back within REPLAY_AFTER to a running device
  // that has just been shown. Zooming and resizing don't animate.
  const REPLAY_AFTER = 3000; // ms
  let wrap = $state(null);
  let rotor = $state(null);
  let last = null; // { udid, running, scale } as last shown
  const leftAt = new Map(); // udid → when another device replaced it
  $effect(() => {
    ui.shown;
    untrack(() => {
      const prev = last;
      last = { udid: ui.udid, running: ui.running, scale: ui.scale };
      const same = prev?.udid === ui.udid;
      if (prev && !same) leftAt.set(prev.udid, performance.now());
      if (!rotor || !wrap || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
      const easing = { duration: 450, easing: 'cubic-bezier(0.2, 0.9, 0.25, 1)' };
      if (same) {
        if (prev.running === ui.running) return;
        rotor.getAnimations().forEach((a) => a.cancel());
        rotor.animate([{ transform: `scale(${prev.scale / ui.scale})` }, { transform: 'none' }], easing);
        return;
      }
      if (!ui.running || performance.now() - (leftAt.get(ui.udid) ?? -Infinity) < REPLAY_AFTER) return;
      wrap.getAnimations().forEach((a) => a.cancel());
      wrap.animate([{ transform: 'scale(0.85)', opacity: 0 }, { transform: 'none', opacity: 1 }], easing);
    });
  });

  // Hardware buttons sit under the body. At rest they show OUTSET points; the
  // chrome's rollover offset slides them further out on hover, as in Device Hub.
  const OUTSET = 13; // pt, measured from Device Hub: |normal offset| 8 → 5 pt showing

  function buttonFrame(b, size) {
    const { width: w, height: h } = b.size;
    const o = b.normal;
    const along = (offset, length, total) => (b.align === 'trailing' ? total + offset - length : offset);
    switch (b.anchor) {
      case 'left': return { x: o.x - OUTSET, y: along(o.y, h, size.height), w, h };
      case 'right': return { x: size.width + o.x + OUTSET - w, y: along(o.y, h, size.height), w, h };
      case 'top': return { x: along(o.x, w, size.width), y: o.y - OUTSET, w, h };
      default: return { x: along(o.x, w, size.width), y: size.height + o.y + OUTSET - h, w, h };
    }
  }

  const SLICES = ['topLeft', 'top', 'topRight', 'left', null, 'right', 'bottomLeft', 'bottom', 'bottomRight'];
  const chrome = $derived(ui.chrome);
  const px = (n) => `${n * ui.scale}px`;
  const mask = $derived(chrome?.mask ? `url("${chrome.mask}")` : '');

  // The device turns on screen as iOS turns its interface; the framebuffer,
  // touches and the accessibility tree stay portrait inside it. The rotor is
  // the turned outline, so layout and fit-to-window see the right size.
  const degrees = $derived(ui.running ? ROTATION[ui.orientation] : 0);
  const sideways = $derived(Math.abs(degrees) === 90);
  // The angle on screen stays continuous so every turn animates the short
  // way: the third quarter turn goes 180° → 270°, not back round to -90°.
  let angle = $state(0);
  $effect.pre(() => {
    const target = degrees;
    untrack(() => { angle += ((((target - angle) % 360) + 540) % 360) - 180; });
  });
  const outer = $derived(chrome ? { w: chrome.size.width + MARGIN * 2, h: chrome.size.height + MARGIN * 2 } : { w: 0, h: 0 });
</script>

<section class="stage" bind:this={stage}>
  <div class="device-wrap" bind:this={wrap} hidden={!!ui.message || !chrome}>
    <div class="rotor" bind:this={rotor} style:width={px(sideways ? outer.h : outer.w)} style:height={px(sideways ? outer.w : outer.h)}>
      <div
        class="bezel"
        class:annotating={ui.mode === 'annotate'}
        style:width={chrome && px(chrome.size.width)}
        style:height={chrome && px(chrome.size.height)}
        style:transform="translate(-50%, -50%) rotate({angle}deg)"
        style:--unrotate="{-angle}deg"
      >
        {#if chrome}
          <div id="side-buttons">
            {#each chrome.buttons as button (button.name)}
              <SideButton {button} frame={buttonFrame(button, chrome.size)} />
            {/each}
          </div>
          <div
            class="bezel-art"
            style:grid-template-columns="{px(chrome.slices.topLeft.width)} 1fr {px(chrome.slices.topRight.width)}"
            style:grid-template-rows="{px(chrome.slices.topLeft.height)} 1fr {px(chrome.slices.bottomLeft.height)}"
          >
            {#each SLICES as key, i (i)}
              {#if key}<img src={chrome.slices[key].url} alt="" draggable="false">{:else}<span></span>{/if}
            {/each}
          </div>
        {/if}
        <div
          id="device-frame"
          class="device"
          class:preview={!ui.running}
          class:annotating={ui.mode === 'annotate'}
          style:left={chrome && px(chrome.screen.x)}
          style:top={chrome && px(chrome.screen.y)}
          style:width={chrome && px(chrome.screen.width)}
          style:height={chrome && px(chrome.screen.height)}
          style:mask-image={mask}
          style:-webkit-mask-image={mask}
        >
          <canvas id="screen" bind:this={canvas}></canvas>
          <!-- The runtime draws hover, selection and markers into this layer. It
               takes pointer and key input for the simulator, hence the handlers. -->
          <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
          <div
            id="overlay"
            tabindex="0"
            role="application"
            aria-label="Simulator screen"
            bind:this={overlay}
            onpointerdown={onPointerDown}
            onpointermove={onPointerMove}
            onpointerup={onPointerUp}
            onwheel={onWheel}
            onkeydown={onScreenKey}
          ></div>
        </div>
        <!-- Over the screen but outside its mask, so labels and markers aren't
             cut off by the screen's rounded corners. -->
        <div
          class="float-layer"
          bind:this={float}
          style:left={chrome && px(chrome.screen.x)}
          style:top={chrome && px(chrome.screen.y)}
          style:width={chrome && px(chrome.screen.width)}
          style:height={chrome && px(chrome.screen.height)}
        ></div>
      </div>
    </div>
    {#if chrome && !ui.running}
      <div class="preview-info" bind:this={previewInfo}>
        <div class="preview-name">{ui.simName}</div>
        <div class="preview-sub">{ui.runtime} Simulator</div>
        <button class="start-btn" disabled={ui.starting} onclick={startDevice}>{ui.starting ? 'Starting…' : 'Start'}</button>
      </div>
    {/if}
  </div>
  {#if ui.message}<p class="stage-message">{ui.message}</p>{/if}
</section>

{#if ui.running}
  <footer class="canvas-bottom">
    {#if ui.inputShadowed}
      <!-- Device Hub holds this device's buttons; say so where they are. -->
      <div class="notice input-notice" role="status">
        <span>Xcode's Device Hub has taken this simulator's buttons.</span>
        <button class="alert-btn default" disabled={ui.reclaiming} title="Restarts the simulator's SpringBoard; open apps close" onclick={reclaimInput}>
          {ui.reclaiming ? 'Taking Back…' : 'Take Back'}
        </button>
      </div>
    {/if}
    <div class="bottom-row">
      <div class="pill" role="group" aria-label="Device">
        <button class="icon-btn" title="Home" data-icon="home" onclick={pressHome}>{@html icon('home')}</button>
        <button class="icon-btn" title="Save screenshot" data-icon="screenshot" onclick={saveScreenshot}>{@html icon('screenshot')}</button>
        <button
          class="icon-btn"
          class:recording={ui.recording}
          title={ui.recording ? 'Stop recording and save the video' : 'Record the screen'}
          data-icon="record"
          onclick={toggleRecording}
        >{@html icon(ui.recording ? 'record-stop' : 'record')}</button>
      </div>
      <div class="pill" role="group" aria-label="Rotate">
        <button class="icon-btn" title="Rotate" data-icon="rotate" onclick={rotate}>{@html icon('rotate')}</button>
      </div>
    </div>
  </footer>
{/if}
