// Stream formats and their decoders: WebSocket messages in, paintable
// frames out. Adapted from baguette's frame-decoder.js and stream-format.js
// (https://github.com/tddworks/baguette, Apache License 2.0). Changes: HEVC
// alongside H.264, HEVC 4:2:2, decoder errors reported so the caller can
// restart.
//
// Wire format (see DeviceSession.swift): `mjpeg` sends one JPEG per binary
// message; `avcc` and `hevc` send [tag][payload], where 0x01 is the
// avcC/hvcC description, 0x02 a keyframe, 0x03 a delta frame and 0x04 a
// JPEG seed that paints before the first keyframe decodes.

// In the order Auto tries them.
export const FORMATS = [
  { id: 'hevc', label: 'H.265', name: 'H.265 (HEVC)' },
  { id: 'avcc', label: 'H.264', name: 'H.264 (AVC)' },
  { id: 'mjpeg', label: 'JPEG', name: 'JPEG per frame' },
];

// H.265 in 4:2:2 10-bit: a variant of `hevc`, picked with the chroma switch.
export const HEVC_422 = { id: 'hevc422', name: 'H.265 (HEVC) 4:2:2 10-bit' };

// Codec strings only used to ask whether the browser can decode the format;
// the real ones come from each stream's description.
const PROBES = { avcc: 'avc1.640033', hevc: 'hvc1.1.6.L153.90', hevc422: 'hvc1.4.10.L153.BD.08' };

// Auto tries these in order. H.265 first: same latency and frame rate as
// H.264, better pictures per bit. H.264 decodes nearly everywhere. JPEG
// needs no WebCodecs at all. 4:2:2 stays manual: twice the bitrate and no
// low-latency rate control, for edges you only see zoomed in.
export const AUTO_ORDER = FORMATS.map((f) => f.id);

/**
 * What this browser can do with each format: `playable` (WebCodecs can
 * decode it; it needs a secure context, which localhost is) and `hardware`
 * (decodes on the media engine; false means a software decoder, which is
 * brutal at full resolution and 60 fps; null means unknown).
 */
export async function decodeCapabilities() {
  const playable = { mjpeg: true, avcc: false, hevc: false, hevc422: false };
  const hardware = { mjpeg: null, avcc: null, hevc: null, hevc422: null };
  if (typeof VideoDecoder === 'undefined') return { playable, hardware };
  await Promise.all(
    Object.entries(PROBES).map(async ([id, codec]) => {
      try {
        playable[id] = (await VideoDecoder.isConfigSupported({ codec })).supported === true;
      } catch {}
      if (playable[id]) hardware[id] = await probeHardware(codec);
    }),
  );
  return { playable, hardware };
}

/**
 * The format to stream for a choice: the chosen one when it plays here, or
 * for 'auto' the first of AUTO_ORDER that plays in hardware and hasn't
 * failed this session. JPEG always plays.
 */
export function pickFormat(choice, { playable, hardware }, failed = new Set()) {
  if (choice !== 'auto' && playable[choice]) return choice;
  if (choice === 'hevc422' && playable.hevc) return 'hevc';
  return AUTO_ORDER.find((id) => playable[id] && hardware[id] !== false && !failed.has(id)) ?? 'mjpeg';
}

export const formatLabel = (id) => (id === HEVC_422.id ? 'H.265 4:2:2' : (FORMATS.find((f) => f.id === id)?.label ?? id));

/**
 * A decoder for one stream. `onFrame` gets an ImageBitmap or a VideoFrame,
 * both drawable and closable; the caller owns closing them. `onError`
 * reports a video decoder that died; make a new one and ask for a keyframe.
 */
export function createDecoder(format, { onFrame, onError }) {
  return format === 'mjpeg' ? jpegDecoder(onFrame) : videoDecoder(format, onFrame, onError);
}

function jpegDecoder(onFrame) {
  const stats = { received: 0, firstAt: 0, decoded: 0, backlog: 0 };
  let decoding = 0;
  return {
    stats,
    feed(buffer) {
      stats.received++;
      stats.firstAt ||= performance.now();
      stats.backlog = Math.max(stats.backlog, ++decoding);
      createImageBitmap(new Blob([buffer], { type: 'image/jpeg' })).then((bitmap) => {
        decoding--;
        stats.decoded++;
        onFrame(bitmap);
      }, () => decoding--);
    },
    hardware: null,
    dispose() {},
  };
}

