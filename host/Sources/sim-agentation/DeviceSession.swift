import CoreGraphics
import Foundation
import IOSurface
import SimBridge

/// One viewer of one simulator over a WebSocket: streams the screen as JPEG
/// binary messages and takes input and accessibility requests as JSON text
/// messages. The wire format matches baguette's stream socket, so the
/// existing web UI works unchanged.
final class DeviceSession: @unchecked Sendable {
    private let udid: String
    private let socket: WebSocket
    private let capture: ScreenCapture
    private let encoder = JPEGEncoder(quality: 0.8)
    private let encodeQueue = DispatchQueue(label: "sim-agentation.encode", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "sim-agentation.input", qos: .userInteractive)
    private let lock = NSLock()
    private var encoding = false
    private var latest: IOSurface? // newest frame not yet sent
    private var retryScheduled = false
    private var lastSent: UInt64 = 0
    private lazy var input = HIDInput(udid: udid)

    /// At most one frame per this interval (about 60 fps).
    private static let minFrameInterval: UInt64 = 16_000_000

    init(udid: String, socket: WebSocket) {
        self.udid = udid
        self.socket = socket
        self.capture = ScreenCapture(udid: udid)
    }

    /// Sessions stay alive until their socket closes.
    nonisolated(unsafe) private static var live: [ObjectIdentifier: DeviceSession] = [:]
    private static let liveLock = NSLock()

    func start() {
        Self.liveLock.lock(); Self.live[ObjectIdentifier(self)] = self; Self.liveLock.unlock()
        socket.start(
            onMessage: { [weak self] message in
                if case .text(let text) = message { self?.handle(text) }
            },
            onClose: { [weak self] in
                guard let self else { return }
                self.capture.stop()
                Self.liveLock.lock(); Self.live[ObjectIdentifier(self)] = nil; Self.liveLock.unlock()
            }
        )
        do {
            try capture.start { [weak self] surface in self?.frame(surface) }
        } catch {
            socket.send(json: ["type": "error", "error": "\(error)"])
            socket.close()
        }
    }

    // MARK: - frames

    /// Called on the capture queue.
    private func frame(_ surface: IOSurface) {
        lock.lock(); latest = surface; lock.unlock()
        pump()
    }

    /// Sends the newest frame once the encoder is free, the socket has caught
    /// up and the frame interval has passed. A frame that arrives too early
    /// waits instead of being dropped: dropping one that came a hair under
    /// 16 ms left a 33 ms gap, and dropping the last frame of an animation
    /// left the screen stale until the idle refresh.
    private func pump() {
        lock.lock()
        guard !encoding, let surface = latest else { lock.unlock(); return }
        let now = DispatchTime.now().uptimeNanoseconds
        let due = lastSent + Self.minFrameInterval
        if now < due || socket.isBackedUp {
            if !retryScheduled {
                retryScheduled = true
                let delay = max(due > now ? due - now : 0, 2_000_000)
                encodeQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
                    guard let self else { return }
                    self.lock.lock(); self.retryScheduled = false; self.lock.unlock()
                    self.pump()
                }
            }
            lock.unlock()
            return
        }
        encoding = true
        latest = nil
        lastSent = now
        lock.unlock()
        IOSurfaceIncrementUseCount(surface)
        encodeQueue.async { [weak self] in
            defer { IOSurfaceDecrementUseCount(surface) }
            guard let self else { return }
            if let jpeg = self.encoder.encode(surface) { self.socket.send(binary: jpeg) }
            self.lock.lock(); self.encoding = false; self.lock.unlock()
            self.pump()
        }
    }

    // MARK: - messages

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String
        else { return }
        switch type {
        case "snapshot":
            capture.requestFrame()
        case "describe_ui":
            describe(msg)
        default:
            nonisolated(unsafe) let message = msg // decoded JSON, only read on inputQueue
            inputQueue.async { [weak self] in self?.perform(type, message) }
        }
    }

    private func describe(_ msg: [String: Any]) {
        let point = (msg["x"] as? Double).flatMap { x in (msg["y"] as? Double).map { CGPoint(x: x, y: $0) } }
        // AXPTranslator only answers on the main thread.
        DispatchQueue.main.async { [udid, socket] in
            let tree: [String: Any]? = if let point {
                Accessibility.describe(udid: udid, at: point)?.json
            } else {
                Accessibility.describe(udid: udid)
            }
            if let tree {
                socket.send(json: ["type": "describe_ui_result", "ok": true, "tree": tree])
            } else {
                socket.send(json: ["type": "describe_ui_result", "ok": false, "error": "no accessibility data"])
            }
        }
    }

    /// Runs on `inputQueue`: gestures block for their duration.
    private func perform(_ type: String, _ msg: [String: Any]) {
        func num(_ key: String) -> Double? { (msg[key] as? NSNumber)?.doubleValue }
        func point(_ x: String, _ y: String) -> CGPoint? {
            guard let px = num(x), let py = num(y) else { return nil }
            return CGPoint(x: px, y: py)
        }
        let size = CGSize(width: num("width") ?? 1, height: num("height") ?? 1)
        let edge = (msg["edge"] as? String).flatMap(ScreenEdge.init(rawValue:))

        switch type {
        case "tap":
            if let p = point("x", "y") { input.tap(at: p, size: size, hold: num("duration") ?? 0.05) }
        case "swipe":
            if let a = point("startX", "startY"), let b = point("endX", "endY") {
                input.swipe(from: a, to: b, size: size, duration: num("duration") ?? 0.25)
            }
        case "touch1-down", "touch1-move", "touch1-up":
            let phase = TouchPhase(rawValue: String(type.dropFirst("touch1-".count)))!
            if let p = point("x", "y") { input.touch(phase, at: p, size: size, edge: edge) }
        case "touch2-down", "touch2-move", "touch2-up":
            let phase = TouchPhase(rawValue: String(type.dropFirst("touch2-".count)))!
            if let a = point("x1", "y1"), let b = point("x2", "y2") { input.touch2(phase, first: a, second: b, size: size) }
        case "scroll":
            input.scroll(dx: num("deltaX") ?? 0, dy: num("deltaY") ?? 0)
        case "button":
            if let name = msg["button"] as? String, let button = HardwareButton(rawValue: name) {
                input.press(button, hold: num("duration") ?? 0)
            }
        case "key":
            let mods = (msg["modifiers"] as? [String] ?? []).compactMap { Keyboard.modifiers[$0] }
            if let code = msg["code"] as? String, let usage = Keyboard.usage(forCode: code) {
                input.key(usage: usage, modifiers: mods, hold: num("duration") ?? 0)
            }
        case "type":
            for character in (msg["text"] as? String ?? "") {
                guard let stroke = Keyboard.keystroke(for: character) else { break }
                input.key(usage: stroke.usage, modifiers: stroke.shift ? [Keyboard.modifiers["shift"]!] : [])
            }
        case "paste":
            paste(msg["text"] as? String ?? "", press: msg["press"] as? Bool ?? true)
        default:
            break
        }
    }

    /// Arbitrary text goes through the pasteboard, then ⌘V.
    private func paste(_ text: String, press: Bool) {
        do {
            try Simulators.shared.copyToPasteboard(udid, text: text)
            usleep(150_000)
            if press { input.key(usage: Keyboard.usage(forCode: "KeyV")!, modifiers: [Keyboard.modifiers["command"]!]) }
            socket.send(json: ["type": "paste_result", "ok": true])
        } catch {
            socket.send(json: ["type": "paste_result", "ok": false, "error": "\(error)"])
        }
    }
}
