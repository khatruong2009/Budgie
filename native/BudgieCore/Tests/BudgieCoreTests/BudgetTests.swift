import Foundation
import Testing

@testable import BudgieCore

@Suite("Budgets: limit mutations patch the stored object; Home rows")
struct BudgetTests {
    private func data(_ limits: String?, extra: String = "") -> FinancialData {
        var json = "{"
        if let limits { json += #""categoryBudgetLimits":\#(limits)"# }
        if !extra.isEmpty { json += (limits == nil ? "" : ",") + extra }
        json += "}"
        return homeData(try! JSONParser.parse(json).objectValue!)
    }

    private func section(_ data: FinancialData) -> String { DartJSON.encodeString(data.budgetLimitsSection()) }

    @Test("new keys append as double lexemes; existing keys keep their position; others keep their lexemes")
    func setKeepsLexemes() {
        var d = data(#"{"Groceries":100,"Travel":150.5}"#)
        do {
            let wrote = d.setBudgetLimit(category: "Health", limit: 100)
            #expect(wrote)
        }
        #expect(section(d) == #"{"Groceries":100,"Travel":150.5,"Health":100.0}"#)
        do {
            let wrote = d.setBudgetLimit(category: "Travel", limit: 75)
            #expect(wrote)
        }
        #expect(section(d) == #"{"Groceries":100,"Travel":75.0,"Health":100.0}"#)
        // An int lexeme that is rewritten becomes a double; same value still writes.
        do {
            let wrote = d.setBudgetLimit(category: "Groceries", limit: 100)
            #expect(wrote)
        }
        #expect(section(d) == #"{"Groceries":100.0,"Travel":75.0,"Health":100.0}"#)
        #expect(d.budgetLimit(for: "Travel") == 75)
    }

    @Test("category is Dart-trimmed; empty or non-finite input changes nothing")
    func trimAndReject() {
        var d = data(#"{"A":1.0}"#)
        do {
            let wrote = d.setBudgetLimit(category: "\u{FEFF} Rent\u{A0}", limit: 900)
            #expect(wrote)
        }
        #expect(section(d) == #"{"A":1.0,"Rent":900.0}"#)
        for bad in ["", "   ", "\u{FEFF}\u{3000}"] {
            do {
                let wrote = d.setBudgetLimit(category: bad, limit: 5)
                #expect(!wrote)
            }
        }
        for bad in [Double.nan, .infinity, -.infinity] {
            do {
                let wrote = d.setBudgetLimit(category: "A", limit: bad)
                #expect(!wrote)
            }
        }
        #expect(section(d) == #"{"A":1.0,"Rent":900.0}"#)
    }

    @Test("limit <= 0 removes the trimmed key; remove is exact and a no-op when absent")
    func removal() {
        var d = data(#"{"A":1.0,"B":2.0,"C":3.0}"#)
        do {
            let wrote = d.setBudgetLimit(category: " B ", limit: 0)
            #expect(wrote)
        }
        #expect(section(d) == #"{"A":1.0,"C":3.0}"#)
        do {
            let wrote = d.setBudgetLimit(category: "C", limit: -0.0)
            #expect(wrote)
        }
        #expect(section(d) == #"{"A":1.0}"#)
        do {
            let wrote = d.setBudgetLimit(category: "Missing", limit: -5)
            #expect(!wrote)
        }
        do {
            let wrote = d.removeBudgetLimit(category: " A")
            #expect(!wrote)
        }
        do {
            let wrote = d.removeBudgetLimit(category: "a")
            #expect(!wrote)
        }
        do {
            let wrote = d.removeBudgetLimit(category: "Missing")
            #expect(!wrote)
        }
        #expect(section(d) == #"{"A":1.0}"#)
        do {
            let wrote = d.removeBudgetLimit(category: "A")
            #expect(wrote)
        }
        #expect(section(d) == "{}")
    }

    @Test("a key Dart dropped at load (<= 0) is replaced at the end, like Dart's map; removing it is a no-op")
    func droppedKeys() {
        var d = data(#"{"Zero":0,"G":250,"Neg":-5.0}"#)
        do {
            let wrote = d.removeBudgetLimit(category: "Zero")
            #expect(!wrote)
        }
        do {
            let wrote = d.setBudgetLimit(category: "Zero", limit: 20)
            #expect(wrote)
        }
        #expect(section(d) == #"{"G":250,"Neg":-5.0,"Zero":20.0}"#)
        #expect(d.budgetLimits.map(\.0) == ["G", "Zero"])
    }

    @Test("repeated keys: Dart's value is the last, position the first; a set collapses them")
    func repeatedKeys() {
        var d = data(#"{"A":1.0,"B":2.0,"A":3.0}"#)
        #expect(d.budgetLimits.map(\.0) == ["A", "B"])
        #expect(d.budgetLimit(for: "A") == 3)
        do {
            let wrote = d.setBudgetLimit(category: "A", limit: 4)
            #expect(wrote)
        }
        #expect(section(d) == #"{"A":4.0,"B":2.0}"#)
    }

    @Test("keys compare as UTF-16: NFC and NFD spellings are different budgets")
    func utf16Keys() {
        var d = data(#"{"Café":10.0}"#)
        #expect(d.budgetLimit(for: "Cafe\u{301}") == nil)
        do {
            let wrote = d.setBudgetLimit(category: "Cafe\u{301}", limit: 12)
            #expect(wrote)
        }
        #expect(d.budgetLimits.count == 2)
        do {
            let wrote = d.removeBudgetLimit(category: "Café")
            #expect(wrote)
        }
        #expect(d.budgetLimits.map { Array($0.0.utf16) } == [Array("Cafe\u{301}".utf16)])
    }

    // MARK: - Progress

    private func summary(_ spent: [(String, Double)]) -> MonthSummary {
        var s = MonthSummary()
        s.categoryExpenses = spent.map { (name: $0.0, amount: $0.1) }
        return s
    }

    @Test("status thresholds: 0.85 is warning, spent == limit is warning not over")
    func status() {
        #expect(BudgetProgress(category: "x", spent: 84.99, limit: 100).status == .ok)
        #expect(BudgetProgress(category: "x", spent: 85, limit: 100).status == .warning)
        let full = BudgetProgress(category: "x", spent: 100, limit: 100)
        #expect(full.status == .warning && !full.isOver && full.remaining == 0)
        let over = BudgetProgress(category: "x", spent: 100.01, limit: 100)
        #expect(over.status == .over && over.isOver && over.remaining < 0)
        #expect(BudgetProgress(category: "x", spent: 0, limit: 100).progress == 0)
    }

    @Test("rows: budgeted categories only, spent by exact name, sorted spent desc then UTF-16 name")
    func rows() {
        var d = data(
            #"{"Groceries":100.0,"Pets":50.0,"Clothing":50.0,"Travel":10.0,"Health":0,"Old":5.0}"#,
            extra: #""categories":[{"id":"a","type":"expense","name":"Groceries","sortOrder":0},{"id":"b","type":"expense","name":"Pets","sortOrder":1},{"id":"c","type":"expense","name":"Clothing","sortOrder":2},{"id":"d","type":"expense","name":"Travel","sortOrder":3},{"id":"e","type":"expense","name":"Health","sortOrder":4},{"id":"f","type":"expense","name":"Old","sortOrder":5,"isArchived":true},{"id":"g","type":"expense","name":"Zed","sortOrder":6}]"#)
        // A limit whose name has no definition (set after launch) has no row.
        do {
            let wrote = d.setBudgetLimit(category: "Orphan", limit: 30)
            #expect(wrote)
        }
        let rows = d.budgetProgress(summary([("groceries", 70), ("Pets", 20), ("Clothing", 20), ("Old", 9), ("Orphan", 1)]))
        #expect(rows.map(\.category) == ["Clothing", "Pets", "Groceries", "Travel"])
        #expect(rows.map(\.spent) == [20, 20, 0, 0])
        #expect(d.budgetedCategories().map(\.name) == ["Groceries", "Pets", "Clothing", "Travel"])
        #expect(d.unbudgetedCategories().map(\.name) == ["Health", "Zed"])
    }

    @Test("Dart double.compareTo")
    func compare() {
        #expect(dartCompare(-0.0, 0.0) == -1)
        #expect(dartCompare(0.0, -0.0) == 1)
        #expect(dartCompare(.nan, 1e308) == 1)
        #expect(dartCompare(.nan, .nan) == 0)
        #expect(dartCompare(1, .nan) == -1)
        #expect(dartCompare(2, 2) == 0)
    }
}
