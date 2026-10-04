// Auto's resolution, bitrate and frame rate, with the codec on Auto. Each
// second the host says how the stream kept up (DeviceSession's `stats`) and
// the page adds how its decoder did; `observe` learns from that and
// `decide` picks from what's learned, what the page shows and what this
// browser said it decodes smoothly.
//
// The connection: the host counts the bytes the viewer hasn't received yet
// and how long frames waited for them, and the page how late the host's
// report arrives, which catches a backlog past the host's socket too (a
// tunnel or a proxy takes everything at once, then holds it). When either
// grows the stream is faster than the connection, so the estimate of what
// it carries drops to 85% of what got through, as WebRTC's congestion
// control does; when the picture is already far behind, the stream all
// but stops until it catches up. Coming
// back is quick to where it last backed up, careful past that, and
// `probeFor` checks for room with padding before the picture goes back up,
// since a stream held down doesn't fill the connection and can't show it
// carries more. On this Mac the backlog stays empty and the estimate
// unlimited. The browser's Network Information API isn't asked: it
// describes the internet connection, not the way to the host, which may be
// a tunnel.

export const MIN_BITRATE = 1_000_000;
const MAX_BITRATE = 16_000_000;
const BITS_PER_PIXEL = { hevc: 0.035, avcc: 0.05, hevc422: 0.06 }; // per frame, at 60 fps
const HEADROOM = 0.9; // of the estimate, for keyframes
export const HIDDEN_FPS = 5;

/** The bitrate a codec needs for a sharp picture at this size and frame rate, 2–16 Mbps. */
export function idealBitrate(format, { width, height }, scale, fps = 60) {
  const bps = (width / scale) * (height / scale) * fps * (BITS_PER_PIXEL[format] ?? 0.05);
  return Math.min(MAX_BITRATE, Math.max(2_000_000, bps));
}

export function createAuto() {
  return {
    estimate: Infinity, // bits/s the connection carries, as far as anyone has seen
    limit: 0,           // bits/s that got through the last time it backed up
    calm: 0,            // reports since the connection last backed up
    drains: [],         // the last reports' backlog, in ms of stream
    offsets: [],        // the last minute's reports: when they arrived less when they were sent
    late: 0,            // reports in a row that came late
    lateMs: 0,          // how late the last one was
    draining: false,    // the picture is far behind: next to nothing streams till it catches up
    link: null,         // { behindMs, carried, backingUp } from the last report, for the settings
    quiet: 2,           // reports to ignore: a new stream starts with a burst
    netHalf: false,     // the connection can't carry full resolution well
    probing: false,     // a probe is out (see probeFor)
    nextProbeAt: 0,
    probeFailures: 0,   // probes in a row the connection didn't take
    mjpegStep: 0,       // JPEG has no bitrate: 0 full, 1 half, 2 half at 30 fps
    smooth: null,       // the browser decodes full resolution at 60 fps smoothly (null: unknown)
    // The decoder or the Mac's encoder falling behind at full resolution
    // gets it half for a while (see observe).
    decodeLag: 0,       // reports in a row the decoder fell behind
    decodeHalfUntil: 0,
    decodeStrikes: 0,
    encodeLag: 0,
    encodeHalfUntil: 0,
    encodeStrikes: 0,
    encodeTrial: null,  // { frames, checks }: what full resolution sent, while half is on trial
    encodeIdleUntil: 0, // half didn't help the encoder, so it isn't tried again till then
    changedAt: 0,       // when the resolution last changed
    byPage: false,      // ...and whether the page's size was why
    lowFps: false,      // 30 fps for a slow connection
  };
}

/** Another format: another decoder and encoder, so what the last ones couldn't do doesn't hold. */
export function newFormat(auto) {
  Object.assign(auto, { decodeHalfUntil: 0, decodeStrikes: 0, encodeHalfUntil: 0, encodeStrikes: 0, encodeTrial: null, encodeIdleUntil: 0, mjpegStep: 0 });
}

