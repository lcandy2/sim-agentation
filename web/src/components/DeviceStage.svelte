<script>
  import { onMount, untrack } from 'svelte';
  import {
    ui, MARGIN, ROTATION, attachStage, onStageResize, startDevice, pressHome, reclaimInput, saveScreenshot, toggleRecording, rotate, isFoldable, POSES, currentPose, setPose, slideHinge, hingeAngle, is3D, toggle3D, pressButton, maps3D, attachScreen3D, syncScreen3D, ACTIVE_FACING,
    onPointerDown, onPointerMove, onPointerUp, onWheel, onScreenKey,
  } from '../lib/app.svelte.js';
  import { icon } from '../lib/icons.js';
  import { layerSize, layerStyle, facing } from '../lib/screen3d.js';
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
  // The screen's mask once it has loaded: a mask that fails to load hides
  // all it masks (the screen gone, the bezel's black showing), so until
  // then, or if it never does, the screen is a rect rounded as the device.
  let maskLoaded = $state(null);
  $effect(() => {
    const url = chrome?.mask;
    if (!url) return;
    let current = true;
    const img = new Image();
    img.onload = () => current && (maskLoaded = url);
    img.src = url;
    return () => (current = false);
  });
  const mask = $derived(chrome?.mask && maskLoaded === chrome.mask ? `url("${chrome.mask}")` : '');
  const unmaskedCorner = $derived(chrome && !mask ? px(Math.max(0, (chrome.cornerRadius ?? 0) - chrome.screen.x)) : null);

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

  // iPhone Duo in 3D, as Device Hub draws it: the host renders the book at
  // the stage's size, so the screen is the whole frame, unturned and
  // unmasked, and the keys are glyphs beside it where the host says.
  const in3D = $derived(is3D());
  // Switching between the book and the flat chrome isn't a turn: the flat
  // view's angle accumulates (450° after a few turns), and animating it to
  // or from the book's none spun the device round. Nor is a foldable lighting
  // its other panel, which is mounted turned (the unfolded one landscape).
  // Only turns animate.
  let switching = $state(false);
  let shown;
  $effect.pre(() => {
    const view = `${in3D}|${ui.chrome?.panel}`;
    if (view === shown) return;
    shown = view;
    switching = true;
    requestAnimationFrame(() => requestAnimationFrame(() => (switching = false)));
  });
  const box = $derived(ui.box3d ?? { width: 0, height: 0 });
  const KEYS = {
    'volume-down': ['Volume Down', '<path d="M2.5 6.5h2.8L9 3.5v11L5.3 11.5H2.5z"/><path d="M11.5 9h4"/>'],
    'volume-up': ['Volume Up', '<path d="M2.5 6.5h2.8L9 3.5v11L5.3 11.5H2.5z"/><path d="M11.5 9h4M13.5 7v4"/>'],
    action: ['Camera Control', '<path d="M2.5 6.5h3l1.5-2h4l1.5 2h3v8h-13z"/><circle cx="9" cy="10.2" r="2.4"/>'],
    power: ['Sleep/Wake', '<rect x="4" y="8" width="10" height="7.5" rx="1.5"/><path d="M6 8V5.8a3 3 0 0 1 6 0V8"/>'],
  };
  // Design Mode on the 3D book: a layer of framebuffer coordinates laid
  // onto each piece of the screen (strips across the crease), the first
  // piece's drawn on and the others' copies of it, each cut at its edges;
  // labels and markers stand flat on the page. Annotating, a piece turned
  // too far from the camera is left out.
  const pieces3D = $derived(in3D && ui.scene && ui.box3d ? maps3D() : []);
  const layer3D = $derived(pieces3D.length ? layerSize(pieces3D) : { width: 1, height: 1 });
  const layers3D = $derived(pieces3D.map((piece) => ({ ...layerStyle(piece, layer3D), off: ui.mode === 'annotate' && facing(piece) < ACTIVE_FACING })));
  let boxes3D = $state(), floats3D = $state(), flat3D = $state();
  let mirrors3D = $state([]);
  $effect(() => {
    if (!boxes3D || !floats3D || !flat3D) return;
    return attachScreen3D({ boxes: boxes3D, floats: floats3D, flat: flat3D, mirrors: mirrors3D.slice(1, layers3D.length) });
  });
  $effect(() => {
    layers3D;
    syncScreen3D();
  });

  // A key's glyph stays on the stage, however close the book comes.
  const keySpot = (at, length) => Math.min(length - 16, Math.max(16, at * length));
  const glyph = (paths) => `<svg viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
</script>

<section class="stage" bind:this={stage}>
  <div class="device-wrap" bind:this={wrap} hidden={!!ui.message || !chrome} style:visibility={ui.settling ? 'hidden' : null}>
    <div
      class="rotor"
      bind:this={rotor}
      style:width={in3D ? `${box.width}px` : px(sideways ? outer.h : outer.w)}
      style:height={in3D ? `${box.height}px` : px(sideways ? outer.w : outer.h)}
    >
      <div
        class="bezel"
        class:annotating={ui.mode === 'annotate'}
        class:in3d={in3D}
        class:instant={switching}
        style:width={in3D ? `${box.width}px` : chrome && px(chrome.size.width)}
        style:height={in3D ? `${box.height}px` : chrome && px(chrome.size.height)}
        style:transform={in3D ? 'translate(-50%, -50%)' : `translate(-50%, -50%) rotate(${angle}deg)`}
        style:--unrotate="{in3D ? 0 : -angle}deg"
      >
        {#if in3D}
          <div class="screen3d" style:--unrotate="{-(ROTATION[ui.orientation] ?? 0)}deg">
            {#each layers3D as layer, i (i)}
              <div
                class="piece3d"
                class:off={layer.off}
                style:width="{layer3D.width}px"
                style:height="{layer3D.height}px"
                style:transform={layer.transform}
                style:clip-path={layer.clip}
              >
                {#if i === 0}
                  <div class="piece-layer" bind:this={boxes3D}></div>
                  <div class="piece-layer floats" bind:this={floats3D}></div>
                {:else}
                  <div class="piece-layer" bind:this={mirrors3D[i]}></div>
                {/if}
              </div>
            {/each}
          </div>
          <div class="flat3d" bind:this={flat3D}></div>
          <div class="hw-keys">
            {#each ui.scene.buttons as key (key.id)}
              <button
                class="hw-key"
                title={KEYS[key.id]?.[0] ?? key.id}
                aria-label={KEYS[key.id]?.[0] ?? key.id}
                style:left="{keySpot(key.control[0], box.width)}px"
                style:top="{keySpot(key.control[1], box.height)}px"
                onclick={() => pressButton(key.id)}
              >{@html glyph(KEYS[key.id]?.[1] ?? '')}</button>
            {/each}
          </div>
        {:else if chrome}
          <div id="side-buttons">
            {#each chrome.buttons as button (button.name)}
              <SideButton {button} frame={buttonFrame(button, chrome.size)} />
            {/each}
          </div>
          {#if chrome.composite}
            <div class="bezel-art composite">
              <img src={chrome.composite.url} alt="" draggable="false">
            </div>
          {:else}
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
        {/if}
        <div
          id="device-frame"
          class="device"
          class:preview={!ui.running}
          class:annotating={ui.mode === 'annotate'}
          class:in3d={in3D}
          style:left={in3D ? '0px' : chrome && px(chrome.screen.x)}
          style:top={in3D ? '0px' : chrome && px(chrome.screen.y)}
          style:width={in3D ? `${box.width}px` : chrome && px(chrome.screen.width)}
          style:height={in3D ? `${box.height}px` : chrome && px(chrome.screen.height)}
          style:mask-image={in3D ? '' : mask}
          style:-webkit-mask-image={in3D ? '' : mask}
          style:border-radius={in3D ? null : unmaskedCorner}
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
          style:left={in3D ? '0px' : chrome && px(chrome.screen.x)}
          style:top={in3D ? '0px' : chrome && px(chrome.screen.y)}
          style:width={in3D ? `${box.width}px` : chrome && px(chrome.screen.width)}
          style:height={in3D ? `${box.height}px` : chrome && px(chrome.screen.height)}
        ></div>
      </div>
    </div>
    {#if chrome && !ui.running}
      <div class="preview-info" bind:this={previewInfo}>
        <div class="preview-name">{ui.simName}</div>
        <div class="preview-sub">{ui.runtime} Simulator</div>
        <button class="start-btn" disabled={ui.starting} onclick={() => startDevice()}>{ui.starting ? 'Starting…' : 'Start'}</button>
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
      {#if isFoldable()}
        <!-- Device Hub's pose picker and hinge slider; the pose nearest the hinge is lit. -->
        <div class="pill pose-picker" role="group" aria-label="Pose">
          {#each POSES as pose (pose.name)}
            <button
              class="icon-btn pose"
              class:on={currentPose().name === pose.name}
              title={pose.label}
              aria-pressed={currentPose().name === pose.name}
              data-icon="pose-{pose.name}"
              onclick={() => setPose(pose.degrees)}
            >{@html icon(`pose-${pose.name}`)}</button>
          {/each}
          <button
            class="icon-btn"
            class:on={ui.prefer3d}
            title={ui.prefer3d ? 'Show Flat' : 'Show in 3D'}
            aria-pressed={ui.prefer3d}
            data-icon="view-3d"
            onclick={toggle3D}
          >{@html icon('view-3d')}</button>
          <input
            class="hinge-slider"
            type="range"
            min="0"
            max="180"
            step="1"
            aria-label="Hinge"
            title="Hinge {Math.round(hingeAngle())}°"
            value={hingeAngle()}
            oninput={(e) => slideHinge(Number(e.currentTarget.value))}
            onchange={() => slideHinge(null)}
          >
        </div>
      {/if}
      <div class="pill" role="group" aria-label="Rotate">
        <button class="icon-btn" title="Rotate" data-icon="rotate" onclick={rotate}>{@html icon('rotate')}</button>
      </div>
    </div>
  </footer>
{/if}
