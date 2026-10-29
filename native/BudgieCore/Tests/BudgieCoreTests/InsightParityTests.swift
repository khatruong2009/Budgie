import Foundation
import Testing

@testable import BudgieCore

/// Fixtures written by native/ParityHarness/parity/insight_fixtures_test.dart
/// from the real InsightEngine and LocalInsightsSection.
private func insightFixture(_ relative: String) throws -> J {
    try Fixtures.json("insights/" + relative)
}

private func insightZoneFixture(_ zone: String, _ name: String) throws -> J {
    try Fixtures.json("\(Fixtures.zonePath("insights", zone))/\(name)")
}

private func hex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}

/// Dart string equality.
private func same(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return DartString.equal(a, b)
}

/// One recorded case: the inputs and the call, as the harness made it.
private struct InsightCall {
    let label: String
    let calendar: DartCalendar
    let now: DartDateTime
    let selectedMonth: DartDateTime
    let transactions: [TransactionRecord]
    let goals: [SavingsGoalRecord]
    let limits: [(String, Double)]
    let excluded: [String]
    let limit: Int

    init(_ k: J, calendar: DartCalendar) throws {
        self.calendar = calendar
        label = k["label"].string!
        now = try calendar.parse(k["now"].string!)
        selectedMonth = try calendar.parse(k["selectedMonth"].string!)
        transactions = try JSONParser.parse(k["rows"].string!).arrayValue!.map {
            TransactionRecord.parse($0, calendar: calendar, newID: { "unused" })!
        }
        let now = now
        goals = try JSONParser.parse(k["goals"].string!).arrayValue!.map {
            SavingsGoalRecord.parse($0, calendar: calendar, now: now, newID: { "unused" })!
        }
        limits = k["limits"].array.map { ($0[0].string!, bits($0[1])!) }
        excluded = k["excluded"].array.map { $0.string! }
        limit = k["limit"].int!
    }

    func run(excluded: [String], limit: Int) -> [LocalInsight] {
        InsightEngine.generate(
            transactions: transactions, budgetLimits: limits, savingsGoals: goals, selectedMonth: selectedMonth, now: now,
            excludedIDs: excluded, limit: limit, calendar: calendar)
    }
}

/// Differences between Swift's insights and the recorded Dart ones. A Dart
/// call that threw must give no insights.
private func differences(_ actual: [LocalInsight], _ expected: J, _ context: String) -> [String] {
    if expected["throws"].string != nil {
        return actual.isEmpty ? [] : ["\(context): Dart threw, Swift gave \(actual.map(\.id))"]
    }
    let rows = expected.array
    guard rows.count == actual.count else {
        return ["\(context): count \(actual.count) vs \(rows.count): \(actual.map(\.id)) vs \(rows.map { $0["id"].string ?? "?" })"]
    }
    var problems: [String] = []
    for (index, (insight, e)) in zip(actual, rows).enumerated() {
        let at = "\(context)[\(index)]"
        if !same(insight.id, e["id"].string) { problems.append("\(at) id \(insight.id) vs \(e["id"].string ?? "nil")") }
        if insight.type.rawValue != e["type"].string { problems.append("\(at) type \(insight.type) vs \(e["type"].string ?? "nil")") }
        if insight.severity.rawValue != e["severity"].string {
            problems.append("\(at) severity \(insight.severity) vs \(e["severity"].string ?? "nil")")
        }
        if !same(insight.headline, e["headline"].string) { problems.append("\(at) headline \(insight.headline) vs \(e["headline"].string ?? "nil")") }
        if !same(insight.explanation, e["explanation"].string) {
            problems.append("\(at) explanation \(insight.explanation) vs \(e["explanation"].string ?? "nil")")
        }
        if !same(insight.suggestedAction, e["action"].string) {
            problems.append("\(at) action \(insight.suggestedAction) vs \(e["action"].string ?? "nil")")
        }
        if insight.generatedDate.toIso8601String() != e["generatedDate"].string {
            problems.append("\(at) generatedDate \(insight.generatedDate.toIso8601String()) vs \(e["generatedDate"].string ?? "nil")")
        }
        let values = insight.supportingValues.map { "\($0.key)=\(hex($0.value))" }
        let expectedValues = e["values"].array.map { "\($0[0].string ?? "?")=\($0[1].string ?? "?")" }
        if values != expectedValues { problems.append("\(at) values \(values) vs \(expectedValues)") }
    }
    return problems
}

private func check(_ file: String, zone: String) throws {
    let calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
    let fixture = try insightZoneFixture(zone, file)
    #expect(fixture["tz"].string == zone)
    let cases = fixture["cases"].array
    #expect(!cases.isEmpty)
    var problems: [String] = []
    for k in cases {
        let call = try InsightCall(k, calendar: calendar)
        let full = call.run(excluded: [], limit: 1000)
        problems += differences(full, k["full"], "\(call.label) full")
        let result = call.run(excluded: call.excluded, limit: call.limit)
        problems += differences(result, k["result"], "\(call.label) result")
        // The call is the full list minus exclusions, cut at the limit.
        if k["full"]["throws"].string == nil {
            let excluded = Set(call.excluded.map { Array($0.utf16) })
            let expected = full.filter { !excluded.contains(Array($0.id.utf16)) }.prefix(max(call.limit, 0))
            if Array(expected) != result { problems.append("\(call.label): result is not the filtered prefix of full") }
        }
    }
    #expect(problems.isEmpty, "\(problems.count) differences in \(file) (\(zone)):\n\(problems.prefix(20).joined(separator: "\n"))")
}

