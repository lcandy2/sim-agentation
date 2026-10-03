// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). H264Encoder.swift and H264Tuning.swift. Changes: HEVC
// as well as H.264 (hvcC taken from the format description), HEVC 4:2:2,
// the output handler also hears about dropped frames, and a requested
// keyframe carries the parameter sets again so a client can restart its
// decoder.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Real-time hardware H.264 or HEVC for WebCodecs. Submission is
/// fire-and-forget: output arrives on VideoToolbox's queue.
///
/// Tuned for latency, as baguette's `lowLatency` preset: real-time, no
/// frame reordering, no frame delay and low-latency rate control, so the
/// browser's decoder holds nothing back; a long GOP keeps big keyframes rare.
public final class VideoEncoder: @unchecked Sendable {
    public enum Codec: Sendable {
        case h264, hevc
        /// HEVC Main 4:2:2 10-bit: color at half the horizontal resolution
        /// instead of half both ways, so colored text keeps its edges. The
        /// hardware encoder only produces it from 4:2:2 10-bit input and
        /// without low-latency rate control, which pins it to Main 4:2:0.
        case hevc422
    }

    public struct Encoded: Sendable {
        /// avcC or hvcC: sent with the first keyframe, and again with a requested one.
        public let description: Data?
        public let isKeyframe: Bool
        /// Length-prefixed NAL units.
        public let data: Data
    }

    /// Called once per submitted frame on VideoToolbox's queue; nil when
    /// the frame was dropped.
    public var onEncoded: (@Sendable (Encoded?) -> Void)?

    private static let keyFrameIntervalSeconds = 5

    private let codec: Codec
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var fps: Int32
    private var bitrate: Int
    private var emittedDescription = false
    private var frameCount: Int64 = 0
    private var transfer: VTPixelTransferSession? // BGRA → 4:2:2 10-bit, for .hevc422

    public init(codec: Codec, fps: Int = 60, bitrate: Int = 8_000_000) {
        self.codec = codec
        self.fps = Int32(fps)
        self.bitrate = bitrate
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    public func setBitrate(_ bps: Int) {
        lock.lock(); defer { lock.unlock() }
        bitrate = bps
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bps))
    }

    public func setFrameRate(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        fps = Int32(max(1, value))
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
    }

    /// Submits a frame. Returns false when nothing was submitted, in which
    /// case `onEncoded` won't be called for it.
    @discardableResult
    public func encode(_ pixels: CVPixelBuffer, forceKeyframe: Bool = false) -> Bool {
        lock.lock()
        let w = Int32(CVPixelBufferGetWidth(pixels))
        let h = Int32(CVPixelBufferGetHeight(pixels))
        if session == nil || w != width || h != height {
            width = w
            height = h
            rebuildSession()
        }
        if forceKeyframe { emittedDescription = false }
        frameCount += 1
        let pts = CMTime(value: frameCount, timescale: fps)
        let session = self.session
        lock.unlock()
        guard let session else { return false }
        var pixels = pixels
        if codec == .hevc422 {
            guard let converted = convert(pixels, for: session) else { return false }
            pixels = converted
        }

        let frameProperties: NSDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as NSDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixels,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            let encoded = status == noErr ? sampleBuffer.flatMap(self.extract) : nil
            self.onEncoded?(encoded)
        }
        return status == noErr
    }

    // MARK: - private

    /// Lock held.
    private func rebuildSession() {
        if let session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
        // Low-latency rate control is a create-time spec, not a property. If
        // an encoder refuses it, fall back to the regular real-time path.
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue!] as CFDictionary
        let codecType = codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        // 4:2:2 frames come from the session's own pool, converted into it.
        let input: CFDictionary? = codec == .hevc422
            ? [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ] as CFDictionary
            : nil
        var created: VTCompressionSession?
        for spec in codec == .hevc422 ? [nil] : [lowLatency, nil] {
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: width, height: height,
                codecType: codecType,
                encoderSpecification: spec,
                imageBufferAttributes: input,
                compressedDataAllocator: kCFAllocatorDefault,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
            if status == noErr, created != nil { break }
        }
        guard let created else { return }

        // Rejected properties return a non-noErr status we ignore.
        let profile = switch codec {
        case .h264: kVTProfileLevel_H264_High_AutoLevel
        case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel
        case .hevc422: kVTProfileLevel_HEVC_Main42210_AutoLevel
        }
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, profile),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Self.keyFrameIntervalSeconds * Int(max(1, fps)))),
            (kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0)),
        ]
        for (key, value) in properties { VTSessionSetProperty(created, key: key, value: value) }
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        emittedDescription = false
    }

    /// BGRA into a 4:2:2 10-bit buffer from the session's pool.
    private func convert(_ pixels: CVPixelBuffer, for session: VTCompressionSession) -> CVPixelBuffer? {
        if transfer == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) }
        guard let transfer, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output, VTPixelTransferSessionTransferImage(transfer, from: pixels, to: output) == noErr else { return nil }
        return output
    }

    private func extract(_ sample: CMSampleBuffer) -> Encoded? {
        let isKeyframe = !Self.notSync(sample)
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer
        else { return nil }
        let data = Data(bytes: pointer, count: length)

        var description: Data?
        lock.lock()
        if isKeyframe, !emittedDescription, let format = CMSampleBufferGetFormatDescription(sample) {
            description = codec == .h264 ? Self.avcC(format) : Self.hvcC(format)
            emittedDescription = description != nil
        }
        lock.unlock()
        return Encoded(description: description, isKeyframe: isKeyframe, data: data)
    }

    private static func notSync(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let dict = CFArrayGetValueAtIndex(attachments, 0)
        else { return false }
        let cfDict = unsafeBitCast(dict, to: CFDictionary.self)
        return CFDictionaryContainsKey(cfDict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque())
    }

    /// avcC parameter-set blob (ISO/IEC 14496-15 §5.2.4.1).
    private static func avcC(_ format: CMFormatDescription) -> Data? {
        var spsCount = 0
        var spsPointer: UnsafePointer<UInt8>?
        var spsSize = 0
        var nalSize: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: &spsPointer, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &spsCount, nalUnitHeaderLengthOut: &nalSize
        ) == noErr, let spsPointer else { return nil }
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 1,
            parameterSetPointerOut: &ppsPointer, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        ) == noErr, let ppsPointer else { return nil }

        let sps = UnsafeBufferPointer(start: spsPointer, count: spsSize)
        let pps = UnsafeBufferPointer(start: ppsPointer, count: ppsSize)
        var blob = Data([0x01, sps[1], sps[2], sps[3], 0xFF, 0xE1])
        blob.append(contentsOf: [UInt8((spsSize >> 8) & 0xFF), UInt8(spsSize & 0xFF)])
        blob.append(contentsOf: sps)
        blob.append(contentsOf: [0x01, UInt8((ppsSize >> 8) & 0xFF), UInt8(ppsSize & 0xFF)])
        blob.append(contentsOf: pps)
        return blob
    }

    /// hvcC record (ISO/IEC 14496-15 §8.3.3), as VideoToolbox writes it into
    /// the format description.
    private static func hvcC(_ format: CMFormatDescription) -> Data? {
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
        return (atoms as? [String: Any])?["hvcC"] as? Data
    }
}
