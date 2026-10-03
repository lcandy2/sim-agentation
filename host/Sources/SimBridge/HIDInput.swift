// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). Changes: merged IndigoHIDInput and
// IOHIDDigitizerDispatch, phone touch target only, no CarPlay or watch
// planes, gestures limited to what the annotation UI sends.

import CoreGraphics
import Foundation
import ObjectiveC

public enum TouchPhase: String, Sendable { case down, move, up }

public enum ScreenEdge: String, Sendable { case left, top, right, bottom }

public enum HardwareButton: String, Sendable, CaseIterable {
    case home, lock, power, action
    case volumeUp = "volume-up", volumeDown = "volume-down"
    case appSwitcher = "app-switcher"
    case swipeToHome = "swipe-to-home"
    /// The Face ID gesture: up from the bottom edge, a pause, then lift. The
    /// double home press `appSwitcher` sends does nothing there on iOS 26.5
    /// and 27 (measured).
    case swipeToAppSwitcher = "swipe-to-app-switcher"
}

/// Sends touches, buttons, scrolls and keys to a simulator through
/// SimulatorKit's Indigo HID messages, as Simulator.app does. Calls block
/// for the gesture's duration; run them off the main and network queues.
public final class HIDInput: @unchecked Sendable {
    private let udid: String
    private let lock = NSLock()
    private var client: AnyObject?
    private var touchId: UInt32 = 0
    private var activeTouch: UInt32?

    /// The built-in digitizer slot every phone and tablet screen answers on.
    private static let target: UInt32 = 0x32

    public init(udid: String) {
        self.udid = udid
    }

    deinit {
        if let client, let remove = Symbols.shared.removePointerService, let msg = remove() {
            Self.send(msg, to: client)
        }
    }

    // MARK: - touches (points are in screen points, `size` is the screen size)

    @discardableResult
    public func touch(_ phase: TouchPhase, at point: CGPoint, size: CGSize, edge: ScreenEdge? = nil) -> Bool {
        guard let c = warm() else { return false }
        if phase == .down { activeTouch = nextTouchId() }
        let id = activeTouch ?? nextTouchId()
        if phase == .up { activeTouch = nil }
        return Digitizer.send(normalized(point, size), id: id, phase: phase, edge: edge, target: Self.target, to: c)
    }

    @discardableResult
    public func tap(at point: CGPoint, size: CGSize, hold: Double = 0.05) -> Bool {
        guard let c = warm() else { return false }
        let id = nextTouchId()
        let p = normalized(point, size)
        guard Digitizer.send(p, id: id, phase: .down, edge: nil, target: Self.target, to: c) else { return false }
        usleep(UInt32(max(0.02, hold) * 1_000_000))
        return Digitizer.send(p, id: id, phase: .up, edge: nil, target: Self.target, to: c)
    }

    @discardableResult
    public func swipe(from start: CGPoint, to end: CGPoint, size: CGSize, duration: Double = 0.25) -> Bool {
        guard let c = warm() else { return false }
        let steps = 10
        let stepMs = UInt32(max(8, duration * 1000 / Double(steps + 2)))
        return Digitizer.swipe(from: normalized(start, size), to: normalized(end, size), steps: steps, stepMs: stepMs, edge: nil, id: nextTouchId(), target: Self.target, to: c)
    }

    /// Two-finger gestures (pinch, rotate) go through the mouse-event path.
    @discardableResult
    public func touch2(_ phase: TouchPhase, first: CGPoint, second: CGPoint, size: CGSize) -> Bool {
        guard let c = warm(), let mouse = Symbols.shared.mouse else { return false }
        let (eventType, direction): (UInt32, UInt32) = switch phase {
        case .down: (1, 1)
        case .move: (6, 0)
        case .up: (2, 2)
        }
        var p1 = normalized(first, size)
        var p2 = normalized(second, size)
        for _ in 0..<12 {
            let msg = withUnsafePointer(to: &p1) { a in
                withUnsafePointer(to: &p2) { b in
                    mouse(a, b, Self.target, eventType, direction, 1, 1, size.width, size.height)
                }
            }
            if let msg {
                Self.send(msg, to: c)
                return true
            }
            usleep(5_000)
        }
        return false
    }

