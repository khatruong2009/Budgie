import Foundation
import Testing

@testable import BudgieCore

/// Zones the insight fixtures were generated in: the harness zones (one of
/// them, America/Santiago, has a midnight skipped by DST).
let insightZones = fixtureZones

/// budget_app/test/insight_engine_test.dart, in every insight zone.
@Suite("Insights: the Dart engine tests")
struct InsightEngineDartTests {
    struct Setup {
        let calendar: DartCalendar
        let now: DartDateTime
        var counter = 0

        init(_ zone: String) {
            calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
            now = calendar.date(2026, 7, 10)
        }

        mutating func expense(
            _ amount: Double, _ date: DartDateTime, description: String = "Purchase", category: String = "General",
            template: String? = nil
        ) -> TransactionRecord {
            counter += 1
            return TransactionRecord.make(
                id: "t\(counter)", type: .expense, description: description, amount: amount, category: category,
                date: date, recurringTemplateId: template, now: now)
        }

        mutating func income(_ amount: Double, _ date: DartDateTime) -> TransactionRecord {
            counter += 1
            return TransactionRecord.make(
                id: "t\(counter)", type: .income, description: "Paycheck", amount: amount, category: "Salary", date: date, now: now)
        }

        func generate(
            _ transactions: [TransactionRecord], budgets: [(String, Double)] = [], goals: [SavingsGoalRecord] = [],
            excluded: [String] = [], limit: Int = 3
        ) -> [LocalInsight] {
            InsightEngine.generate(
                transactions: transactions, budgetLimits: budgets, savingsGoals: goals,
                selectedMonth: calendar.date(2026, 7), now: now, excludedIDs: excluded, limit: limit, calendar: calendar)
        }
    }

    @Test("flags category spending that is well ahead of calendar pace", arguments: insightZones)
    func pace(zone: String) {
        var s = Setup(zone)
        let insights = s.generate(
            [s.expense(80, s.calendar.date(2026, 7, 5), category: "Groceries")], budgets: [("Groceries", 100)])
        let pace = insights.filter { $0.type == .budgetPace }
        #expect(pace.count == 1)
        #expect(pace.first?.severity == .warning)
        #expect(pace.first?.explanation.contains("80%") == true)
    }

    @Test("detects duplicate transactions with an explainable stable id", arguments: insightZones)
    func duplicate(zone: String) {
        var s = Setup(zone)
        let transactions = [
            s.expense(24.5, s.calendar.date(2026, 7, 4, 9), description: "Corner Cafe", category: "Eating Out"),
            s.expense(24.5, s.calendar.date(2026, 7, 4, 18), description: "Corner Cafe", category: "Eating Out"),
        ]
        let first = s.generate(transactions)
        let second = s.generate(transactions)
        #expect(first.count == 1 && second.count == 1)
        #expect(first.first?.type == .possibleDuplicate)
        #expect(first.first?.id == second.first?.id)
        #expect(first.first?.explanation.contains("same amount and date") == true)
    }

    @Test("detects a changed recurring amount", arguments: insightZones)
    func recurring(zone: String) {
        var s = Setup(zone)
        let insights = s.generate([
            s.expense(100, s.calendar.date(2026, 6, 2), description: "Internet", template: "internet"),
            s.expense(120, s.calendar.date(2026, 7, 2), description: "Internet", template: "internet"),
        ])
        #expect(insights.contains { $0.type == .recurringAmountChange })
    }

    @Test("flags three consecutive negative cash-flow months", arguments: insightZones)
    func negativeFlow(zone: String) {
        var s = Setup(zone)
        var transactions: [TransactionRecord] = []
        for month in [5, 6, 7] {
            transactions.append(s.income(1000, s.calendar.date(2026, month, 1)))
            transactions.append(s.expense(1200, s.calendar.date(2026, month, 2)))
        }
        let insight = s.generate(transactions).first
        #expect(insight?.type == .negativeCashFlow)
        #expect(insight?.severity == .urgent)
    }

