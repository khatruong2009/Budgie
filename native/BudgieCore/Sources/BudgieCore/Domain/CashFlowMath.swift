import Foundation

/// Every figure on the Flow tab (Flutter `HistoryPage`, history_page.dart),
/// with Flutter's formulas and summation orders.
///
/// Two month windows are in play:
/// - the bars and the metric strip use the last `range` months **with data**
///   at or before the selected month (gaps are skipped, not zero-filled, so
///   six bars can span more than six calendar months);
/// - year over year and the 12-month trend use calendar months, and a month
///   without data counts as zero.
///
/// Money strings go through the caller's `MoneyFormatter` (so Hide balances
/// applies); the `...Text` helpers make exactly the calls Flutter makes.
public enum CashFlowMath {
    // MARK: Range

    /// The range sheet's options (`hp:478`).
    public static let rangeOptions = [3, 6, 12]
    /// `_rangeMonths` starts at 6 (`hp:35`); it is page state, not persisted.
    public static let defaultRange = 6

    /// `_rangeLabel`: "6 months".
    public static func rangeLabel(_ months: Int) -> String { "\(months) months" }

    /// `_getChartDisplayData` (`hp:126-141`): entries of `history` (ascending,
    /// months with data) up to and including the selected month, then the last
    /// `months` of those.
    public static func chartWindow(_ history: [MonthCashFlow], selectedMonth: DartDateTime, months: Int) -> [MonthCashFlow] {
        let selected = selectedMonth.fields
        let kept = history.filter { entry in
            let f = entry.month.fields
            return f.year < selected.year || (f.year == selected.year && f.month <= selected.month)
        }
        if kept.count > months { return Array(kept[(kept.count - months)...]) }
        return kept
    }

    // MARK: Metric strip

    public struct Metrics: Sendable, Equatable {
        /// (Σincome − Σexpenses) / number of data months in the window.
        public let avgSaved: Double
        /// Σincome > 0 ? savings / Σincome × 100 : 0.
        public let savingsRate: Double

        /// Chip colour: income when true, danger otherwise (`hp:224, 234`).
        public var avgSavedIsPositive: Bool { avgSaved >= 0 }
        public var savingsRateIsPositive: Bool { savingsRate >= 0 }
    }

    /// `_computeMetrics` (`hp:143-152`): two ascending folds from 0.0.
    public static func metrics(_ window: [MonthCashFlow]) -> Metrics {
        guard !window.isEmpty else { return Metrics(avgSaved: 0, savingsRate: 0) }
        var totalIncome = 0.0
        for entry in window { totalIncome += entry.income }
        var totalExpenses = 0.0
        for entry in window { totalExpenses += entry.expenses }
        let totalSavings = totalIncome - totalExpenses
        let avgSavings = totalSavings / Double(window.count)
        let savingsRate = totalIncome > 0 ? (totalSavings / totalIncome) * 100 : 0.0
        return Metrics(avgSaved: avgSavings, savingsRate: savingsRate)
    }

    /// 'AVG SAVED / MO' value: `formatSigned(avg, decimalDigits: 0)` (no '+';
    /// a value in (-0.5, 0) prints "-$0").
    public static func avgSavedText(_ avgSaved: Double, formatter: MoneyFormatter) -> String {
        formatter.formatSigned(avgSaved, decimalDigits: 0)
    }

    /// 'SAVINGS RATE' value: `'${rate.toStringAsFixed(0)}%'` ("-0%" kept).
    public static func savingsRateText(_ rate: Double) -> String {
        DartFixed.toStringAsFixed(rate, 0) + "%"
    }

    // MARK: Year over year

    /// `_percentDelta` (`hp:191-194`): nil when there is no prior figure.
    /// (Home's delta differs: it returns 100 when only the previous is 0.)
    public static func percentDelta(current: Double, previous: Double) -> Double? {
        if previous == 0 { return nil }
        return ((current - previous) / previous) * 100
    }

    /// `_formatPercentDelta` (`hp:196-204`): "new", or a sign ('+' above
    /// zero, '-' below, none at zero) and one decimal of the magnitude.
    public static func formatPercentDelta(_ delta: Double?) -> String {
        guard let delta else { return "new" }
        let sign = delta > 0 ? "+" : delta < 0 ? "-" : ""
        return sign + DartFixed.toStringAsFixed(abs(delta), 1) + "%"
    }

    public struct YearOverYearRow: Sendable, Equatable {
        public let current: Double
        public let previous: Double
        public let delta: Double?
        /// 'This year' bar fill: current / max(current, previous), 0 if max <= 0.
        public let thisYearFraction: Double
        /// 'Last year' bar fill.
        public let lastYearFraction: Double

        public var deltaLabel: String { CashFlowMath.formatPercentDelta(delta) }
    }

    public struct YearOverYear: Sendable, Equatable {
        /// `DateTime(sel.year, sel.month)` and the same month a year earlier.
        public let currentMonth: DartDateTime
        public let previousMonth: DartDateTime
        public let income: YearOverYearRow
        public let expenses: YearOverYearRow

