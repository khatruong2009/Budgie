import Foundation

/// Pure logic behind the Worth tab's widgets (net_worth_page.dart), kept out
/// of the views so it can be checked against Dart (Fixtures/worth).

/// Growth chart range pills (`_GrowthRange`, NW:406-422).
public enum NetWorthGrowthRange: String, CaseIterable, Sendable {
    case sixMonths, oneYear, all

    public var label: String {
        switch self {
        case .sixMonths: "6M"
        case .oneYear: "1Y"
        case .all: "ALL"
        }
    }

    /// `_rangeData` over the oldest-first history: points in the last 6 / 12
    /// months counted back from the newest point's month; at least the last
    /// two points when there are two; everything when the filter is empty.
    public func filter(_ data: [NetWorthHistoryPoint], calendar: DartCalendar) -> [NetWorthHistoryPoint] {
        guard let anchor = data.last?.date, self != .all else { return data }
        let months = self == .sixMonths ? 6 : 12
        let a = anchor.fields
        let cutoff = calendar.date(a.year, a.month - (months - 1))
        let filtered = data.filter { !calendar.month(of: $0.date).isBefore(cutoff) }
        if filtered.count < 2 && data.count >= 2 { return Array(data.suffix(2)) }
        return filtered.isEmpty ? data : filtered
    }
}

/// Padded y-axis bounds of the two line charts.
public struct NetWorthChartScale: Equatable, Sendable {
    public let min: Double
    public let max: Double

    /// `_netWorthChartScale` (NW:826-836): range at least 1 and 10% of
    /// `|max|`, padded 18% each side. nil for no values.
    public static func growth(_ values: [Double]) -> NetWorthChartScale? {
        guard let first = values.first else { return nil }
        let low = values.dropFirst().reduce(first, dartMin), high = values.dropFirst().reduce(first, dartMax)
        let range = dartMax(high - low, dartMax(1.0, abs(high) * 0.10))
        return NetWorthChartScale(min: low - range * 0.18, max: high + range * 0.18)
    }

    /// `_AccountHistoryChart` (NW:1936-1943): range at least 1 and 8% of the
    /// larger magnitude, padded 20% each side. nil for no values.
    public static func account(_ values: [Double]) -> NetWorthChartScale? {
        guard let first = values.first else { return nil }
        let low = values.dropFirst().reduce(first, dartMin), high = values.dropFirst().reduce(first, dartMax)
        let baseline = dartMax(1.0, dartMax(abs(high), abs(low)) * 0.08)
        let range = dartMax(high - low, baseline)
        return NetWorthChartScale(min: low - range * 0.20, max: high + range * 0.20)
    }

    /// fl_chart's `getPixelY` on a plot `height` tall (no titles, so the
    /// plot is the whole box): `min` at the bottom, `max` at the top.
    public func y(_ value: Double, height: CGFloat) -> CGFloat {
        let h = Double(height), range = max - min
        return CGFloat(range == 0 ? h : h - (value - min) / range * h)
    }

    /// The spots' positions on a plot of `size`: x is the index over
    /// `maxX = max(1, n - 1)` (points evenly spaced, first on the left
    /// edge, last on the right), y by `y(_:height:)`. One value is drawn as
    /// two spots, (0, v) and (1, v): a flat line across the plot.
    public func points(_ values: [Double], size: CGSize) -> [CGPoint] {
        let spots = values.count == 1 ? [values[0], values[0]] : values
        let maxX = Double(Swift.max(1, spots.count - 1))
        return spots.enumerated().map { index, value in
            CGPoint(x: CGFloat(Double(index) / maxX * Double(size.width)), y: y(value, height: size.height))
        }
    }

    /// The values of both charts' horizontal grid lines: fl_chart 1.2.0
    /// with `horizontalInterval: (max - min) / 4` and `baselineY` 0 draws
    /// the multiples of the interval counted from 0 that lie inside
    /// (min, max), both ends excluded (`AxisChartHelper.iterateThroughAxis`
    /// with `Utils.getBestInitialIntervalValue`, axis_chart_painter.dart:
    /// 105-120): four lines, three when `min` is itself a multiple, and one
    /// at 0 whenever 0 is inside. Not five evenly spaced lines.
    public var gridLines: [Double] {
        let interval = (max - min) / 4
        guard interval > 0, interval.isFinite else { return [] }
        // Dart `%` is Euclidean: 0 <= mod < interval.
        var mod = (0 - min).truncatingRemainder(dividingBy: interval)
        if mod < 0 { mod += interval }
        let initial = abs(max - min) <= mod || mod == 0 ? min : min + mod
        var seek = initial
        if seek == min { seek += interval }
        let count = ((max - min) / interval).rounded(.towardZero)
        let end = initial + count * interval == max ? max - interval : max
        let epsilon = interval / 100000
        var values: [Double] = []
        while seek <= end + epsilon {
            values.append(seek)
            seek += interval
        }
        return values
    }
}

