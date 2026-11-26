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
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSON.parse(Data(contentsOf: url)).objectValue)
    }

    static func hit(_ name: String, _ x: Double, _ y: Double) throws -> JSONObject {
        try #require(AX.hitTest(tree(name), x: x, y: y)).node
    }
}

@Suite struct HitTestTests {
    @Test func theTitleMenusTextNamesThePopUp() throws {
        let node = try Peri.hit("peri-current", 190, 75)
        #expect(AX.describe(node) == "PopUpButton \"Touchpad\"")
        #expect(node["identifier"]?.stringValue == "titleMenu")
    }

    @Test func theHostIconNamesThePopUp() throws {
        let node = try Peri.hit("peri-current", 307, 84)
        #expect(AX.describe(node) == "PopUpButton \"Host: No Host\"")
    }

    @Test func aButtonsIconNamesTheButton() throws {
        #expect(AX.describe(try Peri.hit("peri-current", 75, 790)) == "Button \"Left click\"")
        #expect(AX.describe(try Peri.hit("peri-old", 75, 790)) == "Button \"Left click\"")
    }

    @Test func theInterfacesTextNamesThePopUp() throws {
        let node = try Peri.hit("peri-old", 340, 126)
        #expect(AX.describe(node) == "PopUpButton \"Interfaces\"")
        #expect(node["identifier"]?.stringValue == "interfacesMenu")
    }

    @Test func aTabsImageNamesTheRadioButton() throws {
        let node = try Peri.hit("peri-old", 51, 85)
        #expect(node["role"]?.stringValue == "AXRadioButton")
        #expect(AX.describe(node) == "RadioButton \"Touchpad\"")
        #expect(AX.describe(try Peri.hit("peri-old", 240, 85)) == "RadioButton \"Game Controller\"")
    }

    @Test func plainTextStaysTheText() throws {
        let text = "StaticText \"This device can't act as a Bluetooth keyboard.\""
        #expect(AX.describe(try Peri.hit("peri-current", 200, 125)) == text)
        #expect(AX.describe(try Peri.hit("peri-old", 200, 168)) == text)
    }

    @Test func aNamedControlIsItsOwnTarget() throws {
        #expect(AX.describe(try Peri.hit("peri-current", 38, 84)) == "Button \"Settings\"")
        #expect(AX.describe(try Peri.hit("peri-current", 358, 300)) == "Slider \"Scroll\"")
    }

    @Test func thePathEndsAtTheControl() throws {
        let entry = try #require(AX.hitTest(Peri.tree("peri-current"), x: 190, y: 75))
        #expect(entry.path.last == "PopUpButton \"Touchpad\"")
        #expect(entry.path.dropLast().last == "Group")
    }

    @Test func aWidgetIsOneTarget() throws {
        func n(_ role: String, _ label: String, _ value: String?, _ frame: (Double, Double, Double, Double), _ children: [JSON] = []) -> JSON {
            .object(JSONObject([
                "role": .string(role), "label": .string(label), "value": value.map(JSON.string) ?? .null,
                "frame": .object(JSONObject(["x": .number(frame.0), "y": .number(frame.1), "width": .number(frame.2), "height": .number(frame.3)])),
                "children": .array(children),
            ]))
        }
        let tree = try #require(n("AXApplication", "", nil, (0, 0, 402, 874), [
            n("AXGroup", "Weather", "Widget, Stack", (20, 80, 170, 170), [n("AXStaticText", "Cupertino", nil, (36, 96, 90, 20))]),
        ]).objectValue)
        #expect(AX.describe(try #require(AX.hitTest(tree, x: 50, y: 100)).node) == "Group \"Weather\"")
    }
}
