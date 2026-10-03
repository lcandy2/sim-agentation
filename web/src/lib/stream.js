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

export const FORMATS = [
  { id: 'avcc', label: 'H.264', name: 'H.264 (AVC)' },
  { id: 'hevc', label: 'H.265', name: 'H.265 (HEVC)' },
  { id: 'mjpeg', label: 'JPEG', name: 'JPEG per frame' },
];

// H.265 in 4:2:2 10-bit: a variant of `hevc`, picked with the chroma switch.
export const HEVC_422 = { id: 'hevc422', name: 'H.265 (HEVC) 4:2:2 10-bit' };

// Codec strings only used to ask whether the browser can decode the format;
// the real ones come from each stream's description.
const PROBES = { avcc: 'avc1.640033', hevc: 'hvc1.1.6.L153.90', hevc422: 'hvc1.4.10.L153.BD.08' };

/** Which formats this browser can play. WebCodecs needs a secure context, which localhost is. */
export async function playableFormats() {
  const playable = { mjpeg: true, avcc: false, hevc: false, hevc422: false };
  if (typeof VideoDecoder === 'undefined') return playable;
  await Promise.all(
    Object.entries(PROBES).map(async ([id, codec]) => {
      try {
        playable[id] = (await VideoDecoder.isConfigSupported({ codec })).supported === true;
      } catch {}
    }),
  );
  return playable;
}

/** The stored preference when it plays here, else the best format that does. */
export function pickFormat(stored, playable) {
  if (stored && playable[stored]) return stored;
  if (stored === 'hevc422' && playable.hevc) return 'hevc';
  return FORMATS.find((f) => playable[f.id]).id;
}

/**
 * A decoder for one stream. `onFrame` gets an ImageBitmap or a VideoFrame,
 * both drawable and closable; the caller owns closing them. `onError`
 * reports a video decoder that died; make a new one and ask for a keyframe.
 */
export function createDecoder(format, { onFrame, onError }) {
  return format === 'mjpeg' ? jpegDecoder(onFrame) : videoDecoder(format, onFrame, onError);
}

function jpegDecoder(onFrame) {
  return {
    feed(buffer) {
      createImageBitmap(new Blob([buffer], { type: 'image/jpeg' })).then(onFrame, () => {});
    },
    hardware: null,
    dispose() {},
  };
}

function videoDecoder(format, onFrame, onError) {
  let timestamp = 0;
  const state = { hardware: null };
  const decoder = new VideoDecoder({
    output: onFrame,
    error: (e) => onError?.(e),
  });
  return {
    get hardware() {
      return state.hardware;
    },
    feed(buffer) {
      if (buffer.byteLength < 2) return;
      const bytes = new Uint8Array(buffer);
      const tag = bytes[0];
      const payload = bytes.subarray(1);
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
