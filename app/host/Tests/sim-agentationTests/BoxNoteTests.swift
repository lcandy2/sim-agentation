import Foundation
@testable import sim_agentation
import Testing

/// describe_ui output from Peri Keys on an iPhone 18 Pro (402×874 pt), with
/// the app's automation tree. `peri-tabs` has a bar of Settings, a heading
/// over six mode tabs (each an image in a radio button), Debug and Record;
/// `peri-title-menu` has Settings, Debug, a heading over the titleMenu pop-up
/// (a button over text runs and images), the Host pop-up and Record.
private func tree(_ name: String) throws -> JSONObject {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try #require(JSON.parse(Data(contentsOf: url)).objectValue)
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> JSON {
    .object(JSONObject(["x": .number(x), "y": .number(y), "width": .number(w), "height": .number(h)]))
}

/// A box note as the server builds one from a tree.
private func boxNote(_ tree: JSONObject, _ box: JSON) -> String {
    let x = JS.number(box["x"]) + JS.number(box["width"]) / 2, y = JS.number(box["y"]) + JS.number(box["height"]) / 2
    return Format.toMarkdown(JSONObject([
        "id": .string("box"),
        "status": .string("pending"),
        "comment": .string("Note"),
        "kind": .string("area"),
        "rect": box,
        "within": AX.hitTest(tree, x: x, y: y).map { AX.summarize($0.node) } ?? .null,
        // The server keeps the first 20.
        "inside": .array(AX.nodesInRect(tree, box).prefix(20).map { AX.summarize($0.node) }),
    ]))
}

/// The lines under "Inside the box".
private func inside(_ note: String) -> [String] {
    let lines = note.components(separatedBy: "\n")
    guard let start = lines.firstIndex(of: "- **Inside the box**:") else { return [] }
    return lines[(start + 1)...].prefix { $0.hasPrefix("  - ") }.map { String($0.dropFirst(4)) }
}

private func line(_ note: String, _ prefix: String) -> String? {
    note.components(separatedBy: "\n").first { $0.hasPrefix(prefix) }
}

private let bar = rect(0, 60, 402, 57)

@Suite struct BoxNoteTests {
    @Test func aBarOfTabsListsEveryControlWithItsIcon() throws {
        let note = boxNote(try tree("peri-tabs"), bar)
        // Each tab's image is on its tab's line, named when it adds a name.
        #expect(inside(note) == [
            "Button \"Settings\" at (20, 66) 36×36pt",
            "Button \"Record\" id=record at (342, 66) 40×36pt",
            "Button \"Debug\" at (282, 66) 44×36pt",
            "RadioButton \"Keyboard\" id=keyboard value=\"0\" at (75, 61) 47×48pt",
            "RadioButton \"Media\" id=playpause value=\"0\" at (122, 61) 47×48pt, showing Image \"Play/Pause\" id=playpause",
            "RadioButton \"Air Pointer\" id=cursorarrow.motionlines value=\"0\" at (169, 61) 47×48pt, showing Image \"Pointer arrow with motion lines\" id=pointer.arrow.motionlines",
            "RadioButton \"Presenter\" id=videoprojector value=\"0\" at (263, 61) 47×48pt, showing Image \"Video projector\" id=videoprojector",
            "RadioButton \"Touchpad\" id=rectangle.and.hand.point.up.left value=\"1\" at (28, 61) 47×48pt, showing Image \"Rectangle with a hand pointing up-left\" id=rectangle.and.hand.point.up.left",
            "RadioButton \"Game Controller\" id=gamecontroller value=\"0\" at (216, 61) 47×48pt, showing Image \"Game controller\" id=gamecontroller",
            "Heading \"Peri Keys\" at (72, 60) 194×47pt",
            "Group id=Peri Keys at (0, 62) 402×54pt",
            "Group at (72, 60) 194×47pt",
            "and 1 more",
        ])
        #expect(line(note, "- **Within**: ") == "- **Within**: RadioButton \"Air Pointer\" id=cursorarrow.motionlines value=\"0\" at (169, 61) 47×48pt")
    }

    @Test func aBarWithATitleMenuListsThePopUpsAndButtons() throws {
        let note = boxNote(try tree("peri-title-menu"), bar)
        // The pop-ups' inner buttons, text runs and images are on their lines.
        #expect(inside(note) == [
            "PopUpButton \"Host: No Host\" value=\"Bluetooth keyboard unsupported\" at (291, 66) 35×36pt, showing Image \"Desktop Computer With An Exclamation Mark Triangle Badge\" id=desktopcomputer.trianglebadge.exclamationmark",
            "Button \"Record\" id=record at (346, 66) 36×36pt",
            "Button \"Settings\" at (20, 66) 43×36pt",
            "Button \"Debug\" at (79, 66) 44×36pt",
            "PopUpButton \"Touchpad\" id=titleMenu value=\"Bluetooth keyboard unsupported\" at (139, 66) 134×36pt, showing StaticText \"Bluetooth keyboard unsupported\", Image \"Warning\" id=exclamationmark.triangle and Image \"Go Down\" id=chevron.down.circle.fill",
            "Group id=Touchpad at (0, 62) 402×54pt",
            "Group at (290, 66) 36×36pt",
            "Group at (290, 66) 36×36pt",
        ])
        #expect(line(note, "- **Within**: ") == "- **Within**: PopUpButton \"Touchpad\" id=titleMenu value=\"Bluetooth keyboard unsupported\" at (139, 66) 134×36pt")
        let terms = try #require(line(note, "- **Search the source for**: "))
        #expect(terms.hasPrefix("- **Search the source for**: `titleMenu`, `Touchpad`"))
    }

    @Test func moreControlsThanFitAreListedFirstAndCounted() throws {
        func n(_ role: String, _ label: String?, _ x: Double, _ w: Double, _ children: [JSON] = []) -> JSON {
            .object(JSONObject([
                "role": .string(role),
                "label": label.map(JSON.string) ?? .null,
                "identifier": .null,
                "frame": rect(x, 100, w, 40),
                "hidden": .bool(false),
                "children": .array(children),
            ]))
        }
        // Fifteen keys in a row, each a button over a text run and an image.
        let keys = (0..<15).map { i -> JSON in
            let x = Double(i) * 26
            return n("AXButton", "Key \(i)", x, 26, [
                n("AXGroup", nil, x, 26, [n("AXStaticText", "K\(i)", x + 2, 22), n("AXImage", "Glyph \(i)", x + 4, 18)]),
            ])
        }
        let root = try #require(n("AXApplication", "Keys", 0, 402, [n("AXGroup", nil, 0, 402, keys)]).objectValue)
        let lines = inside(boxNote(root, rect(0, 90, 402, 60)))
        // The 20 the server keeps are the 15 keys and the first 5 text runs.
        let keyLines = (0..<12).map { i in
            "Button \"Key \(i)\" at (\(i * 26), 100) 26×40pt" + (i < 5 ? ", showing StaticText \"K\(i)\"" : "")
        }
        #expect(lines == keyLines + ["and 3 more"])
    }

    @Test func aControlNamesThreeOfItsContentsAndCountsTheRest() {
        func n(_ role: String, _ label: String, _ x: Double, _ w: Double) -> JSON {
            .object(JSONObject(["role": .string(role), "label": .string(label), "frame": rect(x, 0, w, 20)]))
        }
        let note = Format.toMarkdown(JSONObject([
            "kind": .string("area"),
            "rect": rect(0, 0, 100, 20),
            "inside": .array([n("AXStaticText", "a", 0, 10), n("AXStaticText", "b", 10, 10), n("AXImage", "c", 20, 10),
                              n("AXImage", "d", 30, 10), n("AXImage", "e", 40, 10), n("AXButton", "Row", 0, 100)]),
        ]))
        #expect(inside(note) == ["Button \"Row\" at (0, 0) 100×20pt, showing StaticText \"a\", StaticText \"b\", Image \"c\" and 2 more"])
    }
}
