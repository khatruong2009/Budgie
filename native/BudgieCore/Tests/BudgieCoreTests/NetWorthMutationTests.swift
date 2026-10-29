import Foundation
import Testing

@testable import BudgieCore

/// Ports of budget_app/test/transaction_model_net_worth_test.dart and the
/// account-row case of net_worth_page_widget_test.dart, plus the Swift-only
/// persistence rules. The clock is pinned to 2026-09-28 09:15 New York, so
/// January to July 2026 are past months (Dart's tests use the real clock).
@Suite("Net worth mutations (transaction_model_net_worth_test.dart and more)")
struct NetWorthMutationTests {
    let calendar = DartCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
    var now: DartDateTime { calendar.date(2026, 9, 28, 9, 15) }

    private var counter = 0
    private mutating func id() -> String {
        counter += 1
        return "id-\(counter)"
    }

    func empty(_ sections: JSONObject = JSONObject(), preferences: [String: PreferenceValue] = [:]) -> FinancialData {
        let now = self.now
        return FinancialData.load(
            FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences(preferences), calendar: calendar,
            now: { now }, newID: { UUID().uuidString.lowercased() }
        ).data
    }

    func section(_ data: FinancialData) -> String { DartJSON.encodeString(data.netWorthSection()) }

    // MARK: - Dart tests

    @Test("T1 net worth is driven by manual asset and liability balances")
    mutating func manualBalances() {
        var data = empty()
        let march = calendar.date(2026, 3)
        data.selectNetWorthMonth(march)
        data.addNetWorthEntry(name: "Checking", type: .asset, amount: 1000, month: march, id: id(), now: now)
        data.addNetWorthEntry(name: "Credit Card", type: .liability, amount: 400, month: march, id: id(), now: now)
        _ = data.addTransaction(type: .income, description: "Salary", amount: 250, category: "Income",
                                date: calendar.date(2026, 3, 15), id: id(), now: now)
        _ = data.addTransaction(type: .expense, description: "Groceries", amount: 100, category: "Food",
                                date: calendar.date(2026, 3, 16), id: id(), now: now)
        let marchSummary = LedgerIndex.build(data.transactions, calendar: calendar).summary(forMonth: march)
        #expect(marchSummary.income == 250)
        #expect(marchSummary.expenses == 100)
        #expect(data.totalAssets(forMonth: data.selectedNetWorthMonth) == 1000)
        #expect(data.totalLiabilities(forMonth: data.selectedNetWorthMonth) == 400)
        #expect(data.netWorth(forMonth: data.selectedNetWorthMonth) == 600)
    }

    @Test("T2 monthly balances can be carried forward and updated manually")
    mutating func carryForward() {
        var data = empty()
        let january = calendar.date(2026, 1), february = calendar.date(2026, 2)
        data.selectNetWorthMonth(january)
        data.addNetWorthEntry(name: "Brokerage", type: .asset, amount: 200000, month: january, id: id(), now: now)
        let mortgage = data.addNetWorthEntry(name: "Mortgage", type: .liability, amount: 150000, month: january, id: id(), now: now)!
        let didCarry = data.carryNetWorthMonthForward(february, now: now)
        data.updateNetWorthEntry(id: mortgage.id, name: mortgage.name, type: mortgage.type, amount: 149500, month: february, now: now)
        #expect(didCarry)
        #expect(data.totalAssets(forMonth: february) == 200000)
        #expect(data.totalLiabilities(forMonth: february) == 149500)
        #expect(data.netWorth(forMonth: february) == 50500)
        #expect(data.trackedNetWorthEntryCount(forMonth: february) == 2)
        let ok65 = data.updatedNetWorthEntryCount(forMonth: february) == 2
        #expect(ok65)
        #expect(data.staleNetWorthEntryCount(forMonth: february) == 0)
    }

