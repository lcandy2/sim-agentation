import Foundation

/// Accessibility-tree helpers for notes. Frames are in device points, the
/// same space as describe_ui output. The page (web/src/lib/ax.js) picks what
/// a click names; the server finds those picks by position in `flatten`
/// (`entry(_:in:)`).
enum AX {
    struct Entry {
        let node: JSONObject
        let depth: Int
        let path: [String]
        /// The parent's position in the same `flatten` list.
        var parent: Int? = nil
    }

    /// The tree's nodes in pre-order, the root first: the order of ax.js's
    /// `flatten`, whose positions the page sends as references.
    static func flatten(_ tree: JSONObject) -> [Entry] {
        var out: [Entry] = []
        func walk(_ node: JSONObject, _ depth: Int, _ path: [String], _ parent: Int?) {
            let here = path + [describe(node)]
            let at = out.count
            out.append(Entry(node: node, depth: depth, path: here, parent: parent))
            for child in node["children"]?.arrayValue ?? [] {
                if let child = child.objectValue { walk(child, depth + 1, here, at) }
            }
        }
        walk(tree, 0, [], nil)
        return out
    }

    static func describe(_ node: JSONObject) -> String {
        let role = JS.truthy(node["role"]) ? JS.string(node["role"]) : "AXElement"
        let bare = JS.dropAX(role)
        let name = name(node)
        return name.isEmpty ? bare : "\(bare) \"\(name)\""
    }

    /// What a node is called: its label, else its title, else its
    /// identifier; empty when it has none.
    private static func name(_ node: JSONObject) -> String {
        if let label = JS.trimmed(node["label"]), !label.isEmpty { return label }
        if let title = JS.trimmed(node["title"]), !title.isEmpty { return title }
        return JS.truthy(node["identifier"]) ? JS.string(node["identifier"]) : ""
    }

    static func area(_ f: JSON?) -> Double {
        JS.number(f?["width"]) * JS.number(f?["height"])
    }

    static func intersection(_ a: JSON?, _ b: JSON?) -> Double {
        let ax = JS.number(a?["x"]), ay = JS.number(a?["y"]), aw = JS.number(a?["width"]), ah = JS.number(a?["height"])
        let bx = JS.number(b?["x"]), by = JS.number(b?["y"]), bw = JS.number(b?["width"]), bh = JS.number(b?["height"])
        let x = jsMax(ax, bx)
        let y = jsMax(ay, by)
        let w = jsMin(ax + aw, bx + bw) - x
        let h = jsMin(ay + ah, by + bh) - y
        return w > 0 && h > 0 ? w * h : 0
    }

    // Math.max/min: NaN wins.
    private static func jsMax(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.max(a, b) }
    private static func jsMin(_ a: Double, _ b: Double) -> Double { a.isNaN || b.isNaN ? .nan : Swift.min(a, b) }

    private static func visible(_ entry: Entry) -> Bool {
        entry.depth > 0 && !JS.truthy(entry.node["hidden"]) && JS.truthy(entry.node["frame"]) && area(entry.node["frame"]) > 0
    }

    /// The entry a page's reference names: its position in `entries`, a
    /// `flatten` list. Nil for anything else: no reference, not a whole
    /// number, or not a position in the list.
    static func entry(_ ref: JSON?, in entries: [Entry]) -> Entry? {
        guard let i = ref?.numberValue, i >= 0, i < Double(entries.count), i.rounded(.towardZero) == i else { return nil }
        return entries[Int(i)]
    }

