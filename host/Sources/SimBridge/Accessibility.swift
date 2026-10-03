// Adapted from baguette (https://github.com/tddworks/baguette),
// Copyright 2026 tddworks, licensed under the Apache License 2.0 (see
// LICENSE-baguette). Changes: merged AXPTranslatorAccessibility, AXNode,
// AXElementReader, AXFrameTransform, AXHitTestGrid and AXNodeMerge into
// one file; nodes are emitted as JSON-ready dictionaries.

import CoreGraphics
import Foundation
import ObjectiveC

/// Reads the frontmost app's accessibility tree on a simulator through the
/// private AccessibilityPlatformTranslation framework, the same path the
/// Accessibility Inspector uses. Frames come back in screen points.
public enum Accessibility {
    /// The whole tree, plus elements found by probing uncovered screen areas
    /// (SwiftUI often leaves leaves out of `accessibilityChildren`).
    public static func describe(udid: String) -> AXNode? {
        withContext(udid: udid) { ctx in
            stampSubtree(ctx.root, token: ctx.token, depth: 0)
            let base = AXNode.walk(ctx.root, transform: ctx.transform, deadline: ctx.deadline)
            return sweep(base, ctx: ctx)
        }
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
    private static let timeout: TimeInterval = 5
    private static let gridStep: Double = 32
    private static let gridCap = 600
    private static let sweepBudget: TimeInterval = 2.5

    private struct Context {
        let translator: NSObject
        let token: String
        let root: NSObject
        let transform: FrameTransform
        let deadline: Date
    }

    private static func withContext(udid: String, _ body: (Context) -> AXNode?) -> AXNode? {
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

    private static func sweep(_ base: AXNode, ctx: Context) -> AXNode {
        let size = ctx.transform.pointSize
        let deadline = min(ctx.deadline, Date().addingTimeInterval(sweepBudget))
        let covered = base.contentLeafFrames()
        var found: [AXNode] = []
        var y = gridStep / 2
        var probes = 0
        outer: while y < size.height {
            var x = gridStep / 2
            while x < size.width {
                let p = CGPoint(x: x, y: y)
                if !covered.contains(where: { $0.contains(p) }) {
                    if Date() >= deadline || probes >= gridCap { break outer }
                    probes += 1
                    if let node = discover(at: p, ctx: ctx, depthCap: 0) { found.append(node) }
                }
                x += gridStep
            }
            y += gridStep
        }
        return base.merging(found)
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

    func hitTest(_ p: CGPoint) -> AXNode? {
        for child in children { if let hit = child.hitTest(p) { return hit } }
        return frame.contains(p) ? self : nil
    }

    private static let contentLeafRoles: Set<String> = [
        "AXStaticText", "AXButton", "AXImage", "AXTextField", "AXTextArea", "AXSecureTextField", "AXLink",
        "AXCheckBox", "AXRadioButton", "AXSlider", "AXSwitch", "AXStepper", "AXValueIndicator",
        "AXPopUpButton", "AXMenuItem", "AXMenuButton", "AXDisclosureTriangle", "AXProgressIndicator",
    ]

    func contentLeafFrames() -> [CGRect] {
        if children.isEmpty && Self.contentLeafRoles.contains(role) { return [frame] }
        return children.flatMap { $0.contentLeafFrames() }
    }

    private var key: String {
        "\(role)|\(identifier ?? "")|\(label ?? "")|\(frame.minX.rounded()),\(frame.minY.rounded()),\(frame.width.rounded()),\(frame.height.rounded())"
    }

    private func keys(into set: inout Set<String>) {
        set.insert(key)
        for child in children { child.keys(into: &set) }
    }

    /// Adds probed nodes the walk missed, each under the deepest existing
    /// node that contains its centre.
    func merging(_ discovered: [AXNode]) -> AXNode {
        var seen = Set<String>()
        keys(into: &seen)
        var fresh: [AXNode] = []
        for node in discovered where !seen.contains(node.key) {
            seen.insert(node.key)
            fresh.append(node)
        }
        return fresh.isEmpty ? self : graft(fresh)
    }

    private func graft(_ fresh: [AXNode]) -> AXNode {
        var unclaimed = fresh
        let center = { (n: AXNode) in CGPoint(x: n.frame.midX, y: n.frame.midY) }
        let newChildren = children.map { child -> AXNode in
            let claimed = unclaimed.filter { child.frame.contains(center($0)) }
            guard !claimed.isEmpty else { return child }
            unclaimed.removeAll { child.frame.contains(center($0)) }
            return child.graft(claimed)
        }
        return AXNode(role: role, subrole: subrole, label: label, value: value, identifier: identifier, title: title, help: help, frame: frame, enabled: enabled, focused: focused, hidden: hidden, children: newChildren + unclaimed)
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
