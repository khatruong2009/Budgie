import Foundation

/// Where a Spend row, slice or bar takes its colour from. The app resolves
/// it per theme (light and dark values in app_colors.dart).
public enum SpendPaletteSlot: Hashable, Sendable {
    /// Ranks 0...5, the design's fixed segment palette in this order
    /// (`segmentPalette`, category_page.dart:119-129): `getAccent`,
    /// `getIncome`, `getDanger`, `getWarning`, `getInfo`, `AppColors.pink`
    /// (#F0ABFC in both themes).
    case accent, income, danger, warning, info, pink
    /// `AppColors.getChartColors(isDark)[index]`, index 0..<14: light is
    /// `categoryColors` (app_colors.dart:200-215), dark the list at :223-238.
    case chart(Int)
    /// `AppColors.getDonutRemainder`: the "Other" slice and the tail bar.
    case remainder
}

/// The Spend tab's breakdown of one month (Flutter `CategoryPage.build`,
/// category_page.dart:37-154, where it is inline; there is no Flutter type).
/// Built from the ledger's `MonthSummary`, never by scanning transactions.
public struct CategoryBreakdown: Sendable {
    /// `_maxVisibleCategories` (category_page.dart:34): slices and rows
    /// before the tail.
    public static let maxVisibleCategories = 6
    /// Length of `AppColors.getChartColors` in both themes.
    public static let chartColorCount = 14
    /// Ranks 0...5 (category_page.dart:119-129).
    public static let rankPalette: [SpendPaletteSlot] = [.accent, .income, .danger, .warning, .info, .pink]

    /// One ranked category (`_CategoryRecord`, category_page.dart:590-620).
    public struct Record: Sendable, Equatable {
        /// The transactions' category string, exact.
        public let name: String
        /// Sum of the month's expense amounts, in stored order.
        public let amount: Double
        /// `total > 0 ? (amount / total) * 100 : 0.0` (:105-106).
        public let percentage: Double
        /// `percentage.toStringAsFixed(0)` (row subtitle, :299).
        public let percentageText: String
        /// Expense rows of the month in this category (:67-76).
        public let count: Int
        /// `getCategoryBudgetLimit(name)`: exact key, always > 0 when set.
        public let budgetLimit: Double?
        /// Position after the sort, 0 = largest.
        public let rank: Int
        public let palette: SpendPaletteSlot
        /// Index in the active expense categories (Dart `expenseCategories`
        /// keys), nil when the name is not one of them (archived, a case
        /// variant, deleted). Flutter shows the grid icon for nil.
        public let activeIndex: Int?
        /// Progress bar value `largest > 0 ? amount / largest : 0.0`
        /// (:381-383), unclamped (the bar clamps to 0...1, NaN to 0).
        public let barFraction: Double

        /// Amount above a set limit: the subtitle says "over limit".
        public var isOverLimit: Bool {
            guard let budgetLimit, budgetLimit > 0 else { return false }
            return amount > budgetLimit
        }

        /// The row subtitle (:296-305): "3 transactions · 42%", then
        /// " · over limit" or " · $100 limit" when a limit > 0 is set.
        /// `money` must be the app's formatter (Hide balances masks the limit).
        public func subtitle(money: MoneyFormatter) -> String {
            var text = "\(count) transaction\(count == 1 ? "" : "s") · \(percentageText)%"
            if let budgetLimit, budgetLimit > 0 {
                text += amount > budgetLimit ? " · over limit" : " · \(money.format(budgetLimit, decimalDigits: 0)) limit"
            }
            return text
        }
    }

    /// One donut slice (`CategorySlice`, :136-154).
    public struct Slice: Sendable, Equatable {
        /// The category name, or "Other" for the tail.
        public let label: String
        public let value: Double
        public let palette: SpendPaletteSlot
        public var isOther: Bool { palette == .remainder }
    }

    /// The "N more categories" row and "Other" slice (records past rank 5).
    public struct Tail: Sendable, Equatable {
        /// Names in rank order.
        public let names: [String]
        /// `records.skip(6).fold(0.0, +)` in rank order (:145-147, :395).
        public let total: Double
        /// `largest > 0 ? total / largest : 0.0` (:452), unclamped.
        public let barFraction: Double

        public var count: Int { names.count }
        /// "1 more category" / "7 more categories" (:423-425).
        public var title: String { "\(count) more categor\(count == 1 ? "y" : "ies")" }
        /// Names joined with ", " (:396).
        public var subtitle: String { names.joined(separator: ", ") }
    }

