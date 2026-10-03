<script>
  import { ui, setStreamChoice, setStreamScale, setStreamBitrate, toggleSdk, BITRATE_STEPS } from '../lib/app.svelte.js';
  import { AUTO_ORDER, FORMATS, HEVC_422, formatLabel } from '../lib/stream.js';
  import { mbps } from '../lib/auto.js';

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
  // How the way to the host is doing, from the host's last report, and
  // what Auto gave up for it.
  const connection = $derived.by(() => {
    if (!s.link) return 'Connection: measuring…';
    const behind = s.link.behindMs >= 5 ? `, ${s.link.behindMs} ms behind` : '';
    const n = s.net ?? {};
    if (n.draining) return `Connection: catching up${behind}, so half resolution, 15 fps, 0.5 Mbps`;
    if (s.link.backingUp) return `Connection: backing up at about ${mbps(s.link.carried)}${behind}`;
    const cuts = [n.scale && 'half resolution', n.fps && `${s.fpsTarget} fps`, n.bitrate && `${(s.bitrate / 1e6).toFixed(1)} Mbps`].filter(Boolean);
    if (!cuts.length) return `Connection: keeps up${behind}`;
    const check = n.probing ? '; checking for room…' : n.checkIn ? `; checks for room in ${n.checkIn} s` : '';
    return `Connection: carries about ${mbps(s.estimate)}${behind}, so ${cuts.join(', ')}${check}`;
  });
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
  <!-- With the codec on Auto these follow it (see auto.js): full resolution
       unless the page, the connection, the decoder or the encoder says
       half; the bitrate the codec needs, under what the connection carries;
       60 fps unless the connection is slow or the page hidden. A pinned
       codec lets you choose resolution and bitrate. -->
  <label class="setting">
    <span>Resolution</span>
    {#if auto}
      <span class="setting-value" title={s.why.scale ? `Half: ${s.why.scale}` : 'Full: every pixel the device renders'}>{s.scale === 2 ? 'Half' : 'Full'}</span>
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
        <span class="setting-value" title={s.why.bitrate ? `Bitrate ${s.why.bitrate}` : 'What the codec needs at this resolution'}>{(s.bitrate / 1e6).toFixed(1)} Mbps</span>
      {:else}
        <select class="popup" value={s.bitrateChoice} onchange={(e) => setStreamBitrate(Number(e.currentTarget.value))}>
          {#each BITRATE_STEPS as bps (bps)}<option value={bps}>{bps / 1e6} Mbps</option>{/each}
        </select>
      {/if}
    </label>
  {/if}
  {#if auto}
    <div class="setting">
      <span>Frame Rate</span>
      <span class="setting-value" title={s.why.fps ? `${s.fpsTarget} fps: ${s.why.fps}` : 'As fast as the simulator draws'}>{s.fpsTarget} fps</span>
    </div>
  {/if}
  <div class="setting-note">
    <p>{auto ? `Auto: ${label}` : label} · {s.fps} fps · {s.mbps.toFixed(1)} Mbit/s{decoding ? ` · ${decoding}` : ''}</p>
    {#if auto}
      <p>{connection}</p>
      {#if s.why.scale && !s.net?.scale}<p>Half resolution: {s.why.scale}.</p>{/if}
      {#if s.why.fps && !s.net?.fps}<p>{s.fpsTarget} fps: {s.why.fps}.</p>{/if}
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
