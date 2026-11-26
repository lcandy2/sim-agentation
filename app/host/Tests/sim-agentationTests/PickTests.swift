import Foundation
@testable import sim_agentation
import Testing

/// Peri Keys on an iPhone 18 Pro (402×874 pt), as the host walks it with the
/// automation tree. The current build's bar holds Settings, Debug, a title
/// pop-up (`titleMenu`) whose button holds texts and images, a Host pop-up
/// and Record. The old build's bar holds six mode tabs, radio buttons each
/// with an image, and below it Host and Interfaces (`interfacesMenu`)
/// pop-ups.
enum Peri {
    static func tree(_ name: String) throws -> JSONObject {
        // app/host/Tests/Fixtures, shared with SimBridgeTests and the web tests.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try #require(try JSON.parse(Data(contentsOf: url)).objectValue)
    }
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> JSON {
    .object(JSONObject(["x": .number(x), "y": .number(y), "width": .number(w), "height": .number(h)]))
}

/// The position of the first node in `tree` that `match` accepts, as the
/// page counts positions.
private func index(_ tree: JSONObject, _ match: (JSONObject) -> Bool) throws -> Double {
    Double(try #require(AX.flatten(tree).firstIndex { match($0.node) }))
}

/// The server's resolution of the page's picks: the page hit-tests and sends
/// each picked node by its position in the tree it sends.
@Suite struct PickTests {
    @Test func anElementPickNamesItsNodeAndPath() throws {
        let tree = try Peri.tree("peri-title-menu")
        // ax.test.js checks the page sends 12 for a click on the title menu's text.
        let picked = AppServer.picks(JSONObject(["kind": .string("element"), "target": .number(12)]), tree: tree)
        #expect(picked["kind"]?.stringValue == "element")
        #expect(picked["target"]?["identifier"]?.stringValue == "titleMenu")
        #expect(picked["within"]?.isNull == true)
        let path = (picked["targetPath"]?.arrayValue ?? []).compactMap(\.stringValue)
        #expect(path.last == "PopUpButton \"Touchpad\"")
        #expect(path.dropLast().last == "Group")
    }

    @Test func anAreaNamesWhatItIsWithin() throws {
        let tree = try Peri.tree("peri-tabs")
        let at = try index(tree) { $0["label"]?.stringValue == "Air Pointer" }
        let picked = AppServer.picks(JSONObject(["kind": .string("area"), "within": .number(at)]), tree: tree)
        #expect(picked["kind"]?.stringValue == "area")
        #expect(picked["target"]?.isNull == true)
        #expect(AX.describe(try #require(picked["within"]?.objectValue)) == "RadioButton \"Air Pointer\"")
        #expect(picked["targetPath"]?.arrayValue?.isEmpty == true)
    }

    /// An API client's or a script's note: an element by its point, or a box
    /// with no references, saves its rect alone.
    @Test func aPickWithoutAReferenceNamesNothing() throws {
        let tree = try Peri.tree("peri-title-menu")
        let point = JSON.object(JSONObject(["x": .number(190), "y": .number(75)]))
        for body in [JSONObject(["kind": .string("element"), "point": point]), JSONObject(["kind": .string("area")])] {
            let picked = AppServer.picks(body, tree: tree)
            #expect(picked["kind"]?.stringValue == "area")
            #expect(picked["target"]?.isNull == true)
            #expect(picked["within"]?.isNull == true)
            #expect(picked["targetPath"]?.arrayValue?.isEmpty == true)
        }
    }

    /// The page names each pick by `target` or `within` (null for nothing
    /// there). A page loaded from an older server, still open after it
    /// restarts, sends a tree with neither, and the server turns it away
    /// rather than save notes that name nothing.
    @Test func aTreeWithoutReferencesIsFromAnOutdatedPage() throws {
        let tree = JSON.object(try Peri.tree("peri-title-menu"))
        let point = JSON.object(JSONObject(["x": .number(190), "y": .number(75)]))
        let area = JSON.object(JSONObject(["kind": .string("area"), "rect": rect(346, 66, 36, 36)]))
        let element = JSON.object(JSONObject(["kind": .string("element"), "rect": rect(291, 66, 35, 36), "point": point]))
        for body in [
            JSONObject(["kind": .string("element"), "point": point, "tree": tree]),
            JSONObject(["kind": .string("area"), "tree": tree]),
            JSONObject(["kind": .string("area"), "tree": tree, "parts": .array([element, area])]),
        ] {
            #expect(AppServer.fromAnOutdatedPage(body))
        }
        let within = JSON.object(JSONObject(["kind": .string("area"), "rect": rect(346, 66, 36, 36), "within": .null]))
        let target = JSON.object(JSONObject(["kind": .string("element"), "rect": rect(291, 66, 35, 36), "target": .number(3)]))
        for body in [
            JSONObject(["kind": .string("element"), "target": .number(12), "tree": tree]),
            JSONObject(["kind": .string("area"), "within": .null, "tree": tree]),
            JSONObject(["kind": .string("area"), "within": .number(12), "tree": tree]),
            JSONObject(["kind": .string("area"), "tree": tree, "parts": .array([target, within])]),
            // With no tree there is nothing to name, from any page.
            JSONObject(["kind": .string("element"), "point": point]),
        ] {
            #expect(!AppServer.fromAnOutdatedPage(body))
        }
    }

    @Test func aBadReferenceNamesNothing() throws {
        let tree = try Peri.tree("peri-title-menu")
        let count = Double(AX.flatten(tree).count)
        for ref: JSON in [.number(-1), .number(1.5), .number(count), .number(.infinity), .string("12"), .null, .bool(true)] {
            let element = AppServer.picks(JSONObject(["kind": .string("element"), "target": ref]), tree: tree)
            #expect(element["kind"]?.stringValue == "area")
            #expect(element["target"]?.isNull == true)
            #expect(AppServer.picks(JSONObject(["kind": .string("area"), "within": ref]), tree: tree)["within"]?.isNull == true)
        }
        // A reference with no tree to find it in.
        #expect(AppServer.picks(JSONObject(["kind": .string("element"), "target": .number(12)]), tree: nil)["target"]?.isNull == true)
    }

    @Test func eachPartNamesItsOwnNode() throws {
        let tree = try Peri.tree("peri-title-menu")
        let host = try index(tree) { $0["label"]?.stringValue == "Host: No Host" }
        let record = try index(tree) { $0["identifier"]?.stringValue == "record" }
        let picked = AppServer.picks(JSONObject([
            "kind": .string("area"),
            // A box of several names no one thing it is within.
            "within": .number(12),
            "parts": .array([
                .object(JSONObject(["kind": .string("element"), "rect": rect(291, 66, 35, 36), "target": .number(host), "color": .string("blue")])),
                .object(JSONObject(["kind": .string("area"), "rect": rect(346, 66, 36, 36), "within": .number(record)])),
                .object(JSONObject(["kind": .string("element"), "rect": rect(20, 66, 43, 36), "target": .number(-1)])),
            ]),
        ]), tree: tree)
        #expect(picked["within"]?.isNull == true)
        let parts = try #require(picked["parts"]?.arrayValue)
        #expect(parts.count == 3)
        #expect(parts[0]["kind"]?.stringValue == "element")
        #expect(parts[0]["target"]?["label"]?.stringValue == "Host: No Host")
        #expect(parts[0]["color"]?.stringValue == "blue")
        #expect(parts[1]["kind"]?.stringValue == "area")
        #expect(parts[1]["within"]?["identifier"]?.stringValue == "record")
        #expect(parts[2]["kind"]?.stringValue == "area")
        #expect(parts[2]["target"]?.isNull == true)
        #expect(parts[2]["within"]?.isNull == true)
    }
}
