import Foundation

/// A JSON value that keeps object key order and formats numbers the way
/// JavaScript does, so whatever JSON.parse/JSON.stringify wrote round-trips
/// byte for byte (annotations.json, the SDK snapshot, chrome.json).
enum JSON: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var objectValue: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [JSON]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var numberValue: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// An object with JavaScript's property order: array-index keys ascending,
/// then the other keys in insertion order. Setting an existing key keeps its
/// position, like assigning to a property.
struct JSONObject: Sendable {
    private(set) var entries: [(key: String, value: JSON)] = []

    init() {}

    /// Pairs with a nil value are left out, the way JSON.stringify drops
    /// `undefined` properties.
    init(_ pairs: KeyValuePairs<String, JSON?>) {
        for (key, value) in pairs { if let value { self[key] = value } }
    }

    var keys: [String] { entries.map(\.key) }

    subscript(key: String) -> JSON? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
                return
            }
            guard let newValue else { return }
            if let index = Self.arrayIndex(key) {
                // Index keys sit in front, ascending.
                let position = entries.firstIndex { Self.arrayIndex($0.key).map { $0 > index } ?? true } ?? entries.count
                entries.insert((key, newValue), at: position)
            } else {
                entries.append((key, newValue))
            }
        }
    }

    private static func arrayIndex(_ key: String) -> UInt64? {
        let utf8 = key.utf8
        guard let first = utf8.first, utf8.count <= 10, utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if first == 48 && utf8.count > 1 { return nil }
        guard let value = UInt64(key), value < 4_294_967_295 else { return nil }
        return value
    }
}

// MARK: - parsing

struct JSONParseError: Error, CustomStringConvertible {
    let description: String
}

extension JSON {
    /// Parses like JSON.parse. Invalid UTF-8 is replaced, as a text decoder would.
    static func parse(_ data: Data) throws -> JSON {
        try parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) throws -> JSON {
        var text = text
        return try text.withUTF8 { buffer in
            var parser = JSONParser(bytes: buffer)
            parser.skipWhitespace()
            let value = try parser.parseValue(depth: 0)
            parser.skipWhitespace()
            guard parser.index == buffer.count else { throw parser.error("unexpected data after JSON") }
            return value
        }
    }
}

private struct JSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var index = 0
    static let maxDepth = 1000

    init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

    func error(_ message: String) -> JSONParseError { JSONParseError(description: message) }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func parseValue(depth: Int) throws -> JSON {
        guard index < bytes.count else { throw error("unexpected end of input") }
        guard depth < Self.maxDepth else { throw error("too deeply nested") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func expect(_ literal: StaticString) throws {
        let count = literal.utf8CodeUnitCount
        guard index + count <= bytes.count else { throw error("unexpected end of input") }
        for i in 0..<count where bytes[index + i] != literal.utf8Start[i] { throw error("unexpected token") }
        index += count
    }

    mutating func parseObject(depth: Int) throws -> JSON {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a property name") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end of input") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw error("expected ',' or '}'")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSON {
        index += 1
        var array: [JSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
        while true {
            skipWhitespace()
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end of input") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
            throw error("expected ',' or ']'")
        }
    }

    mutating func parseString() throws -> String {
        index += 1 // opening quote
        let start = index
        // Fast path: no escapes.
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let string = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                index += 1
                return string
            }
            if byte == UInt8(ascii: "\\") { break }
            if byte < 0x20 { throw error("control character in string") }
            index += 1
        }
        var out = [UInt8](UnsafeBufferPointer(rebasing: bytes[start..<index]))
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: out, as: UTF8.self)
            }
            if byte < 0x20 { throw error("control character in string") }
            if byte != UInt8(ascii: "\\") {
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < bytes.count else { break }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var unit = try hex4()
                if (0xD800..<0xDC00).contains(unit), index + 6 <= bytes.count,
                   bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                    let save = index
                    index += 2
                    let low = try hex4()
                    if (0xDC00..<0xE000).contains(low) {
                        unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = save
                    }
                }
                // A lone surrogate can't live in a Swift string.
                let scalar = Unicode.Scalar(unit) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            default:
                throw error("bad escape")
            }
        }
        throw error("unterminated string")
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("bad unicode escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case 48...57: digit = UInt32(byte - 48)
            case 65...70: digit = UInt32(byte - 55)
            case 97...102: digit = UInt32(byte - 87)
            default: throw error("bad unicode escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    mutating func parseNumber() throws -> Double {
        let start = index
        func digits() -> Int {
            let from = index
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
            return index - from
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw error("unexpected end of input") }
        if bytes[index] == 48 {
            index += 1
        } else if digits() == 0 {
            throw error("unexpected token")
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw error("bad number") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw error("bad number") }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        guard let value = Double(text) else { throw error("bad number") }
        return value
    }
}

