import Foundation
import SimBridge

// A device with more than one integrated panel: iPhone Duo (Xcode 27.1,
// iOS 27.1), whose cover is lit while it's folded and whose larger panel is
// lit open. The hinge decides which, SpringBoard lights it, and nothing on
// the host says which one is lit but the hinge itself, so this reads it and
// the stream, the touches and the page follow the lit panel. The hinge,
// the device's turn and its keys are driven through the guest (see
// `GuestControl`), as Device Hub drives them. Ported from baguette's
// HingeAngle, DevicectlHinge, ConnectedScreens and FoldableInput
// (https://github.com/tddworks/baguette, Apache License 2.0); changes:
// one watcher per stream, and the device's turn read once from
// `simctl io enumerate`, then kept as the page last set it.

final class Foldable: @unchecked Sendable {
    /// What the stream binds to: the lit panel, and how the page turns it
    /// upright (the open pose puts SpringBoard in landscape by itself).
    struct Lit: Sendable, Equatable {
        let panel: ChromeService.Panel
        /// The page's name for the turn that reads the panel upright.
        let orientation: String
        /// The panel that's dark.
        let other: ChromeService.Panel
    }

    /// Where SpringBoard hands over, measured on iOS 27.1 with HingeControl's
    /// sweeps: opening lights the unfolded panel from 85° (84° leaves the
    /// cover lit), and closing gives the cover back only below 10° (10°
    /// leaves the unfolded panel lit). In between, the lit one stays lit.
    /// Device Hub's poses land well clear (closed ≈ 3°, open ≈ 130°).
    static let opensAt = 85.0
    static let shutsBelow = 10.0

    let udid: String
    private let cover: ChromeService.Panel
    private let unfolded: ChromeService.Panel
    private let lock = NSLock()
    private var process: Process?
    private var lit: Lit?
    private var degrees: Double?
    /// Whether the hinge last opened the device (passed `opensAt`) or shut
    /// it (went below `shutsBelow`).
    private var open: Bool?
    /// The device's own turn, in quarter turns clockwise (see `turns`):
    /// read with the first panel lit, then the page's.
    private var device: Int?
    private var stopped = false
    private var onLit: (@Sendable (Lit) -> Void)?
    private var onAngle: (@Sendable (Double) -> Void)?
    /// The hinge slider's latest angle not yet played, and whether one is
    /// playing (see `slide`).
    private var sliding: (wanted: Double?, playing: Bool) = (nil, false)

    /// Nil for a device with one panel.
    init?(udid: String, panels: [ChromeService.Panel]) {
        guard let cover = panels.first(where: { $0.name == "primary" }),
              let unfolded = panels.first(where: { $0.name != "primary" })
        else { return nil }
        self.udid = udid
        self.cover = cover
        self.unfolded = unfolded
    }