    @Test("flags a goal materially behind its elapsed schedule", arguments: insightZones)
    func goal(zone: String) throws {
        let s = Setup(zone)
        let json = try JSONParser.parse(
            #"{"id":"emergency","name":"Emergency fund","targetAmount":1000.0,"currentAmount":100.0,"# +
                #""targetDate":"2026-10-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null}"#)
        let goal = try #require(SavingsGoalRecord.parse(json, calendar: s.calendar, now: s.now, newID: { "unused" }))
        let insights = s.generate([], goals: [goal])
        #expect(insights.count == 1)
        #expect(insights.first?.type == .goalBehindSchedule)
        #expect(insights.first?.headline.contains("Emergency fund") == true)
    }

    @Test("honors exclusions and requested result limit", arguments: insightZones)
    func exclusions(zone: String) {
        var s = Setup(zone)
        let transactions = [
            s.expense(40, s.calendar.date(2026, 7, 3), description: "Cafe"),
            s.expense(40, s.calendar.date(2026, 7, 3), description: "Cafe"),
            s.expense(90, s.calendar.date(2026, 7, 5), category: "Groceries"),
        ]
        let all = s.generate(transactions, budgets: [("Groceries", 100)], limit: 10)
        #expect(all.count == 2)
        let filtered = s.generate(transactions, budgets: [("Groceries", 100)], excluded: [all[0].id], limit: 1)
        #expect(filtered.count == 1)
        #expect(filtered.first?.id != all[0].id)
    }

    @Test("does not create change insights from sparse data", arguments: insightZones)
    func sparse(zone: String) {
        var s = Setup(zone)
        let insights = s.generate([
            s.expense(100, s.calendar.date(2026, 6, 2)),
            s.expense(200, s.calendar.date(2026, 7, 2)),
        ])
        #expect(!insights.contains { $0.type == .monthlySpendingChange })
    }
}

@Suite("Insights: engine details")
struct InsightEngineDetailTests {
    @Test("slug: trim, Dart lowercase, runs outside [a-z0-9] become one dash")
    func slug() {
        #expect(InsightEngine.slug("  Rent 2026! ") == "rent-2026")
        #expect(InsightEngine.slug("--a--b--") == "a-b")
        #expect(InsightEngine.slug("\u{130}stanbul") == "istanbul")
        #expect(InsightEngine.slug("\u{212A}elvin") == "kelvin")
        #expect(InsightEngine.slug("Stra\u{DF}e") == "stra-e")
        #expect(InsightEngine.slug("\u{3A3}\u{39F}\u{3A6}\u{399}\u{391}") == "")
        #expect(InsightEngine.slug("\u{FEFF}x\u{FEFF}") == "x")
        #expect(InsightEngine.slug("") == "")
    }

    @Test("round: half away from zero, saturating, throwing on NaN and infinities")
    func round() throws {
        #expect(try InsightEngine.dartRound(2.5) == 3)
        #expect(try InsightEngine.dartRound(-2.5) == -3)
        #expect(try InsightEngine.dartRound(0.49999999999999994) == 0)
        #expect(try InsightEngine.dartRound(1e302) == Int.max)
        #expect(try InsightEngine.dartRound(-1e302) == Int.min)
        #expect(throws: InsightEngine.NotFinite.self) { try InsightEngine.dartRound(.nan) }
        #expect(throws: InsightEngine.NotFinite.self) { try InsightEngine.dartRound(.infinity) }
    }