    /// The donut's month-over-month pill (category_donut_chart.dart:412-443).
    public struct Delta: Sendable, Equatable {
        public enum Direction: Sendable, Equatable {
            /// `|percent| < 0.5`: secondary colour, `remove` icon.
            case neutral
            /// Spending went up: danger colour, `north_east` icon.
            case up
            /// Spending went down (or NaN): income colour, `south_west` icon.
            case down
        }

        /// `(total - previous) / previous * 100`.
        public let percent: Double
        public let direction: Direction
        /// "12% vs August" (`|percent|.toStringAsFixed(0)`).
        public let text: String
    }

    /// What the donut centre shows (`_CenterLabel`, :315-400).
    public enum CentreLabel: Sendable, Equatable {
        /// "SPENT", the whole-dollar total, then the pill when there is one.
        case total(Double, delta: Delta?)
        /// The slice's label uppercased (Dart `toUpperCase`), its
        /// whole-dollar value, and "`pct`%" with pct = value / month total.
        case slice(title: String, value: Double, percentText: String)
    }

    public let month: DartDateTime
    public let previousMonth: DartDateTime
    /// `DateFormat.MMMM` of the previous month, for the pill.
    public let previousMonthLabel: String
    /// Sorted by amount, largest first; ties keep first-appearance order.
    public let records: [Record]
    /// `values.fold(0.0, +)` over the per-category sums in first-appearance
    /// order (:63-64). Not `MonthSummary.expenses`: the float association
    /// differs.
    public let total: Double
    /// nil when the previous month has no transactions of either type;
    /// otherwise its expense sum, possibly 0 (:81-87).
    public let previousTotal: Double?
    /// `records.first.amount`, 0 without records (:131).
    public let largestAmount: Double
    /// Ranks 0...5, then "Other" when there are more than six records.
    public let slices: [Slice]
    /// Records past rank 5, nil for six or fewer.
    public let tail: Tail?

    /// Flutter shows "No Expenses" instead of the donut and list when the
    /// total is exactly 0 (also -0.0) (:219-227). A negative total still
    /// shows them, with every percentage 0.
    public var showsEmptyState: Bool { total == 0.0 }

    /// `_deltaPct` (category_donut_chart.dart:412-416): nil when the
    /// previous total is nil or 0.
    public var deltaPercent: Double? {
        guard let previousTotal, previousTotal != 0.0 else { return nil }
        return (total - previousTotal) / previousTotal * 100
    }

    /// The pill, nil when hidden.
    public var delta: Delta? {
        guard let percent = deltaPercent else { return nil }
        let direction: Delta.Direction = percent.magnitude < 0.5 ? .neutral : percent > 0 ? .up : .down
        let word = previousMonthLabel.isEmpty ? "last month" : previousMonthLabel
        return Delta(percent: percent, direction: direction, text: "\(DartFixed.toStringAsFixed(percent.magnitude, 0))% vs \(word)")
    }

    /// Rows shown: ranks 0...5 collapsed, every record expanded (:229-230).
    /// The tail row follows when collapsed and `tail != nil`; the
    /// "Show less" row follows when expanded and `tail != nil`.
    public func visibleRecords(expanded: Bool) -> ArraySlice<Record> {
        expanded ? records[...] : records.prefix(Self.maxVisibleCategories)
    }

    /// Whether the row at `rank` is tinted for the selected slice (:291-292):
    /// only ranks 0...5; selecting "Other" (index 6) tints nothing.
    public static func isRowHighlighted(rank: Int, selectedSlice: Int?) -> Bool {
        rank == selectedSlice && rank < maxVisibleCategories
    }

    /// The centre label for a selection. An index outside the slices (a
    /// stale one) shows the total, as in Flutter.
    public func centreLabel(selectedSlice: Int?) -> CentreLabel {
        guard let index = selectedSlice, slices.indices.contains(index) else {
            return .total(total, delta: delta)
        }
        let slice = slices[index]
        let percent = total > 0 ? slice.value / total * 100 : 0.0
        return .slice(
            title: DartString.uppercase(slice.label), value: slice.value,
            percentText: "\(DartFixed.toStringAsFixed(percent, 0))%")
    }

    /// Ring geometry for these slices.
    public var donut: DonutGeometry { DonutGeometry(values: slices.map(\.value)) }

    /// The breakdown of `month` from the ledger. `budgetLimits` is
    /// `FinancialData.budgetLimits`; `activeExpenseCategories` is the
    /// expense picker order (`FinancialData.categoryPicker(for: .expense)`
    /// names), which is what Dart's `expenseCategories` keys hold.
    public static func build(
        month: DartDateTime, ledger: LedgerIndex, budgetLimits: [(String, Double)], activeExpenseCategories: [String]
    ) -> CategoryBreakdown {
        let previous = HomeSummary.previousMonth(of: month, calendar: ledger.calendar)
        return build(
            month: month, previousMonth: previous, summary: ledger.summary(forMonth: month),
            previousSummary: ledger.summary(forMonth: previous), budgetLimits: budgetLimits,
            activeExpenseCategories: activeExpenseCategories)
    }

