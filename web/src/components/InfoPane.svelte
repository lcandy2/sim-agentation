<script>
  import { ui, flashStatus } from '../lib/app.svelte.js';
  import { formatLabel } from '../lib/stream.js';

  const sim = $derived(ui.sims.find((s) => s.udid === ui.udid));
  const model = $derived(sim?.deviceType.replace(/^.*SimDeviceType\./, '').replaceAll('-', ' ') ?? '');
  const screen = $derived(ui.chrome?.screen);
  const rows = $derived(
    sim
      ? [
          ['Name', sim.name],
          ['Model', model],
          ['Software', sim.runtime],
          ['State', sim.state === 'Booted' ? 'Running' : sim.state],
          ['Screen', screen ? `${screen.width} × ${screen.height} pt` : '—'],
          ['Orientation', ui.running ? ui.orientation.replaceAll('-', ' ') : '—'],
          ['Stream', ui.live ? `${formatLabel(ui.stream.format)} · ${ui.stream.fps} fps` : '—'],
        ]
      : [],
  );

  async function copyId() {
    await navigator.clipboard.writeText(sim.udid);
    flashStatus('Copied the identifier');
  }
</script>

<section class="settings-group">
  <h3>{sim?.name ?? 'Device'}</h3>
  {#if sim}
    <dl class="info">
      {#each rows as [label, value] (label)}
        <dt>{label}</dt><dd>{value}</dd>
      {/each}
      <dt>Identifier</dt>
      <dd><button class="link" title="Copy" onclick={copyId}>{sim.udid}</button></dd>
    </dl>
  {:else}
    <p class="setting-note">No simulator selected.</p>
  {/if}
</section>