/** A new stream: the first moments are a keyframe and a seed, not a measure of anything. */
export function restart(auto) {
  auto.quiet = 2;
  auto.probing = false;
  auto.decodeLag = auto.encodeLag = 0;
}

/**
 * Learns from one second of streaming. `host` is the host's stats message,
 * `page` what the page saw in the same second: `fed` frames into the
 * decoder, `decoded` frames out and `backlog`, the most it held at once;
 * `received`, bits/s that arrived; `offset`, when the report arrived less
 * its `t` (two clocks, so only its changes mean anything).
 */
export function observe(auto, host, page, { format, fps, scale, hidden, now = performance.now() }) {
  // A hidden page streams slowly on purpose and decodes when it likes; a
  // probe's padding is in the backlog on purpose.
  if (hidden || auto.probing) return;
  // How late the report came, past the least of the last minute: the
  // frames ahead of it are as late, wherever they waited. Twice in a row,
  // or very late once, as one slow moment of the page's makes one late.
  let lateMs = 0;
  if (Number.isFinite(page.offset)) {
    auto.offsets = [...auto.offsets.slice(-59), page.offset];
    lateMs = page.offset - Math.min(...auto.offsets);
    // Seconds late is a clock that jumped (a Mac waking up), not a backlog.
    if (lateMs > 5000) [auto.offsets, lateMs] = [[page.offset], 0];
  }
  auto.lateMs = Math.round(lateMs);
  if (auto.quiet > 0) return void auto.quiet--;

  const carried = (host.bytes * 8) / Math.max(0.25, host.seconds || 1); // bits/s onto the connection
  // How far behind the viewer is, in time at the rate the stream goes. A
  // far-away viewer is always a round trip behind (bytes not acknowledged
  // yet), so only what's above the last ten seconds' least counts.
  const behindMs = carried > 0 ? ((host.queued * 8) / carried) * 1000 : 0;
  auto.drains = [...auto.drains.slice(-9), behindMs];
  const growing = behindMs - Math.min(...auto.drains);
  // Late only counts when less arrived than was sent: a page busy with
  // something else takes its messages late too, but takes them all.
  const short = page.received > 0 && page.received < carried * 0.9;
  auto.late = lateMs > 150 && short ? auto.late + 1 : 0;
  const lateBacklog = auto.late >= 2 || (lateMs > 400 && short);
  const backingUp = host.held > 0.1 || (host.queued > 32_000 && growing > 60) || lateBacklog;
  // Far behind because of the connection: next to nothing streams till it catches up.
  auto.draining = auto.draining ? lateMs > 100 : lateMs > 300 && lateBacklog;
  auto.link = { behindMs: Math.round(Math.max(behindMs, lateMs)), carried, backingUp };

  if (backingUp) {
    // What got through: what reached the page, when past the host's
    // socket something took more than it passed on.
    const through = page.received > 0 ? Math.min(carried, page.received) : carried;
    auto.limit = through;
    auto.estimate = Math.max(MIN_BITRATE / HEADROOM, Math.min(auto.estimate, through) * 0.85);
    auto.calm = 0;
    if (format === 'mjpeg' && auto.mjpegStep < 2) auto.mjpegStep++;
  } else if (++auto.calm >= 3) {
    if (Number.isFinite(auto.estimate)) {
      const filling = carried >= auto.estimate * HEADROOM * 0.8;
      if (auto.estimate < auto.limit * 0.95) auto.estimate *= 1.08;
      else if (filling) auto.estimate *= 1.01; // probes find room faster
      // Well past what the stream ever asks for: the connection isn't a limit.
      if (auto.estimate > MAX_BITRATE * 2) auto.estimate = Infinity;
    }
    // JPEG steps back up one at a time, after a calm while each.
    if (format === 'mjpeg' && auto.mjpegStep > 0 && auto.calm >= 10) {
      auto.mjpegStep--;
      auto.calm = 0;
    }
  }

  // The decoder and the encoder: whichever falls behind at full resolution
  // gets half for a minute, then full again, as what kept it busy may be
  // done; each time it falls behind again, twice as long, up to ten.
  const halfFor = (strikes) => now + Math.min(600_000, 60_000 * 2 ** strikes);

  // The decoder: frames piling up in it, or coming out far fewer than went in.
  const lagging = page.backlog >= 4 || (page.fed >= 10 && page.decoded < page.fed * 0.85);
  auto.decodeLag = lagging ? auto.decodeLag + 1 : 0;
  if (auto.decodeLag >= 3 && scale === 1) auto.decodeHalfUntil = halfFor(auto.decodeStrikes++);

  // The Mac's encoder: a frame takes longer than the frame interval and a
  // quarter of the frames don't go out, though the connection isn't what
  // holds them. (VideoToolbox takes about one interval as a rule.) Half
  // gets five seconds to send clearly more frames; if it doesn't, the Mac
  // is busy with something else and half buys nothing, so full comes back
  // and half isn't tried again for five minutes.
  const slow = host.encodeMs > 1000 / fps && host.frames < fps * 0.75 && !backingUp;
  auto.encodeLag = slow ? auto.encodeLag + 1 : 0;
  if (auto.encodeLag >= 3 && scale === 1 && now >= auto.encodeHalfUntil && now >= auto.encodeIdleUntil) {
    auto.encodeHalfUntil = halfFor(auto.encodeStrikes++);
    auto.encodeTrial = { frames: host.frames, checks: 0 };
  } else if (auto.encodeTrial && scale === 2 && ++auto.encodeTrial.checks >= 5) {
    if (host.frames < auto.encodeTrial.frames * 1.2) {
      auto.encodeHalfUntil = 0;
      auto.encodeIdleUntil = now + 300_000;
    }
    auto.encodeTrial = null;
  }
}

