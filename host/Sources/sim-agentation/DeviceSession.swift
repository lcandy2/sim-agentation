import CoreGraphics
import Foundation
import IOSurface
import SimBridge

/// How the screen goes over the wire, as baguette's stream socket names it.
///
/// - `mjpeg`: one JPEG per binary message.
/// - `avcc` (H.264), `hevc` and `hevc422` (HEVC 4:2:2 10-bit):
///   `[tag][payload]` binary messages, where the
///   tag is 0x01 for the avcC/hvcC description, 0x02 for a keyframe, 0x03
///   for a delta frame and 0x04 for a JPEG seed that paints before the
///   first keyframe decodes.
///
/// In every format 0x05 is a full-resolution still (see `sendStill`) and
/// 0x06 padding the page drops (see `probe`).
enum StreamFormat: String, Sendable {
    case mjpeg, avcc, hevc, hevc422
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
    private enum Tag: UInt8 { case description = 0x01, keyframe = 0x02, delta = 0x03, seed = 0x04, still = 0x05, padding = 0x06 }

    private let udid: String
    private let socket: WebSocket
    private let capture: ScreenCapture
    private let format: StreamFormat
    private let jpeg = JPEGEncoder(quality: 0.8)
    private let scaler = VideoFrameScaler()
    private let stillScaler = VideoFrameScaler() // its own pool: stills are full size, the stream may not be
    private let video: VideoEncoder?
    private let encodeQueue = DispatchQueue(label: "sim-agentation.encode", qos: .userInteractive)
    private let inputQueue = DispatchQueue(label: "sim-agentation.input", qos: .userInteractive)
    /// A foldable's hinge, turns and keys, played in the guest one at a
    /// time (a fold takes 0.8 s) without holding up touches.
    private let guestQueue = DispatchQueue(label: "sim-agentation.guest", qos: .userInitiated)
    private let lock = NSLock()
    private var options: StreamOptions
    private var encoding = false
    private var latest: IOSurface? // newest frame not yet sent
    private var lastSurface: IOSurface?
    private var retryScheduled = false
    private var lastSent: UInt64 = 0
    private var pendingSeed = true
    private var pendingKeyframe = true
    private var videoFailures = 0 // frames in a row the encoder didn't produce
    private var reportedFailure = false
    private var idlePump: DispatchSourceTimer?
    private lazy var input = HIDInput(udid: udid)
    /// iPhone Duo and its like: the stream follows the panel the hinge lights.
    private let foldable: Foldable?

    // How the stream keeps up, reported once a second for the page's Auto
    // (see `report`).
    private struct Period {
        var start = DispatchTime.now().uptimeNanoseconds
        var frames = 0
        var bytes = 0
        var encodeNanos: UInt64 = 0
        var queued = 0
        var queuedSamples = 0
        var heldNanos: UInt64 = 0
    }
    private var period = Period()
    private var statsTimer: DispatchSourceTimer?
    private var encodeStart: UInt64 = 0
    private var backedUpSince: UInt64?
    private var lastFrameBytes = 0
    private var lastRate = 0 // bits/s of stream in the last report
    private var probing: Probe?
    private struct Probe {
        let bps: Int
        let until: UInt64
        let slack: Int // bytes the viewer may be behind and padding still go out
        var planned = 0
        var sent = 0
        var timer: DispatchSourceTimer
    }

