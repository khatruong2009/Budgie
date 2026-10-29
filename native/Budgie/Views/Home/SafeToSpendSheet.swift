import BudgieCore
import SwiftUI

/// The breakdown behind Home's safe-to-spend card (`_showSafeToSpendBreakdown`,
/// spending_page.dart:362-446, 1330-1385), restyled per REDESIGN_PLAN 4.3:
/// title, blurb, the feature card holding the total, the six signed rows in
/// one card, and the footer. On the card colour with the grab handle, sized
/// to its content; the system adds the bottom safe area (Flutter's
/// `SafeArea`).
struct SafeToSpendSheet: View {
    let breakdown: SafeToSpendBreakdown
    let formatter: MoneyFormatter

    @State private var contentHeight: CGFloat = 0

    private static let blurb = TextSpec(face: .gabaritoRegular, size: 14, height: 1.4, relativeTo: .subheadline)
    private static let featureLabel = TextSpec(face: .gabaritoSemiBold, size: 13, height: 1.3, relativeTo: .footnote)
    private static let featureTotal = TextSpec(
        face: .gabaritoExtraBold, size: 40, tracking: -1.2, height: 1.1, tabular: true, relativeTo: .largeTitle)
    private static let featureSubtitle = TextSpec(face: .gabaritoRegular, size: 13, height: 1.3, relativeTo: .footnote)
    private static let label = TextSpec(face: .gabaritoRegular, size: 15, height: 1.3, relativeTo: .subheadline)
    private static let value = TextSpec(face: .monoSemiBold, size: 14, height: 1.3, tabular: true, relativeTo: .footnote)

    var body: some View {
        let isOver = breakdown.isOverCommitted
        let sheet = HomeSummary.breakdownSheet(breakdown, formatter: formatter)
        let card = HomeSummary.safeToSpendCard(breakdown, formatter: formatter)
        // The six rows' amounts in `sheet.rows` order; a zero reads quietly.
        let amounts = [
            breakdown.actualIncome, breakdown.expectedIncome, breakdown.actualExpenses,
            breakdown.upcomingRecurringExpenses, breakdown.flexibleBudgetReserve, breakdown.plannedGoalContributions,
        ]
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(sheet.title)
                    .textStyle(.sheetTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(sheet.blurb)
                    .textStyle(Self.blurb)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                total(sheet: sheet, subtitle: card.subtitle, isOver: isOver)
                    .padding(.top, 18)
                GlowCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(sheet.rows.indices, id: \.self) { index in
                            if index > 0 { Hairline() }
                            row(
                                sheet.rows[index].label, sheet.rows[index].value,
                                color: amounts[index] == 0
                                    ? BudgieColor.textSecondary : index < 2 ? BudgieColor.income : BudgieColor.textPrimary)
                        }
                    }
                    .padding(.horizontal, Metrics.spacingM)
                    .padding(.vertical, Metrics.spacingXXS)
                }
                .padding(.top, Metrics.spacingM)
                Text(sheet.footer)
                    .textStyle(.rowSubtitle)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 14, leading: 4, bottom: 0, trailing: 4))
            }
            .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: 24, trailing: Metrics.pageHorizontal))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChangeCompat { contentHeight = $0.height }
        }
        .scrollBounceBehavior(.basedOnSize)
        .budgieSheetChrome()
        .presentationDetents([
            .height(BudgetSheetLayout.handleHeight + (contentHeight > 0 ? contentHeight : estimatedHeight))
        ])
    }

    /// The content's height at the default text size, so the sheet opens at
    /// its final height instead of resizing once measured: 12, the title,
    /// 6, the blurb (two lines when over), 18, the feature card (18, 17,
    /// 44, 17, 18), 16, the rows card (2, six 48pt rows with five hairlines,
    /// 2, plus the border), 14, the footer (two lines when over with days
    /// left), 24. Every line is `round(size * height)` (`textStyle`).
    private var estimatedHeight: CGFloat {
        let blurbLines: CGFloat = breakdown.isOverCommitted ? 2 : 1
        let footerLines: CGFloat = breakdown.isOverCommitted && breakdown.daysRemaining > 0 ? 2 : 1
        return 12 + 29 + 6 + blurbLines * 20 + 18 + (18 + 17 + 44 + 17 + 18 + 2) + 16 + (2 + 6 * 46 + 5 + 2 + 2) + 14
            + footerLines * 15 + 24
    }

    /// The total, on the feature card: "Safe to spend" or "Projected
    /// shortfall", the figure (`featureDanger` for a shortfall) and the
    /// card's subtitle. One element for VoiceOver.
    private func total(sheet: HomeSummary.BreakdownSheet, subtitle: String, isOver: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sheet.totalLabel)
                .textStyle(Self.featureLabel)
                .foregroundStyle(BudgieColor.featureSecondary)
            Text(sheet.totalValue)
                .textStyle(Self.featureTotal)
                .foregroundStyle(isOver ? BudgieColor.featureDanger : BudgieColor.featureAmount)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(subtitle)
                .textStyle(Self.featureSubtitle)
                .foregroundStyle(BudgieColor.featureSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .featureCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sheet.totalLabel), \(sheet.totalValue). \(subtitle)")
        .accessibilityAddTraits(.isStaticText)
    }

    /// `_BreakdownRow`; the signed value text comes from `HomeSummary.breakdownSheet`.
    private func row(_ label: String, _ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .textStyle(Self.label)
                .foregroundStyle(BudgieColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(text)
                .textStyle(Self.value)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(text)")
        // Plain text: without a trait the audit takes the row for a
        // control with a hit area that is too small.
        .accessibilityAddTraits(.isStaticText)
    }
}
