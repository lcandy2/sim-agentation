// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). Changes: none beyond formatting.

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface

public struct JPEGEncoder: Sendable {
    public let quality: Double

    public init(quality: Double = 0.8) {
        self.quality = quality
    }

    /// Wraps the IOSurface zero-copy and encodes it.
    public func encode(_ surface: IOSurface) -> Data? {
        var buffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surface,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixels = buffer?.takeRetainedValue() else { return nil }
        return encode(pixels)
    }

    /// Encodes a BGRA pixel buffer, e.g. one from `VideoFrameScaler`.
    public func encode(_ pixels: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels),
              let context = CGContext(
                  data: base,
                  width: CVPixelBufferGetWidth(pixels),
                  height: CVPixelBufferGetHeight(pixels),
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let image = context.makeImage()
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