// MARK: - serializing

extension JSON {
    /// JSON.stringify(value), or JSON.stringify(value, null, indent).
    func serialized(indent: Int = 0) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(to: &out, indent: indent, depth: 0)
        return String(decoding: out, as: UTF8.self)
    }

    func data(indent: Int = 0) -> Data { Data(serialized(indent: indent).utf8) }

    private func write(to out: inout [UInt8], indent: Int, depth: Int) {
        switch self {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
        case .number(let n): out.append(contentsOf: (n.isFinite ? JS.numberString(n) : "null").utf8)
        case .string(let s): JSON.writeString(s, to: &out)
        case .array(let items):
            if items.isEmpty { out.append(contentsOf: "[]".utf8); return }
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JSON.newline(&out, indent: indent, depth: depth + 1)
                item.write(to: &out, indent: indent, depth: depth + 1)
            }
            JSON.newline(&out, indent: indent, depth: depth)
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            if object.entries.isEmpty { out.append(contentsOf: "{}".utf8); return }
            out.append(UInt8(ascii: "{"))
            for (i, entry) in object.entries.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                JSON.newline(&out, indent: indent, depth: depth + 1)
                JSON.writeString(entry.key, to: &out)
                out.append(UInt8(ascii: ":"))
                if indent > 0 { out.append(UInt8(ascii: " ")) }
                entry.value.write(to: &out, indent: indent, depth: depth + 1)
            }
            JSON.newline(&out, indent: indent, depth: depth)
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func newline(_ out: inout [UInt8], indent: Int, depth: Int) {
        guard indent > 0 else { return }
        out.append(0x0A)
        out.append(contentsOf: repeatElement(UInt8(ascii: " "), count: indent * depth))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func writeString(_ s: String, to out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in s.utf8 {
            switch byte {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0..<0x20:
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0xF)]])
            default: out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

// MARK: - JavaScript semantics

