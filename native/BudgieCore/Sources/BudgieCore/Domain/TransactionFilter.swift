import Foundation

/// The Flow tab's SEE ALL page filters (Flutter `_TransactionsDetailPage`,
/// history_page.dart:1248-2119). All conditions are ANDed over every
/// transaction, newest first; the page's month pill does not filter.
public struct TransactionFilter: Equatable, Sendable {
    /// `_HistoryTransactionTypeFilter`; the raw value is Dart's `.name`.
    public enum Kind: String, CaseIterable, Sendable {
        case all, income, expense

        /// Segment labels, in segment order.
        public var label: String {
            switch self {
            case .all: "All"
            case .income: "Income"
            case .expense: "Expense"
            }
        }
    }

    /// The search field's text as typed. Flutter keeps `value.trim()` as the
    /// query (`hp:1657`), so only `query` matters.
    public var searchText = ""
    public var kind = Kind.all
    /// Exact category name (case-sensitive, untrimmed); nil is "All categories".
    public var category: String?
    public var tagId: String?
    /// Inclusive local calendar days; only the date part is compared.
    public private(set) var from: DartDateTime?
    public private(set) var to: DartDateTime?
    /// Inclusive bounds on `amount`, whatever the type. The app reads its
    /// fields with the locale-aware parse (D6); `parseAmount` is Flutter's.
    public var minAmount: Double?
    public var maxAmount: Double?

    public init() {}

    /// `_searchQuery`: the field text with Dart's `trim`.
    public var query: String { DartString.trim(searchText) }

    /// `_hasActiveFilters` (`hp:1424-1433`). Whitespace-only search text is
    /// not a filter.
    public var isActive: Bool {
        !query.isEmpty || kind != .all || category != nil || tagId != nil || from != nil || to != nil
            || minAmount != nil || maxAmount != nil
    }

    /// Picking a From date (`_pickDateRangeEndpoint`, `hp:1830-1836`): an
    /// existing To day before it moves to the picked date.
    public mutating func setFrom(_ picked: DartDateTime) {
        from = picked
        if let to, Self.dayKey(to) < Self.dayKey(picked) { self.to = picked }
    }

    /// Picking a To date (`hp:1837-1842`): an existing From day after it
    /// moves to the picked date.
    public mutating func setTo(_ picked: DartDateTime) {
        to = picked
        if let from, Self.dayKey(from) > Self.dayKey(picked) { self.from = picked }
    }

    /// RESET (`_resetFilters`): clears every filter and the search text.
    public mutating func reset() { self = TransactionFilter() }

    /// The SEE ALL month pill's pick (D6; Flutter's pill filters nothing):
    /// From the month's first day, To its last (`DateTime(y, m + 1, 0)`).
    /// `month` may be any instant in the month.
    public mutating func limit(toMonth month: DartDateTime, calendar: DartCalendar) {
        let bounds = Self.monthBounds(month, calendar: calendar)
        from = bounds.first
        to = bounds.last
    }

    /// Whether From/To are exactly `month`'s first and last days, as
    /// `limit(toMonth:calendar:)` sets them; compared as local calendar days.
    public func isLimited(toMonth month: DartDateTime, calendar: DartCalendar) -> Bool {
        guard let from, let to else { return false }
        let bounds = Self.monthBounds(month, calendar: calendar)
        return Self.dayKey(from) == Self.dayKey(bounds.first) && Self.dayKey(to) == Self.dayKey(bounds.last)
    }

    private static func monthBounds(_ month: DartDateTime, calendar: DartCalendar) -> (first: DartDateTime, last: DartDateTime) {
        (calendar.date(month.year, month.month), calendar.date(month.year, month.month + 1, 0))
    }

