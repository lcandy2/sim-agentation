import Foundation
@testable import sim_agentation
import Testing

/// describe_ui output from Peri Keys on an iPhone 18 Pro (402×874 pt), with
/// the app's automation tree. `peri-tabs` has a bar of Settings, a heading
/// over six mode tabs (each an image in a radio button), Debug and Record;
/// `peri-title-menu` has Settings, Debug, a heading over the titleMenu pop-up
/// (a button over text runs and images), the Host pop-up and Record.
/// `settings` is Settings' top level, its search field floating over the
/// list's last rows.
private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> JSON {
    .object(JSONObject(["x": .number(x), "y": .number(y), "width": .number(w), "height": .number(h)]))
}

/// A box note as the server builds one from a tree. `within` is the
/// position the page sends for the node under the box's centre, which
/// ax.test.js checks the page gives for that box.
private func boxNote(_ tree: JSONObject, _ box: JSON, within: Double? = nil, keep: Int = AX.insideKept) -> String {
    let picked = AppServer.picks(JSONObject(["kind": .string("area"), "within": within.map(JSON.number) ?? .null]), tree: tree)
    let inside = AX.inside(tree, box, keep: keep)
    return Format.toMarkdown(JSONObject([
        "id": .string("box"),
        "status": .string("pending"),
        "comment": .string("Note"),
        "kind": .string("area"),
        "rect": box,
        "within": picked["within"]!,
        "inside": .array(inside.nodes),
        "insideTotal": .number(Double(inside.total)),
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
        let note = boxNote(try Peri.tree("peri-tabs"), bar, within: 18)
        // Each tab's image is on its tab's line, named when it adds a name;
        // the unnamed groups around the controls add nothing.
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
        ])
        #expect(line(note, "- **Within**: ") == "- **Within**: RadioButton \"Air Pointer\" id=cursorarrow.motionlines value=\"0\" at (169, 61) 47×48pt")
    }

    @Test func aBarWithATitleMenuListsThePopUpsAndButtons() throws {
        let note = boxNote(try Peri.tree("peri-title-menu"), bar, within: 12)
        // The pop-ups' inner buttons, text runs and images are on their lines,
        // less the text that repeats the title menu's value; the two unnamed
        // groups around the Host pop-up add nothing.
        #expect(inside(note) == [
            "PopUpButton \"Host: No Host\" value=\"Bluetooth keyboard unsupported\" at (291, 66) 35×36pt, showing Image \"Desktop Computer With An Exclamation Mark Triangle Badge\" id=desktopcomputer.trianglebadge.exclamationmark",
            "Button \"Record\" id=record at (346, 66) 36×36pt",
            "Button \"Settings\" at (20, 66) 43×36pt",
            "Button \"Debug\" at (79, 66) 44×36pt",
            "PopUpButton \"Touchpad\" id=titleMenu value=\"Bluetooth keyboard unsupported\" at (139, 66) 134×36pt, showing Image \"Warning\" id=exclamationmark.triangle and Image \"Go Down\" id=chevron.down.circle.fill",
            "Heading \"Touchpad\" at (139, 66) 134×36pt",
            "Group id=Touchpad at (0, 62) 402×54pt",
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
        // Twenty-five keys in a row, each a button over a text run and an image.
        let keys = (0..<25).map { i -> JSON in
            let x = Double(i) * 16
            return n("AXButton", "Key \(i)", x, 16, [
                n("AXGroup", nil, x, 16, [n("AXStaticText", "K\(i)", x + 2, 12), n("AXImage", "Glyph \(i)", x + 4, 8)]),
            ])
        }
        let root = try #require(n("AXApplication", "Keys", 0, 402, [n("AXGroup", nil, 0, 402, keys)]).objectValue)
        let keyLines = (0..<20).map { i in "Button \"Key \(i)\" at (\(i * 16), 100) 16×40pt, showing StaticText \"K\(i)\" and Image \"Glyph \(i)\"" }
        #expect(inside(boxNote(root, rect(0, 90, 402, 60))) == keyLines + ["and 5 more"])
        // Nodes the server didn't keep count too: of the 101 in the box, it
        // kept the 25 keys and 5 text runs.
        let kept = inside(boxNote(root, rect(0, 90, 402, 60), keep: 30))
        #expect(kept.last == "and 76 more")
        #expect(kept.first == "Button \"Key 0\" at (0, 100) 16×40pt, showing StaticText \"K0\"")
    }

    @Test func aWholeScreenListsEveryControl() throws {
        let lines = inside(boxNote(try Peri.tree("peri-tabs"), rect(0, 0, 402, 874)))
        #expect(lines.count == 21)
        #expect(lines.contains("Button \"Left click\" at (16, 778) 127×46pt, showing StaticText \"Click\" and Image \"Cursor Arrow With A Click Indicator\" id=cursorarrow.click"))
        #expect(lines.contains("Button \"Right Click\" id=contextualmenu.and.cursorarrow at (259, 778) 127×46pt"))
        // The element under the box's centre, which Within names.
        #expect(lines.contains("GenericElement \"Touchpad\" at (16, 189) 316×581pt"))
        #expect(lines.last == "and 5 more")
    }

    /// Settings' floating search field sits over the Screen Time row; it and
    /// its icon are not the row's.
    @Test func aFieldDrawnOverARowKeepsItsOwnLine() throws {
        let note = boxNote(try Peri.tree("settings"), rect(20, 800, 362, 44), within: 126)
        #expect(line(note, "- **Within**: ") == "- **Within**: TextField value=\"Search\" at (28, 808) 346×28pt")
        #expect(inside(note) == [
            "Button \"Dictate\" at (342, 811) 17×22pt",
            "TextField value=\"Search\" at (28, 808) 346×28pt, showing Image \"Search\" id=magnifyingglass",
            "Button \"Screen Time\" id=com.apple.settings.screenTime at (16, 796) 370×52pt, showing Image id=chevron.forward",
        ])
    }

    /// The automation tree holds Settings' Dictate button twice, at one frame.
    @Test func anElementTheTreeHoldsTwiceIsOneLine() throws {
        let lines = inside(boxNote(try Peri.tree("settings"), rect(0, 0, 402, 874)))
        #expect(lines.filter { $0.hasPrefix("Button \"Dictate\"") } == ["Button \"Dictate\" at (342, 811) 17×22pt"])
    }

    @Test func aNoteSavedWithoutAncestryListsEveryNode() {
        func n(_ role: String, _ label: String, _ x: Double, _ w: Double) -> JSON {
            .object(JSONObject(["role": .string(role), "label": .string(label), "frame": rect(x, 0, w, 20)]))
        }
        let note = Format.toMarkdown(JSONObject([
            "kind": .string("area"),
            "rect": rect(0, 0, 100, 20),
            "inside": .array([n("AXStaticText", "a", 0, 10), n("AXButton", "Row", 0, 100)]),
        ]))
        #expect(inside(note) == ["Button \"Row\" at (0, 0) 100×20pt", "StaticText \"a\" at (0, 0) 10×20pt"])
    }

    @Test func aControlNamesThreeOfItsContentsAndCountsTheRest() {
        func n(_ role: String, _ label: String, _ x: Double, _ w: Double, in parent: Int? = 5) -> JSON {
            .object(JSONObject(["role": .string(role), "label": .string(label), "frame": rect(x, 0, w, 20),
                                "parent": parent.map { .number(Double($0)) } ?? .null]))
        }
        let note = Format.toMarkdown(JSONObject([
            "kind": .string("area"),
            "rect": rect(0, 0, 100, 20),
            "inside": .array([n("AXStaticText", "a", 0, 10), n("AXStaticText", "b", 10, 10), n("AXImage", "c", 20, 10),
                              n("AXImage", "d", 30, 10), n("AXImage", "e", 40, 10), n("AXButton", "Row", 0, 100, in: nil)]),
        ]))
        #expect(inside(note) == ["Button \"Row\" at (0, 0) 100×20pt, showing StaticText \"a\", StaticText \"b\", Image \"c\" and 2 more"])
    }

    @Test func aControlNamesTextItDrawsTwiceOnce() {
        func n(_ role: String, _ label: String, _ x: Double, _ w: Double, in parent: Int? = 3) -> JSON {
            .object(JSONObject(["role": .string(role), "label": .string(label), "frame": rect(x, 0, w, 20),
                                "parent": parent.map { .number(Double($0)) } ?? .null]))
        }
        let note = Format.toMarkdown(JSONObject([
            "kind": .string("area"),
            "rect": rect(0, 0, 100, 20),
            "inside": .array([n("AXStaticText", "Click", 30, 40), n("AXStaticText", "Click", 30, 40), n("AXImage", "Arrow", 0, 20),
                              n("AXButton", "Left click", 0, 100, in: nil)]),
        ]))
        #expect(inside(note) == ["Button \"Left click\" at (0, 0) 100×20pt, showing StaticText \"Click\" and Image \"Arrow\""])
    }
}
