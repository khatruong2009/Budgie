import BudgieCore
import SwiftUI

/// What was loaded, for upgrade rehearsals and support: one `SectionHeader`
/// and card of label / value rows per section (REDESIGN_PLAN 4.7).
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            if let data = model.data {
                let formatter = model.moneyFormatter
                let month = model.calendar.month(of: model.now)
                let totals = model.ledger.summary(forMonth: month)
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    section("Ledger", rows: [
                        row("Transactions", "\(data.transactions.count)"),
                        row("Unreadable rows kept", "\(data.unreadableTransactionCount)"),
                        row("This month income", formatter.format(totals.income)),
                        row("This month expenses", formatter.format(totals.expenses)),
                        row("Recurring templates", "\(data.templates.count)"),
                    ])
                    section("Net worth", rows: [
                        row("Net worth (this month)", formatter.format(data.netWorth(forMonth: month))),
                        row("Accounts", "\(data.netWorthEntries.count)"),
                    ])
                    section("Settings", rows: [
                        row("Currency", data.appSettings.baseCurrencyCode),
                        row("Theme", model.themeMode.rawValue),
                        row("App Lock", data.appSettings.appLockEnabled ? "On" : "Off"),
                    ])
                    section("Migration", rows: [
                        AnyView(detail(String(describing: model.backupOutcome))),
                        AnyView(detail(String(describing: model.loadReport))),
                        row("Unsaved changes", model.hasUnsavedChanges ? "Yes" : "No"),
                    ])
                }
                .padding(EdgeInsets(top: Metrics.spacingM, leading: Metrics.pageHorizontal, bottom: Metrics.spacingXL, trailing: Metrics.pageHorizontal))
                .frame(maxWidth: Metrics.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BudgieColor.background)
        .budgiePushedTitle("Budgie", singleLine: true)
    }

    private func section(_ title: String, rows: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            GlowListCard(rows: rows)
        }
    }

    /// The label (15, primary) and the value (mono 14 w600) at the trailing
    /// edge, as the Safe to spend sheet's rows; the value wraps under a long
    /// label's width when it must. One accessibility element per row.
    private func row(_ label: String, _ value: String) -> AnyView {
        AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .textStyle(DiagnosticsText.label)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(value)
                    .textStyle(DiagnosticsText.value)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(12)
            .frame(minHeight: Metrics.formRowHeight)
            // One element, "Transactions" with its count as the value, so
            // VoiceOver never lands on a bare figure.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(.isStaticText))
    }

    /// A raw report (the backup outcome, the load report) in mono 11.
    private func detail(_ text: String) -> some View {
        Text(text)
            .textStyle(DiagnosticsText.detail)
            .foregroundStyle(BudgieColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}

private enum DiagnosticsText {
    static let label = TextSpec(face: .gabaritoRegular, size: 15, height: 1.25, relativeTo: .body)
    static let value = TextSpec(face: .monoSemiBold, size: 14, height: 1.25, tabular: true, relativeTo: .subheadline)
    static let detail = TextSpec(face: .monoRegular, size: 11, height: 1.4, relativeTo: .caption2)
}
