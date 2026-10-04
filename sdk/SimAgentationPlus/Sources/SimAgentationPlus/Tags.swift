#if DEBUG
import SwiftUI

struct Tag: Encodable {
    let name: String
    let file: String
    let line: Int
    let frame: Rect
}

@MainActor
final class TagRegistry {
    static let shared = TagRegistry()
    private var tags: [UUID: Tag] = [:]

    func update(_ id: UUID, _ tag: Tag) { tags[id] = tag }
    func remove(_ id: UUID) { tags[id] = nil }

    /// Tags currently on screen, outermost first. UIKit frames are read live.
    var visible: [Tag] {
        (Array(tags.values) + uikit)
            .filter { $0.frame.width > 0 && $0.frame.height > 0 }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    private var views: [ObjectIdentifier: UIKitTag] = [:]

    func tag(_ view: UIView, name: String, file: String, line: Int) {
        views[ObjectIdentifier(view)] = UIKitTag(view: view, name: name, file: file, line: line)
    }

    private var uikit: [Tag] {
        views = views.filter { $0.value.view != nil }
        return views.values.compactMap { entry -> Tag? in
            guard let view = entry.view, view.window != nil, !view.isHidden else { return nil }
            return Tag(name: entry.name, file: entry.file, line: entry.line, frame: Rect(view.convert(view.bounds, to: nil)))
        }
    }
    #else
    private var uikit: [Tag] { [] }
    #endif
}

#if os(iOS) || os(tvOS) || os(visionOS)
private struct UIKitTag {
    weak var view: UIView?
    let name: String
    let file: String
    let line: Int
}
#endif

struct SimTagModifier: ViewModifier {
    let name: String
    let file: String
    let line: Int
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                TagRegistry.shared.update(id, Tag(name: name, file: file, line: line, frame: Rect(frame)))
            }
            .onDisappear { TagRegistry.shared.remove(id) }
    }
}
#endif
