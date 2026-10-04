// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). Changes: VideoFrameDimensions folded in.

import CoreImage
import CoreVideo
import Foundation
import IOSurface

/// Projects an IOSurface into a pooled, codec-ready video frame.
///
/// Every frame is copied on the GPU before an encoder sees it: VideoToolbox
/// encodes asynchronously and SimulatorKit recycles the framebuffer surface
/// in place, so the bare surface races. At divisor 1 this is a 1:1 copy.
public final class VideoFrameScaler: @unchecked Sendable {
    private let context = CIContext(options: [.priorityRequestLow: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: (width: Int, height: Int)?

    public init() {}

    /// The surface divided by `divisor` (1 = full size), with both sides
    /// even because H.264 and HEVC use 4:2:0 chroma planes.
    public func scale(_ surface: IOSurface, by divisor: Int) -> CVPixelBuffer? {
        let sourceWidth = IOSurfaceGetWidth(surface)
        let sourceHeight = IOSurfaceGetHeight(surface)
        let divisor = max(1, divisor)
        let even = { (n: Int) in n.isMultiple(of: 2) ? n : n + 1 }
        let width = even(max(2, sourceWidth / divisor))
        let height = even(max(2, sourceHeight / divisor))

        if pool == nil || poolSize?.width != width || poolSize?.height != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = (width, height)
        }
        guard let pool else { return nil }

        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return nil }

        let image = CIImage(ioSurface: surface)
        let transform = CGAffineTransform(
            scaleX: CGFloat(width) / CGFloat(sourceWidth),
            y: CGFloat(height) / CGFloat(sourceHeight)
        )
        context.render(image.transformed(by: transform), to: output)

        // Publishes Core Image's GPU write before a CPU or VideoToolbox reader.
        CVPixelBufferLockBaseAddress(output, [])
        CVPixelBufferUnlockBaseAddress(output, [])
        return output
    }
}
