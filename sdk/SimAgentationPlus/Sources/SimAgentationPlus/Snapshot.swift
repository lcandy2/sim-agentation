#if DEBUG
import UIKit

struct Rect: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ r: CGRect) {
        x = r.origin.x
        y = r.origin.y
        width = r.size.width
        height = r.size.height
    }
}

struct Node: Encodable {
    let kind: String // "view" or "layer"
    let type: String
    let frame: Rect
    /// True for classes defined in the app rather than UIKit/SwiftUI.
    let custom: Bool
    /// Set on the root view of a view controller defined in the app: its class name.
    let controller: String?
    /// Set on a UIHostingController's root view: the SwiftUI view it hosts.
    let hosts: String?
    let identifier: String?
    let background: String?
    let cornerRadius: Double?
    let children: [Node]
}

struct Snapshot: Encodable {
    let bundleId: String?
    let appName: String?
    let screen: Rect
    let tags: [Tag]
    let windows: [Node]
}

/// Walks every visible window's views, plus the layers SwiftUI draws
/// backgrounds and shapes into, in window coordinates (points).
@MainActor
enum SnapshotBuilder {
    static func build() -> Snapshot {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden }
        let info = Bundle.main.infoDictionary
        return Snapshot(
            bundleId: Bundle.main.bundleIdentifier,
            appName: (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String,
            screen: Rect(windows.first?.screen.bounds ?? .zero),
            tags: TagRegistry.shared.visible,
            windows: windows.compactMap { node($0, in: $0) }
        )
    }

    private static func node(_ view: UIView, in window: UIWindow) -> Node? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        let frame = view.convert(view.bounds, to: window)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let children = view.subviews.compactMap { node($0, in: window) } + layers(under: view.layer, in: window)
        let owner = controller(owning: view)
        return Node(
            kind: "view",
            type: shortName(of: view),
            frame: Rect(frame),
            custom: isAppClass(type(of: view)),
            controller: owner.flatMap { isAppClass(type(of: $0)) ? shortName(of: $0) : nil },
            hosts: owner.flatMap(hostedViewName),
            identifier: view.accessibilityIdentifier,
            background: hex(view.layer.backgroundColor),
            cornerRadius: view.layer.cornerRadius > 0 ? view.layer.cornerRadius : nil,
            children: children
        )
    }

    /// Sublayers that aren't a subview's backing layer (those are walked as views).
    private static func layers(under layer: CALayer, in window: UIWindow) -> [Node] {
        (layer.sublayers ?? []).compactMap { $0.delegate is UIView ? nil : node($0, in: window) }
    }

    private static func node(_ layer: CALayer, in window: UIWindow) -> Node? {
        guard !layer.isHidden, layer.opacity > 0.01 else { return nil }
        let frame = layer.convert(layer.bounds, to: window.layer)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let children = layers(under: layer, in: window)
        let fill = layer.backgroundColor ?? (layer as? CAShapeLayer)?.fillColor
        let paints = (fill?.alpha ?? 0) > 0.01 || layer.borderWidth > 0 || layer.contents != nil
        if !paints && children.isEmpty { return nil }
        return Node(
            kind: "layer",
            type: shortName(of: layer),
            frame: Rect(frame),
            custom: false,
            controller: nil,
            hosts: nil,
            identifier: nil,
            background: hex(fill),
            cornerRadius: layer.cornerRadius > 0 ? layer.cornerRadius : nil,
            children: children
        )
    }

    /// The view controller whose root view this is. SwiftUI puts its own
    /// responders (like UIKitKeyPressResponder) between a hosting view and
    /// its controller, so walk the chain instead of reading `next`.
    private static func controller(owning view: UIView) -> UIViewController? {
        var responder = view.next
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller.viewIfLoaded === view ? controller : nil
            }
            if current is UIView { return nil } // reached the superview: not a root view
            responder = current.next
        }
        return nil
    }

    /// Classes compiled into the app (including its Swift packages) live in
    /// the main bundle; UIKit, SwiftUI and other frameworks don't.
    static func isAppClass(_ cls: AnyClass) -> Bool {
        Bundle(for: cls).bundleURL == Bundle.main.bundleURL
    }

    /// `EntryPassView` for `UIHostingController<ModifiedContent<EntryPassView, SimTagModifier>>`.
    /// Nil for wrappers that don't name a view, like the app's own root `AnyView`.
    static func hostedViewName(of controller: UIViewController) -> String? {
        let prefix = "UIHostingController<"
        let full = String(describing: type(of: controller))
        guard full.hasPrefix(prefix) else { return nil }
        let wrappers: Set = ["ModifiedContent", "AnyView", "Optional", "TupleView", "Group"]
        return full.dropFirst(prefix.count)
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init)
            .first { !wrappers.contains($0) && !$0.hasPrefix("_") && !$0.hasSuffix("Modifier") }
    }

    static func shortName(of object: AnyObject) -> String {
        let name = String(describing: type(of: object))
        return name.split(separator: "<").first.map(String.init) ?? name
    }

    private static func hex(_ color: CGColor?) -> String? {
        guard let color, color.alpha > 0.01,
              let rgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = rgb.components, c.count >= 3 else { return nil }
        let bytes = [c[0], c[1], c[2], rgb.alpha].map { Int(($0 * 255).rounded().clamped(to: 0...255)) }
        return "#" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
#endif
