// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette in SimBridge). DeviceHubAttachment.swift and
// SimctlInputSurface.swift. Changes: folded into one type over our run().

import Foundation

/// Whether Xcode 27's Device Hub has taken a simulator's legacy input, and
/// taking it back.
///
/// Device Hub runs a guest daemon, `dtuhidd`, that publishes the Darwin
/// notify state `com.apple.coredevice.dtuhidd.active`. When it flips to 1,
/// backboardd's SimulatorHID disconnects the legacy Indigo services our
/// input goes to (screen touches, the main screen's buttons, the keyboard),
/// and iOS 27 never reconnects them: sends still report success, the home
/// button does nothing. Reclaiming clears the state, then restarts
/// backboardd so it comes up with every legacy service live; SpringBoard
/// restarts with it, so open apps close. It holds until Device Hub's daemon
/// restarts.
enum InputSurface {
    static let stateKey = "com.apple.coredevice.dtuhidd.active"
    private static let springBoard = "com.apple.SpringBoard"
    private static let backboardd = "system/com.apple.backboardd"

    static func shadowed(udid: String) async -> Bool {
        guard let out = try? await spawn(udid, ["notifyutil", "-g", stateKey]) else { return false }
        return out.split(whereSeparator: \.isNewline).contains { $0.split(separator: " ").map(String.init) == [stateKey, "1"] }
    }

    /// Clear the state, restart backboardd, and wait for a new SpringBoard.
    static func reclaim(udid: String) async throws {
        let before = await springBoardPid(udid)
        try await spawn(udid, ["notifyutil", "-s", stateKey, "0"])
        try await spawn(udid, ["launchctl", "kickstart", "-k", backboardd])
        try await Task.sleep(for: .milliseconds(500))
        for attempt in 0..<60 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(500)) }
            if let now = await springBoardPid(udid), now != before {
                try await Task.sleep(for: .seconds(2)) // a pid comes before a home screen
                return
            }
        }
        throw ChromeError("SpringBoard didn't come back after restarting backboardd")
    }

    /// After a boot: wait for it to finish, give Device Hub's daemon its
    /// moment to attach (it lands a beat after), and take the input back.
    static func healAfterBoot(udid: String) async {
        _ = try? await blocking { try run(["xcrun", "simctl", "bootstatus", udid, "-b"]) }
        for attempt in 0..<20 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500)) }
            if await shadowed(udid: udid) {
                try? await reclaim(udid: udid)
                return
            }
        }
    }

    private static func springBoardPid(_ udid: String) async -> Int32? {
        guard let listing = try? await spawn(udid, ["launchctl", "list"]) else { return nil }
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t")
            if fields.count == 3, fields[2] == springBoard { return Int32(fields[0]) }
        }
        return nil
    }

    @discardableResult
    private static func spawn(_ udid: String, _ command: [String]) async throws -> String {
        try await blocking { try run(["xcrun", "simctl", "spawn", udid] + command) }
    }
}
