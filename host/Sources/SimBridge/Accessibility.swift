// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). Changes: merged AXPTranslatorAccessibility, AXNode,
// AXElementReader and AXFrameTransform into one file; nodes are emitted as
// JSON-ready dictionaries; the fixed-grid hit-test sweep is replaced by
// sim-use's CollapsedChildrenRecovery; a stale hierarchy is remediated the
// way idb does it (see `remediateStaleHierarchy`).

import CoreGraphics
import Foundation
import ObjectiveC

/// Reads the frontmost app's accessibility tree on a simulator through the
/// private AccessibilityPlatformTranslation framework, the same path the
/// Accessibility Inspector uses. Frames come back in screen points.
public enum Accessibility {
    /// The whole tree as JSON, with collapsed children recovered by probing
    /// (SwiftUI often leaves elements out of `accessibilityChildren`).
    public static func describe(udid: String) -> [String: Any]? {
        if let tree = describeOnce(udid: udid) { return tree }
        guard remediateStaleHierarchy(udid: udid) else { return nil }
        return describeOnce(udid: udid)
    }

    /// Nil when the hierarchy looks stale: the frontmost application came
    /// back with a zero frame and no children.
    private static func describeOnce(udid: String) -> [String: Any]? {
        var stale = false
        let tree: [String: Any]? = withContext(udid: udid) { ctx in
            stampSubtree(ctx.root, token: ctx.token, depth: 0)
            let base = AXNode.walk(ctx.root, transform: ctx.transform, deadline: ctx.deadline)
            if base.frame.isEmpty && base.children.isEmpty {
                stale = true
                return nil
            }
            // The application element can come back 0×0 (AXPTranslator has no
            // host window to size it against); give it the screen.
            let (recovered, probes) = CollapsedChildrenRecovery.recover(
                in: base.withScreenFrame(ctx.transform.pointSize).json,
                probe: { point in discover(at: point, ctx: ctx, depthCap: 0)?.json },
                deadline: min(ctx.deadline, Date().addingTimeInterval(recoveryBudget))
            )
            log("accessibility: recovered with \(probes) probes")
            return recovered
        }
        return stale ? nil : tree
    }

    nonisolated(unsafe) private static var lastRemediation: [String: Date] = [:]

