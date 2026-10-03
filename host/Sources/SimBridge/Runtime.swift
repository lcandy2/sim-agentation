// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). Changes: merged the framework loading, developer
// directory lookup and ObjC message helpers into one file.

import Foundation
import ObjectiveC

/// Loads CoreSimulator and SimulatorKit at runtime. They are private and
/// SimulatorKit lives inside whichever Xcode is installed, so nothing is
/// linked at build time.
enum Frameworks {
    nonisolated(unsafe) private static var loaded = false
    private static let lock = NSLock()

    static func load() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        let coreSimulator = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        if dlopen(coreSimulator, RTLD_NOW | RTLD_GLOBAL) == nil {
            log("CoreSimulator load failed: \(dlerrorString())")
        }
        guard let kit = simulatorKitPath else {
            log("SimulatorKit not found under \(developerDir). Set DEVELOPER_DIR to an Xcode that has it.")
            return
        }
        if dlopen(kit, RTLD_NOW | RTLD_GLOBAL) == nil {
            log("SimulatorKit load failed: \(dlerrorString())")
        }
    }

    static var simulatorKitPath: String? { simulatorKit(in: developerDir) }

    /// SimulatorKit moved from Developer/Library/PrivateFrameworks to
    /// SharedFrameworks in newer Xcodes; check both.
    static func simulatorKit(in developerDir: String) -> String? {
        let contents = (developerDir as NSString).deletingLastPathComponent
        let candidates = [
            "\(developerDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
            "\(contents)/SharedFrameworks/SimulatorKit.framework/SimulatorKit",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// An Xcode developer directory that has SimulatorKit: DEVELOPER_DIR,
    /// then `xcode-select -p`, then any Xcode*.app in /Applications.
    static let developerDir: String = {
        if let env = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], simulatorKit(in: env) != nil { return env }
        if let selected = xcodeSelect(), simulatorKit(in: selected) != nil { return selected }
        let canonical = "/Applications/Xcode.app/Contents/Developer"
        if simulatorKit(in: canonical) != nil { return canonical }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        for app in apps.sorted() where app.hasPrefix("Xcode") && app.hasSuffix(".app") {
            let dir = "/Applications/\(app)/Contents/Developer"
            if simulatorKit(in: dir) != nil { return dir }
        }
        return xcodeSelect() ?? canonical
    }()

    private static func xcodeSelect() -> String? {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        task.arguments = ["-p"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}

func dlerrorString() -> String {
    guard let err = dlerror() else { return "(null)" }
    return String(cString: err)
}

/// Diagnostics go to stderr: stdout may be an MCP stdio channel.
func log(_ message: String) {
    FileHandle.standardError.write(Data("[sim-agentation] \(message)\n".utf8))
}

// MARK: - ObjC message helpers for selectors with C-typed signatures

func callObject(_ target: AnyObject, _ selector: String) -> NSObject? {
    let sel = NSSelectorFromString(selector)
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(target, sel) as? NSObject
}

func callObjectWithError(_ target: NSObject, _ selector: String, _ error: inout NSError?) -> NSObject? {
    let sel = NSSelectorFromString(selector)
    guard let imp = class_getMethodImplementation(type(of: target), sel) else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(target, sel, &error) as? NSObject
}

func callClassObject(_ cls: AnyClass, _ selector: String, _ arg: AnyObject, _ error: inout NSError?) -> NSObject? {
    let sel = NSSelectorFromString(selector)
    guard let meta = object_getClass(cls), let imp = class_getMethodImplementation(meta, sel) else { return nil }
    typealias Fn = @convention(c) (AnyClass, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(cls, sel, arg, &error) as? NSObject
}

func callClassObject(_ cls: AnyClass, _ selector: String) -> NSObject? {
    let sel = NSSelectorFromString(selector)
    guard let meta = object_getClass(cls), let imp = class_getMethodImplementation(meta, sel) else { return nil }
    typealias Fn = @convention(c) (AnyClass, Selector) -> AnyObject?
    return unsafeBitCast(imp, to: Fn.self)(cls, sel) as? NSObject
}