/** Bits/s full resolution at 60 fps wants the connection to carry. */
const fullNeed = (format, pixels) => idealBitrate(format, pixels, 1) / HEADROOM;

/**
 * A probe to ask the host for now, { bps, slackMs }, or null: whether the
 * connection has room again, while it's holding anything back. Each one
 * that passes doubles the next, up to what full resolution at 60 fps
 * wants, so a connection that recovers is used again within seconds; each
 * one that fails waits longer for the next: 5 s, 10 s, then every 15 s.
 * They cost next to nothing either way (see DeviceSession's probe).
 */
export function probeFor(auto, { format, pixels, hidden, now = performance.now() }) {
  if (format === 'mjpeg' || hidden || auto.probing || auto.quiet > 0 || auto.calm < 3 || now < auto.nextProbeAt) return null;
  const need = fullNeed(format, pixels);
  if (auto.estimate >= need) return null;
  auto.probing = true;
  return {
    bps: Math.round(Math.min(need, Math.max(auto.estimate * 2, MIN_BITRATE * 2))),
    // How far behind the viewer may be and padding still go out: the
    // round trip it's always behind by, and a little.
    slackMs: Math.round(Math.min(300, Math.min(...auto.drains, 260) + 40)),
  };
}

/**
 * The host's answer to a probe. The host only knows its own socket took
 * the padding; the answer arriving late means something past it (a tunnel,
 * a proxy) took it and is still passing it on, so that's no room either.
 */
export function probed(auto, { ok, bps, offset }, now = performance.now()) {
  auto.probing = false;
  if (Number.isFinite(offset) && auto.offsets.length && offset - Math.min(...auto.offsets) > 120) ok = false;
  auto.quiet = Math.max(auto.quiet, 1); // the padding is in this second's backlog
  if (ok) {
    auto.estimate = Math.max(auto.estimate, bps);
    auto.limit = Math.max(auto.limit, bps);
    auto.probeFailures = 0;
    auto.nextProbeAt = now + 1000;
  } else {
    auto.nextProbeAt = now + Math.min(15_000, 5000 * 2 ** auto.probeFailures++);
  }
}

/**
 * Resolution, bitrate and frame rate to stream now, each with why.
 * `shown` is the share of the device's pixels the page draws (1 or more is
 * every pixel), `current` the resolution streaming now.
 */