    /// The simulator's accessibility bridge can keep serving an application
    /// whose process has gone (after SpringBoard or the app restarts), which
    /// reads as a zero-framed root with no children. idb's remedy: stop
    /// com.apple.CoreSimulator.bridge inside the simulator; launchd restarts
    /// it with a fresh hierarchy. At most once per 20 s per simulator.
    private static func remediateStaleHierarchy(udid: String) -> Bool {
        if let last = lastRemediation[udid], Date().timeIntervalSince(last) < 20 { return false }
        lastRemediation[udid] = Date()
        log("accessibility: hierarchy looks stale; restarting com.apple.CoreSimulator.bridge")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        task.arguments = ["simctl", "spawn", udid, "launchctl", "stop", "com.apple.CoreSimulator.bridge"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        Thread.sleep(forTimeInterval: 1.0)
        return task.terminationStatus == 0
    }

    /// The topmost element at a point, in screen points.
    public static func describe(udid: String, at point: CGPoint) -> AXNode? {
        withContext(udid: udid) { ctx in
            discover(at: point, ctx: ctx, depthCap: maxDepth) ?? {
                let tree = AXNode.walk(ctx.root, transform: ctx.transform, deadline: ctx.deadline)
                return tree.hitTest(point) ?? tree
            }()
        }
    }

    // MARK: - context

    private static let maxDepth = 60
    private static let timeout: TimeInterval = 8
    /// Wall-clock cap on recovery probes, inside `timeout`.
    private static let recoveryBudget: TimeInterval = 4.5

    private struct Context {
        let translator: NSObject
        let token: String
        let root: NSObject
        let transform: FrameTransform
        let deadline: Date
    }

    private static func withContext<T>(udid: String, _ body: (Context) -> T?) -> T? {
        guard let translator = sharedTranslator, let device = Simulators.shared.object(for: udid) else { return nil }
        let token = UUID().uuidString
        let deadline = Date().addingTimeInterval(timeout)
        dispatcher.register(device: device, token: token, deadline: deadline)
        defer { dispatcher.unregister(token: token) }
        guard let translation = frontmostApplication(translator, token: token) else { return nil }
        translation.setValue(token, forKey: "bridgeDelegateToken")
        guard let root = macElement(translator, translation) else { return nil }
        let transform = FrameTransform(rootFrame: frame(of: root), pointSize: pointSize(of: device))
        return body(Context(translator: translator, token: token, root: root, transform: transform, deadline: deadline))
    }

    private static func discover(at point: CGPoint, ctx: Context, depthCap: Int) -> AXNode? {
        guard let hit = objectAtPoint(ctx.translator, point: ctx.transform.unmap(point), token: ctx.token) else { return nil }
        hit.setValue(ctx.token, forKey: "bridgeDelegateToken")
        guard let element = macElement(ctx.translator, hit) else { return nil }
        stampElement(element, token: ctx.token)
        if depthCap > 0 { stampSubtree(element, token: ctx.token, depth: 0, cap: depthCap) }
        return AXNode.walk(element, transform: ctx.transform, depthCap: depthCap, deadline: ctx.deadline)
    }

    /// Every element's translation needs the token, or its XPC requests have nowhere to go.
    private static func stampSubtree(_ element: NSObject, token: String, depth: Int, cap: Int = maxDepth) {
        stampElement(element, token: token)
        guard depth < cap else { return }
        for child in children(of: element) { stampSubtree(child, token: token, depth: depth + 1, cap: cap) }
    }

    private static func stampElement(_ element: NSObject, token: String) {
        (element.value(forKey: "translation") as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
    }

    private static func pointSize(of device: NSObject) -> CGSize {
        let fallback = CGSize(width: 393, height: 852)
        guard let type = device.value(forKey: "deviceType") as? NSObject else { return fallback }
        let pixels: CGSize
        if let size = type.value(forKey: "mainScreenSize") as? CGSize { pixels = size }
        else if let value = type.value(forKey: "mainScreenSize") as? NSValue { pixels = value.sizeValue }
        else { return fallback }
        let scale = (type.value(forKey: "mainScreenScale") as? NSNumber)?.doubleValue ?? 3
        return scale > 0 ? CGSize(width: pixels.width / scale, height: pixels.height / scale) : fallback
    }

    // MARK: - AXPTranslator

    private static let dispatcher = TokenDispatcher()

    nonisolated(unsafe) private static let sharedTranslator: NSObject? = {
        let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
        guard dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            log("AccessibilityPlatformTranslation load failed: \(dlerrorString())")
            return nil
        }
        Frameworks.load()
        guard let cls = NSClassFromString("AXPTranslator"), let translator = callClassObject(cls, "sharedInstance") else {
            log("AXPTranslator unavailable")
            return nil
        }
        translator.setValue(dispatcher, forKey: "bridgeTokenDelegate")
        return translator
    }()

    private static func frontmostApplication(_ translator: NSObject, token: String) -> NSObject? {
        let sel = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        guard let imp = class_getMethodImplementation(type(of: translator), sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, UInt32, AnyObject) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(translator, sel, 0, token as NSString) as? NSObject
    }

    private static func macElement(_ translator: NSObject, _ translation: NSObject) -> NSObject? {
        let sel = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard let imp = class_getMethodImplementation(type(of: translator), sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(translator, sel, translation) as? NSObject
    }

    private static func objectAtPoint(_ translator: NSObject, point: CGPoint, token: String) -> NSObject? {
        let sel = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        guard translator.responds(to: sel), let imp = class_getMethodImplementation(type(of: translator), sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, CGPoint, UInt32, AnyObject) -> AnyObject?
        return unsafeBitCast(imp, to: Fn.self)(translator, sel, point, 0, token as NSString) as? NSObject
    }

    static func frame(of element: NSObject) -> CGRect {
        let sel = NSSelectorFromString("accessibilityFrame")
        guard element.responds(to: sel), let imp = class_getMethodImplementation(type(of: element), sel) else { return .zero }
        typealias Fn = @convention(c) (AnyObject, Selector) -> CGRect
        return unsafeBitCast(imp, to: Fn.self)(element, sel)
    }

    static func children(of element: NSObject) -> [NSObject] {
        (element.value(forKey: "accessibilityChildren") as? [NSObject]) ?? []
    }
}

/// Maps macOS-space accessibility frames onto the device screen in points.
struct FrameTransform: Sendable {
    let rootFrame: CGRect
    let pointSize: CGSize

    private var valid: Bool { rootFrame.width > 0 && rootFrame.height > 0 && pointSize.width > 0 && pointSize.height > 0 }
    private var scale: Double { pointSize.width / rootFrame.width }
    private var yOffset: Double { (pointSize.height - rootFrame.height * scale) / 2 }

    func map(_ r: CGRect) -> CGRect {
        guard valid else { return r }
        return CGRect(x: (r.minX - rootFrame.minX) * scale, y: (r.minY - rootFrame.minY) * scale + yOffset, width: r.width * scale, height: r.height * scale)
    }

    func unmap(_ p: CGPoint) -> CGPoint {
        guard valid else { return p }
        return CGPoint(x: p.x / scale + rootFrame.minX, y: (p.y - yOffset) / scale + rootFrame.minY)
    }
}

/// Answers AXPTranslator's XPC callbacks by forwarding each request to the
/// simulator registered under the request's token.
private final class TokenDispatcher: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: (device: NSObject, deadline: Date)] = [:]

    func register(device: NSObject, token: String, deadline: Date) {
        lock.lock(); defer { lock.unlock() }
        devices[token] = (device, deadline)
    }

