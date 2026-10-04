import Foundation

// HingeControl (host/Guest/HingeControl), a small iOS Simulator program run
// inside the guest, does for iPhone Duo what only Device Hub does from the
// host: it moves the hinge, turns the device and presses its keys, by
// dispatching the HID events Device Hub's own daemon dispatches. Ported
// from baguette's GuestHingeMotor and its installer
// (https://github.com/tddworks/baguette, Apache License 2.0); changes:
// built here on first use, for this Mac's architecture, instead of shipped
// prebuilt, and one class for the tool and the child that serves it.

struct GuestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One `HingeControl serve` per device, started on the first command and
/// kept (a spawn is most of a second; the HID services it registers stay up
/// between commands). Each command waits for the tool's `done <status>`,
/// so it returns once the guest has acted. Commands play one at a time.
final class GuestControl: @unchecked Sendable {
    private let udid: String
    private let lock = NSLock()
    private let commands = NSLock()
    private var helper: Helper?

    /// How long a command may take beyond its own playing time, and how
    /// long the tool may take to start (it refuses to act past that).
    private static let allowance: TimeInterval = 8

    nonisolated(unsafe) private static var devices: [String: GuestControl] = [:]
    private static let devicesLock = NSLock()

    static func forDevice(_ udid: String) -> GuestControl {
        devicesLock.withLock {
            if let made = devices[udid] { return made }
            let made = GuestControl(udid: udid)
            devices[udid] = made
            return made
        }
    }

    private init(udid: String) { self.udid = udid }

    /// Moves the hinge from `from` to `to` degrees over `seconds`, at 60 Hz
    /// with Device Hub's ease-out.
    func sweep(from: Double, to: Double, over seconds: TimeInterval) throws {
        try send("sweep \(Self.number(from)) \(Self.number(to)) \(Self.number(seconds * 1000))", playing: seconds)
    }

    /// Straight to `degrees`, as Device Hub's hinge slider moves it.
    func angle(_ degrees: Double) throws {
        try send("angle \(Self.number(degrees))", playing: 0)
    }

    /// Device Hub's rotate: `portrait`, `pud`, `landscape-left` or
    /// `landscape-right`, the device's own (UIDeviceOrientation's) names.
    func turn(native: String) throws {
        try send("orientation \(native)", playing: 0)
    }

    /// One key, held `seconds`, on a service shaped as Device Hub's buttons.
    func press(page: UInt32, usage: UInt32, hold seconds: TimeInterval) throws {
        try send("button \(page) \(usage) \(Self.number(seconds * 1000))", playing: seconds)
    }

    private func send(_ line: String, playing: TimeInterval) throws {
        commands.lock()
        defer { commands.unlock() }
        let helper = try serving()
        do {
            try helper.input.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            abandon(helper)
            throw GuestError("HingeControl stopped listening: \(error)")
        }
        switch helper.answer(within: playing + Self.allowance + 1) {
        case .done(0): return
        case .exited(3): throw GuestError("HingeControl started too late to act")
        case .done(let status), .exited(let status): throw GuestError("HingeControl failed (\(status)): \(line)")
        case .silent:
            abandon(helper)
            throw GuestError("HingeControl didn't answer: \(line)")
        }
    }

    private func serving() throws -> Helper {
        let tool = try Self.tool()
        return try lock.withLock {
            if let helper { return helper }
            let deadline = Date().timeIntervalSince1970 + Self.allowance
            let started = try Helper(arguments: ["simctl", "spawn", udid, tool, "--deadline", String(format: "%.3f", deadline), "serve"]) { [weak self] ended in
                guard let self else { return }
                self.lock.withLock { if self.helper === ended { self.helper = nil } }
            }
            helper = started
            return started
        }
    }