    @Test("T3 available months stay newest-first when an older month is selected")
    mutating func availableMonths() {
        var data = empty()
        let n = now.fields
        let current = calendar.date(n.year, n.month), previous = calendar.date(n.year, n.month - 1)
        let older = calendar.date(n.year, n.month - 2)
        data.selectNetWorthMonth(previous)
        data.addNetWorthEntry(name: "Savings", type: .asset, amount: 5000, month: older, id: id(), now: now)
        #expect(data.netWorthAvailableMonths(now: now) == [current, previous, older])
    }

    @Test("T4 carried balances do not create synthetic month-end history points")
    mutating func noSyntheticPoints() {
        var data = empty()
        let january = calendar.date(2026, 1), february = calendar.date(2026, 2)
        data.addNetWorthEntry(name: "Savings", type: .asset, amount: 5000, month: january,
                              recordedAt: calendar.date(2026, 1, 20, 9), id: id(), now: now)
        data.selectNetWorthMonth(february)
        #expect(data.hasNetWorthData(forMonth: february))
        let ok88 = data.updatedNetWorthEntryCount(forMonth: february) == 0
        #expect(ok88)
        let history = data.netWorthHistory(limit: 10)
        #expect(history.count == 1)
        #expect(history.first?.date == calendar.date(2026, 1, 20))
        #expect(history.first?.netWorth == 5000)
        #expect(data.netWorthChange(forMonth: february) == nil)
    }

    @Test("T5 monthly change uses recorded balances from the previous month")
    mutating func monthlyChange() {
        var data = empty()
        let june = calendar.date(2026, 6), july = calendar.date(2026, 7)
        let brokerage = data.addNetWorthEntry(name: "Brokerage", type: .asset, amount: 200000, month: june,
                                              recordedAt: calendar.date(2026, 6, 20, 9), id: id(), now: now)!
        data.updateNetWorthEntry(id: brokerage.id, name: brokerage.name, type: brokerage.type, amount: 210000, month: july,
                                 recordedAt: calendar.date(2026, 7, 20, 9), now: now)
        #expect(data.netWorthChange(forMonth: july) == 10000)
    }

    @Test("T6 same-month net worth updates create separate history points")
    mutating func sameMonthPoints() {
        var data = empty()
        let march = calendar.date(2026, 3)
        data.selectNetWorthMonth(march)
        let checking = data.addNetWorthEntry(name: "Checking", type: .asset, amount: 1000, month: march,
                                             recordedAt: calendar.date(2026, 3, 10, 9), id: id(), now: now)!
        data.updateNetWorthEntry(id: checking.id, name: checking.name, type: checking.type, amount: 1400, month: march,
                                 recordedAt: calendar.date(2026, 3, 25, 17), now: now)
        let history = data.netWorthHistory(limit: 10)
        #expect(history.map(\.date) == [calendar.date(2026, 3, 25), calendar.date(2026, 3, 10)])
        #expect(history.map(\.netWorth) == [1400, 1000])
        #expect(history.map(\.assetCount) == [1, 1])
        #expect(history.map(\.liabilityCount) == [0, 0])
        #expect(history.allSatisfy { $0.granularity == .day })
        #expect(data.netWorth(forMonth: march) == 1400)
    }

