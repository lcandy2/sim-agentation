<script>
  import { onMount } from 'svelte';
  import {
    ui, MARGIN, attachStage, onStageResize, startDevice, pressButton, saveScreenshot,
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
</script>

<section class="stage" bind:this={stage}>
  <div class="device-wrap" hidden={!!ui.message || !chrome}>
    <div
      class="bezel"
      class:annotating={ui.mode === 'annotate'}
      style:width={chrome && px(chrome.size.width)}
      style:height={chrome && px(chrome.size.height)}
      style:margin={px(MARGIN)}
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
      <!-- Over the screen but outside its mask, so labels, markers and the
           badge aren't cut off by the screen's rounded corners. -->
      <div
        class="float-layer"
        bind:this={float}
        style:left={chrome && px(chrome.screen.x)}
        style:top={chrome && px(chrome.screen.y)}
        style:width={chrome && px(chrome.screen.width)}
        style:height={chrome && px(chrome.screen.height)}
      >
        {#if ui.frozen}
          <div id="frozen-badge" class="glass">Click or drag · ↑ parent · Esc to resume</div>
        {/if}
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
    <div class="pill" role="group" aria-label="Device">
      <button class="icon-btn" title="Home" data-icon="home" onclick={() => pressButton('home')}>{@html icon('home')}</button>
      <button class="icon-btn" title="Save screenshot" data-icon="screenshot" onclick={saveScreenshot}>{@html icon('screenshot')}</button>
      <button class="icon-btn" title="Lock" data-icon="lock" onclick={() => pressButton('lock')}>{@html icon('lock')}</button>
      <button class="icon-btn" title="App switcher" data-icon="app-switcher" onclick={() => pressButton('app-switcher')}>{@html icon('app-switcher')}</button>
    </div>
  </footer>
{/if}
