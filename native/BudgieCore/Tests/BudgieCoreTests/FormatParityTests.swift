import Foundation
import Testing

@testable import BudgieCore

@Suite("DartDateFormat and DartString match intl / Dart String output")
struct FormatParityTests {
    @Test("every en_US pattern the app uses, against intl")
    func dateFormats() throws {
        let fixture = try Fixtures.json("logic/date_formats.json")
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let formatters: [String: (DartDateTime) -> String] = [
            "MMMM": DartDateFormat.MMMM, "MMM": DartDateFormat.MMM, "y": DartDateFormat.y,
            "MMMd": DartDateFormat.MMMd, "yMMMd": DartDateFormat.yMMMd, "MMM d, y": DartDateFormat.yMMMd,
            "MMM dd, yyyy": DartDateFormat.MMMddyyyy, "yMMMM": DartDateFormat.yMMMM, "MMMM y": DartDateFormat.yMMMM,
            "MMMM yyyy": DartDateFormat.MMMMyyyy, "yMMMMd": DartDateFormat.yMMMMd, "MMM ''yy": DartDateFormat.MMMyy,
            "EEEE": DartDateFormat.EEEE, "EEEE, MMM dd, yyyy": DartDateFormat.EEEEMMMddyyyy,
            "yyyy-MM-dd": DartDateFormat.yyyyMMdd, "yyyy-MM": DartDateFormat.yyyyMM, "jm": DartDateFormat.jm,
        ]
        let cases = fixture["cases"].array
        #expect(cases.count == 12)
        for c in cases {
            let f = c["fields"].array.compactMap(\.int)
            let date = calendar.date(f[0], f[1], f[2], f[3], f[4])
            #expect(Set(c["formats"].keys) == Set(formatters.keys))
            for key in c["formats"].keys {
                #expect(formatters[key]!(date) == c["formats"][key].string, "\(key) \(f)")
            }
        }
    }

    /// The VM's Unicode 5.1 case tables: later mappings (Cherokee, Georgian
    /// Mtavruli, Osage, Adlam, ...) are not applied.
    @Test("Dart toLowerCase for every scalar")
    func lowercaseEveryScalar() throws {
        let fixture = try Fixtures.json("logic/lower.json")
        var expected: [UInt32: [UInt16]] = [:]
        for entry in fixture["lower"].array {
            expected[UInt32(entry[0].int!)] = entry[1].array.map { UInt16($0.int!) }
        }
        #expect(expected.count > 1000)
        var mismatches: [UInt32] = []
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let text = String(Character(scalar))
            let want = expected[value] ?? Array(text.utf16)
            if Array(DartString.lowercase(text).utf16) != want { mismatches.append(value) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count): \(mismatches.prefix(20).map { String($0, radix: 16) })")
    }

    @Test("trim, toLowerCase, ==, contains, startsWith, compareTo over an awkward corpus")
    func strings() throws {
        let fixture = try Fixtures.json("logic/strings.json")
        let single = fixture["single"].array
        #expect(single.count > 20)
        for c in single {
            let s = c["s"].string!
            #expect(Array(DartString.trim(s).utf16) == Array(c["trim"].string!.utf16), "trim \(Array(s.unicodeScalars))")
            #expect(Array(DartString.lowercase(s).utf16) == Array(c["lower"].string!.utf16), "lower \(s)")
        }
        let pairs = fixture["pairs"].array
        #expect(pairs.count == single.count * single.count)
        for p in pairs {
            let a = p["a"].string!, b = p["b"].string!
            #expect(DartString.equal(a, b) == p["equal"].bool, "== \(a) \(b)")
            #expect(DartString.contains(a, b) == p["contains"].bool, "contains \(a) \(b)")
            #expect(DartString.hasPrefix(a, b) == p["startsWith"].bool, "startsWith \(a) \(b)")
            let compare = p["compare"].int!
            #expect(DartString.precedes(a, b) == (compare < 0), "compare \(a) \(b)")
            #expect(DartString.precedes(b, a) == (compare > 0), "compare \(b) \(a)")
        }
    }
}
