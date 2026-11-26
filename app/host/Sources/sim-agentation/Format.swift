import Foundation

/// An annotation as Markdown for agents.
enum Format {
    private static func node(_ n: JSON?) -> String {
        let role = JS.string(n?["role"])
        var parts = [JS.dropAX(role)]
        if let label = JS.trimmed(n?["label"]), !label.isEmpty { parts.append("\"\(label)\"") }
        if JS.truthy(n?["identifier"]) && !strictEquals(n?["identifier"], n?["label"]) {
            parts.append("id=\(JS.string(n?["identifier"]))")
        }
        if JS.truthy(n?["value"]) { parts.append("value=\"\(JS.string(n?["value"]))\"") }
        return parts.joined(separator: " ")
    }

    private static func frame(_ f: JSON?) -> String {
        func r(_ key: String) -> String { JS.numberString(JS.round(JS.number(f?[key]))) }
        return "(\(r("x")), \(r("y"))) \(r("width"))×\(r("height"))pt"
    }

    /// `===` for the values JSON can hold; objects and arrays are never
    /// identical once they've been through JSON (or built separately).
    private static func strictEquals(_ a: JSON?, _ b: JSON?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (.null?, .null?): return true
        case (.bool(let x)?, .bool(let y)?): return x == y
        case (.number(let x)?, .number(let y)?): return x == y
        case (.string(let x)?, .string(let y)?): return JS.same(x, y)
        default: return false
        }
    }

    /// `[...array]` for arrays; anything else counts as empty.
    private static func items(_ value: JSON?) -> [JSON] { value?.arrayValue ?? [] }

    /// Array.prototype.join: null and undefined become empty strings.
    private static func join(_ values: [JSON], _ separator: String) -> String {
        values.map { $0.isNull ? "" : JS.string($0) }.joined(separator: separator)
    }

    /// Lines listed under "Inside the box"; the rest are counted.
    private static let insideLines = 20
    /// What a control's line names of the things drawn in it; the rest are counted.
    private static let shownPerControl = 3

    /// "a", "a and b", "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard let last = items.last, items.count > 1 else { return items.joined() }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// What the box holds, one line each: named controls first, then other
    /// named elements, images and unnamed elements (`AX.rank`), smallest
    /// first within each. With the tree's ancestry (each node's `parent`, a
    /// position in the same list), what a listed control holds goes on that
    /// control's line, so a bar's icons, text runs and wrapper groups don't
    /// push its controls off the list, and an unnamed wrapper around a
    /// listed element adds nothing and is left out. Only descendants fold:
    /// something drawn over a control, such as a floating search field over
    /// a list row, keeps its own line. Notes saved without ancestry list
    /// every node. Lines that read the same (the automation tree can hold an
    /// element twice) are one line. The last line counts what didn't fit,
    /// including nodes the server didn't keep (`insideTotal`).
    private static func inside(_ a: JSONObject, besides target: JSON?) -> [String] {
        let given = items(a["inside"])
        let actionable = given.map(AX.actionable)
        // Ties keep list order, so notes stored smallest first come out the same as new ones.
        let order = given.indices.filter { !strictEquals(given[$0], target) }
            .sorted { (AX.rank(given[$0]), $0) < (AX.rank(given[$1]), $1) }
        func parent(_ i: Int) -> Int? {
            guard let p = given[i]["parent"]?.numberValue.flatMap({ Int(exactly: $0) }), given.indices.contains(p) else { return nil }
            return p
        }
        // Innermost first; a malformed list that loops stops after a full pass.
        let ancestors: [[Int]] = given.indices.map { i in
            var out: [Int] = []
            var at = parent(i)
            while let p = at, p != i, out.count < given.count { out.append(p); at = parent(p) }
            return out
        }
        // The listed control each node's line folds into, if any.
        var held: [Int: [Int]] = [:]
        var listed: [Int] = []
        for i in order {
            if !actionable[i], let j = ancestors[i].first(where: { actionable[$0] }) {
                held[j, default: []].append(i)
            } else {
                listed.append(i)
            }
        }
        let around = Set(listed.flatMap { ancestors[$0] })
        var lines: [(head: String, shown: [String])] = []
        var lineOf: [String: Int] = [:]
        for j in listed where !(AX.rank(given[j]) == 3 && around.contains(j)) {
            let n = given[j]
            // Only what adds a name the control's own line doesn't print.
            let own = [n["label"], n["value"], n["identifier"]].compactMap { JS.trimmed($0) }.filter { !$0.isEmpty }
            let shown = (held[j] ?? []).map { given[$0] }.filter { m in
                let label = JS.trimmed(m["label"]) ?? ""
                return (!label.isEmpty && !own.contains { JS.same($0, label) })
                    || (JS.truthy(m["identifier"]) && !strictEquals(m["identifier"], n["identifier"]))
            }.map(node)
            let head = "\(node(n)) at \(frame(n["frame"]))"
            if let k = lineOf[head] {
                lines[k].shown += shown
            } else {
                lineOf[head] = lines.count
                lines.append((head, shown))
            }
        }
        let text = lines.map { line in
            // The automation tree can hold the same text run twice in one control.
            let shown = line.shown.reduce(into: [String]()) { seen, name in if !seen.contains(name) { seen.append(name) } }
            let named = shown.count > shownPerControl
                ? shown.prefix(shownPerControl) + ["\(shown.count - shownPerControl) more"]
                : shown
            return line.head + (named.isEmpty ? "" : ", showing \(list(Array(named)))")
        }
        let dropped = max(0, Int(a["insideTotal"]?.numberValue ?? 0) - given.count)
        let more = max(0, text.count - insideLines) + dropped
        return more > 0 ? text.prefix(insideLines) + ["and \(more) more"] : text
    }

    /// Strings worth grepping the Swift sources for. With several picked
    /// together, the box spans everything between them, so what it covers
    /// isn't part of the note: only the picks themselves count.
    private static func searchTerms(_ a: JSONObject) -> [String] {
        var terms: [String] = []
        let picked = items(a["parts"])
        let parts = picked.flatMap { [$0["target"], $0["within"]] }
        let inside = picked.count > 1 ? [] : items(a["inside"]).map(Optional.some)
        for n in ([a["target"], a["within"]] + parts + inside) where JS.truthy(n) {
            for key in ["identifier", "label", "title"] {
                guard let t = JS.trimmed(n?[key]), !t.isEmpty, JS.length(t) > 1, JS.length(t) < 60 else { continue }
                if !terms.contains(where: { JS.same($0, t) }) { terms.append(t) }
            }
        }
        return Array(terms.prefix(8))
    }

    static func toMarkdown(_ a: JSONObject) -> String {
        // Scalar by scalar: "\r\n" is one Character in Swift but two code units in JavaScript.
        var comment = String.UnicodeScalarView()
        for scalar in JS.string(a["comment"]).unicodeScalars {
            if scalar == "\n" { comment.append(contentsOf: "\n> ".unicodeScalars) } else { comment.append(scalar) }
        }
        var lines = ["## \(JS.string(a["id"])) [\(JS.string(a["status"]))]", "", "> \(String(comment))", ""]
        let screen = a["screen"]
        let `where` = join(items(screen?["headings"]), " › ")
        let device = a["device"]
        let deviceName = device?["name"].flatMap { $0.isNull ? nil : $0 } ?? device?["udid"]
        let runtime = JS.truthy(device?["runtime"]) ? " (\(JS.string(device?["runtime"])))" : ""
        lines.append("- **Device**: \(JS.string(deviceName))\(runtime)")
        let app: JSON = a["app"].flatMap { $0.isNull ? nil : $0 }
            ?? .object(JSONObject(["bundleId": .null, "name": screen?["app"]]))
        if JS.truthy(app["name"]) || JS.truthy(app["bundleId"]) {
            var parts: [String] = []
            if JS.truthy(app["name"]) { parts.append(JS.string(app["name"])) }
            if JS.truthy(app["bundleId"]) { parts.append("(\(JS.string(app["bundleId"])))") }
            lines.append("- **App**: \(parts.joined(separator: " "))")
        }
        if !`where`.isEmpty { lines.append("- **Screen**: \(`where`)") }
        let source = items(a["source"])
        if let inner = source.first, JS.truthy(inner) {
            lines.append("- **Source**: `\(JS.string(inner["name"]))` at \(JS.string(inner["file"])):\(JS.string(inner["line"]))")
            for s in source.dropFirst() {
                lines.append("  - inside `\(JS.string(s["name"]))` at \(JS.string(s["file"])):\(JS.string(s["line"]))")
            }
        }
        if JS.truthy(a["controller"]) { lines.append("- **View controller**: `\(JS.string(a["controller"]))`") }
        let views = items(a["views"])
        if !views.isEmpty {
            lines.append("- **Views** (innermost first): \(views.map { "`\(JS.string($0))`" }.joined(separator: " › "))")
        }
        let target = a["target"]
        let parts = items(a["parts"])
        if parts.count > 1 {
            // Several picked together: the note is about all of them.
            lines.append("- **Elements** (\(parts.count), the note is about them together):")
            for p in parts {
                let box = JS.truthy(p["color"]) ? " (\(JS.string(p["color"])) box)" : ""
                if JS.same(p["kind"]?.stringValue, "element") && JS.truthy(p["target"]) {
                    lines.append("  - \(node(p["target"])) at \(frame(p["target"]?["frame"]))\(box)")
                } else {
                    let picked = JS.trimmed(p["label"]).flatMap { $0.isEmpty || $0 == "Area" ? nil : $0 }
                    let within = JS.truthy(p["within"]) ? ", within \(node(p["within"]))" : ""
                    lines.append("  - Area \(picked.map { "\($0) " } ?? "")at \(frame(p["rect"]))\(within)\(box)")
                }
                if let s = items(p["source"]).first, JS.truthy(s) {
                    lines.append("    - source `\(JS.string(s["name"]))` at \(JS.string(s["file"])):\(JS.string(s["line"]))")
                }
            }
        } else if JS.same(a["kind"]?.stringValue, "element") && JS.truthy(target) {
            lines.append("- **Element**: \(node(target)) at \(frame(target?["frame"]))")
            let path = items(a["targetPath"])
            if path.count > 1 { lines.append("- **Path**: \(join(path, " › "))") }
        } else {
            let picked = JS.trimmed(a["label"]).flatMap { $0.isEmpty || $0 == "Area" ? nil : $0 }
            lines.append("- **Area**: \(picked.map { "\($0) at " } ?? "")\(frame(a["rect"]))")
            if JS.truthy(a["within"]) { lines.append("- **Within**: \(node(a["within"])) at \(frame(a["within"]?["frame"]))") }
        }
        let inside = inside(a, besides: target)
        if !inside.isEmpty && parts.count < 2 {
            lines.append("- **Inside the box**:")
            for line in inside { lines.append("  - \(line)") }
        }
        let terms = searchTerms(a)
        if !terms.isEmpty { lines.append("- **Search the source for**: \(terms.map { "`\($0)`" }.joined(separator: ", "))") }
        let several = parts.count > 1
        lines.append("- **Screenshot (\(several ? "each element's box drawn in its color" : "box drawn in red"))**: \(JS.string(a["images"]?["full"]))")
        lines.append("- **Close-up of the \(several ? "boxes" : "box")**: \(JS.string(a["images"]?["crop"]))")
        for r in items(a["replies"]) { lines.append("- **\(JS.string(r["from"]))**: \(JS.string(r["message"]))") }
        if JS.truthy(a["resolution"]) { lines.append("- **Resolution**: \(JS.string(a["resolution"]))") }
        return lines.joined(separator: "\n")
    }
}