export function decide(auto, { format, pixels, shown, current, hidden, now = performance.now() }) {
  const video = format !== 'mjpeg';
  const budget = auto.estimate * HEADROOM;

  // The connection and full resolution: below about half of what full
  // wants, half with the same bits looks better. Back at 70%.
  if (video) {
    const full = idealBitrate(format, pixels, 1);
    auto.netHalf = budget < full * (auto.netHalf ? 0.7 : 0.45);
  } else {
    auto.netHalf = auto.mjpegStep >= 1;
  }

  // Resolution: half for the first of these that holds. Full looks sharper
  // than half even with the page showing the device at half its pixels (a
  // 4:2:0 codec keeps color at a quarter of the pixels, and scaling down
  // hides what compression leaves), so only a small window gets half for
  // its size: a third of the pixels or less. Going back waits for 42%, so
  // a window dragged across the line doesn't flip the encoder back and forth.
  const pageHalf = current === 2 && auto.byPage ? shown <= 0.42 : shown <= 0.35;
  const catchingUp = `catching up: the picture is ${auto.lateMs} ms behind`;
  const reasons = [
    [pageHalf, `the page shows the device at ${Math.round(shown * 100)}% of its pixels`],
    [auto.draining && video, catchingUp],
    [auto.netHalf, `the connection carries about ${mbps(auto.estimate)}`],
    [auto.smooth === false, 'this browser can’t decode full resolution smoothly'],
    [now < auto.decodeHalfUntil, 'the decoder fell behind at full resolution'],
    [now < auto.encodeHalfUntil, 'the Mac’s encoder fell behind at full resolution'],
  ];
  const half = reasons.find(([holds]) => holds);
  let scale = half ? 2 : 1;
  // Back to full right away when zooming in; otherwise not within 5 s of
  // the last change, which cost a keyframe.
  if (scale < current && !auto.byPage && now - auto.changedAt < 5000) scale = current;
  if (scale !== current) {
    auto.changedAt = now;
    auto.byPage = half === reasons[0];
  }

  // Frame rate: the hidden page needs next to none; a connection under
  // about 1.2 Mbps (or JPEG at its last step) does better with fewer, sharper frames.
  auto.lowFps = video ? budget < (auto.lowFps ? 1_800_000 : 1_200_000) : auto.mjpegStep >= 2;
  let fps = 60;
  let fpsWhy = null;
  if (hidden) [fps, fpsWhy] = [HIDDEN_FPS, 'the page is hidden'];
  else if (auto.draining) [fps, fpsWhy] = [15, catchingUp];
  else if (auto.lowFps) [fps, fpsWhy] = [30, `the connection carries about ${mbps(auto.estimate)}`];

  // Bitrate: what the codec needs at that size, unless the connection carries less.
  let bitrate = null;
  let bitrateWhy = null;
  if (video) {
    const ideal = idealBitrate(format, pixels, scale, fps);
    bitrate = Math.round(Math.max(MIN_BITRATE, Math.min(ideal, budget)) / 100_000) * 100_000;
    if (budget < ideal) bitrateWhy = `held under the ${mbps(auto.estimate)} the connection carries`;
    if (auto.draining) [bitrate, bitrateWhy] = [500_000, catchingUp];
  }

  const net = {
    scale: scale === 2 && (half === reasons[1] || half === reasons[2]),
    bitrate: !!bitrateWhy,
    fps: !hidden && (auto.draining || auto.lowFps),
    draining: auto.draining,
  };
  return {
    scale,
    bitrate,
    fps,
    why: { scale: half?.[1] ?? null, bitrate: bitrateWhy, fps: fpsWhy },
    // What the connection is why of those, and whether it's being checked
    // for room, or when it will be.
    net: {
      ...net,
      probing: auto.probing,
      checkIn: (net.scale || net.bitrate || net.fps) && auto.nextProbeAt > now ? Math.ceil((auto.nextProbeAt - now) / 1000) : null,
    },
  };
}

export const mbps = (bps) => (Number.isFinite(bps) ? `${(bps / 1e6).toFixed(1)} Mbps` : 'unlimited');