    @Test("a limit of zero or less returns nothing, even for data that would throw")
    func nonPositiveLimit() {
        let calendar = DartCalendar(timeZone: TimeZone(identifier: "UTC")!)
        let now = calendar.date(2026, 7, 10)
        let row = TransactionRecord.make(
            id: "a", type: .expense, description: "x", amount: 90, category: "G", date: now, now: now)
        for limit in [0, -1] {
            #expect(InsightEngine.generate(
                transactions: [row], budgetLimits: [("G", 100)], savingsGoals: [], selectedMonth: now, now: now,
                limit: limit, calendar: calendar).isEmpty)
        }
    }

    @Test("excluded ids match by UTF-16 code units, not canonical equivalence")
    func excludedCodeUnits() {
        let calendar = DartCalendar(timeZone: TimeZone(identifier: "UTC")!)
        let now = calendar.date(2026, 7, 10)
        let rows = (0..<2).map {
            TransactionRecord.make(
                id: "r\($0)", type: .expense, description: "K", amount: 5, category: "G",
                date: calendar.date(2026, 7, 4, $0), now: now)
        }
        func run(_ excluded: [String]) -> Int {
            InsightEngine.generate(
                transactions: rows, budgetLimits: [], savingsGoals: [], selectedMonth: now, now: now,
                excludedIDs: excluded, calendar: calendar
            ).count
        }
        let id = "duplicate:expense:k:5.00:2026-07-04T00:00:00.000"
        #expect(run([id]) == 0)
        // U+212A KELVIN SIGN is canonically equivalent to "K" in Swift.
        #expect(run([id.uppercased().replacingOccurrences(of: "K", with: "\u{212A}")]) == 1)
    }

    /// The research budget is about 20ms for 10k rows in a release build
    /// (measured about 10ms). `swift test` builds debug, where the same call
    /// takes about 60ms alone and up to about 110ms while the other suites
    /// run in parallel. So the check is the calling thread's CPU time (a busy
    /// machine does not count), best of three, against 150ms in debug and
    /// 20ms in release, plus the growth from 2,500 to 10,000 rows: about 4x
    /// for the linear passes, 16x for an accidental O(n^2) rule, so more
    /// than 8x fails even when the absolute bound is noisy.
    @Test("10k rows: every rule within budget, growing linearly")
    func large() {
        let calendar = DartCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
        let now = calendar.date(2026, 9, 28, 9, 15)
        let rows = generatedFlowRows(seed: 777, count: 10_000, startYear: 2022, months: 60).map {
            TransactionRecord.parse($0, calendar: calendar, newID: { "unused" })!
        }
        let limits: [(String, Double)] = [("Groceries", 500), ("Travel", 800), ("Housing", 3000), ("Caf\u{E9}", 100)]
        var result: [LocalInsight] = []
        func cpuMilliseconds(_ rows: [TransactionRecord]) -> Double {
            (0..<3).map { _ in
                let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                result = InsightEngine.generate(
                    transactions: rows, budgetLimits: limits, savingsGoals: [], selectedMonth: calendar.month(of: now),
                    now: now, limit: 1000, calendar: calendar)
                return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
            }.min()!
        }
        let quarter = cpuMilliseconds(Array(rows.prefix(2_500)))
        let full = cpuMilliseconds(rows)
        #expect(!result.isEmpty)
        #if DEBUG
        let budget = 150.0
        #else
        let budget = 20.0
        #endif
        #expect(full < budget, "took \(full)ms")
        #expect(full < quarter * 8, "2,500 rows \(quarter)ms, 10,000 rows \(full)ms")
    }
}

/// Swift-only checks of the preference load quirks and writes (the Dart
/// fixture, prefs.json, covers what Flutter can load without throwing).
@Suite("Insights: preferences")
struct InsightPreferencesTests {
    let zone = TimeZone(identifier: "America/New_York")!
    var calendar: DartCalendar { DartCalendar(timeZone: zone) }

    func load(_ dismissed: PreferenceValue?, _ snoozed: PreferenceValue?) -> InsightPreferences {
        InsightPreferences.load(dismissed: dismissed, snoozed: snoozed, timeZone: zone)
    }

    @Test("wrong-typed values read as absent (Dart throws and hides the section)")
    func wrongTypes() {
        let store = InMemoryPreferences([
            InsightPreferences.dismissedKey: .string("a"),
            InsightPreferences.snoozedKey: .stringList(["{}"]),
        ])
        let prefs = InsightPreferences.load(from: store, timeZone: zone)
        #expect(prefs.dismissed.isEmpty && prefs.snoozed.isEmpty)
        #expect(load(.bool(true), .int(5)) == InsightPreferences())
        #expect(load(.double(1), .double(2)) == InsightPreferences())
        #expect(store.stringList(InsightPreferences.dismissedKey) == nil)
    }

    @Test("a list holding a non-string reads as absent through UserDefaults")
    func mixedList() {
        #expect(UserDefaultsPreferences.decode(["a", 1] as [Any]) == nil)
        #expect(UserDefaultsPreferences.decode(["a", "b"] as [Any]) == .stringList(["a", "b"]))
    }

    @Test("snoozed JSON quirks")
    func snoozedQuirks() {
        let future = "2026-10-01T09:00:00.000"
        func ids(_ raw: String) -> [String] { load(nil, .string(raw)).snoozed.map(\.id) }
        for raw in ["", "not json", "[]", "\"x\"", "5", "null", "{}", "\u{FEFF}{\"a\":\"\(future)\"}", "{\"a\":\"\(future)\",}"] {
            #expect(ids(raw).isEmpty, "\(raw)")
        }
        #expect(ids("{\"a\":\"\(future)\",\"b\":5,\"c\":\"\(future)\"}") == ["a"])
        #expect(ids("{\"a\":\"\(future)\",\"b\":null,\"c\":\"\(future)\"}") == ["a"])
        #expect(ids("{\"a\":\"\(future)\",\"b\":[\"\(future)\"],\"c\":\"\(future)\"}") == ["a"])
        #expect(ids("{\"a\":\"garbage\",\"b\":\"\",\"c\":\"\(future)\"}") == ["c"])
        // A repeated key keeps its first position and its last value, before
        // the loop sees it: the non-string first value no longer aborts.
        #expect(ids("{\"a\":5,\"b\":\"\(future)\",\"a\":\"\(future)\"}") == ["a", "b"])
        #expect(ids("{\"a\":\"\(future)\",\"b\":\"\(future)\",\"a\":5}") == [])
        // Keys are code units: NFC and NFD stay apart.
        #expect(ids("{\"caf\u{E9}\":\"\(future)\",\"cafe\u{301}\":\"\(future)\"}").count == 2)
        let forms = load(nil, .string(
            "{\"z\":\"2026-10-01T13:00:00Z\",\"o\":\"2026-10-01T09:00+05:30\",\"c\":\"20261001\",\"s\":\"2026-10-01 09:00\"}"))
        #expect(forms.snoozed.map(\.until.isUtc) == [true, true, false, false])
        #expect(forms.snoozed[1].until.toIso8601String() == "2026-10-01T03:30:00.000Z")
        #expect(forms.snoozed[2].until.toIso8601String() == "2026-10-01T00:00:00.000")
    }