    /// Calls `onLit` with the lit panel once the hinge first reads (in
    /// about 0.3 s), or the cover after 1.5 s without a reading (how the
    /// device boots), then whenever it changes; `onAngle` with every
    /// reading (60 a second while it moves).
    func start(onLit: @escaping @Sendable (Lit) -> Void, onAngle: @escaping @Sendable (Double) -> Void) {
        lock.withLock {
            self.onLit = onLit
            self.onAngle = onAngle
        }
        watch()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.lock.withLock({ self.lit == nil && !self.stopped }) else { return }
            self.light(self.cover)
        }
    }

    func stop() {
        let process: Process? = lock.withLock {
            stopped = true
            onLit = nil
            onAngle = nil
            return self.process
        }
        if process?.isRunning == true { process?.terminate() }
    }

    /// `devicectl device motion hinge-angle`, kept running: its first sample
    /// is the current angle, then one for every change (the 60 Hz sweep
    /// Device Hub makes). Restarted if it ends while the stream goes on (it
    /// can fall silent after SpringBoard restarts, until the pose moves).
    private func watch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "devicectl", "device", "motion", "hinge-angle", "--device", udid,
            "--timeout", "86400", "--update-interval", "0.01", "--change-threshold", "0.1",
        ]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let buffer = LineBuffer()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            for line in buffer.append(data) {
                if let degrees = Self.angle(in: line) { self?.angle(degrees) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self, !self.lock.withLock({ self.stopped }) else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                self.watch()
            }
        }
        lock.withLock { self.process = process }
        do { try process.run() } catch {
            FileHandle.standardError.write(Data("sim-agentation: hinge: devicectl didn't start: \(error)\n".utf8))
        }
    }

    private func angle(_ degrees: Double) {
        let notify = lock.withLock {
            self.degrees = degrees
            return onAngle
        }
        notify?(degrees)
        // Only on a hand-over: `swap` may have followed the screen instead.
        // A first reading in between is taken for the nearer side.
        let crossed: Bool? = lock.withLock {
            let side = degrees >= Self.opensAt ? true
                : degrees < Self.shutsBelow ? false
                : open ?? (degrees >= (Self.opensAt + Self.shutsBelow) / 2)
            defer { open = side }
            return open != side ? side : nil
        }
        if let crossed { light(crossed ? unfolded : cover) }
    }

    /// The panel the hinge chose stayed dark while the other one showed
    /// something (see `ScreenCapture.preferPlane`): SpringBoard lit that one,
    /// so the stream follows the screen until the hinge crosses again.
    func swap() {
        guard let current = lock.withLock({ lit?.panel }) else { return }
        light(current == cover ? unfolded : cover)
    }

    /// The panel stands as the device does, turned by how it's mounted:
    /// the open pose, held upright, puts the unfolded panel in landscape.
    private func light(_ panel: ChromeService.Panel) {
        guard lock.withLock({ lit?.panel != panel && !stopped }) else { return }
        // Read only while nothing is known: a panel just lit can still say
        // the Portrait it said dark, and a turning one says Ambiguous.
        let read = lock.withLock { device == nil } ? Self.interfaceTurn(of: panel, udid: udid) : nil
        let next: (Lit, (@Sendable (Lit) -> Void)?)? = lock.withLock {
            guard lit?.panel != panel, !stopped else { return nil }
            let device = self.device ?? read.map { ($0 - panel.mount + 4) % 4 } ?? 0
            self.device = device
            let made = Lit(panel: panel, orientation: Self.turns[(device + panel.mount) % 4], other: panel == cover ? unfolded : cover)
            lit = made
            return (made, onLit)
        }
        if let next { next.1?(next.0) }
    }

    // MARK: - driving it

    /// Device Hub's poses: shut 0°, open 130°, flat 180°. Swept from where
    /// the hinge was last heard over Device Hub's 0.8 s; the hinge reading
    /// that follows lights the panel. Blocks until the guest has played it.
    func fold(to target: Double) throws {
        let from = lock.withLock { degrees ?? (lit?.panel == unfolded ? 130 : 0) }
        try GuestControl.forDevice(udid).sweep(from: from, to: min(180, max(0, target)), over: 0.8)
    }

    /// Device Hub's hinge slider: straight to `degrees`, no sweep. A drag
    /// asks faster than the guest plays, so only the latest angle waits,
    /// played on `queue` once the one before it is done.
    func slide(to degrees: Double, on queue: DispatchQueue, failed: @escaping @Sendable (Error) -> Void) {
        let start: Bool = lock.withLock {
            sliding.wanted = min(180, max(0, degrees))
            if sliding.playing { return false }
            sliding.playing = true
            return true
        }
        guard start else { return }
        queue.async { [weak self] in
            guard let self else { return }
            while let next: Double = self.lock.withLock({
                let next = self.sliding.wanted
                self.sliding = (nil, next != nil)
                return next
            }) {
                do { try GuestControl.forDevice(self.udid).angle(next) } catch { failed(error) }
            }
        }
    }

    /// Turns the device so the page sees the lit panel turned `orientation`
    /// (the page's names), with Device Hub's rotate: the Purple event that
    /// turns a phone does nothing here.
    func turn(to orientation: String) throws {
        guard let turn = Self.turns.firstIndex(of: orientation) else { throw GuestError("no orientation \(orientation)") }
        let device = (turn - lock.withLock { lit?.panel.mount ?? 0 } + 4) % 4
        try GuestControl.forDevice(udid).turn(native: Self.native[device])
        lock.withLock { self.device = device }
    }

    /// Presses a key the way Device Hub does; false for a button that
    /// isn't one of its keys (home and the gestures go the usual way).
    func press(_ button: HardwareButton, hold: Double) throws -> Bool {
        guard let key = Self.key(for: button) else { return false }
        try GuestControl.forDevice(udid).press(page: key.page, usage: key.usage, hold: hold > 0 ? hold : 0.25)
        return true
    }

    /// The keys Device Hub sends, measured by baguette on iPhone Duo: the
    /// legacy press reaches backboardd as a touchscreen's and is ignored.
    static func key(for button: HardwareButton) -> (page: UInt32, usage: UInt32)? {
        switch button {
        case .power, .lock: (0x0C, 0x30)
        case .volumeUp: (0x0C, 0xE9)
        case .volumeDown: (0x0C, 0xEA)
        case .action: (0xFF00, 0x66) // the camera control
        default: nil
        }
    }

    /// The page's turns, a quarter clockwise each (UIDeviceOrientation's
    /// names), and the same as the orientation picker's values.
    static let turns = ["portrait", "landscape-right", "portrait-upside-down", "landscape-left"]
    private static let native = ["portrait", "landscape-right", "pud", "landscape-left"]

    /// One line of devicectl's monitor:
    ///
    ///     • +0.000s : Angle:130.0°  Mech:130.0°  Velocity:+0.0°/s  AngleValid:Y  VelocityValid:N  Range:0-180°
    ///
    /// A sample flagged `AngleValid:N` is not a reading.
    static func angle(in line: String) -> Double? {
        guard line.contains("AngleValid:Y"),
              let match = line.firstMatch(of: #/Angle:\s*(-?[0-9]+(?:\.[0-9]+)?)°/#)
        else { return nil }
        return Double(match.1)
    }

    /// How the guest turned the panel's interface, in the page's quarter
    /// turns (see `turns`), which only `simctl io enumerate` tells the
    /// host. The guest's "Landscape Left" holds its status bar along the
    /// left edge of the portrait framebuffer and reads upright turned a
    /// quarter clockwise, which the page calls landscape-right (Apple's
    /// device orientation; baguette's names are the other way round). Nil
    /// for a dark or turning panel ("Ambiguous").
    static func interfaceTurn(of panel: ChromeService.Panel, udid: String) -> Int? {
        guard let text = try? run(["xcrun", "simctl", "io", udid, "enumerate"]) else { return nil }
        var screen: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Device Name:") { screen = line.dropFirst("Device Name:".count).trimmingCharacters(in: .whitespaces) }
            guard screen == panel.name, line.hasPrefix("UI Orientation:") else { continue }
            switch line.dropFirst("UI Orientation:".count).trimmingCharacters(in: .whitespaces) {
            case "Portrait": return 0
            case "Landscape Left": return 1
            case "Portrait Upside Down": return 2
            case "Landscape Right": return 3
            default: return nil
            }
        }
        return nil
    }
}

/// Bytes in, complete lines out.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return lines
        }
    }
}
