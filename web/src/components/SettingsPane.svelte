<script>
  import { ui, setStreamChoice, setStreamScale, setStreamBitrate, toggleSdk, BITRATE_STEPS } from '../lib/app.svelte.js';
  import { AUTO_ORDER, FORMATS, HEVC_422, formatLabel } from '../lib/stream.js';

  const SCALES = [
    { value: 1, label: 'Full' },
    { value: 2, label: 'Half' },
  ];

  const s = $derived(ui.stream);
  const auto = $derived(s.choice === 'auto');
  // hevc422 is H.265 with the 4:2:2 switch on.
  const manualCodec = $derived(auto ? null : s.choice === HEVC_422.id ? 'hevc' : s.choice);
  const label = $derived(s.format ? formatLabel(s.format) : '');
  const autoOrder = AUTO_ORDER.map(formatLabel).join(' → ');
  const decoding = $derived(s.format === 'mjpeg' ? 'JPEG decode' : s.hardware === false ? 'software decode' : s.hardware ? 'hardware decode' : '');
</script>

<section class="settings-group">
  <h3>Stream</h3>
  <label class="setting">
    <span>Codec</span>
    <select class="popup" title="Auto: the best this browser decodes in hardware, {autoOrder}" value={auto ? 'auto' : manualCodec} onchange={(e) => setStreamChoice(e.currentTarget.value)}>
      <option value="auto">Auto</option>
      {#each FORMATS as f (f.id)}
        <option value={f.id} disabled={!s.playable[f.id]}>{s.playable[f.id] ? f.label : `${f.label} (can't decode)`}</option>
      {/each}
    </select>
  </label>
  {#if manualCodec === 'hevc'}
    <label class="setting">
      <span title="How much color detail survives: 4:2:2 keeps colored text edges sharper">Chroma</span>
      <select class="popup" value={s.choice} onchange={(e) => setStreamChoice(e.currentTarget.value)}>
        <option value="hevc">4:2:0</option>
        <option value={HEVC_422.id} disabled={!s.playable[HEVC_422.id]}>{s.playable[HEVC_422.id] ? '4:2:2' : "4:2:2 (can't decode)"}</option>
      </select>
    </label>
  {/if}
  <!-- With the codec on Auto these follow it: half resolution when the page
       shows the device at half its pixels or less, a bitrate from the
       resolution and codec. A pinned codec lets you choose them. -->
  <label class="setting">
    <span>Resolution</span>
    {#if auto}
      <span class="setting-value" title="Half when the page shows the device at half its pixels or less">{s.scale === 2 ? 'Half' : 'Full'}</span>
    {:else}
      <select class="popup" value={s.scaleChoice} onchange={(e) => setStreamScale(Number(e.currentTarget.value))}>
        {#each SCALES as option (option.value)}<option value={option.value}>{option.label}</option>{/each}
      </select>
    {/if}
  </label>
  {#if s.format !== 'mjpeg'}
    <label class="setting">
      <span>Bitrate</span>
      {#if auto}
        <span class="setting-value" title="From the resolution and codec, 2–16 Mbps">{s.bitrate / 1e6} Mbps</span>
      {:else}
        <select class="popup" value={s.bitrateChoice} onchange={(e) => setStreamBitrate(Number(e.currentTarget.value))}>
          {#each BITRATE_STEPS as bps (bps)}<option value={bps}>{bps / 1e6} Mbps</option>{/each}
        </select>
      {/if}
    </label>
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