    /// `_getFilteredTransactions` (`hp:1350-1391`) over `index.newestFirst`.
    /// Search is description only (D8): `description.toLowerCase()
    /// .contains(query.toLowerCase())`, compared as UTF-16 code units.
    public func apply(_ index: LedgerIndex) -> [LedgerRow] {
        let needle = Array(DartString.lowercase(query).utf16)
        let category = category.map { Array($0.utf16) }
        let tag = tagId.map { Array($0.utf16) }
        let fromKey = from.map(Self.dayKey)
        let toKey = to.map(Self.dayKey)
        let minAmount = minAmount, maxAmount = maxAmount
        let kind = kind

        return index.newestFirst.filter { row in
            let record = row.record
            if !needle.isEmpty && !Self.contains(row.descriptionLower.utf16, needle) { return false }
            switch kind {
            case .all: break
            case .income: if record.type != .income { return false }
            case .expense: if record.type != .expense { return false }
            }
            if let category, !record.category.utf16.elementsEqual(category) { return false }
            if let tag, !record.tagIds.contains(where: { $0.utf16.elementsEqual(tag) }) { return false }
            if let fromKey, row.dayKey < fromKey { return false }
            if let toKey, row.dayKey > toKey { return false }
            if let minAmount, record.amount < minAmount { return false }
            if let maxAmount, record.amount > maxAmount { return false }
            return true
        }
    }

    /// `DateTime(y, m, d)` comparisons of local days, as integers
    /// (`LedgerRow.dayKey` form).
    static func dayKey(_ d: DartDateTime) -> Int {
        let f = d.fields
        return f.year * 10000 + f.month * 100 + f.day
    }

    /// Dart `String.contains` on code units, without copying the haystack.
    private static func contains(_ haystack: String.UTF16View, _ needle: [UInt16]) -> Bool {
        let first = needle[0]
        var start = haystack.startIndex
        while start != haystack.endIndex {
            if haystack[start] == first {
                var h = haystack.index(after: start)
                var n = 1
                while n < needle.count && h != haystack.endIndex && haystack[h] == needle[n] {
                    h = haystack.index(after: h)
                    n += 1
                }
                if n == needle.count { return true }
                if h == haystack.endIndex { return false }
            }
            start = haystack.index(after: start)
        }
        return false
    }

    // MARK: Amount fields

    /// `_parseAmount` (`hp:1458-1462`): drop every ',', Dart `trim`, empty is
    /// nil, then `double.tryParse` (optional sign, ".5", "5.", exponents;
    /// hex and grouping are rejected). Non-finite results ("NaN",
    /// "Infinity", "1e400") are nil here; Dart keeps them (PARITY_GAPS).
    /// Kept for the parity tests: the app's Min / Max fields parse with the
    /// money format's separators instead (D6).
    // Test-only: checked against Fixtures/flow (amounts)
    public static func parseAmount(_ text: String) -> Double? {
        let normalized = DartString.trim(String(decoding: text.utf16.filter { $0 != 0x2C }, as: UTF16.self))
        if normalized.isEmpty { return nil }
        guard let value = DartDouble.tryParse(normalized), value.isFinite else { return nil }
        return value
    }

    // MARK: Pickers

    /// The date picker's initial day (`hp:1818-1820`).
    public func pickerInitialDate(isStart: Bool, now: DartDateTime) -> DartDateTime {
        isStart ? (from ?? to ?? now) : (to ?? from ?? now)
    }

    /// The date picker's range: 2000-01-01 through December 31 ten years
    /// after `now`'s year (`hp:1824-1825`).
    public static func pickerRange(now: DartDateTime, calendar: DartCalendar) -> ClosedRange<DartDateTime> {
        calendar.date(2000)...calendar.date(now.year + 10, 12, 31)
    }

    /// The From/To buttons' value: "Any date" or `MMM d` (no year).
    public static func dateButtonValue(_ d: DartDateTime?) -> String {
        d.map(DartDateFormat.MMMd) ?? "Any date"
    }

    /// The Category button's value.
    public var categoryButtonValue: String { category ?? "All categories" }

    // MARK: Pagination

    /// Rows shown at first and added by each 'Load more transactions'.
    public static let pageSize = 50