    func unregister(token: String) {
        lock.lock(); defer { lock.unlock() }
        devices[token] = nil
    }

    @objc dynamic func accessibilityTranslationDelegateBridgeCallbackWithToken(_ token: NSString) -> Any {
        lock.lock()
        let entry = devices[token as String]
        lock.unlock()
        let block: @convention(block) (AnyObject) -> AnyObject = { request in
            guard let entry else { return TokenDispatcher.emptyResponse() }
            let remaining = entry.deadline.timeIntervalSinceNow
            guard remaining > 0 else { return TokenDispatcher.emptyResponse() }
            return TokenDispatcher.send(request, to: entry.device, timeout: min(remaining, 10)) ?? TokenDispatcher.emptyResponse()
        }
        return block
    }

    @objc dynamic func accessibilityTranslationConvertPlatformFrameToSystem(_ rect: CGRect, withToken token: NSString) -> CGRect { rect }

    @objc dynamic func accessibilityTranslationRootParentWithToken(_ token: NSString) -> AnyObject? { nil }

    private static func send(_ request: AnyObject, to device: NSObject, timeout: Double) -> AnyObject? {
        let sel = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
        guard let imp = class_getMethodImplementation(type(of: device), sel) else { return nil }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue, Any) -> Void
        final class Box: @unchecked Sendable { var value: AnyObject? }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        let done: @convention(block) (AnyObject?) -> Void = { response in
            box.value = response
            group.leave()
        }
        unsafeBitCast(imp, to: Fn.self)(device, sel, request, DispatchQueue(label: "sim-agentation.ax"), done as Any)
        guard group.wait(timeout: .now() + timeout) == .success else {
            log("accessibility request timed out after \(timeout)s")
            return nil
        }
        return box.value
    }

    static func emptyResponse() -> AnyObject {
        NSClassFromString("AXPTranslatorResponse").flatMap { callClassObject($0, "emptyResponse") } ?? NSNull()
    }
}

// MARK: - tree

public struct AXNode: Sendable {
    public let role: String
    public let subrole: String?
    public let label: String?
    public let value: String?
    public let identifier: String?
    public let title: String?
    public let help: String?
    public let frame: CGRect
    public let enabled: Bool
    public let focused: Bool
    public let hidden: Bool
    public let children: [AXNode]

    static func walk(_ element: NSObject, transform: FrameTransform, depthCap: Int = 60, deadline: Date, depth: Int = 0) -> AXNode {
        func string(_ key: String) -> String? {
            guard let s = element.value(forKey: key) as? String, !s.isEmpty else { return nil }
            return s
        }
        func bool(_ keys: String...) -> Bool? {
            for key in keys { if let n = element.value(forKey: key) as? NSNumber { return n.boolValue } }
            return nil
        }
        let value: String? = switch element.value(forKey: "accessibilityValue") {
        case let s as String: s.isEmpty ? nil : s
        case let n as NSNumber: n.stringValue
        default: nil
        }
        let kids = depth >= depthCap || Date() >= deadline ? [] : Accessibility.children(of: element)
        return AXNode(
            role: string("accessibilityRole") ?? "AXUnknown",
            subrole: string("accessibilitySubrole"),
            label: string("accessibilityLabel"),
            value: value,
            identifier: string("accessibilityIdentifier"),
            title: string("accessibilityTitle"),
            help: string("accessibilityHelp"),
            frame: transform.map(Accessibility.frame(of: element)),
            enabled: bool("accessibilityEnabled", "isAccessibilityEnabled") ?? true,
            focused: bool("isAccessibilityFocused", "accessibilityFocused") ?? false,
            hidden: bool("isAccessibilityHidden", "accessibilityHidden") ?? false,
            children: kids.map { walk($0, transform: transform, depthCap: depthCap, deadline: deadline, depth: depth + 1) }
        )
    }

    func withScreenFrame(_ size: CGSize) -> AXNode {
        guard frame.isEmpty else { return self }
        return AXNode(role: role, subrole: subrole, label: label, value: value, identifier: identifier, title: title, help: help, frame: CGRect(origin: .zero, size: size), enabled: enabled, focused: focused, hidden: hidden, children: children)
    }

    func hitTest(_ p: CGPoint) -> AXNode? {
        for child in children { if let hit = child.hitTest(p) { return hit } }
        return frame.contains(p) ? self : nil
    }

    /// The JSON shape the web UI and agents read.
    public var json: [String: Any] {
        [
            "role": role,
            "subrole": subrole ?? NSNull(),
            "label": label ?? NSNull(),
            "value": value ?? NSNull(),
            "identifier": identifier ?? NSNull(),
            "title": title ?? NSNull(),
            "help": help ?? NSNull(),
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
            "enabled": enabled,
            "focused": focused,
            "hidden": hidden,
            "children": children.map(\.json),
        ]
    }
}