    @Test("T7 older daily points compress into monthly snapshots when history is crowded")
    mutating func compression() {
        var data = empty()
        data.selectNetWorthMonth(calendar.date(2026, 3))
        let checking = data.addNetWorthEntry(name: "Checking", type: .asset, amount: 1000, month: calendar.date(2026, 1),
                                             recordedAt: calendar.date(2026, 1, 2, 9), id: id(), now: now)!
        for (amount, m, d) in [(1100.0, 1, 10), (1200, 1, 20), (1300, 2, 5), (1400, 2, 18), (1500, 3, 8)] {
            data.updateNetWorthEntry(id: checking.id, name: checking.name, type: checking.type, amount: amount,
                                     month: calendar.date(2026, m), recordedAt: calendar.date(2026, m, d, 9), now: now)
        }
        let history = data.netWorthHistory(limit: 4)
        #expect(history.count == 4)
        #expect(history.map(\.date) == [
            calendar.date(2026, 3, 8), calendar.date(2026, 2, 18), calendar.date(2026, 2, 5), calendar.date(2026, 1, 31, 23, 59, 59, 999),
        ])
        #expect(history.map(\.granularity) == [.day, .day, .day, .month])
        #expect(history[3].netWorth == 1200)
    }

    @Test("T8 individual net worth snapshots can be deleted without deleting the account")
    mutating func deleteSnapshot() {
        var data = empty()
        let march = calendar.date(2026, 3)
        data.selectNetWorthMonth(march)
        let brokerage = data.addNetWorthEntry(name: "Brokerage", type: .asset, amount: 1000, month: march,
                                              recordedAt: calendar.date(2026, 3, 1, 9), id: id(), now: now)!
        data.updateNetWorthEntry(id: brokerage.id, name: brokerage.name, type: brokerage.type, amount: 1500, month: march,
                                 recordedAt: calendar.date(2026, 3, 20, 9), now: now)
        let ok153 = data.deleteNetWorthSnapshot(entryID: brokerage.id, recordedAt: calendar.date(2026, 3, 1, 9))
        #expect(ok153)
        let remaining = data.netWorthEntries.first!
        #expect(data.netWorthEntries.count == 1)
        #expect(remaining.name == "Brokerage")
        #expect(data.netWorthEntryHistory(id: remaining.id).map(\.amount) == [1500])
        #expect(data.netWorthHistory(limit: 10).map(\.netWorth) == [1500])
    }

    @Test("T9 legacy baseline values migrate into tracked accounts")
    func legacyBaseline() {
        let data = empty(preferences: [PreferenceKey.startingAssets: .double(3200), PreferenceKey.startingLiabilities: .double(900)])
        let month = data.selectedNetWorthMonth
        #expect(data.netWorthEntries.count == 2)
        #expect(data.totalAssets(forMonth: month) == 3200)
        #expect(data.totalLiabilities(forMonth: month) == 900)
        #expect(data.netWorth(forMonth: month) == 2300)
    }

    /// net_worth_page_widget_test.dart:44: the share and the change are
    /// separate numbers.
    @Test("account rows separate allocation percentage from percent change")
    mutating func rowPercentages() {
        var data = empty()
        let march = calendar.date(2026, 3)
        data.selectNetWorthMonth(march)
        let brokerage = data.addNetWorthEntry(name: "Brokerage", type: .asset, amount: 1000, month: march,
                                              recordedAt: calendar.date(2026, 3, 1, 9), id: id(), now: now)!
        data.updateNetWorthEntry(id: brokerage.id, name: brokerage.name, type: brokerage.type, amount: 1500, month: march,
                                 recordedAt: calendar.date(2026, 3, 20, 9), now: now)
        data.addNetWorthEntry(name: "Savings", type: .asset, amount: 400, month: march,
                              recordedAt: calendar.date(2026, 3, 20, 9), id: id(), now: now)
        let total = data.totalAssets(forMonth: march)
        var labels: [String] = []
        for entry in data.netWorthEntries(forMonth: march, type: .asset) {
            let stats = entry.rowStats(forMonth: march, categoryTotal: total, calendar: calendar)
            labels += [NetWorthText.rowShare(stats.share, isAssetsTab: true), NetWorthText.rowChange(stats.percentChange)]
        }
        #expect(labels == ["78.9% of assets", "+50.0%", "21.1% of assets", "\u{2014}"])
        #expect(!labels.contains("+78.9%"))
    }

    // MARK: - Defaults and edge cases

    @Test("default snapshot date: now in the current month, else the end-of-month sentinel")
    func defaultDate() {
        let data = empty()
        #expect(data.defaultSnapshotDate(forMonth: calendar.date(2026, 9, 17, 23), now: now) == now)
        #expect(data.defaultSnapshotDate(forMonth: calendar.date(2026, 8, 3), now: now).toIso8601String() == "2026-08-31T23:59:59.999")
        #expect(data.defaultSnapshotDate(forMonth: calendar.date(2026, 10), now: now).toIso8601String() == "2026-10-31T23:59:59.999")
    }

    @Test("empty or whitespace names are a no-op; names are trimmed like Dart")
    mutating func names() {
        var data = empty()
        let ok207 = data.addNetWorthEntry(name: " \u{FEFF}\u{3000}", type: .asset, amount: 1, id: id(), now: now) == nil
        #expect(ok207)
        #expect(data.netWorthRows.isEmpty)
        let entry = data.addNetWorthEntry(name: "\u{FEFF} Mortgage \n", type: .liability, amount: 1, id: id(), now: now)!
        #expect(entry.name == "Mortgage")
        #expect(entry.raw["name"]?.stringValue == "Mortgage")
        let before = section(data)
        let ok213 = !data.updateNetWorthEntry(id: entry.id, name: "   ", type: .asset, amount: 2, now: now)
        #expect(ok213)
        #expect(section(data) == before)
    }

    @Test("a past month re-save replaces its sentinel; the current month appends a now-stamped snapshot")
    mutating func resave() {
        var data = empty()
        let august = calendar.date(2026, 8), september = calendar.date(2026, 9)
        let entry = data.addNetWorthEntry(name: "Cash", type: .asset, amount: 10, month: august, id: id(), now: now)!
        data.updateNetWorthEntry(id: entry.id, name: "Cash", type: .asset, amount: 11, month: august, now: now)
        #expect(data.netWorthEntry(id: entry.id)!.snapshots.map(\.amount) == [11])
        data.updateNetWorthEntry(id: entry.id, name: "Cash", type: .asset, amount: 12, month: september, now: now)
        data.updateNetWorthEntry(id: entry.id, name: "Cash", type: .asset, amount: 12, month: september, now: now.adding(microseconds: 1))
        #expect(data.netWorthEntry(id: entry.id)!.snapshots.map(\.amount) == [11, 12, 12])
        // Same instant again: replaced, not duplicated.
        data.updateNetWorthEntry(id: entry.id, name: "Cash", type: .asset, amount: 13, month: september, now: now.adding(microseconds: 1))
        #expect(data.netWorthEntry(id: entry.id)!.snapshots.map(\.amount) == [11, 12, 13])
    }

    @Test("a type change moves the whole history to the other side")
    mutating func typeChange() {
        var data = empty()
        let entry = data.addNetWorthEntry(name: "Card", type: .asset, amount: 100, month: calendar.date(2026, 6), id: id(), now: now)!
        data.updateNetWorthEntry(id: entry.id, name: "Card", type: .liability, amount: 50, month: calendar.date(2026, 7), now: now)
        #expect(data.totalAssets(forMonth: calendar.date(2026, 6)) == 0)
        #expect(data.totalLiabilities(forMonth: calendar.date(2026, 6)) == 100)
        #expect(data.netWorthEntry(id: entry.id)!.raw["type"]?.stringValue == "liability")
    }

    @Test("delete entry and delete snapshot report whether anything changed")
    mutating func deletes() {
        var data = empty()
        let entry = data.addNetWorthEntry(name: "A", type: .asset, amount: 1, month: calendar.date(2026, 6), id: id(), now: now)!
        let before = section(data)
        let ok247 = !data.deleteNetWorthSnapshot(entryID: entry.id, recordedAt: calendar.date(2026, 6, 30))
        #expect(ok247)
        let ok248 = !data.deleteNetWorthSnapshot(entryID: "missing", recordedAt: entry.snapshots[0].recordedAt)
        #expect(ok248)
        let ok249 = !data.deleteNetWorthEntry(id: "missing")
        #expect(ok249)
        #expect(section(data) == before)
        // The last snapshot may go (the UI prevents it): no value in any month.
        let ok252 = data.deleteNetWorthSnapshot(entryID: entry.id, recordedAt: entry.snapshots[0].recordedAt)
        #expect(ok252)
        #expect(data.netWorthEntry(id: entry.id)!.snapshots.isEmpty)
        #expect(data.hasNetWorthEntries && !data.hasNetWorthData(forMonth: calendar.date(2026, 6)))
        let ok255 = data.deleteNetWorthEntry(id: entry.id)
        #expect(ok255)
        #expect(!data.hasNetWorthEntries)
        #expect(section(data) == "[]")
    }

    @Test("carry forward: false when there is nothing to carry; the current month is stamped now")
    mutating func carryCurrent() {
        var data = empty()
        let ok263 = !data.carryNetWorthMonthForward(calendar.date(2026, 9), now: now)
        #expect(ok263)
        data.addNetWorthEntry(name: "A", type: .asset, amount: 5, month: calendar.date(2026, 7), id: id(), now: now)
        let ok265 = data.carryNetWorthMonthForward(calendar.date(2026, 9, 15), now: now)
        #expect(ok265)
        #expect(data.netWorthEntries[0].snapshots.last!.recordedAt == now)
        let ok267 = !data.carryNetWorthMonthForward(calendar.date(2026, 9), now: now)
        #expect(ok267)
    }

    @Test("the selected month is normalised, written as Dart's ISO string, and reloads")
    func selectedMonth() {
        var data = empty()
        data.selectNetWorthMonth(calendar.date(2026, 3, 17, 10, 45, 1, 2, 3))
        #expect(data.selectedNetWorthMonthSection().stringValue == "2026-03-01T00:00:00.000")
        var sections = JSONObject()
        sections[Section.selectedNetWorthMonth] = data.serializedSection(Section.selectedNetWorthMonth)
        #expect(empty(sections).selectedNetWorthMonth == calendar.date(2026, 3))
    }

    @Test("new entries: Dart key order, createdAt = now, double lexemes")
    mutating func newEntryShape() {
        var data = empty()
        let entry = data.addNetWorthEntry(name: "Checking", type: .asset, amount: 1000, month: calendar.date(2026, 3), id: "abc-1", now: now)!
        #expect(entry.createdAt == now)
        #expect(entry.raw.keys == ["id", "name", "type", "createdAt", "snapshots"])
        #expect(section(data) == #"[{"id":"abc-1","name":"Checking","type":"asset","createdAt":"2026-09-28T09:15:00.000","snapshots":[{"recordedAt":"2026-03-31T23:59:59.999","amount":1000.0}]}]"#)
    }

    @Test("NaN and infinity are rejected before anything changes")
    mutating func nonFinite() {
        var data = empty()
        let entry = data.addNetWorthEntry(name: "A", type: .asset, amount: 1, id: id(), now: now)!
        let before = section(data)
        for bad in [Double.nan, .infinity, -.infinity] {
            let ok295 = data.addNetWorthEntry(name: "B", type: .asset, amount: bad, id: id(), now: now) == nil
            #expect(ok295)
            let ok296 = !data.updateNetWorthEntry(id: entry.id, name: "A", type: .asset, amount: bad, now: now)
            #expect(ok296)
        }
        #expect(section(data) == before)
    }

    @Test("unreadable rows, unknown keys and legacy snapshots survive every mutation")
    mutating func preservation() throws {
        let stored = #"""
        [{"id":"a","name":"Keep","type":"asset","createdAt":"2026-01-01T00:00:00.000","color":"teal","snapshots":[{"recordedAt":"2026-02-01T00:00:00.000","amount":10,"note":"x"},{"monthKey":"2026-03","amount":20}]},
         {"id":7,"name":"Unreadable"},
         {"id":"b","name":"Other","type":"liability","createdAt":"2026-01-01T00:00:00.000","snapshots":[{"recordedAt":"2026-02-01T00:00:00.000","amount":1.50}]}]
        """#
        var sections = JSONObject()
        sections[Section.netWorthEntries] = try JSONParser.parse(stored)
        var data = empty(sections)
        #expect(data.netWorthRows.count == 3 && data.netWorthEntries.count == 2)
        let untouched = DartJSON.encodeString(data.netWorthRows[2].record.map { .object($0.raw) }!)

        data.updateNetWorthEntry(id: "a", name: "Keep", type: .asset, amount: 30, month: calendar.date(2026, 4), now: now)
        data.addNetWorthEntry(name: "New", type: .asset, amount: 1, id: id(), now: now)
        data.carryNetWorthMonthForward(calendar.date(2026, 5), now: now)
        data.deleteNetWorthSnapshot(entryID: "b", recordedAt: calendar.date(2026, 5, 31, 23, 59, 59, 999))
        data.deleteNetWorthEntry(id: "new-missing")

        let rows = data.netWorthSection().arrayValue!
        #expect(rows.count == 4)
        #expect(DartJSON.encodeString(rows[1]) == #"{"id":7,"name":"Unreadable"}"#)
        let a = rows[0].objectValue!
        #expect(a.keys == ["id", "name", "type", "createdAt", "color", "snapshots"])
        #expect(DartJSON.encodeString(a["snapshots"]!) == #"[{"recordedAt":"2026-02-01T00:00:00.000","amount":10,"note":"x"},{"recordedAt":"2026-03-01T00:00:00.000","amount":20.0},{"recordedAt":"2026-04-30T23:59:59.999","amount":30.0},{"recordedAt":"2026-05-31T23:59:59.999","amount":30.0}]"#)
        // "b" gained a carried snapshot and lost it again: its original
        // stored object is back, byte for byte.
        #expect(DartJSON.encodeString(rows[2]) == untouched)
    }

    @Test("every entry sharing an id is updated or deleted, as Dart's map/where do")
    mutating func duplicateIDs() throws {
        let row = #"{"id":"d","name":"Dup","type":"asset","createdAt":"2026-01-01T00:00:00.000","snapshots":[]}"#
        var sections = JSONObject()
        sections[Section.netWorthEntries] = try JSONParser.parse("[\(row),\(row)]")
        var data = empty(sections)
        let ok337 = data.updateNetWorthEntry(id: "d", name: "Dup", type: .asset, amount: 5, month: calendar.date(2026, 2), now: now)
        #expect(ok337)
        #expect(data.netWorthEntries.map { $0.snapshots.count } == [1, 1])
        let ok339 = data.deleteNetWorthEntry(id: "d")
        #expect(ok339)
        #expect(data.netWorthRows.isEmpty)
    }

    @Test("entries for a month sort by amount, then Dart-lowercased name in UTF-16 order, stably")
    mutating func ordering() {
        var data = empty()
        let march = calendar.date(2026, 3)
        for name in ["b", "B", "\u{1F600}x", "\u{FF41}", "a", "\u{130}"] {
            data.addNetWorthEntry(name: name, type: .asset, amount: 5, month: march, id: name, now: now)
        }
        data.addNetWorthEntry(name: "big", type: .asset, amount: 50, month: march, id: "big", now: now)
        // "big" first, then by Dart `toLowerCase` code units: "a", "b", "B"
        // (a tie, kept in insertion order), "i" (U+0130 lowercases to it),
        // the surrogate pair (0xD83D), U+FF41 (Swift's scalar order would put
        // U+FF41 before U+1F600).
        #expect(data.netWorthEntries(forMonth: march).map(\.id) == ["big", "a", "b", "B", "\u{130}", "\u{1F600}x", "\u{FF41}"])
    }

}