    /// Stops a child that stopped answering, its guest process first: that
    /// belongs to the simulator's launchd and outlives `simctl spawn`.
    private func abandon(_ helper: Helper) {
        if let pid = helper.pid { kill(pid, SIGKILL) }
        helper.stop()
        lock.withLock { if self.helper === helper { self.helper = nil } }
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - the tool

    private static let toolLock = NSLock()

    /// The tool for this Mac, compiled from host/Guest/HingeControl into the
    /// cache the first time a source is seen (half a second), with the iOS
    /// Simulator SDK of the selected Xcode.
    static func tool() throws -> String {
        try toolLock.withLock {
            guard let web = Config.webDirectory else { throw GuestError("no host/Guest next to web/") }
            let dir = Path.join(web, "..", "host/Guest/HingeControl")
            let names = ["HingeControl.m", "HingeProtocol.h"]
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a, enough to tell sources apart
            for name in names {
                guard let data = FileManager.default.contents(atPath: Path.join(dir, name)) else { throw GuestError("no \(name) in \(dir)") }
                for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            }
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let out = Path.join(Config.cacheDirectory, "guest", "HingeControl-\(String(hash, radix: 16))-\(arch)")
            if FileManager.default.isExecutableFile(atPath: out) { return out }
            try FileManager.default.createDirectory(atPath: Path.join(Config.cacheDirectory, "guest"), withIntermediateDirectories: true)
            let sdk = try run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
            let building = out + ".building"
            // Signed by the linker and never again: the iOS 26+ simulator's
            // dyld rejects a binary re-signed after the build.
            _ = try run([
                "xcrun", "clang", "-arch", arch, "-isysroot", sdk, "-target", "\(arch)-apple-ios17.0-simulator",
                "-framework", "Foundation", "-fobjc-arc", "-Wl,-adhoc_codesign",
                "-o", building, Path.join(dir, "HingeControl.m"),
            ])
            _ = rename(building, out)
            return out
        }
    }

    // MARK: - the serving child

    private final class Helper: @unchecked Sendable {
        enum Answer { case done(Int32), exited(Int32), silent }

        let input: FileHandle
        private let process = Process()
        private let lock = NSLock()
        private let arrived = DispatchSemaphore(value: 0)
        private let lines = LineBuffer()
        private var answers: [Int32] = []
        private var exitStatus: Int32?
        private var guestPid: Int32?

        init(arguments: [String], onExit: @escaping @Sendable (Helper) -> Void) throws {
            let stdin = Pipe(), stdout = Pipe()
            // A write after the child is gone fails instead of killing the host.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            input = stdin.fileHandleForWriting
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = arguments
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                self?.receive(data)
            }
            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.lock.withLock { self.exitStatus = process.terminationStatus }
                self.arrived.signal()
                onExit(self)
            }
            try process.run()
        }

        /// The guest process, from the `pid <n>` line the tool prints first.
        var pid: Int32? { lock.withLock { guestPid } }

        func stop() {
            try? input.close()
            if process.isRunning { process.terminate() }
        }

        private func receive(_ data: Data) {
            var count = 0
            lock.withLock {
                for line in lines.append(data) {
                    let words = line.split(separator: " ")
                    guard words.count == 2, let value = Int32(words[1]) else { continue }
                    if words[0] == "pid" { guestPid = value }
                    if words[0] == "done" { answers.append(value); count += 1 }
                }
            }
            for _ in 0..<count { arrived.signal() }
        }

        /// The next answer, the exit that came first, or `.silent` after `seconds`.
        func answer(within seconds: TimeInterval) -> Answer {
            let deadline = DispatchTime.now() + seconds
            while true {
                let now: Answer? = lock.withLock {
                    if !answers.isEmpty { return .done(answers.removeFirst()) }
                    return exitStatus.map { .exited($0) }
                }
                if let now { return now }
                if arrived.wait(timeout: deadline) == .timedOut {
                    return lock.withLock {
                        if !answers.isEmpty { return .done(answers.removeFirst()) }
                        return exitStatus.map { .exited($0) } ?? .silent
                    }
                }
            }
        }
    }
}