    init(udid: String, socket: WebSocket, options: StreamOptions, foldable: Foldable? = nil) {
        self.udid = udid
        self.socket = socket
        self.foldable = foldable
        self.capture = ScreenCapture(udid: udid)
        self.options = options
        self.format = options.format
        switch options.format {
        case .mjpeg: video = nil
        case .avcc: video = VideoEncoder(codec: .h264, fps: options.fps, bitrate: options.bitrate)
        case .hevc: video = VideoEncoder(codec: .hevc, fps: options.fps, bitrate: options.bitrate)
        case .hevc422: video = VideoEncoder(codec: .hevc422, fps: options.fps, bitrate: options.bitrate)
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
                self.lock.lock()
                self.idlePump?.cancel(); self.idlePump = nil
                self.statsTimer?.cancel(); self.statsTimer = nil
                self.foldable?.stop()
                self.probing?.timer.cancel(); self.probing = nil
                self.lock.unlock()
                Self.liveLock.lock(); Self.live[ObjectIdentifier(self)] = nil; Self.liveLock.unlock()
            }
        )
        video?.onEncoded = { [weak self] encoded in self?.encoded(encoded) }
        let stats = DispatchSource.makeTimerSource(queue: encodeQueue)
        stats.schedule(deadline: .now() + 1, repeating: 1)
        stats.setEventHandler { [weak self] in self?.report() }
        stats.resume()
        lock.lock(); statsTimer = stats; lock.unlock()
        foldable?.start(
            onLit: { [weak self] lit in self?.bind(lit) },
            onAngle: { [weak self] degrees in self?.socket.send(json: ["type": "hinge", "degrees": degrees]) }
        )
        do {
            try capture.start { [weak self] surface in self?.frame(surface) }
        } catch {
            socket.send(json: ["type": "error", "error": "\(error)"])
            socket.close()
        }
    }

    // MARK: - foldables

    /// The hinge lit another panel: frames come from it, touches go to its
    /// own digitizer, and the page draws its chrome, turned as the guest
    /// turned it. The new size starts with a keyframe.
    /// Plays `body` in the guest (see `GuestControl`) and answers `type`,
    /// with the error when it failed, which the page shows.
    private func guest(_ type: String, _ fields: [String: Any], _ body: @escaping @Sendable () throws -> Void) {
        nonisolated(unsafe) let fields = fields // strings and numbers, only read below
        guestQueue.async { [weak self] in
            var reply = fields
            reply["type"] = type
            do {
                try body()
                reply["ok"] = true
            } catch {
                reply["ok"] = false
                reply["error"] = "\(error)"
            }
            self?.socket.send(json: reply)
        }
    }

    private func bind(_ lit: Foldable.Lit) {
        capture.preferPlane(width: lit.panel.width, height: lit.panel.height, other: (lit.other.width, lit.other.height)) { [weak self] in
            self?.foldable?.swap()
        }
        inputQueue.async { [weak self] in self?.input.targetPanel(screenId: lit.panel.screenId) }
        lock.lock(); pendingKeyframe = true; pendingSeed = true; lock.unlock()
        socket.send(json: ["type": "panel", "panel": lit.panel.name, "orientation": lit.orientation])
        capture.requestFrame()
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

    /// How far the viewer may fall behind before frames wait for it: 150 ms
    /// of the stream, and never less than two frames of the last size, so a
    /// keyframe alone doesn't hold the next one. Lock held.
    private var backlogLimit: Int {
        max(64_000, options.bitrate / 8 * 15 / 100, lastFrameBytes * 2)
    }

    /// Sends the newest frame once the encoder is free, the viewer has caught
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
        // A connection slower than the stream fills up with frames the viewer
        // sees ever later; waiting here keeps what it sees current.
        let queued = socket.queuedBytes
        let backedUp = socket.isBackedUp || queued > backlogLimit
        period.queued += queued
        period.queuedSamples += 1
        if backedUp {
            if backedUpSince == nil { backedUpSince = now }
        } else if let since = backedUpSince {
            period.heldNanos += now - since
            backedUpSince = nil
        }
        if now < due || backedUp {
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
        encodeStart = now
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
                let bytes = self.jpeg.encode(pixels)
                if let bytes { self.socket.send(binary: bytes) }
                return self.sent(nil, bytes: bytes?.count ?? 0)
            }
            if seed, let bytes = self.jpeg.encode(pixels) { self.socket.send(binary: Self.tagged(.seed, bytes)) }
            if !video.encode(pixels, forceKeyframe: keyframe) { self.encoded(nil) }
        }
    }

    /// Video output, or nil for a frame the encoder couldn't produce. After a
    /// run of failures (say, no HEVC encoder on this Mac) the page hears
    /// `stream_error` once, so Auto can move to the next format.
    private func encoded(_ output: VideoEncoder.Encoded?) {
        lock.lock()
        videoFailures = output == nil ? videoFailures + 1 : 0
        let report = videoFailures >= 5 && !reportedFailure
        if report { reportedFailure = true }
        lock.unlock()
        if report {
            socket.send(json: ["type": "stream_error", "format": format.rawValue, "error": "the encoder isn't producing frames"])
        }
        sent(output)
    }

    /// The frame in flight is done: sends video output (a JPEG went out
    /// already, `bytes` long), then the next frame.
    private func sent(_ encoded: VideoEncoder.Encoded?, bytes: Int = 0) {
        var bytes = bytes
        if let encoded {
            if let description = encoded.description { socket.send(binary: Self.tagged(.description, description)) }
            socket.send(binary: Self.tagged(encoded.isKeyframe ? .keyframe : .delta, encoded.data))
            bytes = (encoded.description?.count ?? 0) + encoded.data.count
        }
        lock.lock()
        encoding = false
        if bytes > 0 {
            period.frames += 1
            period.bytes += bytes
            period.encodeNanos += DispatchTime.now().uptimeNanoseconds - encodeStart
            lastFrameBytes = bytes
        }
        lock.unlock()
        pump()
    }

    /// Once a second, how the stream kept up, for the page's Auto: frames
    /// and bytes sent, the bytes the viewer was behind on average, the share
    /// of the second frames waited for it, how long a frame took to scale
    /// and encode, and when it was sent (`t`, ms on this Mac's clock): it
    /// arrives behind the frames, so the page can tell how late they are
    /// even when the backlog is past this socket, in a tunnel or a proxy.
    private func report() {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        if let since = backedUpSince {
            period.heldNanos += now - since
            backedUpSince = now
        }
        let p = period
        period = Period()
        let elapsed = Double(max(1, now - p.start))
        lastRate = Int(Double(p.bytes * 8) / (elapsed / 1e9))
        lock.unlock()
        socket.send(json: [
            "type": "stats",
            "frames": p.frames,
            "bytes": p.bytes,
            "queued": p.queuedSamples > 0 ? p.queued / p.queuedSamples : 0,
            "held": min(1, Double(p.heldNanos) / elapsed),
            "encodeMs": p.frames > 0 ? Double(p.encodeNanos) / Double(p.frames) / 1e6 : 0,
            "seconds": elapsed / 1e9,
            "t": Double(DispatchTime.now().uptimeNanoseconds) / 1e6,
        ])
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
        case "still":
            sendStill()
        case "force_idr":
            lock.lock(); pendingKeyframe = true; lock.unlock()
            capture.requestFrame()
        case "set_fps", "set_bitrate", "set_scale":
            reconfigure(type, msg)
        case "probe":
            guard let bps = (msg["bps"] as? NSNumber)?.intValue, bps > 0 else { return }
            let slackMs = min(300, max(40, (msg["slackMs"] as? NSNumber)?.intValue ?? 60))
            probe(bps: min(bps, 100_000_000), ms: min(1000, max(100, (msg["ms"] as? NSNumber)?.intValue ?? 400)), slackMs: slackMs)
        case "orientation":
            guard let name = msg["orientation"] as? String else { return }
            if let foldable {
                // Through the guest, as Device Hub's rotate button turns it:
                // the Purple event that turns a phone does nothing here.
                guest("orientation_result", ["orientation": name]) { try foldable.turn(to: name) }
                return
            }
            guard let orientation = DeviceOrientation(wireName: name) else { return }
            let ok = Orientation.set(orientation, udid: udid)
            socket.send(json: ["type": "orientation_result", "ok": ok, "orientation": name])
        case "pose":
            // Device Hub's pose picker: the hinge to `degrees`.
            guard let foldable, let degrees = (msg["degrees"] as? NSNumber)?.doubleValue, degrees.isFinite else { return }
            guest("pose_result", ["degrees": degrees]) { try foldable.fold(to: degrees) }
        case "hinge":
            // Device Hub's hinge slider: straight there, the latest of a drag.
            guard let foldable, let degrees = (msg["degrees"] as? NSNumber)?.doubleValue, degrees.isFinite else { return }
            foldable.slide(to: degrees, on: guestQueue) { [weak self] error in
                self?.socket.send(json: ["type": "hinge_result", "ok": false, "error": "\(error)"])
            }
        case "describe_ui":
            describe(msg)
        default:
            nonisolated(unsafe) let message = msg // decoded JSON, only read on inputQueue
            inputQueue.async { [weak self] in self?.perform(type, message) }
        }
    }

    /// The screen as it is now at full resolution, whatever the stream's,
    /// as a 0x05-tagged JPEG (in every format: a stream's JPEGs start 0xFF).
    /// Design Mode freezes on it, reads its pixels and saves it.
    private func sendStill() {
        lock.lock(); let surface = lastSurface; lock.unlock()
        guard let surface else { return }
        IOSurfaceIncrementUseCount(surface)
        encodeQueue.async { [weak self] in
            defer { IOSurfaceDecrementUseCount(surface) }
            guard let self, let pixels = self.stillScaler.scale(surface, by: 1),
                  let bytes = JPEGEncoder(quality: 0.92).encode(pixels)
            else { return }
            self.socket.send(binary: Self.tagged(.still, bytes))
        }
    }

    /// Whether the connection carries `bps`, for the page's Auto to come
    /// back up after it backed up: pads the stream to that rate for `ms`
    /// with 0x06 messages the page drops, but only while the viewer is less
    /// than `slackMs` of it behind (a round trip, and a little), so padding
    /// fills spare room and never stacks up in front of frames. A connection
    /// without the room takes less of it: `probe_result` is ok when at
    /// least 85% of the padding went out. Padding beats switching the stream
    /// up to see: a failed try costs next to nothing, not a keyframe and a
    /// stutter, so it can try often.
    private func probe(bps: Int, ms: Int, slackMs: Int) {
        let tick = 0.02
        lock.lock()
        guard probing == nil else { lock.unlock(); return }
        let chunk = max(1, Int(Double(max(0, bps - lastRate)) / 8 * tick))
        let timer = DispatchSource.makeTimerSource(queue: encodeQueue)
        probing = Probe(
            bps: bps,
            until: DispatchTime.now().uptimeNanoseconds + UInt64(ms) * 1_000_000,
            slack: max(16_000, bps / 8 * slackMs / 1000),
            timer: timer
        )
        lock.unlock()
        timer.schedule(deadline: .now(), repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard var probe = self.probing else { self.lock.unlock(); return }
            if DispatchTime.now().uptimeNanoseconds >= probe.until {
                probe.timer.cancel()
                self.probing = nil
                self.lock.unlock()
                let ok = probe.sent >= probe.planned * 85 / 100
                self.socket.send(json: [
                    "type": "probe_result", "ok": ok, "bps": probe.bps, "planned": probe.planned, "sent": probe.sent,
                    "t": Double(DispatchTime.now().uptimeNanoseconds) / 1e6, // as in `report`
                ])
                return
            }
            probe.planned += chunk
            let room = self.socket.queuedBytes < probe.slack
            if room { probe.sent += chunk }
            self.probing = probe
            self.lock.unlock()
            if room {
                var bytes = Data(count: chunk + 1)
                bytes[0] = Tag.padding.rawValue
                self.socket.send(binary: bytes)
            }
        }
        timer.resume()
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
            guard let name = msg["button"] as? String, let button = HardwareButton(rawValue: name) else { return }
            let hold = num("duration") ?? 0
            if let foldable, Foldable.key(for: button) != nil {
                guest("button_result", ["button": name]) { _ = try foldable.press(button, hold: hold) }
            } else {
                input.press(button, hold: hold)
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
