import SwiftUI

/// Debug-only bridge between a running app and sim-agentation.
///
/// Call `.simAgentation()` on your root view and `.simTag()` on the views
/// you want to be selectable by name. In Release builds both are no-ops.
public enum SimAgentation {
    public static let defaultPort: UInt16 = 4850

    /// Starts the local inspector server. Safe to call more than once.
    @MainActor
    public static func start(port: UInt16 = defaultPort) {
        #if DEBUG
        InspectorServer.shared.start(port: port)
        #endif
    }
}

public extension View {
    /// Starts the sim-agentation inspector when this view appears (Debug only).
    func simAgentation(port: UInt16 = SimAgentation.defaultPort) -> some View {
        #if DEBUG
        onAppear { SimAgentation.start(port: port) }
        #else
        self
        #endif
    }

    /// Makes this view selectable in sim-agentation under its type name,
    /// with the file and line it was created on (Debug only).
    func simTag(_ name: String? = nil, fileID: String = #fileID, line: Int = #line) -> some View {
        #if DEBUG
        modifier(SimTagModifier(name: name ?? typeName(Self.self), file: fileID, line: line))
        #else
        self
        #endif
    }
}

/// `ShowRow` for `ShowRow`, `"View"` for wrappers like `ModifiedContent<…>`.
func typeName(_ type: Any.Type) -> String {
    let full = String(describing: type)
    let base = full.split(separator: "<").first.map(String.init) ?? full
    return base == "ModifiedContent" || base.hasPrefix("_") ? "View" : base
}

public extension UIView {
    /// Makes this view selectable in sim-agentation under its class name,
    /// with the file and line where it was tagged (Debug only).
    @MainActor
    @discardableResult
    func simTag(_ name: String? = nil, fileID: String = #fileID, line: Int = #line) -> Self {
        #if DEBUG
        TagRegistry.shared.tag(self, name: name ?? typeName(type(of: self)), file: fileID, line: line)
        #endif
        return self
    }
}