    /// Roles a person would call a control, which rank first in a box note.
    /// ax.js keeps the same set for its click climb from a control's text or
    /// icon to the control, which runs in the page on every pointer move.
    private static let controls: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXRadioButton", "AXCheckBox", "AXSwitch", "AXToggle",
        "AXLink", "AXMenuItem", "AXTab", "AXCell", "AXSlider", "AXIncrementor", "AXTextField", "AXSecureTextField",
        "AXTextArea", "AXSearchField", "AXComboBox", "AXDisclosureTriangle",
    ]

    /// A home-screen widget, one element over its whole card: its value says
    /// "Widget" ("Widget, Stack" in a Smart Stack).
    private static func isWidget(_ node: JSONObject) -> Bool {
        guard let value = node["value"]?.stringValue else { return false }
        return value.split(separator: ",", omittingEmptySubsequences: false).contains { $0.drop(while: \.isWhitespace) == "Widget" }
    }

    private static func isControl(_ node: JSONObject) -> Bool {
        node["role"]?.stringValue.map(controls.contains) == true || isWidget(node)
    }

    private static func named(_ node: JSONObject) -> Bool { !name(node).isEmpty }

    /// Fields that show their text, or their placeholder, as their value
    /// (Settings' search field has no label, only the value "Search").
    private static let fields: Set<String> = ["AXTextField", "AXSecureTextField", "AXTextArea", "AXSearchField", "AXComboBox"]

    /// A control the agent can search for: a control (or widget) with a
    /// label, title or identifier, or a text field with a value.
    static func actionable(_ node: JSON?) -> Bool {
        guard let node = node?.objectValue, isControl(node) else { return false }
        return named(node) || (node["role"]?.stringValue.map(fields.contains) == true && !(JS.trimmed(node["value"]) ?? "").isEmpty)
    }

    /// How much a node in a box tells the agent, best first: named controls,
    /// other named elements, images, then unnamed wrappers. In the app's
    /// automation tree a control's images, text runs and wrappers come with
    /// it and outnumber the controls.
    static func rank(_ node: JSON?) -> Int {
        if actionable(node) { return 0 }
        guard let object = node?.objectValue, named(object) else { return 3 }
        return JS.same(node?["role"]?.stringValue, "AXImage") ? 2 : 1
    }

    /// How many of a box's nodes a note keeps: enough for a whole screen.
    static let insideKept = 200

    /// A box note's `inside`: the nodes that sit mostly inside the box, best
    /// first by `rank` and smallest first within a rank. The first `keep` are summarized, each with `parent`, the
    /// position in this list of its nearest ancestor that is in it too (null
    /// for none), so the note can tell what a control holds from what is
    /// drawn over it. `total` counts them all.
    static func inside(_ tree: JSONObject, _ rect: JSON, keep: Int = insideKept) -> (nodes: [JSON], total: Int) {
        let entries = flatten(tree)
        let found = entries.indices
            .filter { visible(entries[$0]) && intersection(entries[$0].node["frame"], rect) >= area(entries[$0].node["frame"]) * 0.6 }
            .map { (index: $0, rank: rank(.object(entries[$0].node)), area: area(entries[$0].node["frame"])) }
            // Ties keep tree order, as Array.prototype.sort's stable sort does.
            .sorted { ($0.rank, $0.area, $0.index) < ($1.rank, $1.area, $1.index) }
            .map(\.index)
        let kept = Array(found.prefix(keep))
        let position = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        let nodes = kept.map { i -> JSON in
            var up = entries[i].parent
            while let p = up, position[p] == nil { up = entries[p].parent }
            var summary = summarize(entries[i].node).objectValue ?? JSONObject()
            summary["parent"] = up.flatMap { position[$0] }.map { .number(Double($0)) } ?? .null
            return .object(summary)
        }
        return (nodes, found.count)
    }

    private static let statusBar = 54.0 // pt; clock, battery and signal live above this

    /// Best guess at which screen this is: app name plus headings and
    /// navigation titles near the top.
    static func screenContext(_ tree: JSONObject?) -> JSON {
        guard let tree else { return .object(JSONObject(["app": .null, "headings": .array([])])) }
        let app = nonEmpty(JS.trimmed(tree["label"])) ?? nonEmpty(JS.trimmed(tree["title"]))
        var headings: [String] = []
        for entry in flatten(tree) where visible(entry) {
            let node = entry.node
            let y = JS.number(node["frame"]?["y"])
            guard y >= statusBar else { continue }
            let subrole = JS.truthy(node["subrole"]) ? JS.string(node["subrole"]) : ""
            let lower = String(subrole.unicodeScalars.map { $0.isASCII ? Character(String($0).lowercased()) : Character($0) })
            let role = node["role"]?.stringValue
            let isHeading = JS.same(role, "AXHeading")
                || ["header", "navigationbar", "heading"].contains { lower.contains($0) }
                || (JS.same(role, "AXStaticText") && y < 140)
            guard isHeading else { continue }
            guard let text = nonEmpty(JS.trimmed(node["label"])) ?? nonEmpty(JS.trimmed(node["title"])),
                  JS.length(text) <= 40
            else { continue }
            if !headings.contains(where: { JS.same($0, text) }) { headings.append(text) }
        }
        return .object(JSONObject([
            "app": app.map(JSON.string) ?? .null,
            "headings": .array(headings.prefix(5).map(JSON.string)),
        ]))
    }

    static func summarize(_ node: JSONObject) -> JSON {
        let f = node["frame"]
        func round(_ key: String) -> JSON { .number(JS.round(JS.number(f?[key]) * 10) / 10) }
        return .object(JSONObject([
            "role": node["role"],
            "label": node["label"] ?? .null,
            "identifier": node["identifier"] ?? .null,
            "value": node["value"] ?? .null,
            "title": node["title"] ?? .null,
            "frame": .object(JSONObject(["x": round("x"), "y": round("y"), "width": round("width"), "height": round("height")])),
        ]))
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