    @discardableResult
    public func scroll(dx: Double, dy: Double) -> Bool {
        guard let c = warm(), let scroll = Symbols.shared.scroll, let msg = scroll(Self.target, dx, dy, 0) else { return false }
        Self.send(msg, to: c)
        return true
    }

    // MARK: - buttons and keys

    @discardableResult
    public func press(_ button: HardwareButton, hold: Double = 0) -> Bool {
        guard let c = warm() else { return false }
        let holdUs = holdMicroseconds(hold)
        switch button {
        case .home, .lock:
            return legacyButton(button == .home ? 0 : 1, holdUs: holdUs, on: c)
        case .appSwitcher:
            let first = legacyButton(0, holdUs: holdUs, on: c)
            usleep(150_000)
            return legacyButton(0, holdUs: holdUs, on: c) && first
        case .swipeToHome:
            return Digitizer.swipe(from: CGPoint(x: 0.5, y: 0.998), to: CGPoint(x: 0.5, y: 0.30), steps: 12, stepMs: 16, edge: .bottom, id: nextTouchId(), target: Self.target, to: c)
        case .swipeToAppSwitcher:
            // Measured on iOS 27.2: up a quarter of the screen over 400 ms and
            // still for 800 ms opens the switcher; stopping 40% up goes home.
            return Digitizer.swipe(from: CGPoint(x: 0.5, y: 0.998), to: CGPoint(x: 0.5, y: 0.73), steps: 25, stepMs: 16, holdMs: 800, edge: .bottom, id: nextTouchId(), target: Self.target, to: c)
        case .power: return hid(page: 12, usage: 48, holdUs: holdUs, on: c)
        case .volumeUp: return hid(page: 12, usage: 233, holdUs: holdUs, on: c)
        case .volumeDown: return hid(page: 12, usage: 234, holdUs: holdUs, on: c)
        case .action: return hid(page: 11, usage: 45, holdUs: holdUs, on: c)
        }
    }

    /// One keystroke. `usage` is a HID keyboard usage (page 7).
    @discardableResult
    public func key(usage: UInt32, modifiers: [UInt32] = [], hold: Double = 0) -> Bool {
        guard let c = warm(), let arbitrary = Symbols.shared.hidArbitrary else { return false }
        for m in modifiers {
            guard let down = arbitrary(Self.target, 7, m, 1) else { return false }
            Self.send(down, to: c)
        }
        guard let down = arbitrary(Self.target, 7, usage, 1) else { return false }
        Self.send(down, to: c)
        usleep(holdMicroseconds(hold == 0 ? 0.03 : hold))
        guard let up = arbitrary(Self.target, 7, usage, 2) else { return false }
        Self.send(up, to: c)
        for m in modifiers.reversed() {
            guard let release = arbitrary(Self.target, 7, m, 2) else { return false }
            Self.send(release, to: c)
        }
        return true
    }

    // MARK: - private

    private func nextTouchId() -> UInt32 {
        touchId &+= 1
        if touchId == 0 { touchId = 1 }
        return touchId
    }

    private func normalized(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        return CGPoint(x: clamp(p.x / size.width), y: clamp(p.y / size.height))
    }

    private func holdMicroseconds(_ seconds: Double) -> UInt32 {
        seconds > 0 ? UInt32(min(max(seconds * 1_000_000, 20_000), Double(UInt32.max))) : 100_000
    }

    private func legacyButton(_ code: UInt32, holdUs: UInt32, on c: AnyObject) -> Bool {
        guard let button = Symbols.shared.button, let down = button(code, 1, 0x33) else { return false }
        Self.send(down, to: c)
        usleep(holdUs)
        guard let up = button(code, 2, 0x33) else { return false }
        Self.send(up, to: c)
        return true
    }

    private func hid(page: UInt32, usage: UInt32, holdUs: UInt32, on c: AnyObject) -> Bool {
        guard let arbitrary = Symbols.shared.hidArbitrary, let down = arbitrary(Self.target, page, usage, 1) else { return false }
        Self.send(down, to: c)
        usleep(holdUs)
        guard let up = arbitrary(Self.target, page, usage, 2) else { return false }
        Self.send(up, to: c)
        return true
    }

