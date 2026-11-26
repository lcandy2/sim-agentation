import Foundation

/// Accessibility-tree helpers with the same semantics as the browser's
/// web/src/lib/ax.js. Frames are in
/// device points, the same space as describe_ui output.
enum AX {
    struct Entry {
        let node: JSONObject
        let depth: Int
        let path: [String]
    }

    static func flatten(_ tree: JSONObject) -> [Entry] {
        var out: [Entry] = []
        func walk(_ node: JSONObject, _ depth: Int, _ path: [String]) {
            let here = path + [describe(node)]
            out.append(Entry(node: node, depth: depth, path: here))
            for child in node["children"]?.arrayValue ?? [] {
                if let child = child.objectValue { walk(child, depth + 1, here) }
            }
        }
        walk(tree, 0, [])
        return out
    }

    static func describe(_ node: JSONObject) -> String {
        let role = JS.truthy(node["role"]) ? JS.string(node["role"]) : "AXElement"
        let bare = JS.dropAX(role)
        let name: String
        if let label = JS.trimmed(node["label"]), !label.isEmpty {
            name = label
        } else if let title = JS.trimmed(node["title"]), !title.isEmpty {
            name = title
        } else if JS.truthy(node["identifier"]) {
            name = JS.string(node["identifier"])
        } else {
            name = ""
        }
        return name.isEmpty ? bare : "\(bare) \"\(name)\""
    }

    static func area(_ f: JSON?) -> Double {
        JS.number(f?["width"]) * JS.number(f?["height"])
    }

    static func contains(_ f: JSON?, _ x: Double, _ y: Double) -> Bool {
        let fx = JS.number(f?["x"]), fy = JS.number(f?["y"])
        return x >= fx && y >= fy && x <= fx + JS.number(f?["width"]) && y <= fy + JS.number(f?["height"])
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

    /// Smallest visible node under a point: what a click targets. Nodes that
    /// cover most of the screen are window-level wrappers, not targets.
    /// `screen` is the screen size in points and defaults to the root's
    /// frame; a 0×0 root (the simulator now reports the application element
    /// that way) means no limit.
    static func hitTest(_ tree: JSONObject, x: Double, y: Double, screen: JSON?? = nil) -> Entry? {
        let screen: JSON? = screen ?? tree["frame"]
        let limit = JS.truthy(screen) && area(screen) > 0 ? area(screen) * 0.6 : .infinity
        var best: Entry?
        for entry in flatten(tree) {
            guard visible(entry), contains(entry.node["frame"], x, y) else { continue }
            let a = area(entry.node["frame"])
            if a > limit { continue }
            if best == nil || a <= area(best!.node["frame"]) { best = entry }
        }
        return best
    }

    /// What a box centred on (x, y) sits in: the nearest named control
    /// holding the innermost element there, or that element when no control
    /// holds it. In the app's automation tree the innermost element is
    /// usually a control's own text run or image. Nodes carry no identity,
    /// so an ancestor is a node whose path starts the hit's path.
    static func within(_ tree: JSONObject, x: Double, y: Double) -> Entry? {
        guard let hit = hitTest(tree, x: x, y: y) else { return nil }
        if actionable(.object(hit.node)) { return hit }
        var best: Entry?
        for entry in flatten(tree) where entry.depth < hit.depth && (best?.depth ?? -1) < entry.depth {
            guard visible(entry), actionable(.object(entry.node)), contains(entry.node["frame"], x, y),
                  hit.path.starts(with: entry.path)
            else { continue }
            best = entry
        }
        return best ?? hit
    }

    /// Roles a user acts on. Their label names what is drawn inside them.
    private static let controlRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXCheckBox", "AXSwitch", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXLink", "AXCell", "AXSlider", "AXIncrementor", "AXTextField", "AXSecureTextField", "AXSearchField",
        "AXTextArea", "AXComboBox", "AXDisclosureTriangle",
    ]

    private static func named(_ node: JSON?) -> Bool {
        !(JS.trimmed(node?["label"]) ?? "").isEmpty || JS.truthy(node?["identifier"])
    }

    /// A control the agent can search for: a control role with a label or identifier.
    static func actionable(_ node: JSON?) -> Bool {
        controlRoles.contains(JS.string(node?["role"])) && named(node)
    }

    /// How much a node in a box tells the agent, best first: named controls,
    /// other named elements, images, then unnamed wrappers. In the app's
    /// automation tree a control's images, text runs and wrappers come with
    /// it and outnumber the controls.
    static func rank(_ node: JSON?) -> Int {
        if actionable(node) { return 0 }
        if !named(node) { return 3 }
        return JS.same(node?["role"]?.stringValue, "AXImage") ? 2 : 1
    }

    /// Nodes that sit mostly inside a box, best first by `rank`, smallest
    /// first within a rank. The server keeps the first 20 for the note.
    /// ax.js sorts by size alone; its one caller re-sorts by position.
    static func nodesInRect(_ tree: JSONObject, _ rect: JSON) -> [Entry] {
        flatten(tree)
            .filter(visible)
            .filter { intersection($0.node["frame"], rect) >= area($0.node["frame"]) * 0.6 }
            .map { (entry: $0, rank: rank(.object($0.node))) }
            .enumerated()
            .sorted { lhs, rhs in
                // Array.prototype.sort is stable.
                if lhs.element.rank != rhs.element.rank { return lhs.element.rank < rhs.element.rank }
                let a = area(lhs.element.entry.node["frame"]), b = area(rhs.element.entry.node["frame"])
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element.entry)
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
