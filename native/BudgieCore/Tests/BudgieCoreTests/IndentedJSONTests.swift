import Foundation
import Testing

@testable import BudgieCore

@Suite("Backup: indented JSON matches JsonEncoder.withIndent('  ') (Fixtures/backup)")
struct IndentedJSONTests {
    @Test("every Dart vector, byte for byte, and a lexeme-preserving round trip")
    func vectors() throws {
        let fixture = try Fixtures.json("backup/indent_vectors.json")
        let cases = fixture["cases"].array
        #expect(cases.count > 200)
        for vector in cases {
            let input = fixtureBytes(vector["json"])
            let expected = fixtureBytes(vector["indented"])
            let parsed = try JSONParser.parse(input)
            let actual = DartJSON.encodeIndented(parsed, mode: .dartCanonical)
            #expect(actual == expected, "\(String(decoding: input, as: UTF8.self))")
            // Dart's output is canonical: re-reading it and writing its
            // lexemes gives the same bytes, and the compact form agrees.
            let reparsed = try JSONParser.parse(expected)
            #expect(DartJSON.encodeIndented(reparsed) == expected)
            #expect(DartJSON.encode(reparsed) == DartJSON.encode(parsed, mode: .dartCanonical))
        }
    }

    @Test("layout rules")
    func layout() {
        let value = JSONValue.object(JSONObject(ordered: [
            ("a", .array([])), ("b", .object(JSONObject())), ("c", .array([.int(1), .array([])])),
        ]))
        func text(_ value: JSONValue) -> String { String(decoding: DartJSON.encodeIndented(value), as: UTF8.self) }
        #expect(text(value) == "{\n  \"a\": [],\n  \"b\": {},\n  \"c\": [\n    1,\n    []\n  ]\n}")
        #expect(text(.array([])) == "[]")
        #expect(text(.string("x")) == "\"x\"")
    }
}