public enum NetWorthPresentation {
    /// `curveSmoothness` of both Worth charts' curved lines (NW:604-625,
    /// 1990-2010), for `CashFlowMath.trendControlPoints`.
    public static let curveSmoothness = 0.28

    /// `_AssetsLiabilitiesCard`: the green share of the split bar; 1 (all
    /// green) when both totals are 0.
    public static func splitFraction(assets: Double, liabilities: Double) -> Double {
        let total = assets + liabilities
        return total > 0 ? assets / total : 1.0
    }

    /// `SplitGlowBar` flex factors: `(f * 1000).round()` and
    /// `((1 - f) * 1000).round()` (Dart `round`: half away from zero).
    public static func splitFlex(_ fraction: Double) -> (assets: Int, liabilities: Int) {
        (Int((fraction * 1000).rounded(.toNearestOrAwayFromZero)), Int(((1 - fraction) * 1000).rounded(.toNearestOrAwayFromZero)))
    }

    /// `_overlayAlignment` (NW:535-553): the hover card's `Alignment`. `x` is
    /// the point's position mapped to -1...1 and clamped to +-0.84; the card
    /// sits low (`y` 0.5) for points in the upper half of the values, else
    /// high (`y` -0.6).
    public static func hoverAlignment(index: Int, values: [Double]) -> (x: Double, y: Double, useBottom: Bool) {
        let low = values.dropFirst().reduce(values[0], dartMin)
        let high = values.dropFirst().reduce(values[0], dartMax)
        let useBottom = values[index] >= (low + high) / 2
        let x = values.count <= 1 ? 0.0 : dartClamp(Double(index) / Double(values.count - 1) * 2 - 1, -0.84, 0.84)
        return (x, useBottom ? 0.5 : -0.6, useBottom)
    }