    @Test("excluded: dismissed plus snoozes strictly after now")
    func excluded() throws {
        let now = calendar.date(2026, 7, 10, 9)
        let prefs = load(
            .stringList(["d", "d", "x"]),
            .string(
                "{\"past\":\"2026-07-10T08:59:59.999999\",\"now\":\"2026-07-10T09:00:00.000\",\"after\":\"2026-07-10T09:00:00.000001\",\"utc\":\"2026-07-10T13:00:00.001Z\"}"))
        #expect(prefs.dismissed == ["d", "x"])
        #expect(prefs.excludedIDs(now: now) == ["d", "x", "after", "utc"])
    }

    @Test("dismiss writes the whole set sorted by code units; snoozes untouched")
    func dismiss() {
        var prefs = load(.stringList(["b", "\u{3A9}", "a", "b", "Z", "e\u{301}", "\u{E9}"]), .string("not json"))
        let write = prefs.dismiss("c")
        #expect(write.key == "flutter.local_insights_dismissed_v1")
        #expect(write.value == .stringList(["Z", "a", "b", "c", "e\u{301}", "\u{E9}", "\u{3A9}"]))
        if case .stringList(let list) = write.value {
            #expect(list.map { Array($0.utf16) } == ["Z", "a", "b", "c", "e\u{301}", "\u{E9}", "\u{3A9}"].map { Array($0.utf16) })
        }
        // Dismissing again changes nothing but still rewrites.
        #expect(prefs.dismiss("a").value == write.value)
        #expect(prefs.snoozed.isEmpty)
    }

    @Test("snooze: now + 30 x 24h, compact JSON in insertion order, re-snooze keeps position")
    func snooze() {
        let now = calendar.date(2026, 10, 20, 9, 0, 0, 123, 456)
        var prefs = load(nil, .string("{\"a\":\"2026-11-01T00:00:00.000Z\",\"bad\":\"x\",\"b\":\"20261101\",\"c\":7,\"d\":\"2027-01-01\"}"))
        let first = prefs.snooze("new \"quoted\" \u{2028}", now: now)
        #expect(first.key == "flutter.local_insights_snoozed_v1")
        #expect(first.value == .string(
            "{\"a\":\"2026-11-01T00:00:00.000Z\",\"b\":\"2026-11-01T00:00:00.000\",\"new \\\"quoted\\\" \u{2028}\":\"2026-11-19T08:00:00.123456\"}"))
        let second = prefs.snooze("a", now: now)
        #expect(second.value == .string(
            "{\"a\":\"2026-11-19T08:00:00.123456\",\"b\":\"2026-11-01T00:00:00.000\",\"new \\\"quoted\\\" \u{2028}\":\"2026-11-19T08:00:00.123456\"}"))
        #expect(prefs.dismissed.isEmpty)
    }

    @Test("Santiago: 30 x 24h across the September change moves the wall clock")
    func snoozeSantiago() {
        let santiago = DartCalendar(timeZone: TimeZone(identifier: "America/Santiago")!)
        var prefs = InsightPreferences()
        let write = prefs.snooze("x", now: santiago.date(2026, 8, 20, 0, 15))
        #expect(write.value == .string("{\"x\":\"2026-09-19T01:15:00.000\"}"))
    }

    @Test("equality compares ids as code units")
    func equality() {
        let a = load(.stringList(["caf\u{E9}"]), nil)
        let b = load(.stringList(["cafe\u{301}"]), nil)
        #expect(a != b)
        #expect(a == load(.stringList(["caf\u{E9}", "caf\u{E9}"]), nil))
    }
}
