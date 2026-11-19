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
            GlowListCard(rows: rows.map { FlowTransactionRow(row: $0, formatter: formatter, action: onOpen) })
        }
    }
}

/// `_TransactionRow` (hp:1057-1135) as a SEE ALL row: padding 12; the
/// category's tile (its icon and colour; Flutter tints every tile income
/// green or accent); description over "category · MMM d"; the signed
/// amount, green for income and primary text for expenses. No press scale;
/// a light haptic on tap.
private struct FlowTransactionRow: View {
    let row: LedgerRow
    let formatter: MoneyFormatter
    let action: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let record = row.record
        let isIncome = record.type == .income
        let info = model.categoryInfo(named: record.category, type: record.type)
        HapticButton(action: action) {
            TransactionRowLayout(
                // Flutter shows a blank line for an empty description.
                title: record.description.isEmpty ? " " : record.description, isRecurring: record.isRecurring,
                subtitle: row.flowSubtitle, amount: row.flowAmountText(formatter),
                amountColor: isIncome ? BudgieColor.income : BudgieColor.textPrimary
            ) {
                FlowCategoryTile(info: info, isIncome: isIncome)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 1))
        // Read like Home's recent-activity rows: the description, then the rest.
        .accessibilityLabel(record.description.isEmpty ? "Transaction" : record.description)
        .accessibilityValue(record.activityAccessibilityValue(formatter: formatter))
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
