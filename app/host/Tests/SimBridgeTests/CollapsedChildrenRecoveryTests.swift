import CoreGraphics
import Foundation
@testable import SimBridge
import Testing

/// Native walks of one app screen on a 402 × 874 pt iPhone simulator, as
/// `AXNode.walk` emits them: the automation tree (client type 2), nested 13
/// deep with every control in the top bar, and the VoiceOver tree (client
/// type 0), flat, with the top bar left as one childless AXGroup.
/// A fixture from app/host/Tests/Fixtures, shared with sim-agentationTests and the web tests.
private func fixture<T>(_ name: String, as: T.Type = [String: Any].self) throws -> T {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? T)
}

private func rect(_ node: [String: Any]) -> CGRect? {
    guard let f = node["frame"] as? [String: Any],
          let x = (f["x"] as? NSNumber)?.doubleValue, let y = (f["y"] as? NSNumber)?.doubleValue,
          let w = (f["width"] as? NSNumber)?.doubleValue, let h = (f["height"] as? NSNumber)?.doubleValue
    else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

private func flatten(_ node: [String: Any]) -> [[String: Any]] {
    [node] + ((node["children"] as? [[String: Any]]) ?? []).flatMap(flatten)
}

private func canonical(_ tree: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])
}

/// Stands in for the translator's point hit-test: the smallest element of
/// `screen` under the point that isn't a container, without its children,
/// as `discover(at:depthCap: 0)` returns it.
private func hitTest(_ screen: [String: Any]) -> (CGPoint) -> [String: Any]? {
    let containers: Set<String> = ["AXApplication", "AXGroup", "AXHeading", "AXTabGroup"]
    let elements = flatten(screen).filter { !containers.contains(($0["role"] as? String) ?? "") }
    return { point in
        let under = elements.filter { rect($0)?.contains(point) == true }
        guard var hit = under.min(by: { rect($0)!.width * rect($0)!.height < rect($1)!.width * rect($1)!.height }) else { return nil }
        hit["children"] = [[String: Any]]()
        return hit
    }
}

@Suite struct CollapsedChildrenRecoveryTests {
    @Test func aNestedTreeHasOnlyItsStatusBarProbed() throws {
        let tree = try fixture("peri-tabs")
        #expect(!CollapsedChildrenRecovery.isFlat(tree))
        var probed: [CGPoint] = []
        let (recovered, count) = CollapsedChildrenRecovery.recover(
            in: tree,
            probe: { point in probed.append(point); return hitTest(tree)(point) },
            deadline: .distantFuture
        )
        #expect(count == probed.count)
        #expect(count > 0 && count <= CollapsedChildrenRecovery.statusBarMaxProbes)
        #expect(probed.allSatisfy { $0.y <= CollapsedChildrenRecovery.statusBarHeight })
        // Nothing in the strip: the tree comes back as it was.
        #expect(try canonical(recovered) == canonical(tree))
    }

    /// SpringBoard draws the status bar over the app, so only a hit-test
    /// finds its elements; between them it finds what the app draws there,
    /// such as Settings' header, which reaches below the strip.
    @Test func aNestedTreeGainsTheStatusBar() throws {
        let tree = try fixture("peri-tabs")
        let statusBar = try fixture("status-bar", as: [[String: Any]].self)
        let header: [String: Any] = [
            "role": "AXGroup", "label": NSNull(), "children": [[String: Any]](),
            "frame": ["x": 0, "y": 0, "width": 402, "height": 102],
        ]
        let (recovered, count) = CollapsedChildrenRecovery.recover(
            in: tree,
            probe: { point in
                statusBar.filter { rect($0)?.contains(point) == true }
                    .min { rect($0)!.width * rect($0)!.height < rect($1)!.width * rect($1)!.height } ?? header
            },
            deadline: .distantFuture
        )
        #expect(count <= CollapsedChildrenRecovery.statusBarMaxProbes)
        let kids = try #require(recovered["children"] as? [[String: Any]])
        let original = try #require(tree["children"] as? [[String: Any]])
        #expect(try canonical(["c": Array(kids.prefix(original.count))]) == canonical(["c": original]))
        let added = kids.dropFirst(original.count)
        #expect(added.allSatisfy { $0["synthesized"] as? Bool == true })
        #expect(Set(added.compactMap { $0["label"] as? String }) == Set(statusBar.compactMap { $0["label"] as? String }))
        #expect(added.count == statusBar.count)
        #expect(added.contains { $0["identifier"] as? String == "breadcrumb" })
    }

    /// SpringBoard's tree has its own clock, signal and battery, and draws
    /// the Dynamic Island as empty groups, which a probe still names.
    @Test func whatTheTreeNamesInTheStripIsNotProbed() throws {
        var tree = try fixture("peri-tabs")
        let statusBar = try fixture("status-bar", as: [[String: Any]].self)
        let island = try #require(statusBar.first { $0["label"] as? String == "Dynamic Island, Empty" })
        let owned = statusBar.filter { $0["label"] as? String != "Dynamic Island, Empty" }
        let empty: [String: Any] = ["role": "AXGroup", "label": NSNull(), "frame": island["frame"]!, "children": [[String: Any]]()]
        tree["children"] = ((tree["children"] as? [[String: Any]]) ?? []) + [[
            "role": "AXGroup", "label": NSNull(), "children": owned + [empty],
            "frame": ["x": 0, "y": 0, "width": 402, "height": 54],
        ]]
        var probed: [CGPoint] = []
        let (recovered, _) = CollapsedChildrenRecovery.recover(
            in: tree,
            probe: { point in
                probed.append(point)
                return statusBar.filter { rect($0)?.contains(point) == true }
                    .min { rect($0)!.width * rect($0)!.height < rect($1)!.width * rect($1)!.height }
            },
            deadline: .distantFuture
        )
        let kids = try #require(recovered["children"] as? [[String: Any]])
        let added = kids.dropFirst((tree["children"] as? [[String: Any]])!.count)
        #expect(added.map { $0["label"] as? String } == ["Dynamic Island, Empty"])
        let ownedFrames = owned.compactMap(rect)
        #expect(!probed.contains { p in ownedFrames.contains { $0.contains(p) } })
    }

    @Test func aFlatTreeHasItsCollapsedBarProbed() throws {
        let tree = try fixture("voiceover-tree")
        #expect(CollapsedChildrenRecovery.isFlat(tree))
        let (recovered, count) = CollapsedChildrenRecovery.recover(
            in: tree,
            probe: hitTest(try fixture("peri-tabs")),
            deadline: .distantFuture
        )
        #expect(count > 0)
        let bar = try #require((recovered["children"] as? [[String: Any]])?.first { $0["identifier"] as? String == "Peri Keys" })
        let found = ((bar["children"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
        #expect(found.contains("Debug"))
        #expect(found.contains("Record"))
    }

    @Test func aRootWithNoChildrenIsProbed() throws {
        var root = try fixture("voiceover-tree")
        root["children"] = [[String: Any]]()
        #expect(CollapsedChildrenRecovery.isFlat(root))
        let (recovered, count) = CollapsedChildrenRecovery.recover(
            in: root,
            probe: hitTest(try fixture("peri-tabs")),
            deadline: .distantFuture
        )
        #expect(count > 0)
        #expect(!((recovered["children"] as? [[String: Any]]) ?? []).isEmpty)
    }
}
