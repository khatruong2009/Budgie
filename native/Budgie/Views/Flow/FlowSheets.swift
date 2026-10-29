import BudgieCore
import SwiftUI

// MARK: - Range sheet

/// 'CHART RANGE' (`_showRangePicker`, hp:439-496, tiles hp:1188-1220) in the
/// sheet pattern (REDESIGN_PLAN 4.3): the eyebrow, then one row per option
/// (3, 6, 12 months) in a card with hairlines between them; the selected
/// row has an accent check. Picking reports the choice; the caller gives
/// the selection haptic and closes the sheet.
struct RangeSheet: View {
    let selected: Int
    let onPick: (Int) -> Void

    var body: some View {
        let options = CashFlowMath.rangeOptions
        VStack(alignment: .leading, spacing: 0) {
            Text("CHART RANGE")
                .textStyle(.eyebrow)
                .foregroundStyle(BudgieColor.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, Metrics.spacingXS)
            OptionListCard(count: options.count) { index in
                OptionRow(
                    title: CashFlowMath.rangeLabel(options[index]), selected: options[index] == selected,
                    boldWhenSelected: true, identifier: "flow.range.\(options[index])"
                ) {
                    onPick(options[index])
                }
            }
            .padding(.top, 12)
        }
        .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: Metrics.spacingL, trailing: Metrics.pageHorizontal))
        .frame(maxWidth: .infinity, alignment: .leading)
        // 12, the eyebrow line, 12, the card (2, 48pt rows with 1pt
        // hairlines, 2, the border), 24.
        .modifier(
            FlowSheetFit(
                estimate: 12 + 14 + 12 + (4 + CGFloat(options.count) * 49 - 1 + 2) + Metrics.spacingL))
    }
}

// MARK: - Month detail sheet

/// A tapped bar's month (`_showMonthDetailsBottomSheet`, hp:498-620) in the
/// sheet pattern (REDESIGN_PLAN 4.3): the bar-chart tile in the net colour
/// beside the `yMMMM` title, the net on the feature card, then the Income
/// and Expenses rows in a card. A snapshot of the tapped entry; no actions.
struct MonthDetailSheet: View {
    let detail: CashFlowMath.MonthDetail
    let formatter: MoneyFormatter

    private static let featureLabel = TextSpec(face: .gabaritoSemiBold, size: 13, height: 1.3, relativeTo: .footnote)
    private static let featureTotal = TextSpec(
        face: .gabaritoExtraBold, size: 40, tracking: -1.2, height: 1.1, tabular: true, relativeTo: .largeTitle)

    var body: some View {
        let netColor = detail.netIsPositive ? BudgieColor.income : BudgieColor.danger
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                IconTile(symbol: "chart.bar.fill", color: netColor, size: 44)
                Text(detail.title)
                    .textStyle(.sheetTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            net.padding(.top, 18)
            GlowCard(padding: 0) {
                VStack(spacing: 0) {
                    MonthDetailRow(label: "Income", amount: detail.incomeText(formatter), color: BudgieColor.income)
                    Hairline()
                    MonthDetailRow(label: "Expenses", amount: detail.expensesText(formatter), color: BudgieColor.textPrimary)
                }
                .padding(.horizontal, Metrics.spacingM)
                .padding(.vertical, Metrics.spacingXXS)
            }
            .padding(.top, Metrics.spacingM)
        }
        // Top: 12 + the chrome's handle inset, as the other sheets.
        .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: Metrics.spacingL, trailing: Metrics.pageHorizontal))
        // A container: the identifier must not replace the rows' elements.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flow.monthDetail")
        // 12, the 44pt tile, 18, the feature card (18 + 17 + 44 + 18 + 2),
        // 16, the rows card (2 + two 48pt rows + 1 + 2 + 2), 24.
        .modifier(FlowSheetFit(estimate: 12 + 44 + 18 + (18 + 17 + 44 + 18 + 2) + 16 + (2 + 96 + 1 + 2 + 2) + 24))
    }

    /// The net on the feature card: "Net cash flow" and `formatSigned(net)`,
    /// `featureAmount` (or `featureDanger` when negative). One element,
    /// "Net cash flow" with the amount as its value.
    private var net: some View {
        let text = detail.netText(formatter)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Net cash flow")
                .textStyle(Self.featureLabel)
                .foregroundStyle(BudgieColor.featureSecondary)
            Text(text)
                .textStyle(Self.featureTotal)
                .foregroundStyle(detail.netIsPositive ? BudgieColor.featureAmount : BudgieColor.featureDanger)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .featureCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Net cash flow")
        .accessibilityValue(text)
    }
}

/// `_MonthDetailTile` (hp:1137-1186) as a row: the label (15) and the
/// amount (mono 14 w600, income in `income`, expenses in the text colour),
/// at least 48 tall. One element, the label with the amount as its value.
private struct MonthDetailRow: View {
    let label: String
    let amount: String
    let color: Color

    private static let labelText = TextSpec(face: .gabaritoRegular, size: 15, height: 1.3, relativeTo: .subheadline)
    private static let valueText = TextSpec(face: .monoSemiBold, size: 14, height: 1.3, tabular: true, relativeTo: .footnote)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .textStyle(Self.labelText)
                .foregroundStyle(BudgieColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(amount)
                .textStyle(Self.valueText)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.vertical, 12)
        .frame(minHeight: Metrics.formRowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(amount)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Sheet sizing

/// Sizes a Flow sheet to its content (Flutter's modal sheet wraps a
/// `mainAxisSize.min` column) and applies the redesign's sheet chrome. The
/// detent is the grab handle's inset plus the content: the system adds the
/// bottom safe area (Flutter's `SafeArea`) itself. Until the content is measured it uses `estimate`, the content's
/// height at the default text size, so the sheet opens at its final height
/// instead of resizing from `.medium`.
private struct FlowSheetFit: ViewModifier {
    let estimate: CGFloat
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        ScrollView {
            content.onGeometryChangeCompat { contentHeight = $0.height }
        }
        .scrollBounceBehavior(.basedOnSize)
        .budgieSheetChrome()
        .presentationDetents([.height(BudgetSheetLayout.handleHeight + (contentHeight > 0 ? contentHeight : estimate))])
    }
}