        /// "SEP '26 VS SEP '25".
        public var headerText: String {
            DartDateFormat.MMMyy(currentMonth).uppercased() + " VS " + DartDateFormat.MMMyy(previousMonth).uppercased()
        }
        /// Income delta colour: income when true ('new' and 0% included), else danger.
        public var incomeDeltaIsGood: Bool { (income.delta ?? 0) >= 0 }
        /// Expense delta colour: danger when true (a rise), else income.
        public var expenseDeltaIsBad: Bool { (expenses.delta ?? 0) > 0 }
    }

    /// `_buildYearOverYearCard` (`hp:278-355`) with its reports (`hp:45-50,
    /// 154-164`): the selected calendar month against the same month one
    /// year earlier, from the month summaries (0 for a month without data).
    public static func yearOverYear(_ index: LedgerIndex, selectedMonth: DartDateTime) -> YearOverYear {
        let f = selectedMonth.fields
        let currentMonth = index.calendar.date(f.year, f.month)
        let previousMonth = index.calendar.date(f.year - 1, f.month)
        let current = index.summary(forMonth: currentMonth)
        let previous = index.summary(forMonth: previousMonth)
        func row(_ current: Double, _ previous: Double) -> YearOverYearRow {
            let top = dartMax(current, previous)
            return YearOverYearRow(
                current: current, previous: previous, delta: percentDelta(current: current, previous: previous),
                thisYearFraction: top > 0 ? current / top : 0.0, lastYearFraction: top > 0 ? previous / top : 0.0)
        }
        return YearOverYear(
            currentMonth: currentMonth, previousMonth: previousMonth,
            income: row(current.income, previous.income), expenses: row(current.expenses, previous.expenses))
    }

    // MARK: Net cash flow bars

    /// `_NetCashFlowBars` constants (`hp:681-684`).
    public static let barChartHeight = 190.0
    /// Distance from the chart top to the zero baseline.
    public static let barBaselineY = 116.0
    public static let maxPositiveBarHeight = 76.0
    public static let maxNegativeBarHeight = 40.0
    public static let maxBarWidth = 34.0
    /// Corner radius of every bar.
    public static let barCornerRadius = 10.0
    /// The current-month badge sits this far above the bar top.
    public static let badgeOffset = 30.0

    public struct Bar: Sendable, Equatable {
        public let entry: MonthCashFlow
        /// 0 when every net in the window is 0.
        public let height: Double
        /// y of the bar's top edge from the chart top: above the baseline for
        /// a positive (or zero) net, at the baseline for a negative one.
        public let top: Double
        /// `net >= 0`.
        public let isPositive: Bool
        /// Same year and month as the selected month: saturated colour, glow, badge.
        public let isCurrent: Bool

        /// "SEP" (`DateFormat.MMM` upper-cased).
        public var monthLabel: String { DartDateFormat.MMM(entry.month).uppercased() }
        /// Badge box: y of its top edge (`barTop - 30`); the capsule is
        /// centred in a box `4 × barWidth` wide starting `1.5 × barWidth`
        /// left of the bar (`hp:815-818`). Only the current bar has one.
        public var badgeTop: Double { top - CashFlowMath.badgeOffset }
    }

    public struct BarLayout: Sendable, Equatable {
        /// `min(34, availableWidth / count - 4)`, no lower clamp; 34 when empty.
        public let barWidth: Double
        /// Ascending months, laid out left to right with `spaceAround`.
        public let bars: [Bar]
    }

    /// `_NetCashFlowBars.build` (`hp:677-760`) and `_NetCashFlowBar`
    /// (`hp:790-800`). `availableWidth` is the card's inner width (the
    /// `LayoutBuilder` max width). Positive and negative bars scale to
    /// different maxima (76 and 40) of the same largest |net|.
    public static func barLayout(_ window: [MonthCashFlow], selectedMonth: DartDateTime, availableWidth: Double) -> BarLayout {
        var maxMagnitude = 0.0
        for entry in window { maxMagnitude = dartMax(maxMagnitude, abs(entry.net)) }
        let selected = selectedMonth.fields
        let bars = window.map { entry -> Bar in
            let net = entry.net
            let isPositive = net >= 0
            let height: Double
            if maxMagnitude <= 0 {
                height = 0
            } else {
                height = (abs(net) / maxMagnitude) * (isPositive ? maxPositiveBarHeight : maxNegativeBarHeight)
            }
            let f = entry.month.fields
            return Bar(
                entry: entry, height: height, top: isPositive ? barBaselineY - height : barBaselineY,
                isPositive: isPositive, isCurrent: f.year == selected.year && f.month == selected.month)
        }
        let barWidth = window.isEmpty ? maxBarWidth : min(maxBarWidth, availableWidth / Double(window.count) - 4)
        return BarLayout(barWidth: barWidth, bars: bars)
    }

