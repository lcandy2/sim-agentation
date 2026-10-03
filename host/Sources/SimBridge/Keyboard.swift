import Foundation

/// W3C `KeyboardEvent.code` values and ASCII characters as HID keyboard
/// usages (page 7), from the USB HID Usage Tables.
public enum Keyboard {
    public static let modifiers: [String: UInt32] = [
        "control": 0xE0, "shift": 0xE1, "option": 0xE2, "command": 0xE3,
    ]

    public static func usage(forCode code: String) -> UInt32? {
        if code.hasPrefix("Key"), code.count == 4, let c = code.last?.asciiValue, (65...90).contains(c) {
            return 0x04 + UInt32(c - 65)
        }
        if code.hasPrefix("Digit"), code.count == 6, let d = code.last?.wholeNumberValue {
            return d == 0 ? 0x27 : 0x1E + UInt32(d - 1)
        }
        return named[code]
    }

    /// The key and whether Shift is needed to type `character` on a US layout.
    public static func keystroke(for character: Character) -> (usage: UInt32, shift: Bool)? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 97...122: return (0x04 + UInt32(ascii - 97), false)  // a-z
        case 65...90: return (0x04 + UInt32(ascii - 65), true)    // A-Z
        case 49...57: return (0x1E + UInt32(ascii - 49), false)   // 1-9
        case 48: return (0x27, false)                             // 0
        default: return punctuation[ascii]
        }
    }

    private static let named: [String: UInt32] = [
        "Enter": 0x28, "Escape": 0x29, "Backspace": 0x2A, "Tab": 0x2B, "Space": 0x2C,
        "Minus": 0x2D, "Equal": 0x2E, "BracketLeft": 0x2F, "BracketRight": 0x30, "Backslash": 0x31,
        "Semicolon": 0x33, "Quote": 0x34, "Backquote": 0x35, "Comma": 0x36, "Period": 0x37, "Slash": 0x38,
        "ArrowRight": 0x4F, "ArrowLeft": 0x50, "ArrowDown": 0x51, "ArrowUp": 0x52, "Delete": 0x4C,
    ]

    private static let punctuation: [UInt8: (UInt32, Bool)] = [
        32: (0x2C, false), 10: (0x28, false), 9: (0x2B, false),
        33: (0x1E, true), 64: (0x1F, true), 35: (0x20, true), 36: (0x21, true), 37: (0x22, true),
        94: (0x23, true), 38: (0x24, true), 42: (0x25, true), 40: (0x26, true), 41: (0x27, true),
        45: (0x2D, false), 95: (0x2D, true), 61: (0x2E, false), 43: (0x2E, true),
        91: (0x2F, false), 123: (0x2F, true), 93: (0x30, false), 125: (0x30, true),
        92: (0x31, false), 124: (0x31, true), 59: (0x33, false), 58: (0x33, true),
        39: (0x34, false), 34: (0x34, true), 96: (0x35, false), 126: (0x35, true),
        44: (0x36, false), 60: (0x36, true), 46: (0x37, false), 62: (0x37, true),
        47: (0x38, false), 63: (0x38, true),
    ]
}
