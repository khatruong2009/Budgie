import Foundation

/// Dart `String` operations whose Swift counterparts differ.
///
/// Dart strings are sequences of UTF-16 code units: `==`, `contains`,
/// `startsWith` and `compareTo` compare code units, with no canonical
/// equivalence (Swift `String` compares by grapheme and treats "é" and
/// "e\u{301}" as equal).
public enum DartString {
    /// Dart `String.trim`: Unicode White_Space plus U+FEFF (Swift's
    /// `.whitespacesAndNewlines` has no U+FEFF).
    public static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let start = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let end = scalars.lastIndex(where: { !isWhitespace($0) })!
        return String(scalars[start...end])
    }

    /// Dart `String.trim` on UTF-16 code units (every character in the set is
    /// one BMP unit; a surrogate is never whitespace).
    public static func trimUnits(_ units: [UInt16]) -> [UInt16] {
        func space(_ unit: UInt16) -> Bool { Unicode.Scalar(unit).map(isWhitespace) ?? false }
        guard let start = units.firstIndex(where: { !space($0) }) else { return [] }
        let end = units.lastIndex(where: { !space($0) })!
        return Array(units[start...end])
    }

    /// Dart's `trim` whitespace set (`String.trim` docs).
    public static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// Dart `String.toLowerCase` on the VM: the simple (one-to-one) Unicode
    /// lowercase mapping of each scalar, no locale and no final-sigma rule,
    /// from the VM's Unicode 5.1 case tables (as `uppercase`): a mapping to
    /// or from a later character (Cherokee, Georgian Mtavruli, Osage, Adlam,
    /// U+037F, ...) is not applied. The only unconditional full mapping that
    /// differs is U+0130, which Dart maps to plain "i" (Swift's
    /// `lowercased()` gives "i" + U+0307). Verified for every scalar against
    /// Fixtures/logic/lower.json. ASCII takes a fast path (A-Z plus 32, the
    /// rest unchanged): same output, without the per-scalar table lookups.
    public static func lowercase(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value < 0x80 {
                result.append(0x41...0x5A ~= scalar.value ? Unicode.Scalar(UInt8(scalar.value + 32)) : scalar)
                continue
            }
            if scalar.value == 0x130 {
                result.append("i")
                continue
            }
            let mapped = scalar.properties.lowercaseMapping.unicodeScalars
            if mapped.count == 1, inDartTables(scalar), inDartTables(mapped.first!) {
                result.append(contentsOf: mapped)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Whether the Dart VM's case tables (Unicode 5.1) know `scalar`.
    private static func inDartTables(_ scalar: Unicode.Scalar) -> Bool {
        guard let age = scalar.properties.age else { return false }
        return (age.major, age.minor) <= (5, 1)
    }

    /// Dart `String.toUpperCase` on the VM: the simple (one-to-one) Unicode
    /// uppercase mapping of each scalar ("ß" and "ﬁ" stay, U+1F80 becomes
    /// U+1F88), from the VM's Unicode 5.1 case tables: a mapping to or from
    /// a later character (Georgian Mtavruli, "ȿ" to U+2C7E, ...) is not
    /// applied. Swift exposes only the full mappings, so a scalar whose full
    /// uppercase is several scalars takes its titlecase when that is a single
    /// scalar (the iota-subscript Greek letters) and is otherwise unchanged.
    /// Verified for every scalar against Fixtures/spend/strings.json.
    public static func uppercase(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            var mapped = scalar.properties.uppercaseMapping.unicodeScalars
            if mapped.count != 1 { mapped = scalar.properties.titlecaseMapping.unicodeScalars }
            if mapped.count == 1, inDartTables(scalar), inDartTables(mapped.first!) {
                result.append(contentsOf: mapped)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// Dart `String.hashCode` on the VM (JIT and AOT share the runtime's
    /// `String::Hash`): Jenkins one-at-a-time over the UTF-16 code units,
    /// finalised, masked to 30 bits, with 0 mapped to 1. Not the web
    /// (dart2js) value. Verified against Fixtures/spend/strings.json.
    public static func hashCode(_ text: String) -> Int {
        var hash: UInt32 = 0
        for unit in text.utf16 {
            hash &+= UInt32(unit)
            hash &+= hash << 10
            hash ^= hash >> 6
        }
        hash &+= hash << 3
        hash ^= hash >> 11
        hash &+= hash << 15
        hash &= (1 << 30) - 1
        return hash == 0 ? 1 : Int(hash)
    }

    /// Dart `a == b`.
    public static func equal(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    /// Dart `text.startsWith(prefix)`.
    public static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.utf16.starts(with: prefix.utf16)
    }

    /// Dart `text.contains(other)`: a code-unit substring search.
    public static func contains(_ text: String, _ other: String) -> Bool {
        let haystack = Array(text.utf16), needle = Array(other.utf16)
        if needle.isEmpty { return true }
        if needle.count > haystack.count { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return true }
        }
        return false
    }

    /// Dart `a.compareTo(b) < 0`: code-unit order.
    public static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }
}
