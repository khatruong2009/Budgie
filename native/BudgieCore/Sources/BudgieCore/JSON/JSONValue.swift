/// A JSON value that remembers exactly how it was written.
///
/// The Flutter app writes JSON with Dart's `jsonEncode`. To keep data the
/// Swift app does not understand, and to write files the Flutter app reads
/// back without surprises, every value keeps its source text:
///
/// - objects keep their keys in source order (duplicates included);
/// - numbers keep their lexeme (`1200.0` stays `1200.0`, never `1200`);
/// - strings keep their escaped lexeme (lone UTF-16 surrogates, which a Swift
///   `String` cannot hold, survive untouched).
///
/// Values created in Swift are formatted the way Dart's `jsonEncode` would
/// format them (see `DartJSON`).
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(JSONString)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - Numbers

/// A JSON number and its exact lexeme.
public struct JSONNumber: Hashable, Sendable {
    /// The text as it appears in the JSON source, e.g. `1200.0`, `5`, `1e-7`.
    public let lexeme: String

    init(lexeme: String) {
        self.lexeme = lexeme
    }

    /// A Dart `double`, formatted as Dart's `jsonEncode` would. `nil` for
    /// NaN and infinities, which Dart cannot encode either.
    public init?(double value: Double) {
        guard value.isFinite else { return nil }
        lexeme = DartDouble.format(value)
    }

    /// A Dart `int`.
    public init(int value: Int64) {
        lexeme = String(value)
    }

    public init(int value: Int) {
        lexeme = String(value)
    }

    /// Whether Dart's `jsonDecode` yields an `int` for this lexeme: no
    /// fraction or exponent, and within the 64-bit range. Out-of-range
    /// integer lexemes decode to `double` in Dart.
    public var isDartInt: Bool {
        guard !lexeme.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) else { return false }
        return Int64(lexeme) != nil || lexeme == "-0"
    }

    /// The value as a double (what Dart's `num.toDouble()` gives).
    public var doubleValue: Double {
        if let int = Int64(lexeme) { return Double(int) }
        return Double(lexeme) ?? .nan
    }

    /// The value as an int if Dart would decode it as one.
    public var intValue: Int64? {
        guard isDartInt else { return nil }
        return Int64(lexeme) ?? 0
    }

    /// How Dart re-encodes this number after `jsonDecode`.
    public var dartCanonicalLexeme: String {
        if isDartInt { return String(Int64(lexeme) ?? 0) }
        return DartDouble.format(Double(lexeme) ?? 0)
    }
}

// MARK: - Strings

/// A JSON string and its exact escaped lexeme (the text between the quotes).
public struct JSONString: Hashable, Sendable {
    /// Escaped source text between the quotes, valid UTF-8.
    public let lexeme: String

    init(lexeme: String) {
        self.lexeme = lexeme
    }

    /// A Swift string, escaped the way Dart's `jsonEncode` escapes it.
    public init(_ value: String) {
        lexeme = DartJSON.escape(codeUnits: Array(value.utf16))
    }

    /// The decoded UTF-16 code units, exactly as Dart would hold them
    /// (lone surrogates included).
    public var codeUnits: [UInt16] {
        guard lexeme.utf8.contains(UInt8(ascii: "\\")) else { return Array(lexeme.utf16) }
        return JSONString.unescape(lexeme)
    }