@Suite("Insights: InsightEngine matches Dart")
struct InsightParityTests {
    @Test("named scenarios", arguments: insightZones)
    func cases(zone: String) throws {
        try check("cases.json", zone: zone)
    }

    @Test("random differential", arguments: insightZones)
    func random(zone: String) throws {
        try check("random.json", zone: zone)
    }

    @Test("slug matches the engine's `_slug`")
    func slugs() throws {
        let pairs = try insightFixture("slugs.json")["slugs"].array
        #expect(pairs.count > 200)
        let wrong = pairs.filter { !same(InsightEngine.slug($0[0].string!), $0[1].string!) }
            .map { "\($0[0].string!.debugDescription) -> \(InsightEngine.slug($0[0].string!)) vs \($0[1].string!)" }
        #expect(wrong.isEmpty, "\(wrong.prefix(20).joined(separator: "\n"))")
    }
}

// MARK: - Preferences through the real section

/// A typed preference as the harness records it ({"type", "value"}).
private func preferenceValue(_ typed: J) -> PreferenceValue? {
    switch typed["type"].string {
    case "string": return typed["value"].string.map { .string($0) }
    case "stringList": return .stringList(typed["value"].array.map { $0.string! })
    default: return nil
    }
}

private func sameValue(_ a: PreferenceValue?, _ b: PreferenceValue?) -> Bool {
    switch (a, b) {
    case (.string(let x)?, .string(let y)?): return DartString.equal(x, y)
    case (.stringList(let x)?, .stringList(let y)?):
        return x.count == y.count && zip(x, y).allSatisfy { DartString.equal($0, $1) }
    case (nil, nil): return true
    default: return false
    }
}

@Suite("Insights: preferences replay LocalInsightsSection")
struct InsightPreferencesParityTests {
    @Test("load, snooze, dismiss and reload as the Flutter section does", arguments: insightZones)
    func replay(zone: String) throws {
        let timeZone = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: timeZone)
        let fixture = try insightZoneFixture(zone, "prefs.json")
        var problems: [String] = []
        var steps = 0
        for scenario in fixture["scenarios"].array {
            let start = try calendar.parse(scenario["start"].string!)
            let selected = try calendar.parse(scenario["selectedMonth"].string!)
            let rows = try JSONParser.parse(scenario["rows"].string!).arrayValue!.map {
                TransactionRecord.parse($0, calendar: calendar, newID: { "unused" })!
            }
            for c in scenario["cases"].array {
                let label = "\(scenario["start"].string!) \(c["label"].string!)"
                var initial: [String: PreferenceValue] = [:]
                for key in c["initial"].keys { initial[key] = preferenceValue(c["initial"][key]) }
                let store = InMemoryPreferences(initial)
                var prefs = InsightPreferences.load(from: store, timeZone: timeZone)
                var now = start
                func visible() -> [LocalInsight] {
                    InsightEngine.generate(
                        transactions: rows, budgetLimits: [], savingsGoals: [], selectedMonth: selected, now: now,
                        excludedIDs: prefs.excludedIDs(now: now), calendar: calendar)
                }
                var cards = visible()
                for (index, step) in c["steps"].array.enumerated() {
                    steps += 1
                    let at = "\(label) step \(index) \(step["op"].string!)"
                    switch step["op"].string! {
                    case "load":
                        break
                    case "snooze":
                        let write = prefs.snooze(cards[step["index"].int!].id, now: now)
                        store.set(write.value, forKey: write.key)
                    case "dismiss":
                        let write = prefs.dismiss(cards[step["index"].int!].id)
                        store.set(write.value, forKey: write.key)
                    case "reload":
                        now = try calendar.parse(step["at"].string!)
                        prefs = InsightPreferences.load(from: store, timeZone: timeZone)
                    default:
                        problems.append("\(at): unknown op")
                    }
                    cards = visible()
                    let texts = cards.map { [$0.headline, $0.explanation, $0.suggestedAction] }
                    let expectedTexts = step["cards"].array.map { $0.array.map { $0.string! } }
                    if texts.count != expectedTexts.count
                        || !zip(texts, expectedTexts).allSatisfy({ $0.count == $1.count && zip($0, $1).allSatisfy(DartString.equal) })
                    {
                        problems.append("\(at): cards \(texts.map { $0[1] }) vs \(expectedTexts.map { $0.count > 1 ? $0[1] : "?" })")
                    }
                    let expectedKeys = step["prefs"].keys
                    let storedKeys = store.allKeys().filter { $0.contains("local_insights") }
                    if Set(expectedKeys) != Set(storedKeys) { problems.append("\(at): keys \(storedKeys) vs \(expectedKeys)") }
                    for key in expectedKeys where !sameValue(store.value(forKey: key), preferenceValue(step["prefs"][key])) {
                        problems.append("\(at): \(key) \(String(describing: store.value(forKey: key))) vs \(String(describing: preferenceValue(step["prefs"][key])))")
                    }
                }
            }
        }
        #expect(steps > 300)
        #expect(problems.isEmpty, "\(problems.count) differences (\(zone)):\n\(problems.prefix(20).joined(separator: "\n"))")
    }
}
