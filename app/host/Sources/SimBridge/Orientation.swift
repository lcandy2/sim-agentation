// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). DeviceOrientation.swift, OrientationEvent.swift and
// PurpleEventOrientation.swift. Changes: folded into one file; foldable
// devices (Device Hub pose events) are left out; the landscape cases carry
// UIDeviceOrientation's names (baguette has the two swapped).

import Darwin.Mach
import Foundation
import ObjectiveC

/// A booted simulator's orientation, as UIDeviceOrientation: the payload of
/// the GSEvent below is exactly this number. Checked against the stream:
/// with 3 the interface's top lies along the framebuffer's right edge, so
/// the device has turned counterclockwise.
public enum DeviceOrientation: UInt32, Sendable, CaseIterable {
    case portrait = 1
    case portraitUpsideDown = 2
    case landscapeLeft = 3 // turned 90° counterclockwise; the bottom edge on the right
    case landscapeRight = 4 // turned 90° clockwise; the bottom edge on the left

    public init?(wireName: String) {
        switch wireName {
        case "portrait": self = .portrait
        case "portrait-upside-down": self = .portraitUpsideDown
        case "landscape-left": self = .landscapeLeft
        case "landscape-right": self = .landscapeRight
        default: return nil
        }
    }
}

/// Turns the booted iOS guest by sending a `GSEventTypeDeviceOrientationChanged`
/// mach message to the simulator's `PurpleWorkspacePort`, as Simulator.app's
/// `[SimDevice(GSEvents) gsEventsSendOrientation:]` does (idb's
/// `PrivateHeaders/SimulatorApp/GSEvent.h` documents the same bytes).
public enum Orientation {
    /// False when the device isn't booted far enough to have the port yet.
    @discardableResult
    public static func set(_ orientation: DeviceOrientation, udid: String) -> Bool {
        guard let device = Simulators.shared.object(for: udid),
              let port = lookupPort(on: device, named: "PurpleWorkspacePort")
        else { return false }
        var message = machMessage(orientation)
        write(port, at: 0x08, into: &message) // msgh_remote_port
        return message.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return mach_msg_send(base.assumingMemoryBound(to: mach_msg_header_t.self)) == KERN_SUCCESS
        }
    }

    /// The 112-byte message, little-endian:
    ///
    ///     0x00  msgh_bits         0x13 (MACH_MSG_TYPE_COPY_SEND)
    ///     0x04  msgh_size         108
    ///     0x08  msgh_remote_port  patched with PurpleWorkspacePort
    ///     0x14  msgh_id           0x7B (GSEventMachMessageID)
    ///     0x18  GSEvent.type      50 | 0x20000 (DeviceOrientationChanged | host flag)
    ///     0x48  record_info_size  4
    ///     0x4C  record_info_data  the UIDeviceOrientation
    static func machMessage(_ orientation: DeviceOrientation) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 112)
        write(0x13, at: 0x00, into: &bytes)
        write(108, at: 0x04, into: &bytes)
        write(0x7B, at: 0x14, into: &bytes)
        write(50 | 0x20000, at: 0x18, into: &bytes)
        write(4, at: 0x48, into: &bytes)
        write(orientation.rawValue, at: 0x4C, into: &bytes)
        return bytes
    }

    private static func write(_ value: UInt32, at offset: Int, into bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { for i in 0..<4 { bytes[offset + i] = $0[i] } }
    }

    /// `[SimDevice lookup:error:]`: a name in the simulator's bootstrap
    /// namespace to a live port. The error comes back +0 and autoreleased,
    /// hence the autoreleasing pointer (a plain one over-releases it).
    private static func lookupPort(on device: NSObject, named name: String) -> UInt32? {
        let sel = NSSelectorFromString("lookup:error:")
        guard device.responds(to: sel) else { return nil }
        typealias Lookup = @convention(c) (AnyObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt32
        let lookup = unsafeBitCast(device.method(for: sel), to: Lookup.self)
        var error: NSError?
        let port = lookup(device, sel, name as NSString, &error)
        return port == 0 ? nil : port
    }
}