function videoDecoder(format, onFrame, onError) {
  let timestamp = 0;
  const state = { hardware: null };
  // Video messages in and frames out, so a caller can tell a decoder that
  // gets a stream but never produces a picture (the JPEG seed doesn't count),
  // and the most frames it has held at once (reset by the caller), so it can
  // tell one that falls behind.
  const stats = { received: 0, firstAt: 0, decoded: 0, backlog: 0 };
  const decoder = new VideoDecoder({
    output: (frame) => {
      stats.decoded++;
      onFrame(frame);
    },
    error: (e) => onError?.(e),
  });
  return {
    stats,
    get hardware() {
      return state.hardware;
    },
    feed(buffer) {
      if (buffer.byteLength < 2) return;
      const bytes = new Uint8Array(buffer);
      const tag = bytes[0];
      const payload = bytes.subarray(1);
      if (tag <= 0x03) {
        stats.received++;
        stats.firstAt ||= performance.now();
      }
      if (tag === 0x01) {
        const config = {
          codec: format === 'avcc' ? avcCodec(payload) : hevcCodec(payload),
          description: payload.slice(),
          optimizeForLatency: true,
          hardwareAcceleration: 'prefer-hardware',
        };
        probeHardware(config.codec).then((hw) => (state.hardware = hw));
        try {
          decoder.configure(config);
        } catch (e) {
          onError?.(e);
        }
      } else if ((tag === 0x02 || tag === 0x03) && decoder.state === 'configured') {
        try {
          decoder.decode(new EncodedVideoChunk({ type: tag === 0x02 ? 'key' : 'delta', timestamp, data: payload }));
          timestamp += 16667; // never displayed; only has to increase
          stats.backlog = Math.max(stats.backlog, decoder.decodeQueueSize);
        } catch {}
      } else if (tag === 0x04) {
        // JPEG seed: paints before the first keyframe decodes.
        createImageBitmap(new Blob([payload], { type: 'image/jpeg' })).then(onFrame, () => {});
      }
    },
    dispose() {
      try {
        decoder.close();
      } catch {}
    },
  };
}

/**
 * Whether this browser says it decodes the format at this size, 60 fps,
 * smoothly; null when it can't say (or for JPEG, which it always decodes).
 */
export async function decodesSmoothly(format, { width, height }) {
  if (!PROBES[format] || !navigator.mediaCapabilities) return null;
  try {
    const info = await navigator.mediaCapabilities.decodingInfo({
      type: 'file',
      video: { contentType: `video/mp4; codecs="${PROBES[format]}"`, width, height, bitrate: 8_000_000, framerate: 60 },
    });
    return info.supported ? info.smooth : null;
  } catch {
    return null;
  }
}

// `prefer-hardware` silently falls back to a software decoder, which is
// brutal at full resolution and 60 fps. powerEfficient flags the hardware path.
async function probeHardware(codec) {
  try {
    const info = await navigator.mediaCapabilities.decodingInfo({
      type: 'file',
      video: { contentType: `video/mp4; codecs="${codec}"`, width: 1206, height: 2622, bitrate: 8_000_000, framerate: 60 },
    });
    return info.powerEfficient;
  } catch {
    return null;
  }
}

const hex2 = (b) => b.toString(16).padStart(2, '0');

/** avc1.PPCCLL from the avcC record's profile, compatibility and level bytes. */
function avcCodec(avcC) {
  return `avc1.${hex2(avcC[1])}${hex2(avcC[2])}${hex2(avcC[3])}`;
}

/** hvc1 codec string from an hvcC record (ISO/IEC 14496-15 Annex E). */
function hevcCodec(hvcC) {
  const space = ['', 'A', 'B', 'C'][hvcC[1] >> 6];
  const tier = hvcC[1] & 0x20 ? 'H' : 'L';
  const profile = hvcC[1] & 0x1f;
  let compatibility = ((hvcC[2] << 24) | (hvcC[3] << 16) | (hvcC[4] << 8) | hvcC[5]) >>> 0;
  let reversed = 0;
  for (let i = 0; i < 32; i++) {
    reversed = ((reversed << 1) | (compatibility & 1)) >>> 0;
    compatibility >>>= 1;
  }
  const constraints = [...hvcC.subarray(6, 12)];
  while (constraints.length && constraints.at(-1) === 0) constraints.pop();
  const level = hvcC[12];
  return [`hvc1`, `${space}${profile}`, reversed.toString(16).toUpperCase(), `${tier}${level}`, ...constraints.map((b) => hex2(b).toUpperCase())].join('.');
}