    /// The current bar's badge: `formatSigned(net, decimalDigits: 0,
    /// plusForPositive: true)`: "+$2,322", "-$450", "$0" at exactly zero,
    /// "+$0" / "-$0" for |net| < 0.5.
    public static func badgeText(_ net: Double, formatter: MoneyFormatter) -> String {
        formatter.formatSigned(net, decimalDigits: 0, plusForPositive: true)
    }

    // MARK: Month detail sheet

    /// `_showMonthDetailsBottomSheet` (`hp:498-620`) for the tapped entry.
    public struct MonthDetail: Sendable, Equatable {
        public let entry: MonthCashFlow

        public init(entry: MonthCashFlow) { self.entry = entry }

        /// `data.income - data.expenses`.
        public var net: Double { entry.income - entry.expenses }
        /// Net colour (income when true, else danger) and icon (check when
        /// true, else `trending_up`, as Flutter).
        public var netIsPositive: Bool { net >= 0 }
        /// "September 2026".
        public var title: String { DartDateFormat.yMMMM(entry.month) }
        public func incomeText(_ formatter: MoneyFormatter) -> String { formatter.format(entry.income) }
        public func expensesText(_ formatter: MoneyFormatter) -> String { formatter.format(entry.expenses) }
        /// `formatSigned(net)`: two decimals, no '+'.
        public func netText(_ formatter: MoneyFormatter) -> String { formatter.formatSigned(net) }
    }

    // MARK: 12-month trend

    /// `_getRollingTrendData` (`hp:166-181`): the 12 calendar months ending
    /// at the selected month, zero-filled.
    public static func trendSeries(_ index: LedgerIndex, selectedMonth: DartDateTime) -> [MonthCashFlow] {
        index.rollingNet(endingAt: selectedMonth, months: 12)
    }

    /// `_TrendSparkline` (`hp:995-998`): the y axis runs from -bound to
    /// +bound, `bound = maxAbs <= 0 ? 100 : maxAbs × 1.15`.
    public static func sparklineBound(_ nets: [Double]) -> Double {
        var maxMagnitude = 0.0
        for value in nets { maxMagnitude = dartMax(maxMagnitude, abs(value)) }
        return maxMagnitude <= 0 ? 100.0 : maxMagnitude * 1.15
    }

    /// fl_chart's default `curveSmoothness` (`LineChartBarData`), which the
    /// trend line uses.
    public static let trendCurveSmoothness = 0.35

    /// Canvas positions of the trend spots: spot `i` is `(i, nets[i])`, with
    /// `minX 0`, `maxX count - 1`, `minY -bound`, `maxY +bound`, mapped by
    /// fl_chart 1.2.0 `AxisChartPainter._getPixelX/_getPixelY`
    /// (axis_chart_painter.dart:512-544) onto a plot of `size` (the chart has
    /// no axis titles, so the plot is the whole 120pt-high box).
    public static func trendPoints(_ nets: [Double], size: CGSize) -> [CGPoint] {
        let bound = sparklineBound(nets)
        let minX = 0.0, maxX = Double(nets.count - 1)
        let minY = -bound, maxY = bound
        let width = Double(size.width), height = Double(size.height)
        return nets.enumerated().map { index, value in
            let deltaX = maxX - minX
            let x = deltaX == 0.0 ? 0 : ((Double(index) - minX) / deltaX) * width
            let deltaY = maxY - minY
            let y = deltaY == 0.0 ? height : height - (((value - minY) / deltaY) * height)
            return CGPoint(x: x, y: y)
        }
    }

    /// The cubic control points fl_chart 1.2.0 draws between consecutive
    /// points of a curved line (`LineChartPainter.generateNormalBarPath`,
    /// line_chart_painter.dart:564-637, `preventCurveOverShooting` false):
    /// segment `i` (from `points[i]` to `points[i + 1]`) is
    /// `cubicTo(P[i] + T[i], P[i+1] - T[i+1], P[i+1])` where `T[0] = 0` and
    /// `T[k] = ((P[min(k+1, n-1)] - P[k-1]) / 2) * smoothness`. The first
    /// tangent is flat and the curve can overshoot. The path starts with
    /// `moveTo(points[0])` (plus `lineTo(points[0])` when there is one point).
    /// Returns `points.count - 1` pairs `(control1, control2)`.
    public static func trendControlPoints(_ points: [CGPoint], smoothness: Double = trendCurveSmoothness) -> [(CGPoint, CGPoint)] {
        guard points.count > 1 else { return [] }
        var result: [(CGPoint, CGPoint)] = []
        result.reserveCapacity(points.count - 1)
        var tx = 0.0, ty = 0.0
        for i in 1..<points.count {
            let current = points[i], previous = points[i - 1]
            let next = points[i + 1 < points.count ? i + 1 : i]
            let control1 = CGPoint(x: Double(previous.x) + tx, y: Double(previous.y) + ty)
            tx = ((Double(next.x) - Double(previous.x)) / 2) * smoothness
            ty = ((Double(next.y) - Double(previous.y)) / 2) * smoothness
            let control2 = CGPoint(x: Double(current.x) - tx, y: Double(current.y) - ty)
            result.append((control1, control2))
        }
        return result
    }
}
