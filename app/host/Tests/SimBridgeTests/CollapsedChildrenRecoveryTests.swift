import CoreGraphics
import Foundation
@testable import SimBridge
import Testing

/// Native walks of one app screen on a 402 × 874 pt iPhone simulator, as
/// `AXNode.walk` emits them: the automation tree (client type 2), nested 13
/// deep with every control in the top bar, and the VoiceOver tree (client
/// type 0), flat, with the top bar left as one childless AXGroup.
private func fixture(_ name: String) throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
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
    @Test func aNestedTreeIsReturnedUnprobed() throws {
        let tree = try fixture("automation-tree")
        #expect(!CollapsedChildrenRecovery.isFlat(tree))
        var probes = 0
        let (recovered, count) = CollapsedChildrenRecovery.recover(
            in: tree,
            probe: { point in probes += 1; return hitTest(tree)(point) },
            deadline: .distantFuture
        )
        #expect(count == 0)
        #expect(probes == 0)
        #expect(try canonical(recovered) == canonical(tree))
    }

    @Test func aFlatTreeHasItsCollapsedBarProbed() throws {
        let tree = try fixture("voiceover-tree")
        #expect(CollapsedChildrenRecovery.isFlat(tree))
        let (recovered, count) = CollapsedChildrenRecovery.recover(
            in: tree,
            probe: hitTest(try fixture("automation-tree")),
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
            probe: hitTest(try fixture("automation-tree")),
            deadline: .distantFuture
        )
        #expect(count > 0)
        #expect(!((recovered["children"] as? [[String: Any]]) ?? []).isEmpty)
    }
}
