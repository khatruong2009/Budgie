import BudgieCore
import SwiftUI

/// The Flow preview (`_buildTransactionsPreview`, hp:398-427): the three
/// newest transactions of any month, each opening SEE ALL; with none, a
/// tappable card 'No transactions recorded yet.' that opens it too.
struct TransactionsPreviewCard: View {
    let rows: ArraySlice<LedgerRow>
    let formatter: MoneyFormatter
    let onOpen: () -> Void

    var body: some View {
        if rows.isEmpty {
            GlowCard(onTap: onOpen) {
                FlowEmptyMessage(text: "No transactions recorded yet.")
            }
            .accessibilityHint("Opens all transactions")
            .accessibilityIdentifier("flow.preview.empty")
        } else {
            GlowListCard(rows: rows.map { FlowTransactionRow(record: $0.record, formatter: formatter, action: onOpen) })
        }
    }
}

/// `_TransactionRow` (hp:1057-1135) as a SEE ALL row: padding 12; the
/// category's tile (its icon and colour; Flutter tints every tile income
/// green or accent); description over "category · MMM d"; the signed
/// amount, green for income and primary text for expenses. No press scale;
/// a light haptic on tap.
private struct FlowTransactionRow: View {
    let record: TransactionRecord
    let formatter: MoneyFormatter
    let action: () -> Void

    @Environment(AppModel.self) private var model
    @State private var taps = 0

    var body: some View {
        let isIncome = record.type == .income
        let day = DartDateFormat.MMMd(record.date)
        let info = model.categoryInfo(named: record.category, type: record.type)
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: 12) {
                FlowCategoryTile(info: info, isIncome: isIncome)
                VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                    HStack(spacing: 6) {
                        // Flutter shows a blank line for an empty description.
                        Text(record.description.isEmpty ? " " : record.description)
                            .textStyle(.rowTitle)
                            .foregroundStyle(BudgieColor.textPrimary)
                            .lineLimit(1)
                        if record.isRecurring { RecurrenceGlyph(size: 16).fixedSize() }
                    }
                    Text("\(record.category) \u{00B7} \(day)")
                        .textStyle(.rowSubtitle)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .singleLine()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(formatter.formatSigned(isIncome ? record.amount : -record.amount, plusForPositive: true))
                    .textStyle(.amountSmall)
                    .foregroundStyle(isIncome ? BudgieColor.income : BudgieColor.textPrimary)
                    .singleLine()
                    .layoutPriority(1)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 1))
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        // Read like Home's recent-activity rows: the description, then the rest.
        .accessibilityLabel(record.description.isEmpty ? "Transaction" : record.description)
        .accessibilityValue(
            "\(record.category), \(day), \(isIncome ? "income" : "expense") \(formatter.format(record.amount))"
                + (record.isRecurring ? ", recurring" : ""))
        .accessibilityHint("Opens all transactions")
        .accessibilityIdentifier("flow.preview.row")
    }
}

/// A Flow row's 40pt tile: the category's (`IconTile(category:)`), else
/// Flutter's fallback icon (`money_dollar` for income, `square_grid_2x2` for
/// expenses, hp:1131-1135) in income green or accent.
struct FlowCategoryTile: View {
    let info: CategoryInfo?
    let isIncome: Bool

    var body: some View {
        if let info {
            IconTile(category: info)
        } else {
            IconTile(
                symbol: isIncome ? "dollarsign" : "square.grid.2x2", color: isIncome ? BudgieColor.income : BudgieColor.accent)
        }
    }
}