    /// The SimDeviceLegacyHIDClient for this device, created once, with the
    /// pointer and mouse services registered.
    private func warm() -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }
        let symbols = Symbols.shared
        guard let device = Simulators.shared.object(for: udid),
              let cls = NSClassFromString("_TtC12SimulatorKit24SimDeviceLegacyHIDClient"),
              let meta = object_getClass(cls),
              let allocImp = class_getMethodImplementation(meta, NSSelectorFromString("alloc")),
              let initImp = class_getMethodImplementation(cls, NSSelectorFromString("initWithDevice:error:"))
        else {
            log("HID client unavailable for \(udid)")
            return nil
        }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> AnyObject?
        typealias Init = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
        guard let allocated = unsafeBitCast(allocImp, to: Alloc.self)(cls, NSSelectorFromString("alloc")) else { return nil }
        var error: NSError?
        guard let c = unsafeBitCast(initImp, to: Init.self)(allocated, NSSelectorFromString("initWithDevice:error:"), device, &error) else {
            if let error { log("SimDeviceLegacyHIDClient: \(error)") }
            return nil
        }
        for create in [symbols.createPointerService, symbols.createMouseService] {
            if let create, let msg = create() {
                Self.send(msg, to: c)
                usleep(20_000)
            }
        }
        client = c
        return c
    }

    static func send(_ message: UnsafeMutableRawPointer, to client: AnyObject) {
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        guard let cls = object_getClass(client), let imp = class_getMethodImplementation(cls, sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, ObjCBool, AnyObject?, AnyObject?) -> Void
        unsafeBitCast(imp, to: Fn.self)(client, sel, message, ObjCBool(true), nil, nil)
    }
}

// MARK: - SimulatorKit and IOKit symbols

private final class Symbols: @unchecked Sendable {
    static let shared = Symbols()

    typealias Mouse = @convention(c) (UnsafePointer<CGPoint>, UnsafePointer<CGPoint>?, UInt32, UInt32, UInt32, Double, Double, Double, Double) -> UnsafeMutableRawPointer?
    typealias Button = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias HIDArbitrary = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias Scroll = @convention(c) (UInt32, Double, Double, Double) -> UnsafeMutableRawPointer?
    typealias Service = @convention(c) () -> UnsafeMutableRawPointer?
    typealias CreateDigitizer = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<CFTypeRef>?
    typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<CFTypeRef>?
    typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
    typealias TrackpadWrap = @convention(c) (UnsafeRawPointer) -> UnsafeMutableRawPointer?

    let mouse: Mouse?
    let button: Button?
    let hidArbitrary: HIDArbitrary?
    let scroll: Scroll?
    let createPointerService: Service?
    let createMouseService: Service?
    let removePointerService: Service?
    let createDigitizer: CreateDigitizer?
    let createFinger: CreateFinger?
    let append: Append?
    let trackpadWrap: TrackpadWrap?

    private init() {
        Frameworks.load()
        let kit = Frameworks.simulatorKitPath.flatMap { dlopen($0, RTLD_NOW) }
        func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        mouse = sym(kit, "IndigoHIDMessageForMouseNSEvent", Mouse.self)
        button = sym(kit, "IndigoHIDMessageForButton", Button.self)
        hidArbitrary = sym(kit, "IndigoHIDMessageForHIDArbitrary", HIDArbitrary.self)
        scroll = sym(kit, "IndigoHIDMessageForScrollEvent", Scroll.self)
        createPointerService = sym(kit, "IndigoHIDMessageToCreatePointerService", Service.self)
        createMouseService = sym(kit, "IndigoHIDMessageToCreateMouseService", Service.self)
        removePointerService = sym(kit, "IndigoHIDMessageToRemovePointerService", Service.self)
        trackpadWrap = sym(kit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef", TrackpadWrap.self)
        let dyld = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        createDigitizer = sym(dyld, "IOHIDEventCreateDigitizerEvent", CreateDigitizer.self)
        createFinger = sym(dyld, "IOHIDEventCreateDigitizerFingerEvent", CreateFinger.self)
        append = sym(dyld, "IOHIDEventAppendEvent", Append.self)
    }
}

// MARK: - single-finger touches as IOHID digitizer events

/// One finger goes through a real IOHID digitizer event wrapped as an Indigo
/// trackpad message, then patched to target the touchscreen. This is what
/// makes taps, drags and edge swipes behave like a finger rather than a mouse.
private enum Digitizer {
    static func edgeBit(_ edge: ScreenEdge?) -> UInt8 {
        switch edge {
        case .bottom: 0x01
        case .left: 0x02
        case .right: 0x04
        case .top: 0x08
        case nil: 0x00
        }
    }

