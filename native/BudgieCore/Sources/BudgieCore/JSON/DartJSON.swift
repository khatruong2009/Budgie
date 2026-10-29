/// Writes JSON exactly as Dart's `jsonEncode` does: no whitespace, keys in
/// order, Dart number and string formatting.
public enum DartJSON {
    public enum Mode: Sendable {
        /// Emit every number and string from its stored lexeme. A value
        /// loaded from a Dart-written file is reproduced byte for byte.
        case preserving
        /// Emit what Dart would produce after `jsonDecode` then `jsonEncode`
        /// of the same text: numbers re-formatted from their decoded value,
        /// strings re-escaped, duplicate keys collapsed (first position,
        /// last value). Used to verify the legacy v1 envelope checksum and
        /// to compare stores semantically with Dart.
        case dartCanonical
    }

    public static func encode(_ value: JSONValue, mode: Mode = .preserving) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(4096)
        write(value, into: &out, mode: mode)
        return out
    }

    public static func encodeString(_ value: JSONValue, mode: Mode = .preserving) -> String {
        String(decoding: encode(value, mode: mode), as: UTF8.self)
    }

    /// Dart `JsonEncoder.withIndent('  ').convert`: two spaces per level,
    /// LF line breaks, `"key": value`, one array element per line, `[]` and
    /// `{}` for empty containers, no trailing newline. Scalars are written
    /// exactly as `encode` writes them.
    public static func encodeIndented(_ value: JSONValue, mode: Mode = .preserving) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(4096)
        writeIndented(value, depth: 0, into: &out, mode: mode)
        return out
    }

    /// `_JsonPrettyPrinter.writeList` / `writeMap`.
    static func writeIndented(_ value: JSONValue, depth: Int, into out: inout [UInt8], mode: Mode) {
        func newline(_ level: Int) {
            out.append(0x0A)
            for _ in 0..<(level * 2) { out.append(0x20) }
        }
        switch value {
        case .array(let array):
            guard !array.isEmpty else {
                out.append(contentsOf: "[]".utf8)
                return
            }
            out.append(UInt8(ascii: "["))
            for (index, element) in array.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                newline(depth + 1)
                writeIndented(element, depth: depth + 1, into: &out, mode: mode)
            }
            newline(depth)
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            let members = mode == .dartCanonical ? canonicalMembers(object) : object.members.map { ($0.key, $0.value) }
            guard !members.isEmpty else {
                out.append(contentsOf: "{}".utf8)
                return
            }
            out.append(UInt8(ascii: "{"))
            for (index, (key, element)) in members.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                newline(depth + 1)
                writeString(key, into: &out, mode: mode)
                out.append(contentsOf: ": ".utf8)
                writeIndented(element, depth: depth + 1, into: &out, mode: mode)
            }
            newline(depth)
            out.append(UInt8(ascii: "}"))
        default:
            write(value, into: &out, mode: mode)
        }
    }

    /// Dart map semantics: a repeated key keeps its first position and
    /// takes its last value. Keys compare by decoded code units.
    static func canonicalMembers(_ object: JSONObject) -> [(JSONString, JSONValue)] {
        var order: [[UInt16]] = []
        var latest: [[UInt16]: (JSONString, JSONValue)] = [:]
        for member in object.members {
            let units = member.key.codeUnits
            if latest[units] == nil { order.append(units) }
            latest[units] = (member.key, member.value)
        }
        return order.map { latest[$0]! }
    }

    static func write(_ value: JSONValue, into out: inout [UInt8], mode: Mode) {
        switch value {
        case .null:
            out.append(contentsOf: "null".utf8)
        case .bool(let bool):
            out.append(contentsOf: (bool ? "true" : "false").utf8)
        case .number(let number):
            switch mode {
            case .preserving: out.append(contentsOf: number.lexeme.utf8)
            case .dartCanonical: out.append(contentsOf: number.dartCanonicalLexeme.utf8)
            }
        case .string(let string):
            writeString(string, into: &out, mode: mode)
        case .array(let array):
            out.append(UInt8(ascii: "["))
            for (index, element) in array.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                write(element, into: &out, mode: mode)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let object):
            out.append(UInt8(ascii: "{"))
            switch mode {
            case .preserving:
                for (index, member) in object.members.enumerated() {
                    if index > 0 { out.append(UInt8(ascii: ",")) }
                    writeString(member.key, into: &out, mode: mode)
                    out.append(UInt8(ascii: ":"))
                    write(member.value, into: &out, mode: mode)
                }
            case .dartCanonical:
                // Dart map semantics: a repeated key keeps its first position
                // and takes its last value. Keys compare by decoded code units.
                var order: [[UInt16]] = []
                var latest: [[UInt16]: (JSONString, JSONValue)] = [:]
                for member in object.members {
                    let units = member.key.codeUnits
                    if latest[units] == nil { order.append(units) }
                    latest[units] = (member.key, member.value)
                }
                for (index, units) in order.enumerated() {
                    if index > 0 { out.append(UInt8(ascii: ",")) }
                    let (key, value) = latest[units]!
                    writeString(key, into: &out, mode: mode)
                    out.append(UInt8(ascii: ":"))
                    write(value, into: &out, mode: mode)
                }
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    static func writeString(_ string: JSONString, into out: inout [UInt8], mode: Mode) {
        out.append(UInt8(ascii: "\""))
        switch mode {
        case .preserving: out.append(contentsOf: string.lexeme.utf8)
        case .dartCanonical: out.append(contentsOf: string.dartCanonicalLexeme.utf8)
        }
        out.append(UInt8(ascii: "\""))
    }

    /// Dart `_JsonStringifier.writeStringContent`, returning the escaped text
    /// (without quotes). Operates on UTF-16 code units like Dart.
    public static func escape(codeUnits units: [UInt16]) -> String {
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        let count = units.count
        for i in 0..<count {
            let unit = units[i]
            if unit > 0x5C {
                if unit >= 0xD800 {
                    let isLead = unit & 0xFC00 == 0xD800
                    let isTrail = unit & 0xFC00 == 0xDC00
                    let lone =
                        (isLead && !(i + 1 < count && units[i + 1] & 0xFC00 == 0xDC00))
                        || (isTrail && !(i >= 1 && units[i - 1] & 0xFC00 == 0xD800))
                    if lone {
                        out.append(contentsOf: [0x5C, 0x75, 0x64])  // \ud
                        out.append(hexDigit((unit >> 8) & 0xF))
                        out.append(hexDigit((unit >> 4) & 0xF))
                        out.append(hexDigit(unit & 0xF))
                        continue
                    }
                }
                out.append(unit)
                continue
            }
            if unit < 0x20 {
                out.append(0x5C)
                switch unit {
                case 0x08: out.append(0x62)  // b
                case 0x09: out.append(0x74)  // t
                case 0x0A: out.append(0x6E)  // n
                case 0x0C: out.append(0x66)  // f
                case 0x0D: out.append(0x72)  // r
                default:
                    out.append(contentsOf: [0x75, 0x30, 0x30])  // u00
                    out.append(hexDigit((unit >> 4) & 0xF))
                    out.append(hexDigit(unit & 0xF))
                }
            } else if unit == 0x22 || unit == 0x5C {
                out.append(0x5C)
                out.append(unit)
            } else {
                out.append(unit)
            }
        }
        // Every surrogate left in `out` is paired, so this is lossless.
        return String(decoding: out, as: UTF16.self)
    }

    private static func hexDigit(_ value: UInt16) -> UInt16 {
        value < 10 ? 0x30 + value : 0x57 + value  // lowercase, as Dart
    }
}
