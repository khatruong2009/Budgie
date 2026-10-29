import Foundation
import Testing

@testable import BudgieCore

@Suite("JSON: Dart-compatible encoding")
struct DartEncodingTests {
    let numbers = try! Fixtures.jsonObject("logic/numbers.json") as! [String: Any]

    @Test("every double formats exactly like Dart jsonEncode (7000+ vectors)")
    func doubles() throws {
        let vectors = numbers["doubles"] as! [[String: Any]]
        #expect(vectors.count > 7000)
        var failures: [String] = []
        for vector in vectors {
            let bits = UInt64(vector["bits"] as! String, radix: 16)!
            let value = Double(bitPattern: bits)
            let expected = vector["json"] as! String
            let actual = DartDouble.format(value)
            if actual != expected { failures.append("\(vector["bits"]!): dart \(expected) swift \(actual)") }
            // The lexeme must parse back to the identical bits.
            let lexeme = JSONNumber(double: value)!
            if lexeme.doubleValue.bitPattern != bits && value != 0 {
                failures.append("round trip \(expected)")
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(20))")
    }

    @Test("ints format like Dart")
    func ints() {
        for vector in numbers["ints"] as! [[String: Any]] {
            let value = Int64(vector["value"] as! String)!
            #expect(JSONNumber(int: value).lexeme == vector["json"] as! String)
        }
    }

    @Test("string escaping matches Dart, including lone surrogates")
    func strings() {
        for vector in numbers["strings"] as! [[String: Any]] {
            let units = (vector["codeUnits"] as! [Int]).map { UInt16($0) }
            let json = vector["json"] as! String
            let escaped = "\"" + DartJSON.escape(codeUnits: units) + "\""
            #expect(escaped == json, "units \(units)")
            // Parsing Dart's output yields the same code units back.
            let parsed = try! JSONParser.parse(json)
            guard case .string(let string) = parsed else {
                Issue.record("not a string")
                continue
            }
            #expect(string.codeUnits == units)
            #expect(DartJSON.encodeString(parsed, mode: .dartCanonical) == json)
        }
    }

    @Test("decode then re-encode matches Dart (dup keys, exotic numbers, escapes)")
    func decodeReencode() throws {
        for vector in numbers["decodeReencode"] as! [[String: Any]] {
            let input = vector["input"] as! String
            let parsed = try JSONParser.parse(input)
            #expect(DartJSON.encodeString(parsed, mode: .dartCanonical) == vector["reencoded"] as! String, "\(input)")
        }
    }
}

@Suite("JSON: lossless round trip of every Flutter-written file")
struct LosslessRoundTripTests {
    @Test("header and payload of every fixture store file re-encode byte for byte")
    func everyStoreFile() throws {
        var checked = 0
        for file in try Fixtures.allStoreFiles() {
            let bytes = [UInt8](try Data(contentsOf: file))
            guard let newline = bytes.firstIndex(of: 0x0A), newline > 0 else { continue }
            let header = Array(bytes[..<newline])
            let payload = Array(bytes[(newline + 1)...])
            // Damaged fixtures are expected not to parse; skip what fails.
            if let value = try? JSONParser.parse(header) {
                #expect(DartJSON.encode(value) == header, "\(file.path)")
            }
            if let value = try? JSONParser.parse(payload) {
                #expect(DartJSON.encode(value) == payload, "\(file.path)")
                checked += 1
            }
        }
        #expect(checked > 30)
    }

    @Test("canonical encoding of the typical store equals Dart jsonEncode(jsonDecode(payload))")
    func canonicalMatchesDart() throws {
        let expected = try Fixtures.jsonObject("store/typical/expected.json") as! [String: Any]
        let sections = (expected["load"] as! [String: Any])["sections"] as! [String: Any]
        let dartText = sections["json"] as! String
        let bytes = [UInt8](try Fixtures.data("store/typical/input/financial_store_v2.json"))
        let payload = Array(bytes[(bytes.firstIndex(of: 0x0A)! + 1)...])
        let canonical = DartJSON.encodeString(try JSONParser.parse(payload), mode: .dartCanonical)
        #expect(canonical == dartText)
    }
}

@Suite("JSON: parser strictness matches Dart jsonDecode")
struct ParserStrictnessTests {
    @Test(arguments: [
        "", " ", "01", "1.", ".5", "-", "+1", "1e", "1e+", "[1,]", "{\"a\":1,}", "{a:1}",
        "'x'", "\"\\x\"", "\"\\u12\"", "\"a\u{01}b\"", "[1] 2", "\u{FEFF}{}", "NaN", "Infinity",
        "tru", "nul", "[", "{\"a\"}", "\"unterminated",
    ])
    func rejects(_ input: String) {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(input) }
    }

    @Test(arguments: [
        "0", "-0", "-0.0", "1e5", "1E+5", "1e-5", "0.1", "[]", "{}", " \t\n\r{} ", "\"\\/\"",
        "\"\\uD83D\\uDE00\"", "\"\\ud83d\"", "[[[[]]]]", "{\"\":null}",
    ])
    func accepts(_ input: String) throws {
        _ = try JSONParser.parse(input)
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: JSONParseError.invalidUTF8) { try JSONParser.parse([0x7B, 0xFF, 0xFE, 0x7D]) }
    }

    @Test func rejectsDeepNesting() {
        let limit = JSONParser.maxDepth
        let ok = String(repeating: "[", count: limit) + String(repeating: "]", count: limit)
        #expect(throws: Never.self) { try JSONParser.parse(ok) }
        let deep = String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1)
        #expect(throws: JSONParseError.nestingTooDeep) { try JSONParser.parse(deep) }
    }
}

@Suite("JSON: object patching keeps unknown data")
struct ObjectPatchTests {
    @Test func patchKeepsOrderAndUnknownKeys() throws {
        let source = #"{"id":"a","merchant":{"x":1.0},"amount":1200.0,"note":"\ud83d"}"#
        guard case .object(var object) = try JSONParser.parse(source) else { Issue.record(); return }
        object["amount"] = .double(12.5)
        object["new"] = .null
        #expect(DartJSON.encodeString(.object(object))
            == #"{"id":"a","merchant":{"x":1.0},"amount":12.5,"note":"\ud83d","new":null}"#)
    }

    @Test func duplicateKeysFollowDartSemantics() throws {
        guard case .object(var object) = try JSONParser.parse(#"{"b":1,"a":2,"b":3}"#) else { Issue.record(); return }
        #expect(object["b"]?.numberValue?.lexeme == "3")
        #expect(object.keys == ["b", "a"])
        object["b"] = .int(4)
        #expect(DartJSON.encodeString(.object(object)) == #"{"b":4,"a":2}"#)
    }
}
