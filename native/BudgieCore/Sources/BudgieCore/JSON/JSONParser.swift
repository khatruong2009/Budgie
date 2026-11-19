public enum JSONParseError: Error, Equatable, Sendable {
    case invalidUTF8
    case unexpectedEnd
    case unexpectedByte(offset: Int)
    case invalidNumber(offset: Int)
    case invalidEscape(offset: Int)
    case controlCharacterInString(offset: Int)
    case trailingContent(offset: Int)
    case nestingTooDeep
}

/// A strict RFC 8259 parser matching what Dart's `jsonDecode` accepts, that
/// keeps every lexeme (see `JSONValue`).
///
/// Input must be valid UTF-8 (Dart's `utf8.decode` rejects anything else, and
/// the store treats such a file as unreadable). Whitespace is space, tab, LF
/// and CR only; a byte order mark is not whitespace.
public struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    /// Dart has no nesting limit, but every structure the app writes is
    /// under 6 levels deep. The cap keeps recursion well inside a thread's
    /// stack; deeper input is rejected, never truncated.
    static let maxDepth = 128

    public static func parse(_ bytes: [UInt8]) throws(JSONParseError) -> JSONValue {
        guard UTF8Validation.isValid(bytes) else { throw .invalidUTF8 }
        var parser = JSONParser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == bytes.count else { throw .trailingContent(offset: parser.index) }
        return value
    }

    public static func parse(_ text: String) throws(JSONParseError) -> JSONValue {
        try parse(Array(text.utf8))
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private func peek() throws(JSONParseError) -> UInt8 {
        guard index < bytes.count else { throw .unexpectedEnd }
        return bytes[index]
    }

    private mutating func expectLiteral(_ literal: String) throws(JSONParseError) {
        for byte in literal.utf8 {
            guard index < bytes.count else { throw .unexpectedEnd }
            guard bytes[index] == byte else { throw .unexpectedByte(offset: index) }
            index += 1
        }
    }

    private mutating func parseValue() throws(JSONParseError) -> JSONValue {
        switch try peek() {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .number(try parseNumber())
        default:
            throw .unexpectedByte(offset: index)
        }
    }

    private mutating func enter() throws(JSONParseError) {
        depth += 1
        if depth > JSONParser.maxDepth { throw .nestingTooDeep }
    }

    private mutating func parseObject() throws(JSONParseError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // {
        var members: [JSONObject.Member] = []
        skipWhitespace()
        if try peek() == UInt8(ascii: "}") {
            index += 1
            return .object(JSONObject(members: members))
        }
        while true {
            skipWhitespace()
            guard try peek() == UInt8(ascii: "\"") else { throw .unexpectedByte(offset: index) }
            let key = try parseString()
            skipWhitespace()
            guard try peek() == UInt8(ascii: ":") else { throw .unexpectedByte(offset: index) }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            members.append(JSONObject.Member(key: key, value: value))
            skipWhitespace()
            switch try peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"):
                index += 1
                return .object(JSONObject(members: members))
            default: throw .unexpectedByte(offset: index)
            }
        }
    }

    private mutating func parseArray() throws(JSONParseError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // [
        var elements: [JSONValue] = []
        skipWhitespace()
        if try peek() == UInt8(ascii: "]") {
            index += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            switch try peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"):
                index += 1
                return .array(elements)
            default: throw .unexpectedByte(offset: index)
            }
        }
    }

    private mutating func parseString() throws(JSONParseError) -> JSONString {
        index += 1  // opening quote
        let start = index
        while true {
            guard index < bytes.count else { throw .unexpectedEnd }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") { break }
            if byte < 0x20 { throw .controlCharacterInString(offset: index) }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { throw .unexpectedEnd }
                switch bytes[index] {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
                    UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"),
                    UInt8(ascii: "r"), UInt8(ascii: "t"):
                    index += 1
                case UInt8(ascii: "u"):
                    index += 1
                    for _ in 0..<4 {
                        guard index < bytes.count else { throw .unexpectedEnd }
                        guard bytes[index].isHexDigit else { throw .invalidEscape(offset: index) }
                        index += 1
                    }
                default:
                    throw .invalidEscape(offset: index)
                }
                continue
            }
            index += 1
        }
        let lexeme = String(decoding: bytes[start..<index], as: UTF8.self)
        index += 1  // closing quote
        return JSONString(lexeme: lexeme)
    }

    private mutating func skipDigits() {
        while index < bytes.count && bytes[index].isDigit { index += 1 }
    }

    private mutating func parseNumber() throws(JSONParseError) -> JSONNumber {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw .unexpectedEnd }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if bytes[index].isDigit {
            skipDigits()
        } else {
            throw .invalidNumber(offset: index)
        }
        if index < bytes.count && bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, bytes[index].isDigit else { throw .invalidNumber(offset: index) }
            skipDigits()
        }
        if index < bytes.count && (bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E")) {
            index += 1
            if index < bytes.count && (bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")) {
                index += 1
            }
            guard index < bytes.count, bytes[index].isDigit else { throw .invalidNumber(offset: index) }
            skipDigits()
        }
        return JSONNumber(lexeme: String(decoding: bytes[start..<index], as: UTF8.self))
    }
}

private extension UInt8 {
    var isDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
    var isHexDigit: Bool {
        isDigit || (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "f"))
            || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "F"))
    }
}

/// Strict UTF-8 validation (no overlong forms, no encoded surrogates, nothing
/// above U+10FFFF), as Dart's `utf8.decode` requires.
enum UTF8Validation {
    static func isValid(_ bytes: [UInt8]) -> Bool {
        var i = 0
        let n = bytes.count
        while i < n {
            let b0 = bytes[i]
            if b0 < 0x80 {
                i += 1
                continue
            }
            func continuation(_ offset: Int, _ range: ClosedRange<UInt8> = 0x80...0xBF) -> Bool {
                i + offset < n && range.contains(bytes[i + offset])
            }
            switch b0 {
            case 0xC2...0xDF:
                guard continuation(1) else { return false }
                i += 2
            case 0xE0:
                guard continuation(1, 0xA0...0xBF), continuation(2) else { return false }
                i += 3
            case 0xE1...0xEC, 0xEE...0xEF:
                guard continuation(1), continuation(2) else { return false }
                i += 3
            case 0xED:
                guard continuation(1, 0x80...0x9F), continuation(2) else { return false }
                i += 3
            case 0xF0:
                guard continuation(1, 0x90...0xBF), continuation(2), continuation(3) else { return false }
                i += 4
            case 0xF1...0xF3:
                guard continuation(1), continuation(2), continuation(3) else { return false }
                i += 4
            case 0xF4:
                guard continuation(1, 0x80...0x8F), continuation(2), continuation(3) else { return false }
                i += 4
            default:
                return false
            }
        }
        return true
    }
}