    static func send(_ point: CGPoint, id: UInt32, phase: TouchPhase, edge: ScreenEdge?, target: UInt32, to client: AnyObject) -> Bool {
        let s = Symbols.shared
        guard let createDigitizer = s.createDigitizer, let createFinger = s.createFinger,
              let append = s.append, let wrap = s.trackpadWrap
        else { return false }
        let mask: UInt32 = phase == .up ? 0x06 : 0x07 // range | touch | position; lift drops range
        let touching = phase != .up
        let now = mach_absolute_time()
        let finger: UInt32 = 2 // kIOHIDDigitizerTransducerTypeFinger
        guard let parent = createDigitizer(nil, now, finger, 0, id, mask, 0, point.x, point.y, 0, 0, 0, touching, touching, 0)?.takeRetainedValue() else { return false }
        if let child = createFinger(nil, now, 0, id, mask, point.x, point.y, 0, 0, 0, touching, touching, 0)?.takeRetainedValue() {
            append(parent, child, 0)
        }
        let message: UnsafeMutableRawPointer? = withExtendedLifetime(parent) {
            wrap(Unmanaged.passUnretained(parent as AnyObject).toOpaque())
        }
        guard let message else { return false }
        patch(message, edge: edge, target: target)
        HIDInput.send(message, to: client)
        return true
    }

    /// `holdMs` keeps the finger still at `end` before lifting, as a pause in
    /// a gesture does (the app switcher's).
    static func swipe(from start: CGPoint, to end: CGPoint, steps: Int, stepMs: UInt32, holdMs: UInt32 = 0, edge: ScreenEdge?, id: UInt32, target: UInt32, to client: AnyObject) -> Bool {
        guard send(start, id: id, phase: .down, edge: edge, target: target, to: client) else { return false }
        var moved = 0
        for i in 1...steps {
            usleep(stepMs * 1000)
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if send(p, id: id, phase: .move, edge: edge, target: target, to: client) { moved += 1 }
        }
        // A pause is the finger still on the glass: iOS sees it as moves that
        // stay put, not as silence, so keep reporting the same point.
        var held: UInt32 = 0
        while held < holdMs {
            usleep(stepMs * 1000)
            held += stepMs
            _ = send(end, id: id, phase: .move, edge: edge, target: target, to: client)
        }
        usleep(stepMs * 1000)
        return send(end, id: id, phase: .up, edge: edge, target: target, to: client) && moved >= steps / 2
    }

    /// Byte offsets inside the Indigo message, as found by baguette.
    static func patch(_ message: UnsafeMutableRawPointer, edge: ScreenEdge?, target: UInt32) {
        let size = malloc_size(message)
        message.storeBytes(of: target, toByteOffset: 0x6c, as: UInt32.self)
        if size >= 0x110 { message.storeBytes(of: target, toByteOffset: 0x10c, as: UInt32.self) }
        let bit = edgeBit(edge)
        let present: UInt8 = bit == 0 ? 0 : 0x04
        message.storeBytes(of: present, toByteOffset: 0x3a, as: UInt8.self)
        message.storeBytes(of: bit, toByteOffset: 0x3b, as: UInt8.self)
        if size >= 0xdc {
            message.storeBytes(of: present, toByteOffset: 0xda, as: UInt8.self)
            message.storeBytes(of: bit, toByteOffset: 0xdb, as: UInt8.self)
        }
    }
}