    /// The same from month summaries (`previousSummary` is the empty
    /// summary for a month without transactions).
    public static func build(
        month: DartDateTime, previousMonth: DartDateTime, summary: MonthSummary, previousSummary: MonthSummary,
        budgetLimits: [(String, Double)], activeExpenseCategories: [String]
    ) -> CategoryBreakdown {
        // expenseCategories is a map: a repeated name keeps its first position.
        var activeIndex: [[UInt16]: Int] = [:]
        for name in activeExpenseCategories {
            let key = Array(name.utf16)
            if activeIndex[key] == nil { activeIndex[key] = activeIndex.count }
        }
        var limits: [[UInt16]: Double] = [:]
        for (name, limit) in budgetLimits where limits[Array(name.utf16)] == nil { limits[Array(name.utf16)] = limit }

        let entries = summary.categoryExpenses
        let counts = summary.categoryExpenseCounts
        let total = entries.reduce(0.0) { $0 + $1.amount }

        // `sort((a, b) => b.amount.compareTo(a.amount))` (:115). Dart's
        // List.sort is an insertion sort (stable) up to 33 elements and a
        // quicksort above; this is stable at every size (PARITY_GAPS).
        let order = entries.indices.sorted { a, b in
            let c = FinancialData.dartCompare(entries[b].amount, entries[a].amount)
            return c != 0 ? c < 0 : a < b
        }
        let largest = order.first.map { entries[$0].amount } ?? 0.0

        let records = order.enumerated().map { rank, index in
            let (name, amount) = entries[index]
            let key = Array(name.utf16)
            let active = activeIndex[key]
            let percentage = total > 0 ? (amount / total) * 100 : 0.0
            let palette: SpendPaletteSlot
            if rank < rankPalette.count {
                palette = rankPalette[rank]
            } else if let active {
                palette = .chart(active % chartColorCount)
            } else {
                // `chartColors[name.hashCode.abs() % 14]` (:102-103).
                palette = .chart(DartString.hashCode(name) % chartColorCount)
            }
            return Record(
                name: name, amount: amount, percentage: percentage,
                percentageText: DartFixed.toStringAsFixed(percentage, 0), count: counts[index],
                budgetLimit: limits[key], rank: rank, palette: palette, activeIndex: active,
                barFraction: largest > 0 ? amount / largest : 0.0)
        }

        var slices = records.prefix(maxVisibleCategories).map { Slice(label: $0.name, value: $0.amount, palette: $0.palette) }
        var tail: Tail?
        if records.count > maxVisibleCategories {
            let rest = records[maxVisibleCategories...]
            let tailTotal = rest.reduce(0.0) { $0 + $1.amount }
            slices.append(Slice(label: "Other", value: tailTotal, palette: .remainder))
            tail = Tail(names: rest.map(\.name), total: tailTotal, barFraction: largest > 0 ? tailTotal / largest : 0.0)
        }

        return CategoryBreakdown(
            month: month, previousMonth: previousMonth, previousMonthLabel: DartDateFormat.MMMM(previousMonth),
            records: records, total: total,
            previousTotal: previousSummary.transactionCount == 0 ? nil : previousSummary.expenses,
            largestAmount: largest, slices: slices, tail: tail)
    }
}

/// The Spend tab's month (category_page.dart:30, 40-58): local to the tab,
/// never Home's month.
public enum SpendMonth {
    public struct Resolution: Sendable, Equatable {
        /// The month to show and keep; nil only when nothing was selected
        /// and there are no months (the page shows "No Expenses Yet").
        public let month: DartDateTime?
        /// The selection moved: clear the selected slice and collapse the tail.
        public let resetsSelection: Bool
    }

    /// Run on every data change: a selection that is nil or no longer
    /// among `available` (compared by year and month) becomes the newest
    /// month with data, `available.first` (possibly a future month). With
    /// no months the stored selection is kept as it is.
    public static func resolve(selected: DartDateTime?, available: [DartDateTime]) -> Resolution {
        if let selected {
            let f = selected.fields
            if available.contains(where: { $0.year == f.year && $0.month == f.month }) {
                return Resolution(month: selected, resetsSelection: false)
            }
        }
        guard let newest = available.first else { return Resolution(month: selected, resetsSelection: false) }
        return Resolution(month: newest, resetsSelection: true)
    }
}
