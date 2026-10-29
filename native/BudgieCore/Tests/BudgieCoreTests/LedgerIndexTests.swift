import Foundation
import Testing

@testable import BudgieCore

@Suite("LedgerIndex: one pass per revision, same answers as the Dart ledger")
struct LedgerIndexTests {
    @Test("matches the Dart model for every fixture", arguments: DomainParityTests.cases)
    func parity(_ path: String) async throws {
        let url = Fixtures.url(path)
        let scenario = try Scenario(url)
        let dart = try loadExpected(url)["appAfterGenerate"]
        guard dart.value != nil else { return }
        let known = inputIDs(scenario)  // before launch writes generated rows
        guard let data = try await launch(scenario) else { return }
        let calendar = data.calendar
        let index = LedgerIndex.build(data.transactions, calendar: calendar)

        #expect(index.availableMonths.map { $0.toIso8601String() } == dart["availableMonths"].array.compactMap(\.string), "\(path) months")
        #expect(index.newestFirst.map(\.id).filter(known.contains) == dart["sortedIds"].array.compactMap(\.string).filter(known.contains))
        for month in index.availableMonths {
            let key = calendar.netWorthMonthKey(month)
            let want = dart["monthly"][key]
            let summary = index.summary(forMonth: month)
            #expect(summary.income == want["totalIncome"].double && summary.expenses == want["totalExpenses"].double, "\(path) \(key)")
            #expect(summary.net == want["summary"]["net"].double, "\(path) \(key) net")
            // Same names, same (Dart map) order, same sums.
            #expect(summary.categoryExpenses.map(\.name) == want["categoryExpenses"].keys, "\(path) \(key) category order")
            for (name, amount) in summary.categoryExpenses {
                #expect(amount == want["categoryExpenses"][name].double, "\(path) \(key) \(name)")
            }
            #expect(summary.transactionCount == want["transactionIds"].array.count, "\(path) \(key) count")
            let expenseRows = data.transactions.filter { $0.type == .expense && calendar.ledgerMonthKey($0.date) == calendar.ledgerMonthKey(month) }
            #expect(summary.categoryExpenseCounts.count == summary.categoryExpenses.count)
            for ((name, _), count) in zip(summary.categoryExpenses, summary.categoryExpenseCounts) {
                #expect(expenseRows.filter { $0.category.utf16.elementsEqual(name.utf16) }.count == count)
            }
            let monthKey = calendar.ledgerMonthKey(month)
            #expect(index.newestFirst(inMonth: month).map(\.id) == index.newestFirst.filter { $0.monthKey == monthKey }.map(\.id), "\(path) \(key) month rows")
        }
        #expect(index.recent(3).map(\.id) == Array(index.newestFirst.prefix(3).map(\.id)))
        #expect(index.recent(0).isEmpty)
    }

    @Test("history is ascending; the rolling window is contiguous and zero-filled across years")
    func windows() {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let now = calendar.date(2026, 9, 28)
        let rows = [
            TransactionRecord.make(id: "a", type: .income, description: "Pay", amount: 100, category: "Salary",
                                   date: calendar.date(2025, 11, 30, 23, 59), now: now),
            TransactionRecord.make(id: "b", type: .expense, description: "Food", amount: 40, category: "Groceries",
                                   date: calendar.date(2026, 2, 1), now: now),
            TransactionRecord.make(id: "c", type: .expense, description: "More", amount: 2.5, category: "Groceries",
                                   date: calendar.date(2026, 2, 14), now: now),
        ]
        let index = LedgerIndex.build(rows, calendar: calendar)
        #expect(index.netCashFlowHistory.map { $0.month.toIso8601String() } == ["2025-11-01T00:00:00.000", "2026-02-01T00:00:00.000"])
        #expect(index.netCashFlowHistory.map(\.net) == [100, -42.5])
        let window = index.rollingNet(endingAt: calendar.date(2026, 2), months: 5)
        #expect(window.map { $0.month.toIso8601String().prefix(7) } == ["2025-10", "2025-11", "2025-12", "2026-01", "2026-02"])
        #expect(window.map(\.net) == [0, 100, 0, 0, -42.5])
        #expect(index.rollingNet(endingAt: now, months: 0).isEmpty)
        #expect(index.summary(forMonth: calendar.date(2026, 2)).categoryExpenseCounts == [2])
        #expect(index.summary(forMonth: calendar.date(2026, 3)).transactionCount == 0)
        #expect(index.newestFirst(inMonth: calendar.date(2026, 3)).isEmpty)
        let row = index.newestFirst[0]
        #expect(row.dayKey == 20260214 && row.monthKey == 2026 * 12 + 2 && row.descriptionLower == "more")
    }

