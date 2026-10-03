import CoreGraphics
import Foundation
import IOSurface
import SimBridge

/// How the screen goes over the wire, as baguette's stream socket names it.
///
/// - `mjpeg`: one JPEG per binary message.
/// - `avcc` (H.264) and `hevc`: `[tag][payload]` binary messages, where the
///   tag is 0x01 for the avcC/hvcC description, 0x02 for a keyframe, 0x03
///   for a delta frame and 0x04 for a JPEG seed that paints before the
///   first keyframe decodes.
enum StreamFormat: String, Sendable {
    case mjpeg, avcc, hevc
}

/// What the viewer can retune while streaming: `set_fps`, `set_bitrate`
/// and `set_scale` messages, or the same names as query parameters.
struct StreamOptions: Sendable {
    var format: StreamFormat = .mjpeg
    var fps = 60
    var bitrate = 8_000_000
    /// Divisor of the native resolution: 1 is full size, 2 is half.
    var scale = 1
}

/// One viewer of one simulator over a WebSocket: streams the screen as
/// binary messages and takes input and accessibility requests as JSON text
/// messages, on the same protocol as baguette's stream socket.
final class DeviceSession: @unchecked Sendable {
    private enum Tag: UInt8 { case description = 0x01, keyframe = 0x02, delta = 0x03, seed = 0x04 }

    private let udid: String
    private let socket: WebSocket
    private let capture: ScreenCapture
    private let format: StreamFormat
    private let jpeg = JPEGEncoder(quality: 0.8)
    private let scaler = VideoFrameScaler()
    private let video: VideoEncoder?
    private let encodeQueue = DispatchQueue(label: "sim-agentation.encode", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "sim-agentation.input", qos: .userInteractive)
    private let lock = NSLock()
    private var options: StreamOptions
    private var encoding = false
    private var latest: IOSurface? // newest frame not yet sent
    private var lastSurface: IOSurface?
    private var retryScheduled = false
    private var lastSent: UInt64 = 0
    private var pendingSeed = true
    private var pendingKeyframe = true
    private var idlePump: DispatchSourceTimer?
    private lazy var input = HIDInput(udid: udid)

    init(udid: String, socket: WebSocket, options: StreamOptions) {
        self.udid = udid
        self.socket = socket
        self.capture = ScreenCapture(udid: udid)
        self.options = options
        self.format = options.format
        switch options.format {
        case .mjpeg: video = nil
        case .avcc: video = VideoEncoder(codec: .h264, fps: options.fps, bitrate: options.bitrate)
        case .hevc: video = VideoEncoder(codec: .hevc, fps: options.fps, bitrate: options.bitrate)
        }
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
                self.lock.lock(); self.idlePump?.cancel(); self.idlePump = nil; self.lock.unlock()
                Self.liveLock.lock(); Self.live[ObjectIdentifier(self)] = nil; Self.liveLock.unlock()
            }
        )
        video?.onEncoded = { [weak self] encoded in self?.sent(encoded) }
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
        lock.lock()
        latest = surface
        lastSurface = surface
        if video != nil { armIdlePump() }
        lock.unlock()
        pump()
    }

    /// Video only, lock held: re-encodes the last surface every 1/fps until
    /// the next one arrives, as baguette does. Without it an idle simulator
    /// leaves the last delta stuck in the browser's VideoDecoder and the
    /// canvas shows a stale frame. Repeats of a still screen are tiny.
    private func armIdlePump() {
        idlePump?.cancel()
        let interval = 1.0 / Double(max(1, options.fps))
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.latest == nil { self.latest = self.lastSurface }
            self.lock.unlock()
            self.pump()
        }
        timer.resume()
        idlePump = timer
    }

    /// Sends the newest frame once the encoder is free, the socket has caught
    /// up and the frame interval has passed. A frame that arrives too early
    /// waits instead of being dropped: dropping one that came a hair under
    /// 16 ms left a 33 ms gap, and dropping the last frame of an animation
    /// left the screen stale until the idle refresh. Video never skips a
    /// frame it encoded, so its decoder state stays whole.
    private func pump() {
        lock.lock()
        guard !encoding, let surface = latest else { lock.unlock(); return }
        let now = DispatchTime.now().uptimeNanoseconds
        let due = lastSent + 1_000_000_000 / UInt64(max(1, options.fps)) - 600_000 // a little slack for timer jitter
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
        let scale = options.scale
        let seed = pendingSeed
        let keyframe = pendingKeyframe
        pendingSeed = false
        pendingKeyframe = false
        lock.unlock()
        IOSurfaceIncrementUseCount(surface)
        encodeQueue.async { [weak self] in
            defer { IOSurfaceDecrementUseCount(surface) }
            guard let self else { return }
            guard let pixels = self.scaler.scale(surface, by: scale) else { return self.sent(nil) }
            guard let video = self.video else {
                if let bytes = self.jpeg.encode(pixels) { self.socket.send(binary: bytes) }
                return self.sent(nil)
            }
            if seed, let bytes = self.jpeg.encode(pixels) { self.socket.send(binary: Self.tagged(.seed, bytes)) }
            if !video.encode(pixels, forceKeyframe: keyframe) { self.sent(nil) }
        }
    }

    /// The frame in flight is done: sends video output, then the next frame.
    private func sent(_ encoded: VideoEncoder.Encoded?) {
        if let encoded {
            if let description = encoded.description { socket.send(binary: Self.tagged(.description, description)) }
            socket.send(binary: Self.tagged(encoded.isKeyframe ? .keyframe : .delta, encoded.data))
        }
        lock.lock(); encoding = false; lock.unlock()
        pump()
    }

    private static func tagged(_ tag: Tag, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 1)
        out.append(tag.rawValue)
        out.append(payload)
        return out
    }

    // MARK: - messages

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String
        else { return }
        switch type {
        case "snapshot":
            lock.lock(); pendingSeed = true; lock.unlock()
            capture.requestFrame()
        case "force_idr":
            lock.lock(); pendingKeyframe = true; lock.unlock()
            capture.requestFrame()
        case "set_fps", "set_bitrate", "set_scale":
            reconfigure(type, msg)
        case "describe_ui":
            describe(msg)
        default:
            nonisolated(unsafe) let message = msg // decoded JSON, only read on inputQueue
            inputQueue.async { [weak self] in self?.perform(type, message) }
        }
    }

    private func reconfigure(_ type: String, _ msg: [String: Any]) {
        let value = { (key: String) in (msg[key] as? NSNumber).map { Int($0.doubleValue) } }
        lock.lock()
        switch type {
        case "set_fps": if let fps = value("fps"), fps > 0 { options.fps = min(fps, 120); video?.setFrameRate(options.fps) }
        case "set_bitrate": if let bps = value("bps"), bps > 0 { options.bitrate = bps; video?.setBitrate(bps) }
        default: if let scale = value("scale"), scale > 0 { options.scale = min(scale, 4) }
        }
        lock.unlock()
        capture.requestFrame()
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
