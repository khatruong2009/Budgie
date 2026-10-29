import BudgieCore
import SwiftUI

/// 'Year over year' (`_buildYearOverYearCard`, hp:278-355): the selected
/// calendar month's income and expenses against the same month a year
/// earlier, each as a delta and two bars (this year in accent, last year in
/// trackSecondary), then the legend. Percentages only, so nothing here is
/// masked by Hide balances.
struct YearOverYearCard: View {
    let yoy: CashFlowMath.YearOverYear

    var body: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Year over year")
                        .textStyle(.cardTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Text(yoy.headerText)
                        .textStyle(.monoMonth)
                        .foregroundStyle(BudgieColor.textTertiary)
                        .accessibilityLabel(
                            "\(DartDateFormat.yMMMM(yoy.currentMonth)) versus \(DartDateFormat.yMMMM(yoy.previousMonth))")
                }
                YearOverYearRow(
                    label: "Income", row: yoy.income,
                    deltaColor: yoy.incomeDeltaIsGood ? BudgieColor.income : BudgieColor.danger)
                    .padding(.top, 18)
                YearOverYearRow(
                    label: "Expenses", row: yoy.expenses,
                    deltaColor: yoy.expenseDeltaIsBad ? BudgieColor.danger : BudgieColor.income)
                    .padding(.top, Metrics.spacingM)
                HStack(spacing: 14) {
                    LegendDot(color: BudgieColor.accent, label: "This year")
                    LegendDot(color: BudgieColor.trackSecondary, label: "Last year")
                }
                .padding(.top, Metrics.spacingM)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flow.yoy")
    }
}

/// `_YoyRow` (hp:881-941): label and delta, 6, this year's bar, 4, last
/// year's bar (both 12pt; a zero fraction draws no fill).
private struct YearOverYearRow: View {
    let label: String
    let row: CashFlowMath.YearOverYearRow
    let deltaColor: Color

    /// `badge` at 13.
    private static let deltaStyle = TextSpec(face: .gabaritoBold, size: 13, relativeTo: .footnote)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.spacingS) {
                Text(label)
                    .textStyle(.noteStrong)
                    .foregroundStyle(BudgieColor.textSecondary)
                Spacer(minLength: 0)
                Text(row.deltaLabel)
                    .textStyle(Self.deltaStyle)
                    .foregroundStyle(deltaColor)
            }
            GlowProgressBar(value: row.thisYearFraction, height: 12, color: BudgieColor.accent)
                .padding(.top, 6)
            GlowProgressBar(value: row.lastYearFraction, height: 12, color: BudgieColor.trackSecondary, track: BudgieColor.track)
                .padding(.top, Metrics.spacingXS)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(row.delta == nil ? "New" : "\(row.deltaLabel) versus last year")
    }
}

/// `_LegendDot` (hp:943-978): an 8pt radius-3 square, 6, the label.
private struct LegendDot: View {
    let color: Color
    let label: String

    /// `rowSubtitle` w600.
    private static let style = TextSpec(face: .gabaritoSemiBold, size: 12, height: 1.25, relativeTo: .caption)

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .circular)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .textStyle(Self.style)
                .foregroundStyle(BudgieColor.textSecondary)
        }
    }
}