    @Test("canonically equivalent names are two categories (UTF-16 keys) in the index and Dart")
    func canonicalEquivalents() throws {
        let nfc = "Caf\u{E9}", nfd = "Cafe\u{301}"
        #expect(nfc == nfd)  // Swift String equality is canonical; Dart's is not
        var data = homeData(JSONObject(ordered: []))
        let calendar = data.calendar
        let now = calendar.date(2026, 9, 28)
        for (i, (category, amount)) in [(nfc, 30.0), (nfd, 20.0), (nfc, 1.0), (nfd, 0.5), ("Other", 4.0)].enumerated() {
            _ = data.addTransaction(
                type: .expense, description: "x", amount: amount, category: category, date: calendar.date(2026, 9, 1 + i),
                id: "r\(i)", now: now)
        }
        let month = calendar.date(2026, 9)
        let summary = LedgerIndex.build(data.transactions, calendar: calendar).summary(forMonth: month)
        #expect(summary.categoryExpenses.map { Array($0.name.utf16) } == [nfc, nfd, "Other"].map { Array($0.utf16) })
        #expect(summary.categoryExpenses.map(\.amount) == [31, 20.5, 4])
        #expect(summary.categoryExpenseCounts == [2, 2, 1])

        // Dart: the Spend fixture's "unicode" month holds both spellings.
        let cases = try Fixtures.json("spend/breakdowns.json")["cases"].array
        let unicode = try #require(cases.first { $0["dataset"].string == "unicode" })
        let dart = homeData(try JSONParser.parse(unicode["sections"].string!).objectValue!)
        let dartMonth = try dart.calendar.parse(unicode["months"][0]["month"].string!)
        let dartSummary = LedgerIndex.build(dart.transactions, calendar: dart.calendar).summary(forMonth: dartMonth)
        func key(_ name: String, _ amountBits: String, _ count: Int) -> String { "\(Array(name.utf16)) \(amountBits) \(count)" }
        let want = unicode["months"][0]["mirror"]["records"].array.map {
            key($0["name"].string!, $0["amount"].string!, $0["count"].int!)
        }
        let got = zip(dartSummary.categoryExpenses, dartSummary.categoryExpenseCounts).map {
            key($0.0.name, hex($0.0.amount), $0.1)
        }
        #expect(got.count == want.count && Set(got) == Set(want))
        #expect(dartSummary.categoryExpenses.filter { $0.name == nfc }.count == 2)
    }

    @Test("builds the 10k-row store in well under a second")
    func timing() async throws {
        let scenario = try Scenario(Fixtures.url("store/large_10k"))
        let data = try #require(try await launch(scenario))
        #expect(data.transactions.count >= 10_000)
        let clock = ContinuousClock()
        var index = LedgerIndex.empty(calendar: data.calendar)
        let elapsed = clock.measure { index = LedgerIndex.build(data.transactions, calendar: data.calendar) }
        print("LedgerIndex.build(\(data.transactions.count) rows): \(elapsed)")
        #expect(index.newestFirst.count == data.transactions.count)
        #expect(elapsed < .seconds(1))
    }
}

private func hex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}
