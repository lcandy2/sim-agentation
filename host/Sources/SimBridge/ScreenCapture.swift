// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). Changes: phone screens only (largest framebuffer
// plane), merged the capture coalescer and idle floor into this type.

import Foundation
import IOSurface
import ObjectiveC

public enum ScreenError: Error, CustomStringConvertible {
    case ioUnavailable, noFramebuffer, callbackUnavailable

    public var description: String {
        switch self {
        case .ioUnavailable: "the simulator has no IO client; is it booted?"
        case .noFramebuffer: "the simulator has no framebuffer display"
        case .callbackUnavailable: "SimulatorKit framebuffer callbacks are unavailable"
        }
    }
}

/// Receives the simulator's framebuffer as IOSurfaces, as SimulatorKit
/// composites them. Frames arrive on a private serial queue; at most one
/// capture is queued at a time, so a fast compositor degrades gracefully.
public final class ScreenCapture: @unchecked Sendable {
    private let udid: String
    private let queue = DispatchQueue(label: "sim-agentation.screen", qos: .userInteractive)
    private var descriptors: [NSObject] = []
    private var callbacks: [ObjectIdentifier: NSUUID] = [:]
    private var onFrame: ((IOSurface) -> Void)?
    private var idleTimer: DispatchSourceTimer?
    private var captureQueued = false
    private var io: NSObject?
    private var preferred: (width: Int, height: Int)? // on `queue`

    /// SimulatorKit only composites when something changes; pull a frame at
    /// least this often so a still screen still produces one.
    private static let idleInterval: DispatchTimeInterval = .milliseconds(200)

    public init(udid: String) {
        self.udid = udid
    }

    deinit { stop() }

    public func start(onFrame: @escaping (IOSurface) -> Void) throws {
        guard let device = Simulators.shared.object(for: udid) else { throw SimulatorError.notFound(udid) }
        guard let io = callObject(device, "io") else { throw ScreenError.ioUnavailable }
        self.io = io
        self.onFrame = onFrame

        var found = framebufferDescriptors(io)
        if found.isEmpty {
            io.perform(NSSelectorFromString("updateIOPorts"))
            found = framebufferDescriptors(io)
        }
        guard !found.isEmpty else { throw ScreenError.noFramebuffer }
        descriptors = found
        for descriptor in found { try register(on: descriptor) }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.idleInterval)
        timer.setEventHandler { [weak self] in self?.scheduleCapture() }
        timer.resume()
        idleTimer = timer
    }

    public func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        let unregister = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        for descriptor in descriptors {
            if let uuid = callbacks[ObjectIdentifier(descriptor)], descriptor.responds(to: unregister) {
                descriptor.perform(unregister, with: uuid)
            }
        }
        descriptors = []
        callbacks = [:]
        onFrame = nil
        io = nil
    }

    /// Requests a frame now, e.g. when a viewer connects.
    public func requestFrame() {
        queue.async { [weak self] in self?.scheduleCapture() }
    }

    // MARK: - private

    private func framebufferDescriptors(_ io: NSObject) -> [NSObject] {
        guard let ports = io.value(forKey: "deviceIOPorts") as? [NSObject] else { return [] }
        let portId = NSSelectorFromString("portIdentifier")
        let descriptor = NSSelectorFromString("descriptor")
        let surface = NSSelectorFromString("framebufferSurface")
        return ports.compactMap { port in
            guard port.responds(to: portId),
                  let id = port.perform(portId)?.takeUnretainedValue(),
                  "\(id)" == "com.apple.framebuffer.display",
                  port.responds(to: descriptor),
                  let desc = port.perform(descriptor)?.takeUnretainedValue() as? NSObject,
                  desc.responds(to: surface)
            else { return nil }
            return desc
        }
    }

    private func register(on descriptor: NSObject) throws {
        let sel = NSSelectorFromString(
            "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
        )
        guard descriptor.responds(to: sel),
              let imp = class_getMethodImplementation(type(of: descriptor), sel)
        else { throw ScreenError.callbackUnavailable }
        let uuid = NSUUID()
        callbacks[ObjectIdentifier(descriptor)] = uuid
        let frame: @convention(block) () -> Void = { [weak self] in self?.scheduleCapture() }
        let surfaces: @convention(block) () -> Void = { [weak self] in self?.scheduleCapture() }
        let properties: @convention(block) () -> Void = {}
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject, AnyObject, AnyObject) -> Void
        unsafeBitCast(imp, to: Fn.self)(descriptor, sel, uuid, queue as AnyObject, frame as AnyObject, surfaces as AnyObject, properties as AnyObject)
    }

    /// Runs on `queue`. Coalesces: one capture waiting at a time.
    private func scheduleCapture() {
        guard !captureQueued else { return }
        captureQueued = true
        queue.async { [weak self] in
            guard let self else { return }
            self.captureQueued = false
            autoreleasepool { self.capture() }
        }
    }

    /// A foldable's lit panel, by its size in pixels: frames come from the
    /// plane closest to it instead of the largest (iPhone Duo's larger
    /// panel is the dark one while it's folded).
    public func preferPlane(width: Int, height: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preferred = (width, height)
            self.scheduleCapture()
        }
    }

    /// Forwards the main screen: the largest framebuffer plane, or the one
    /// closest to `preferred`.
    private func capture() {
        let sel = NSSelectorFromString("framebufferSurface")
        var best: (surface: IOSurface, score: Int)?
        for descriptor in descriptors {
            guard let object = descriptor.perform(sel)?.takeUnretainedValue() else { continue }
            let surface = unsafeDowncast(object as AnyObject, to: IOSurface.self)
            let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
            guard width * height > 0 else { continue }
            // Higher is better: the area, or how near the preferred size.
            let score = preferred.map { p in -((width - p.width) * (width - p.width) + (height - p.height) * (height - p.height)) } ?? width * height
            if best == nil || score > best!.score { best = (surface, score) }
        }
        if let best { onFrame?(best.surface) }
    }
}
