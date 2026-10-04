import Foundation

// A device with more than one integrated panel: iPhone Duo (Xcode 27.1,
// iOS 27.1), whose cover is lit while it's folded and whose larger panel is
// lit open. The hinge decides which, SpringBoard lights it, and nothing on
// the host says which one is lit but the hinge itself, so this reads it and
// the stream, the touches and the page follow the lit panel. Ported from
// baguette's HingeAngle, DevicectlHinge and ConnectedScreens
// (https://github.com/tddworks/baguette, Apache License 2.0); changes:
// one watcher per stream, and the guest's interface orientation read once
// per change from `simctl io enumerate`.

final class Foldable: @unchecked Sendable {
    /// What the stream binds to: the lit panel, and how the page turns it
    /// upright (the open pose puts SpringBoard in landscape by itself).
    struct Lit: Sendable, Equatable {
        let panel: ChromeService.Panel
        /// The page's name for the turn that reads the panel upright.
        let orientation: String
    }

    /// Where SpringBoard hands over to the unfolded panel, as baguette
    /// measured on iOS 27.1: 60° left the cover lit, 90° lit the unfolded
    /// panel. Device Hub's poses land well clear (closed ≈ 3°, open ≈ 130°).
    static let openBoundary = 90.0

    let udid: String
    private let cover: ChromeService.Panel
    private let unfolded: ChromeService.Panel
    private let lock = NSLock()
    private var process: Process?
    private var lit: Lit?
    private var stopped = false
    private var onLit: (@Sendable (Lit) -> Void)?

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
    /// device boots), then whenever it changes.
    func start(onLit: @escaping @Sendable (Lit) -> Void) {
        lock.withLock { self.onLit = onLit }
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
        light(degrees >= Self.openBoundary ? unfolded : cover)
    }

    private func light(_ panel: ChromeService.Panel) {
        guard lock.withLock({ lit?.panel != panel && !stopped }) else { return }
        let next = Lit(panel: panel, orientation: Self.orientation(of: panel, udid: udid))
        let notify: (@Sendable (Lit) -> Void)? = lock.withLock {
            guard lit?.panel != panel else { return nil }
            lit = next
            return onLit
        }
        notify?(next)
    }

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

    /// The page's turn for the panel's interface orientation, which only
    /// `simctl io enumerate` tells the host. The guest's "Landscape Left"
    /// holds its status bar along the left edge of the portrait framebuffer
    /// and reads upright turned a quarter clockwise, which the page calls
    /// landscape-right (Apple's device orientation; baguette's names are
    /// the other way round). A dark or turning panel says "Ambiguous": then
    /// the cover is portrait and the open panel landscape, as they come.
    static func orientation(of panel: ChromeService.Panel, udid: String) -> String {
        let fallback = panel.name == "primary" ? "portrait" : "landscape-right"
        guard let text = try? run(["xcrun", "simctl", "io", udid, "enumerate"]) else { return fallback }
        var screen: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Device Name:") { screen = line.dropFirst("Device Name:".count).trimmingCharacters(in: .whitespaces) }
            guard screen == panel.name, line.hasPrefix("UI Orientation:") else { continue }
            switch line.dropFirst("UI Orientation:".count).trimmingCharacters(in: .whitespaces) {
            case "Portrait": return "portrait"
            case "Portrait Upside Down": return "portrait-upside-down"
            case "Landscape Left": return "landscape-right"
            case "Landscape Right": return "landscape-left"
            default: return fallback
            }
        }
        return fallback
    }
}

/// Bytes in, complete lines out.
private final class LineBuffer: @unchecked Sendable {
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
