// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). Changes: reduced to the default device set, a flat
// device record, and simctl for boot and shutdown.

import Foundation

public struct SimulatorDevice: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case creating = "Creating", shutdown = "Shutdown", booting = "Booting"
        case booted = "Booted", shuttingDown = "Shutting Down"
    }

    public let udid: String
    public let name: String
    public let runtime: String          // "iOS 26.5"
    public let state: State
    public let deviceType: String       // device type identifier
}

public enum SimulatorError: Error, CustomStringConvertible {
    case notFound(String)
    case command(String)

    public var description: String {
        switch self {
        case .notFound(let udid): "no simulator with udid \(udid)"
        case .command(let message): message
        }
    }
}

/// The default CoreSimulator device set, read through the ObjC runtime.
public final class Simulators: @unchecked Sendable {
    public static let shared = Simulators()

    private init() {
        Frameworks.load()
    }

    public func all() -> [SimulatorDevice] {
        devices().map(record)
    }

    public func find(_ udid: String) -> SimulatorDevice? {
        object(for: udid).map(record)
    }

    /// The underlying `SimDevice`, used by screen, input and accessibility.
    func object(for udid: String) -> NSObject? {
        devices().first { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid }
    }

    public func boot(_ udid: String) throws {
        try simctl(["boot", udid], allowingFailure: "current state: Booted")
    }

    public func shutdown(_ udid: String) throws {
        try simctl(["shutdown", udid], allowingFailure: "current state: Shutdown")
    }

    /// Puts text on the simulator's pasteboard.
    public func copyToPasteboard(_ udid: String, text: String) throws {
        try simctl(["pbcopy", udid], input: Data(text.utf8))
    }

    // MARK: - private

    private func devices() -> [NSObject] {
        guard let set = deviceSet() else { return [] }
        return (set.value(forKey: "availableDevices") as? [NSObject]) ?? []
    }

    private func deviceSet() -> NSObject? {
        guard let cls = NSClassFromString("SimServiceContext") else { return nil }
        var error: NSError?
        guard let context = callClassObject(cls, "sharedServiceContextForDeveloperDir:error:", Frameworks.developerDir as NSString, &error) else {
            if let error { log("SimServiceContext: \(error)") }
            return nil
        }
        return callObjectWithError(context, "defaultDeviceSetWithError:", &error)
    }

    private func record(_ device: NSObject) -> SimulatorDevice {
        let runtime = (device.value(forKey: "runtime") as? NSObject).flatMap {
            ($0.value(forKey: "name") as? String) ?? ($0.value(forKey: "versionString") as? String)
        }
        let type = (device.value(forKey: "deviceType") as? NSObject)?.value(forKey: "identifier") as? String
        let rawState = (device.value(forKey: "state") as? NSNumber)?.uintValue ?? 1
        let state: SimulatorDevice.State = switch rawState {
        case 0: .creating
        case 2: .booting
        case 3: .booted
        case 4: .shuttingDown
        default: .shutdown
        }
        return SimulatorDevice(
            udid: (device.value(forKey: "UDID") as? NSUUID)?.uuidString ?? "",
            name: (device.value(forKey: "name") as? String) ?? "Unknown",
            runtime: runtime ?? "",
            state: state,
            deviceType: type ?? ""
        )
    }

    private func simctl(_ args: [String], input: Data? = nil, allowingFailure benign: String? = nil) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl"] + args
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = FileHandle.nullDevice
        let stdin = Pipe()
        if input != nil { task.standardInput = stdin }
        try task.run()
        if let input {
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
        }
        task.waitUntilExit()
        let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if task.terminationStatus != 0 && !(benign.map(message.contains) ?? false) {
            throw SimulatorError.command(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