/// The bits of JavaScript's value semantics the ported code relies on.
enum JS {
    /// Number.prototype.toString(): shortest round-trip digits, with
    /// exponent notation outside 1e-7 < |n| < 1e21.
    static func numberString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        if value == 0 { return "0" }
        // Swift's description also prints the shortest round-trip digits;
        // only the layout differs.
        var text = abs(value).description
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        var digits = text
        var pointPosition = digits.count
        if let dot = digits.firstIndex(of: ".") {
            pointPosition = digits.distance(from: digits.startIndex, to: dot)
            digits.remove(at: dot)
        }
        var n = pointPosition + exponent
        while digits.hasPrefix("0") { digits.removeFirst(); n -= 1 }
        while digits.hasSuffix("0") { digits.removeLast() }
        if digits.isEmpty { return "0" }
        let k = digits.count
        let sign = value < 0 ? "-" : ""
        if k <= n && n <= 21 {
            return sign + digits + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let i = digits.index(digits.startIndex, offsetBy: n)
            return sign + digits[..<i] + "." + digits[i...]
        }
        if -6 < n && n <= 0 {
            return sign + "0." + String(repeating: "0", count: -n) + digits
        }
        let e = n - 1
        let exp = (e >= 0 ? "+" : "-") + String(abs(e))
        if k == 1 { return sign + digits + "e" + exp }
        return sign + String(digits.first!) + "." + digits.dropFirst() + "e" + exp
    }

    /// String(value); nil is `undefined`.
    static func string(_ value: JSON?) -> String {
        guard let value else { return "undefined" }
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return numberString(n)
        case .string(let s): return s
        case .array(let items):
            return items.map { item in
                if case .null = item { return "" }
                return string(item)
            }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }

    /// Boolean(value); nil is `undefined`.
    static func truthy(_ value: JSON?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// Number(value); nil is `undefined`.
    static func number(_ value: JSON?) -> Double {
        guard let value else { return .nan }
        switch value {
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let n): return n
        case .string(let s): return number(s)
        case .array: return number(string(value))
        case .object: return .nan
        }
    }

    /// Number(string): trims, "" is 0, decimal or 0x/0o/0b integers, Infinity.
    static func number(_ string: String) -> Double {
        let s = trim(string)
        if s.isEmpty { return 0 }
        switch s {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let lower = s.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            let body = s.dropFirst(2)
            guard !body.isEmpty else { return .nan }
            var value = 0.0
            for byte in body.utf8 {
                guard let digit = asciiHexValue(byte), digit < radix else { return .nan }
                value = value * Double(radix) + Double(digit)
            }
            return value
        }
        // StrDecimalLiteral: sign, digits with an optional point, optional exponent.
        var chars = Array(s.utf8)[...]
        if let first = chars.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") { chars = chars.dropFirst() }
        var sawDigit = false
        var i = chars.startIndex
        while i < chars.endIndex, chars[i] >= 48, chars[i] <= 57 { i += 1; sawDigit = true }
        if i < chars.endIndex, chars[i] == UInt8(ascii: ".") {
            i += 1
            while i < chars.endIndex, chars[i] >= 48, chars[i] <= 57 { i += 1; sawDigit = true }
        }
        guard sawDigit else { return .nan }
        if i < chars.endIndex, chars[i] == UInt8(ascii: "e") || chars[i] == UInt8(ascii: "E") {
            i += 1
            if i < chars.endIndex, chars[i] == UInt8(ascii: "+") || chars[i] == UInt8(ascii: "-") { i += 1 }
            let start = i
            while i < chars.endIndex, chars[i] >= 48, chars[i] <= 57 { i += 1 }
            guard i > start else { return .nan }
        }
        guard i == chars.endIndex else { return .nan }
        return Double(s) ?? .nan
    }

    /// Number.isFinite(value): only actual numbers.
    static func isFiniteNumber(_ value: JSON?) -> Bool {
        if case .number(let n)? = value { return n.isFinite }
        return false
    }

    /// Math.round: halves round up, toward +Infinity.
    static func round(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let floor = x.rounded(.down)
        let rounded = x - floor >= 0.5 ? floor + 1 : floor
        return rounded == 0 && x < 0 ? -0.0 : rounded
    }

    /// String.prototype.trim: JavaScript's whitespace and line terminators.
    static func trim(_ s: String) -> String {
        let scalars = s.unicodeScalars
        var start = scalars.startIndex, end = scalars.endIndex
        while start < end, isSpace(scalars[start]) { start = scalars.index(after: start) }
        while end > start, isSpace(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        return String(scalars[start..<end])
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0xFEFF, 0x2028, 0x2029: return true
        default: return c.properties.generalCategory == .spaceSeparator
        }
    }

    /// `a === b` for strings: code units, not Swift's canonical equivalence.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.utf8.elementsEqual(b.utf8)
    }

    /// `s.replace(/^AX/, '')`
    static func dropAX(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard scalars.starts(with: "AX".unicodeScalars) else { return s }
        return String(scalars.dropFirst(2))
    }

    /// String length in UTF-16 code units.
    static func length(_ s: String) -> Int { s.utf16.count }

    /// `value?.trim()` for strings; nil otherwise.
    static func trimmed(_ value: JSON?) -> String? {
        value?.stringValue.map(trim)
    }

    /// encodeURIComponent.
    static func encodeURIComponent(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "!"), UInt8(ascii: "~"),
                 UInt8(ascii: "*"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func asciiHexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 48...57: Int(byte - 48)
        case 65...70: Int(byte - 55)
        case 97...102: Int(byte - 87)
        default: nil
        }
    }

    struct URIError: Error, CustomStringConvertible {
        var description: String { "URI error" }
    }

    /// decodeURIComponent; throws on malformed escapes or UTF-8, like JavaScriptCore.
    static func decodeURIComponent(_ s: String) throws -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%") {
                guard i + 2 < bytes.count, let hi = asciiHexValue(bytes[i + 1]), let lo = asciiHexValue(bytes[i + 2]) else {
                    throw URIError()
                }
                out.append(UInt8(hi << 4 | lo))
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        guard let decoded = String(validating: out, as: UTF8.self) else { throw URIError() }
        return decoded
    }
}
