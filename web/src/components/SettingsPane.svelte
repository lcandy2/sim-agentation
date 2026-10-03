<script>
  import { ui, setStreamChoice, setStreamScale, setStreamBitrate, toggleSdk } from '../lib/app.svelte.js';
  import { AUTO_ORDER, FORMATS, HEVC_422, formatLabel } from '../lib/stream.js';

  const SCALES = [
    { value: 1, label: 'Full' },
    { value: 2, label: 'Half' },
  ];
  const BITRATES = [4_000_000, 8_000_000, 16_000_000];

  const s = $derived(ui.stream);
  const auto = $derived(s.choice === 'auto');
  // hevc422 is H.265 with the 4:2:2 switch on.
  const manualCodec = $derived(auto ? null : s.choice === HEVC_422.id ? 'hevc' : s.choice);
  const label = $derived(s.format ? formatLabel(s.format) : '');
  const autoOrder = AUTO_ORDER.map(formatLabel).join(' → ');
  const decoding = $derived(s.format === 'mjpeg' ? 'JPEG decode' : s.hardware === false ? 'software decode' : s.hardware ? 'hardware decode' : '');
</script>

<div class="pane">
  <section class="settings-group">
    <h3>Stream</h3>
    <div class="setting">
      <span>Codec</span>
      <div class="pill seg-text" role="group" aria-label="Codec">
        <button class:on={auto} title="Best this browser decodes in hardware: {autoOrder}" onclick={() => setStreamChoice('auto')}>Auto</button>
        {#each FORMATS as f (f.id)}
          <button
            class:on={manualCodec === f.id}
            disabled={!s.playable[f.id]}
            title={s.playable[f.id] ? f.name : `This browser can't decode ${f.name}`}
            onclick={() => manualCodec !== f.id && setStreamChoice(f.id)}
          >{f.label}</button>
        {/each}
      </div>
    </div>
    {#if manualCodec === 'hevc'}
      <div class="setting">
        <span title="How much color detail survives: 4:2:2 keeps colored text edges sharper">Chroma</span>
        <div class="pill seg-text" role="group" aria-label="Chroma">
          <button class:on={s.choice === 'hevc'} title="Main 4:2:0, low-latency rate control" onclick={() => setStreamChoice('hevc')}>4:2:0</button>
          <button
            class:on={s.choice === HEVC_422.id}
            disabled={!s.playable[HEVC_422.id]}
            title={s.playable[HEVC_422.id] ? HEVC_422.name : `This browser can't decode ${HEVC_422.name}`}
            onclick={() => setStreamChoice(HEVC_422.id)}
          >4:2:2</button>
        </div>
      </div>
    {/if}
    <div class="setting">
      <span>Resolution</span>
      <div class="pill seg-text" role="group" aria-label="Resolution">
        {#each SCALES as option (option.value)}
          <button class:on={s.scale === option.value} onclick={() => setStreamScale(option.value)}>{option.label}</button>
        {/each}
      </div>
    </div>
    {#if s.format !== 'mjpeg'}
      <div class="setting">
        <span>Bitrate</span>
        <div class="pill seg-text" role="group" aria-label="Bitrate">
          {#each BITRATES as bps (bps)}
            <button class:on={s.bitrate === bps} onclick={() => setStreamBitrate(bps)}>{bps / 1e6} Mbps</button>
          {/each}
        </div>
      </div>
    {/if}
    <div class="setting-note">
      <p>{auto ? `Auto: ${label}` : label} · {s.fps} fps · {s.mbps.toFixed(1)} Mbit/s{decoding ? ` · ${decoding}` : ''}</p>
      {#if auto}
        <p>Tries {autoOrder}, skipping what won't decode in hardware.</p>
        {#each s.skipped as skip (skip.format)}
          <p class="warn">Skipped {formatLabel(skip.format)}: {skip.reason}</p>
        {/each}
      {/if}
    </div>
  </section>

  <section class="settings-group">
    <h3>Annotate</h3>
    <label class="setting">
      <span>Use SimAgentationPlus <kbd>S</kbd></span>
      <input type="checkbox" class="switch" checked={ui.sdkEnabled} onchange={toggleSdk}>
    </label>
    <div class="setting-note">
      <p>
        {#if ui.sdkAvailable}The app in front has the SDK: parents come from its real views.
        {:else}Real views and source lines when the app links the SDK; pixels otherwise.{/if}
      </p>
    </div>
  </section>
</div>
