<script>
  import { ui, pressButton } from '../lib/app.svelte.js';

  // `button` comes from the device chrome; `frame` is its resting frame in points.
  let { button, frame } = $props();

  // Rest: under the body, showing a little. Hover: slides out by the chrome's
  // rollover offset. Pressed: back to rest with the pressed artwork.
  let hovering = $state(false);
  let pressedAt = $state(0);

  const k = $derived(ui.scale);
  const transform = $derived(
    hovering && !pressedAt
      ? `translate(${(button.rollover.x - button.normal.x) * k}px, ${(button.rollover.y - button.normal.y) * k}px)`
      : '',
  );

  function down(e) {
    if (!ui.running) return;
    pressedAt = performance.now();
    e.currentTarget.setPointerCapture(e.pointerId);
  }

  function up() {
    if (!pressedAt) return;
    const held = (performance.now() - pressedAt) / 1000;
    pressedAt = 0;
    // Hold to long-press, like the hardware button.
    pressButton(button.name, held);
  }
</script>

<svelte:head>
  <!-- Preload the pressed artwork so the swap is instant. -->
  <link rel="preload" as="image" href={button.imageDown}>
</svelte:head>
<button
  class="side-button"
  class:on-top={button.onTop}
  title={button.name.replace('-', ' ')}
  style:left="{frame.x * k}px"
  style:top="{frame.y * k}px"
  style:width="{frame.w * k}px"
  style:height="{frame.h * k}px"
  style:transform
  onpointerenter={() => (hovering = true)}
  onpointerleave={() => ((hovering = false), (pressedAt = 0))}
  onpointerdown={down}
  onpointerup={up}
>
  <img src={pressedAt ? button.imageDown : button.image} alt="" draggable="false">
</button>
