<script>
  import { ui, setStreamFormat, setStreamScale, setStreamBitrate } from '../lib/app.svelte.js';
  import { FORMATS } from '../lib/stream.js';

  let open = $state(false);
  let root = $state(null);

  const SCALES = [
    { value: 1, label: 'Full' },
    { value: 2, label: 'Half' },
  ];
  const BITRATES = [4_000_000, 8_000_000, 16_000_000];

  const s = $derived(ui.stream);
  const label = $derived(FORMATS.find((f) => f.id === s.format)?.label ?? '');
  const decoding = $derived(s.format === 'mjpeg' ? 'JPEG decode' : s.hardware === false ? 'software decode' : s.hardware ? 'hardware decode' : '');

  function outside(e) {
    if (open && !root.contains(e.target)) open = false;
  }
</script>

<svelte:window onpointerdown={outside} onkeydown={(e) => open && e.key === 'Escape' && (open = false)} />

<div class="stream-settings" bind:this={root}>
  <button class="pill stream-pill" class:open title="Stream settings" aria-expanded={open} onclick={() => (open = !open)}>
    {label}{#if ui.live}<span class="stream-fps">{s.fps} fps</span>{/if}
  </button>
  {#if open}
    <div class="stream-menu" role="dialog" aria-label="Stream settings">
      <div class="menu-row">
        <span>Codec</span>
        <div class="pill seg-text" role="group" aria-label="Codec">
          {#each FORMATS as f (f.id)}
            <button
              class:on={s.format === f.id}
              disabled={!s.playable[f.id]}
              title={s.playable[f.id] ? f.name : `This browser can't decode ${f.name}`}
              onclick={() => setStreamFormat(f.id)}
            >{f.label}</button>
          {/each}
        </div>
      </div>
      <div class="menu-row">
        <span>Resolution</span>
        <div class="pill seg-text" role="group" aria-label="Resolution">
          {#each SCALES as option (option.value)}
            <button class:on={s.scale === option.value} onclick={() => setStreamScale(option.value)}>{option.label}</button>
          {/each}
        </div>
      </div>
      {#if s.format !== 'mjpeg'}
        <div class="menu-row">
          <span>Bitrate</span>
          <div class="pill seg-text" role="group" aria-label="Bitrate">
            {#each BITRATES as bps (bps)}
              <button class:on={s.bitrate === bps} onclick={() => setStreamBitrate(bps)}>{bps / 1e6} Mbps</button>
            {/each}
          </div>
        </div>
      {/if}
      <p class="menu-stats">{s.fps} fps · {s.mbps.toFixed(1)} Mbit/s{decoding ? ` · ${decoding}` : ''}</p>
    </div>
  {/if}
</div>