    /// The decoded value. Lone surrogates, which only a malformed input can
    /// contain, become U+FFFD here; the lexeme keeps them.
    public var value: String {
        guard lexeme.utf8.contains(UInt8(ascii: "\\")) else { return lexeme }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    /// Dart `==` against `other`: the decoded UTF-16 code units are equal.
    func matches(_ other: String) -> Bool {
        let bytes = lexeme.utf8
        // Without escapes the lexeme is the value, and equal UTF-8 means
        // equal code units.
        if !bytes.contains(UInt8(ascii: "\\")) { return bytes.elementsEqual(other.utf8) }
        return codeUnits.elementsEqual(other.utf16)
    }

    /// How Dart re-encodes this string after `jsonDecode`.
    public var dartCanonicalLexeme: String {
        guard lexeme.utf8.contains(UInt8(ascii: "\\")) else { return lexeme }
        return DartJSON.escape(codeUnits: codeUnits)
    }

    /// Decodes a lexeme already validated by the parser.
    static func unescape(_ lexeme: String) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(lexeme.utf8.count)
        var bytes = Array(lexeme.utf8)[...]
        while let byte = bytes.first {
            if byte != UInt8(ascii: "\\") {
                // Copy one UTF-8 scalar as UTF-16.
                let length = byte < 0x80 ? 1 : byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
                let scalarBytes = bytes.prefix(length)
                bytes = bytes.dropFirst(length)
                out.append(contentsOf: String(decoding: scalarBytes, as: UTF8.self).utf16)
                continue
            }
            bytes = bytes.dropFirst()
            let escape = bytes.removeFirst()
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
                var unit: UInt16 = 0
                for _ in 0..<4 {
                    unit = unit << 4 | UInt16(hexValue(bytes.removeFirst()))
                }
                out.append(unit)
            default:
                preconditionFailure("parser admitted an invalid escape")
            }
        }
        return out
    }

    static func hexValue(_ byte: UInt8) -> UInt8 {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        default: return byte - UInt8(ascii: "A") + 10
        }
    }
}

// MARK: - Objects

/// A JSON object with keys in source order.
public struct JSONObject: Hashable, Sendable {
    public struct Member: Hashable, Sendable {
        public var key: JSONString
        public var value: JSONValue
    }

    public var members: [Member]

    public init(members: [Member] = []) {
        self.members = members
    }

    /// Builds an object in the given key order (keys are Swift strings).
    public init(_ pairs: KeyValuePairs<String, JSONValue>) {
        self.init(ordered: pairs.map { ($0.key, $0.value) })
    }

    public init(ordered pairs: [(String, JSONValue)]) {
        members = pairs.map { Member(key: JSONString($0.0), value: $0.1) }
    }

    /// Keys in first-occurrence order, as Dart's map iterates them. Keys are
    /// distinct as UTF-16 code units, as in Dart (Swift `==` would merge
    /// "é" and "e\u{301}").
    public var keys: [String] {
        var seen = Set<[UInt16]>()
        var result: [String] = []
        for member in members where seen.insert(member.key.codeUnits).inserted {
            result.append(member.key.value)
        }
        return result
    }

    /// Dart semantics: the last occurrence of a key wins. Keys compare as
    /// UTF-16 code units.
    public subscript(key: String) -> JSONValue? {
        get {
            members.last(where: { $0.key.matches(key) })?.value
        }
        set {
            guard let first = members.firstIndex(where: { $0.key.matches(key) }) else {
                if let newValue { members.append(Member(key: JSONString(key), value: newValue)) }
                return
            }
            if let newValue {
                // Replace in place (keeping the key's position and lexeme)
                // and drop later duplicates so the value is unambiguous.
                members[first].value = newValue
                var index = members.count - 1
                while index > first {
                    if members[index].key.matches(key) { members.remove(at: index) }
                    index -= 1
                }
            } else {
                members.removeAll { $0.key.matches(key) }
            }
        }
    }

    public func contains(_ key: String) -> Bool {
        members.contains { $0.key.matches(key) }
    }
}

// MARK: - Convenience

public extension JSONValue {
    static func string(_ value: String) -> JSONValue { .string(JSONString(value)) }
    static func int(_ value: Int) -> JSONValue { .number(JSONNumber(int: value)) }
    /// A Dart double. Traps on NaN/infinity: callers validate input first
    /// (Dart would throw at encode time; see `DartJSONError.nonFinite`).
    static func double(_ value: Double) -> JSONValue {
        guard let number = JSONNumber(double: value) else {
            preconditionFailure("non-finite double reached the JSON layer")
        }
        return .number(number)
    }

    var objectValue: JSONObject? {
        if case .object(let object) = self { return object }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let array) = self { return array }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string.value }
        return nil
    }

    var numberValue: JSONNumber? {
        if case .number(let number) = self { return number }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
