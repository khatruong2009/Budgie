import Foundation
import Testing

@testable import BudgieCore

/// Zones the parity harness ran Dart under (native/ParityHarness/run.sh).
/// America/Santiago changes DST at midnight: 2026-09-06 00:00-00:59 does not
/// exist and 2026-04-04 23:00-23:59 happens twice.
let fixtureZones = ["America/New_York", "UTC", "Australia/Lord_Howe", "Asia/Kolkata", "America/Santiago"]

/// Asia/Beirut (2026-03-29 00:00-00:59 missing, 2026-10-24 23:00-23:59
/// twice): only the logic generator (dates, generator, safe-to-spend) runs
/// under it. Flow, spend, recurring, insights and the rest do not.
let beirutZones = ["Asia/Beirut"]

/// The zones of Fixtures/logic/tz.
let logicZones = fixtureZones + beirutZones

/// Zones of Fixtures/worth and Fixtures/goals: a DST change at 02:00 (New
/// York), at midnight (Santiago), of 30 minutes (Lord Howe), and two zones
/// without one (Kolkata with a half-hour offset, UTC).
let dstFixtureZones = ["America/New_York", "America/Santiago", "Australia/Lord_Howe", "Asia/Kolkata", "UTC"]

func zoneDirectory(_ zone: String) -> String {
    Fixtures.zonePath("logic", zone)
}

func expectDart(_ actual: DartDateTime, _ expected: [String: Any], _ context: String) {
    #expect(actual.toIso8601String() == expected["iso"] as! String, "\(context) iso")
    #expect(actual.microsecondsSinceEpoch == (expected["us"] as! NSNumber).int64Value, "\(context) us")
    #expect(actual.isUtc == expected["isUtc"] as! Bool, "\(context) isUtc")
    #expect(actual.weekday == expected["weekday"] as! Int, "\(context) weekday")
}

@Suite("Dates: DartDateTime matches the Dart VM")
struct DateTests {
    @Test("DateTime.parse vectors", arguments: logicZones)
    func parse(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let fixture = try Fixtures.jsonObject(zoneDirectory(zone) + "/dates.json") as! [String: Any]
        for vector in fixture["parse"] as! [[String: Any]] {
            let input = vector["input"] as! String
            if let result = vector["result"] as? [String: Any] {
                let parsed = try DartDateTime.parse(input, timeZone: tz)
                expectDart(parsed, result, "\(zone) parse \(input)")
            } else {
                #expect(DartDateTime.tryParse(input, timeZone: tz) == nil, "\(zone) should reject \(input)")
            }
        }
    }

    @Test("constructor normalisation, end of month/day", arguments: logicZones)
    func constructed(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let cal = DartCalendar(timeZone: tz)
        let fixture = try Fixtures.jsonObject(zoneDirectory(zone) + "/dates.json") as! [String: Any]
        for vector in fixture["constructed"] as! [[String: Any]] {
            let label = vector["label"] as! String
            let actual: DartDateTime
            if label.hasPrefix("eom ") || label.hasPrefix("eod ") {
                let n = label.dropFirst(4).split(separator: ",").map { Int($0)! }
                actual = label.hasPrefix("eom ")
                    ? cal.endOfNetWorthMonth(cal.date(n[0], n[1]))
                    : cal.endOfNetWorthDay(cal.date(n[0], n[1], n[2]))
            } else {
                let n = label.split(separator: ",").map { Int($0)! }
                actual = cal.date(
                    n[0], n.count > 1 ? n[1] : 1, n.count > 2 ? n[2] : 1, n.count > 3 ? n[3] : 0,
                    n.count > 4 ? n[4] : 0)
            }
            expectDart(actual, vector, "\(zone) \(label)")
        }
    }

    @Test("Duration(days:) arithmetic, inDays, isSameDay", arguments: logicZones)
    func arithmetic(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let cal = DartCalendar(timeZone: tz)
        let fixture = try Fixtures.jsonObject(zoneDirectory(zone) + "/dates.json") as! [String: Any]
        for vector in fixture["arithmetic"] as! [[String: Any]] {
            let start = vector["start"] as! [String: Any]
            let base = DartDateTime(
                microsecondsSinceEpoch: (start["us"] as! NSNumber).int64Value, timeZone: tz)
            expectDart(base, start, "\(zone) start")
            let added = base.adding(days: vector["days"] as! Int)
            expectDart(added, vector["added"] as! [String: Any], "\(zone) add")
            #expect(added.differenceInDays(base) == vector["differenceInDays"] as! Int)
            #expect(cal.isSameDay(added, base) == vector["sameDay"] as! Bool)
        }
        for vector in fixture["inDays"] as! [[String: Any]] {
            let a = vector["a"] as! [String: Any]
            let b = vector["b"] as! [String: Any]
            let x = DartDateTime(microsecondsSinceEpoch: (a["us"] as! NSNumber).int64Value, timeZone: tz)
            let y = DartDateTime(microsecondsSinceEpoch: (b["us"] as! NSNumber).int64Value, timeZone: tz)
            #expect(x.differenceInDays(y) == vector["inDays"] as! Int, "\(zone) inDays")
        }
    }

    @Test("net worth month/day keys", arguments: logicZones)
    func keys(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let cal = DartCalendar(timeZone: tz)
        let fixture = try Fixtures.jsonObject(zoneDirectory(zone) + "/dates.json") as! [String: Any]
        for vector in fixture["keys"] as! [[String: Any]] {
            let d = vector["date"] as! [String: Any]
            let value = DartDateTime(microsecondsSinceEpoch: (d["us"] as! NSNumber).int64Value, timeZone: tz)
            #expect(cal.netWorthMonthKey(value) == vector["monthKey"] as! String)
            #expect(cal.netWorthDayKey(value) == vector["dayKey"] as! String)
            expectDart(cal.netWorthMonthFromKey(vector["monthKey"] as! String)!, vector["monthFromKey"] as! [String: Any], "\(zone) fromKey")
        }
    }

    @Test("every stored date string in the typical store round-trips through parse/format")
    func storedStringsRoundTrip() throws {
        let tz = TimeZone(identifier: "America/New_York")!
        let text = try String(contentsOf: Fixtures.url("store/typical/input/financial_store_v2.json"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #""(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}(\d{3})?)""#)
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        #expect(matches.count > 300)
        var mismatches: [String] = []
        for match in matches {
            let value = String(text[Range(match.range(at: 1), in: text)!])
            let formatted = try DartDateTime.parse(value, timeZone: tz).toIso8601String()
            // Only the DST-gap wall time is expected to move (Dart does the same).
            if formatted != value && !value.hasPrefix("2026-03-08T02:") { mismatches.append(value) }
        }
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
    }
}
