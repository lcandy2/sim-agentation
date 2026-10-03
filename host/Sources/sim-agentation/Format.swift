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

    /// Strings worth grepping the Swift sources for.
    private static func searchTerms(_ a: JSONObject) -> [String] {
        var terms: [String] = []
        for n in ([a["target"]] + items(a["inside"]).map(Optional.some)) where JS.truthy(n) {
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
        if JS.same(a["kind"]?.stringValue, "element") && JS.truthy(target) {
            lines.append("- **Element**: \(node(target)) at \(frame(target?["frame"]))")
            let path = items(a["targetPath"])
            if path.count > 1 { lines.append("- **Path**: \(join(path, " › "))") }
        } else {
            lines.append("- **Area**: \(frame(a["rect"]))")
        }
        let inside = items(a["inside"]).filter { !strictEquals($0, target) }.prefix(12)
        if !inside.isEmpty {
            lines.append("- **Inside the box**:")
            for n in inside { lines.append("  - \(node(n)) at \(frame(n["frame"]))") }
        }
        let terms = searchTerms(a)
        if !terms.isEmpty { lines.append("- **Search the source for**: \(terms.map { "`\($0)`" }.joined(separator: ", "))") }
        lines.append("- **Screenshot (box drawn in red)**: \(JS.string(a["images"]?["full"]))")
        lines.append("- **Close-up of the box**: \(JS.string(a["images"]?["crop"]))")
        for r in items(a["replies"]) { lines.append("- **\(JS.string(r["from"]))**: \(JS.string(r["message"]))") }
        if JS.truthy(a["resolution"]) { lines.append("- **Resolution**: \(JS.string(a["resolution"]))") }
        return lines.joined(separator: "\n")
    }
}
