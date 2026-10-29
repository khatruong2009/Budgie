import Foundation

/// A transaction with the keys every list, filter and chart needs,
/// computed once when the index is built.
public struct LedgerRow: Sendable, Identifiable {
    public let record: TransactionRecord
    /// Local calendar day as `year * 10000 + month * 100 + day`.
    public let dayKey: Int
    /// `year * 12 + month` (Dart `_monthKey`).
    public let monthKey: Int
    /// `DartString.lowercase(description)`, for search.
    public let descriptionLower: String

    public var id: String { record.id }
}

/// One month of the ledger, summed in stored list order (Dart `_monthLedger`).
public struct MonthSummary: Sendable {
    public var income = 0.0
    public var expenses = 0.0
    /// Expense totals per category in first-appearance order (Dart map order).
    /// Names are distinct as UTF-16 code units, like Dart map keys: "é" and
    /// "e\u{301}" are two entries.
    public var categoryExpenses: [(name: String, amount: Double)] = []
    /// Expense row count of each `categoryExpenses` entry (same index).
    public var categoryExpenseCounts: [Int] = []
    /// Rows of both types (a month with rows but no totals is not "no data").
    public var transactionCount = 0

    public var net: Double { income - expenses }

    public init() {}
}

/// Dart `MonthCashFlow`.
public struct MonthCashFlow: Sendable, Equatable {
    public let month: DartDateTime
    public let income: Double
    public let expenses: Double
    public var net: Double { income - expenses }

    public init(month: DartDateTime, income: Double, expenses: Double) {
        self.month = month
        self.income = income
        self.expenses = expenses
    }
}

/// Everything derived from the ledger, built in one pass per data revision
/// (Flutter caches the same things in `TransactionModel._monthLedger` and
/// `_sortedTransactionsCache`). Immutable, so it can be built off the main
/// thread and read from any view.
public struct LedgerIndex: Sendable {
    public let calendar: DartCalendar
    /// Every readable transaction, `Transaction.compareNewestFirst` order.
    public let newestFirst: [LedgerRow]
    /// Months with transactions, newest first (`getAvailableMonths`).
    public let availableMonths: [DartDateTime]
    /// The SEE ALL category filter's options (`_getCategoryOptions`,
    /// history_page.dart:1393-1401): the distinct category names of every
    /// transaction (both types, exact UTF-16 strings, first appearance in
    /// stored order), without blank ones (Dart `trim`), sorted by their
    /// lower-case forms in code-unit order. Ties keep first appearance
    /// (Swift's sort is stable; Dart's is not above 32 elements).
    public let categoryNames: [String]
    private let summaries: [Int: MonthSummary]
    /// Each month's rows are one contiguous run of `newestFirst`, because
    /// that order is by calendar day first.
    private let monthRanges: [Int: Range<Int>]

    public static func empty(calendar: DartCalendar) -> LedgerIndex {
        LedgerIndex(
            calendar: calendar, newestFirst: [], availableMonths: [], categoryNames: [], summaries: [:], monthRanges: [:])
    }

    public static func build(_ transactions: [TransactionRecord], calendar: DartCalendar) -> LedgerIndex {
        var summaries: [Int: MonthSummary] = [:]
        var categoryIndex: [Int: [[UInt16]: Int]] = [:]
        var keyed: [(row: LedgerRow, created: Int64, id: [UInt16])] = []
        keyed.reserveCapacity(transactions.count)
        var seenCategories = Set<[UInt16]>()
        var categories: [(name: String, lower: [UInt16])] = []

        for record in transactions {
            let units = Array(record.category.utf16)
            if seenCategories.insert(units).inserted && !DartString.trim(record.category).isEmpty {
                categories.append((record.category, Array(DartString.lowercase(record.category).utf16)))
            }
            let f = record.date.fields
            let monthKey = f.year * 12 + f.month
            keyed.append((
                LedgerRow(
                    record: record, dayKey: f.year * 10000 + f.month * 100 + f.day, monthKey: monthKey,
                    descriptionLower: DartString.lowercase(record.description)),
                record.createdAt.microsecondsSinceEpoch, Array(record.id.utf16)))

            var summary = summaries[monthKey] ?? MonthSummary()
            summary.transactionCount += 1
            if record.type == .income {
                summary.income += record.amount
            } else {
                summary.expenses += record.amount
                // Dart map keys compare as code units, not canonically.
                if let index = categoryIndex[monthKey]?[units] {
                    summary.categoryExpenses[index].amount += record.amount
                    summary.categoryExpenseCounts[index] += 1
                } else {
                    categoryIndex[monthKey, default: [:]][units] = summary.categoryExpenses.count
                    summary.categoryExpenses.append((record.category, record.amount))
                    summary.categoryExpenseCounts.append(1)
                }
            }
            summaries[monthKey] = summary
        }

        // compareNewestFirst: calendar day desc (local midnights are ordered
        // like the day keys), then createdAt desc, then id desc in UTF-16.
        keyed.sort { a, b in
            if a.row.dayKey != b.row.dayKey { return a.row.dayKey > b.row.dayKey }
            if a.created != b.created { return a.created > b.created }
            return b.id.lexicographicallyPrecedes(a.id)
        }
        let rows = keyed.map(\.row)

        var ranges: [Int: Range<Int>] = [:]
        var start = 0
        while start < rows.count {
            let key = rows[start].monthKey
            var end = start + 1
            while end < rows.count && rows[end].monthKey == key { end += 1 }
            ranges[key] = start..<end
            start = end
        }

        let months = summaries.keys.sorted(by: >).map { calendar.month(fromLedgerKey: $0) }
        // Stable: equal lower-case forms keep first appearance.
        let categoryNames = categories.enumerated()
            .sorted { a, b in
                if a.element.lower != b.element.lower { return a.element.lower.lexicographicallyPrecedes(b.element.lower) }
                return a.offset < b.offset
            }
            .map(\.element.name)
        return LedgerIndex(
            calendar: calendar, newestFirst: rows, availableMonths: months, categoryNames: categoryNames,
            summaries: summaries, monthRanges: ranges)
    }

    /// One month's rows, newest first.
    public func newestFirst(inMonth month: DartDateTime) -> ArraySlice<LedgerRow> {
        guard let range = monthRanges[calendar.ledgerMonthKey(month)] else { return [] }
        return newestFirst[range]
    }

    /// `getMonthlySummary` / `getCategoryExpensesForMonth`; empty for a
    /// month without transactions.
    public func summary(forMonth month: DartDateTime) -> MonthSummary {
        summaries[calendar.ledgerMonthKey(month)] ?? MonthSummary()
    }

    /// `getRecentTransactions(limit)`.
    public func recent(_ limit: Int) -> ArraySlice<LedgerRow> {
        limit <= 0 ? [] : newestFirst.prefix(limit)
    }

    /// `getNetCashFlowHistory`: months with transactions, oldest first.
    public var netCashFlowHistory: [MonthCashFlow] {
        availableMonths.reversed().map { month in
            let s = summary(forMonth: month)
            return MonthCashFlow(month: month, income: s.income, expenses: s.expenses)
        }
    }

    /// `getRollingCashFlowTrend`, ending at `month` instead of today:
    /// `months` consecutive months, zero-filled.
    public func rollingNet(endingAt month: DartDateTime, months: Int) -> [MonthCashFlow] {
        guard months > 0 else { return [] }
        return (0..<months).map { index in
            let m = calendar.addingMonths(month, 1 - months + index)
            let s = summary(forMonth: m)
            return MonthCashFlow(month: m, income: s.income, expenses: s.expenses)
        }
    }
}