    /// Both Worth charts' touch hit: the spot nearest to `x` horizontally,
    /// the earlier one on a tie, so a touch anywhere in the plot selects a
    /// point (each owns the column out to halfway to its neighbours).
    /// fl_chart's `getNearestTouchedSpot` (line_chart_painter.dart:1375-1420)
    /// also requires the spot within `touchSpotThreshold` 48, which on a
    /// wide plot leaves gaps between sparse points; see PARITY_GAPS.md.
    public static func nearestSpot(toX x: CGFloat, in points: [CGPoint]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in points.enumerated() {
            let distance = abs(point.x - x)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    /// `_AxisLabels`: indices of the first, middle (`n ~/ 2`, only when
    /// n > 2) and last points. n == 1 gives [0, 0] (the label twice).
    public static func growthAxisLabelIndices(count n: Int) -> [Int] {
        guard n > 0 else { return [] }
        return n > 2 ? [0, n / 2, n - 1] : [0, n - 1]
    }

    /// The account trend chart's bottom titles: fl_chart asks for x = 0,
    /// interval, 2*interval, ... up to maxX, plus maxX itself (interval =
    /// `max(1, floor(n / 3))`, maxX = `max(1, n - 1)`); the widget hides
    /// indices outside the data and, when n > 3, all but the first, the last
    /// and `(n / 2).round()`. Derived from the fl_chart 1.2.0 source
    /// (`AxisChartHelper.iterateThroughAxis`).
    public static func accountAxisLabelIndices(count n: Int) -> [Int] {
        guard n > 0 else { return [] }
        let interval = max(1, n / 3)
        let maxX = max(1, n - 1)
        var xs = Array(stride(from: 0, through: maxX, by: interval))
        if xs.last != maxX { xs.append(maxX) }
        let middle = Int((Double(n) / 2).rounded(.toNearestOrAwayFromZero))
        return xs.filter { i in
            guard i < n else { return false }
            return n <= 3 || i == 0 || i == n - 1 || i == middle
        }
    }
}

/// One account row of the Worth list (`_AccountRow`, NW:1116-1146).
public struct NetWorthAccountRowStats: Sendable, Equatable {
    /// The value carried into the month (`latestSnapshotThrough(end)`).
    public let effective: NetWorthSnapshotRecord?
    /// The latest snapshot strictly before `effective`.
    public let previous: NetWorthSnapshotRecord?
    /// `effective?.amount ?? 0`.
    public let amount: Double
    /// The row's share of its tab's total, clamped to 0...1 (0 when the
    /// total is not positive).
    public let share: Double
    /// Percent change against `previous`; nil when there is none or
    /// `|previous| < 0.001`.
    public let percentChange: Double?
    /// Green (true) or rose (false) for the change; nil (tertiary) when
    /// there is no change. Assets want a rise, liabilities a fall.
    public let changeIsFavorable: Bool?
}

extension NetWorthEntryRecord {
    public func rowStats(forMonth month: DartDateTime, categoryTotal: Double, calendar: DartCalendar) -> NetWorthAccountRowStats {
        let effective = latestSnapshot(through: calendar.endOfNetWorthMonth(month))
        let amount = effective?.amount ?? 0
        let share = categoryTotal > 0 ? dartClamp(amount / categoryTotal, 0, 1) : 0
        let previous = previousSnapshot(before: effective?.recordedAt)
        var percentChange: Double?
        if let previous, abs(previous.amount) >= 0.001 {
            percentChange = ((amount - previous.amount) / abs(previous.amount)) * 100
        }
        return NetWorthAccountRowStats(
            effective: effective, previous: previous, amount: amount, share: share, percentChange: percentChange,
            changeIsFavorable: percentChange.map { type == .asset ? $0 >= 0 : $0 <= 0 })
    }
}

/// The account history page's derived values (`_AccountHistoryPage`,
/// NW:1383-1409, 1547-1562). All-time, independent of the selected month.
public struct NetWorthAccountHistory: Sendable {
    /// Ascending (chart order).
    public let chart: [NetWorthSnapshotRecord]
    /// Newest first, each with its change from the next older snapshot (nil
    /// for the oldest) and whether that change is good for the entry type.
    public let timeline: [(snapshot: NetWorthSnapshotRecord, delta: Double?, deltaIsFavorable: Bool?)]
    public let latest: NetWorthSnapshotRecord?
    public let previous: NetWorthSnapshotRecord?
    /// `latest?.amount ?? 0`.
    public let latestAmount: Double
    /// Latest minus previous ("vs prior", coloured by sign).
    public let changeFromPrevious: Double?
    /// Last minus first when there are two or more ("overall").
    public let totalChange: Double?
    /// Assets `>= 0`, liabilities `<= 0`.
    public let totalChangeIsPositive: Bool?
    public let peak: Double?
    public let low: Double?

    public init(history chart: [NetWorthSnapshotRecord], type: NetWorthEntryType) {
        self.chart = chart
        let newestFirst = Array(chart.reversed())
        timeline = newestFirst.indices.map { i in
            let delta = i < newestFirst.count - 1 ? newestFirst[i].amount - newestFirst[i + 1].amount : nil
            return (newestFirst[i], delta, delta.map { type == .asset ? $0 >= 0 : $0 <= 0 })
        }
        let last = chart.last, beforeLast = chart.count > 1 ? chart[chart.count - 2] : nil
        latest = last
        previous = beforeLast
        latestAmount = last?.amount ?? 0
        if let last, let beforeLast { changeFromPrevious = last.amount - beforeLast.amount } else { changeFromPrevious = nil }
        totalChange = chart.count > 1 ? chart.last!.amount - chart.first!.amount : nil
        totalChangeIsPositive = totalChange.map { type == .asset ? $0 >= 0 : $0 <= 0 }
        peak = chart.isEmpty ? nil : chart.dropFirst().reduce(chart[0].amount) { dartMax($0, $1.amount) }
        low = chart.isEmpty ? nil : chart.dropFirst().reduce(chart[0].amount) { dartMin($0, $1.amount) }
    }
}

/// The row icon (`_iconForEntry`, NW:1305-1345), named after the Material
/// symbol Flutter shows; views map it to an SF Symbol. First match wins, on
/// Dart `toLowerCase().contains`.
public enum NetWorthAccountIcon: String, Sendable, CaseIterable {
    case accountBalance, savings, trendingUp, home, accountBalanceWallet, northEast
    case attachMoney, southWest

    public init(name: String, type: NetWorthEntryType) {
        let n = DartString.lowercase(name)
        func any(_ words: [String]) -> Bool { words.contains { DartString.contains(n, $0) } }
        switch type {
        case .asset:
            if any(["bank", "checking"]) { self = .accountBalance }
            else if any(["saving"]) { self = .savings }
            else if any(["invest", "stock", "portfolio", "broker", "etf", "401", "ira"]) { self = .trendingUp }
            else if any(["real estate", "house", "home", "property"]) { self = .home }
            else if any(["wallet", "cash"]) { self = .accountBalanceWallet }
            else { self = .northEast }
        case .liability:
            if any(["loan", "student", "auto", "personal"]) { self = .attachMoney }
            else if any(["credit", "card"]) { self = .accountBalanceWallet }
            else { self = .southWest }
        }
    }
}