    /// The page's `filterSignature` (`hp:1285-1294`): Dart's
    /// `[query, type.name, category, tagId, start?.toIso8601String(),
    /// end?.toIso8601String(), min, max].join('|')`, with `null` for nil and
    /// doubles in Dart `toString` form. The visible count resets to
    /// `pageSize` whenever this changes, and only then.
    public var signature: String {
        [
            query, kind.rawValue, category ?? "null", tagId ?? "null", from?.toIso8601String() ?? "null",
            to?.toIso8601String() ?? "null", minAmount.map(DartDouble.format) ?? "null",
            maxAmount.map(DartDouble.format) ?? "null",
        ].joined(separator: "|")
    }

    // MARK: Results

    public struct Summary: Sendable, Equatable {
        public let income: Double
        public let expenses: Double
        public let count: Int
        public var net: Double { income - expenses }

        /// 'Income $1,234.00'.
        public func incomeText(_ formatter: MoneyFormatter) -> String { "Income " + formatter.format(income) }
        /// 'Expenses $1,234.00'.
        public func expensesText(_ formatter: MoneyFormatter) -> String { "Expenses " + formatter.format(expenses) }
        /// 'Net +$1.00' ('+' when above zero).
        public func netText(_ formatter: MoneyFormatter) -> String {
            "Net " + formatter.formatSigned(net, plusForPositive: true)
        }
        /// Net pill colour: income when true, else danger.
        public var netIsPositive: Bool { net >= 0 }
    }

    /// `_buildFilteredSummary` (`hp:1403-1417`): income and expense amounts
    /// each folded from 0.0 in the filtered (newest-first) order, over all
    /// matches, not only the visible ones.
    public static func summary(_ rows: [LedgerRow]) -> Summary {
        var income = 0.0, expenses = 0.0
        for row in rows {
            if row.record.type == .income { income += row.record.amount } else { expenses += row.record.amount }
        }
        return Summary(income: income, expenses: expenses, count: rows.count)
    }

    /// The Results header's trailing text: "{matches} of {all transactions}".
    public static func countText(matches: Int, total: Int) -> String { "\(matches) of \(total)" }

    /// Under the list while more matches exist: "Showing 50 of 120 matches".
    public static func showingText(visible: Int, matches: Int) -> String { "Showing \(visible) of \(matches) matches" }

    /// The empty results card.
    public var emptyMessage: String {
        isActive ? "No transactions match these filters." : "No transactions have been recorded yet."
    }
}

/// The SEE ALL page's visible-row count (`_visibleTransactionCount`,
/// `_lastFilterSignature`).
public struct FilterPagination: Equatable, Sendable {
    public private(set) var visibleCount = TransactionFilter.pageSize
    public private(set) var lastSignature: String?

    public init() {}

    /// Call on every rebuild with the current filter (`hp:1295-1298`): a
    /// changed signature resets the count to 50. A data change does not.
    public mutating func sync(_ filter: TransactionFilter) {
        let signature = filter.signature
        if lastSignature != signature {
            visibleCount = TransactionFilter.pageSize
            lastSignature = signature
        }
    }

    /// 'Load more transactions': 50 more.
    public mutating func loadMore() { visibleCount += TransactionFilter.pageSize }

    /// Rows shown out of `matches`.
    public func visible(of matches: Int) -> Int { min(visibleCount, matches) }

    /// Whether 'Showing ... matches' and the button appear.
    public func hasMore(_ matches: Int) -> Bool { matches > visible(of: matches) }
}

extension LedgerRow {
    /// A Flow list row's subtitle (`hp:1108`): "{category} · {MMM d}".
    public var flowSubtitle: String { "\(record.category) \u{00B7} \(DartDateFormat.MMMd(record.date))" }

    /// A Flow list row's amount (`hp:1077-1080`): income positive with '+',
    /// expense negated (a zero expense is -0.0, which prints "$0.00").
    public func flowAmountText(_ formatter: MoneyFormatter) -> String {
        let amount = record.type == .income ? record.amount : -record.amount
        return formatter.formatSigned(amount, plusForPositive: true)
    }
}
