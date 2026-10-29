import BudgieCore
import SwiftUI

/// '12-month trend' (`_buildTrendCard`, hp:357-396): padding (16, 20, 16,
/// 14), the title row inset 4 with 'NET / MO', 12, then the 120pt
/// sparkline of the 12 calendar months ending at the selected month.
struct TrendCard: View {
    let series: [MonthCashFlow]
    let formatter: MoneyFormatter

    var body: some View {
        GlowCard(padding: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("12-month trend")
                        .textStyle(.cardTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Text("NET / MO")
                        .textStyle(.monoMonth)
                        .foregroundStyle(BudgieColor.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Metrics.spacingXS)
                TrendLine(nets: series.map(\.net))
                    .frame(height: 120)
                    .accessibilityElement()
                    .accessibilityLabel("12-month net trend")
                    .accessibilityValue(spokenRange)
            }
            .padding(EdgeInsets(top: 20, leading: 16, bottom: 14, trailing: 16))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flow.trend")
    }

    /// "From October 2025, +$120, to September 2026, +$3,158" (whole units,
    /// masked under Hide balances).
    private var spokenRange: String {
        guard let first = series.first, let last = series.last else { return "" }
        let from = CashFlowMath.badgeText(first.net, formatter: formatter)
        let to = CashFlowMath.badgeText(last.net, formatter: formatter)
        return "From \(DartDateFormat.yMMMM(first.month)), \(from), to \(DartDateFormat.yMMMM(last.month)), \(to)"
    }
}

/// The sparkline alone (`_TrendSparkline`, hp:982-1055), drawn the way
/// fl_chart 1.2.0 paints it so the curve matches exactly: the plot is the
/// whole frame (no axes, grid, border or touch), y runs from -bound to
/// +bound, the line uses fl_chart's cubic with smoothness 0.35 (overshoot
/// allowed, flat first tangent, butt caps), and only the last point gets a
/// 5pt dot, centred on the right edge so it overhangs the plot. Paint order
/// is fl_chart's with `extraLinesOnTop`: dashed zero line, line (accent,
/// 3pt), end dot, dashed zero line again.
/// A data change animates for 150ms linear (fl_chart's implicit animation);
/// none under Reduce Motion. Self-contained so it can be swapped for Swift
/// Charts.
struct TrendLine: View {
    let nets: [Double]

    var body: some View {
        let values = TrendValues(values: nets)
        // `HorizontalLine(y: 0, width 1, dash [3, 4])`.
        let zeroLine = TrendZeroLine()
            .stroke(BudgieColor.chartZeroLine, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        ZStack {
            zeroLine
            TrendCurve(values: values)
                .stroke(BudgieColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .miter))
            // `FlDotCirclePainter(radius: 5, color: 0xFFF2F2FA, strokeWidth: 0)`.
            TrendEndDot(values: values).fill(BudgieColor.trendDot)
            zeroLine
        }
        .motion(.linear(duration: 0.15), value: nets)
    }
}

/// The trend values as one animatable vector, so a data change interpolates
/// every spot (and the bound derived from them) like fl_chart's lerp. Also
/// the Worth growth chart's values.
struct TrendValues: VectorArithmetic {
    var values: [Double]

    static var zero: TrendValues { TrendValues(values: []) }

    static func + (lhs: TrendValues, rhs: TrendValues) -> TrendValues { combine(lhs, rhs, +) }
    static func - (lhs: TrendValues, rhs: TrendValues) -> TrendValues { combine(lhs, rhs, -) }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

    /// Element-wise; a missing element (the empty `zero`) counts as 0.
    private static func combine(_ lhs: TrendValues, _ rhs: TrendValues, _ op: (Double, Double) -> Double) -> TrendValues {
        let count = max(lhs.values.count, rhs.values.count)
        return TrendValues(values: (0..<count).map { index in
            op(index < lhs.values.count ? lhs.values[index] : 0, index < rhs.values.count ? rhs.values[index] : 0)
        })
    }
}

/// fl_chart's curved bar line (`generateNormalBarPath`) through
/// `CashFlowMath.trendPoints` with `trendControlPoints`.
private struct TrendCurve: Shape {
    var values: TrendValues

    var animatableData: TrendValues {
        get { values }
        set { values = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let points = CashFlowMath.trendPoints(values.values, size: rect.size)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: first) }
        for (index, controls) in CashFlowMath.trendControlPoints(points).enumerated() {
            path.addCurve(to: points[index + 1], control1: controls.0, control2: controls.1)
        }
        return path.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The 5pt dot on the last spot.
private struct TrendEndDot: Shape {
    var values: TrendValues

    var animatableData: TrendValues {
        get { values }
        set { values = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard let last = CashFlowMath.trendPoints(values.values, size: rect.size).last else { return Path() }
        return Path(ellipseIn: CGRect(x: rect.minX + last.x - 5, y: rect.minY + last.y - 5, width: 10, height: 10))
    }
}

/// The zero line: always the vertical centre, since the y range is symmetric.
private struct TrendZeroLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
