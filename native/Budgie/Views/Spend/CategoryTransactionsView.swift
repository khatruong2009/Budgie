import BudgieCore
import SwiftUI

/// A category's expenses in one month (`CategoryTransactionsPage`,
/// category_transactions_page.dart), pushed from a Spend row: the "TOTAL
/// SPENT" card, then the rows newest first in one card, as SEE ALL's day
/// cards. Rows open the edit form and swipe to delete behind the
/// confirmation (a superset of Flutter's read-only, swipe-only rows, like
/// D7).
///
/// Live: the rows come from `model.ledger` on every change, and the colour
/// and icon follow the category's current rank in the month (Flutter keeps
/// the ones it was pushed with); the pushed ones are used only once the
/// category has no expenses left. The month stays the pushed one.
struct CategoryTransactionsView: View {
    let drillIn: SpendDrillIn

    @Environment(AppModel.self) private var model
    @State private var editing: TransactionRecord?
    @State private var pendingDelete: TransactionRecord?
    @State private var rowTaps = 0
    @State private var styleCache = StyleCache()

    var body: some View {
        let category = drillIn.category
        // `where(category == name && type == expense)` on the month's rows,
        // already `compareNewestFirst` in the ledger.
        let rows = MonthListCopy.drillInRows(monthRows: model.ledger.newestFirst(inMonth: drillIn.month), category: category)
        let (color, symbol) = currentStyle()
        let formatter = model.moneyFormatter
        // Folded in row order (:46-49).
        let total = MonthListCopy.drillInTotal(rows, formatter: formatter)

        VStack(alignment: .leading, spacing: 0) {
            SummaryCard(
                total: total, month: drillIn.month, count: rows.count, color: color, symbol: symbol)
                .padding(.horizontal, Metrics.pageHorizontal)
                .padding(.top, 12)
                .frame(maxWidth: Metrics.maxContentWidth)
                .frame(maxWidth: .infinity)
            if rows.isEmpty {
                EmptyStateView(
                    kind: .noData, symbol: "list.bullet.rectangle", title: MonthListCopy.emptyMonthTitle,
                    message: MonthListCopy.drillInEmptyMessage(month: drillIn.month))
                    .frame(maxHeight: .infinity)
            } else {
                Text("TRANSACTIONS")
                    .textStyle(.eyebrow)
                    .foregroundStyle(BudgieColor.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(EdgeInsets(top: 28, leading: 24, bottom: 0, trailing: 24))
                    .frame(maxWidth: Metrics.maxContentWidth)
                    .frame(maxWidth: .infinity)
                ScrollView {
                    // One card, a hairline between rows (SEE ALL's day
                    // cards). The swipe slides a row (on the card fill) over
                    // the delete background; the card clips it at its edge.
                    GlowCard(padding: Metrics.listCardPadding) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                if row.id != rows.first?.id { Hairline().padding(.horizontal, Metrics.hairlineInset) }
                                SwipeToDeleteRow {
                                    pendingDelete = row.record
                                } content: {
                                    ExpenseRow(record: row.record, color: color, symbol: symbol, formatter: formatter) {
                                        rowTaps += 1
                                        editing = row.record
                                    }
                                    .background(BudgieColor.card)
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                    .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: Metrics.pageHorizontal, trailing: Metrics.pageHorizontal))
                    .frame(maxWidth: Metrics.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BudgieColor.background)
        .budgiePushedTitle(category, singleLine: true)
        .sheet(item: $editing) { record in
            TransactionFormView(mode: .edit(record))
        }
        .deleteTransactionAlert(pending: $pendingDelete)
        .sensoryFeedback(.impact(weight: .light), trigger: rowTaps)
    }

    /// The category's colour and icon as its Spend row shows them now, or
    /// the pushed ones when it is no longer in the month's breakdown.
    private func currentStyle() -> (Color, String) {
        styleCache.style(for: drillIn, ledgerRevision: model.ledgerRevision, dataRevision: model.dataRevision) {
            computeStyle()
        }
    }

    private func computeStyle() -> (Color, String) {
        guard let data = model.data else { return (drillIn.palette.color, drillIn.symbol) }
        let picker = data.categoryPicker(for: .expense)
        let breakdown = CategoryBreakdown.build(
            month: drillIn.month, ledger: model.ledger, budgetLimits: data.budgetLimits,
            activeExpenseCategories: picker.map(\.name))
        guard let record = breakdown.records.first(where: { DartString.equal($0.name, drillIn.category) }) else {
            return (drillIn.palette.color, drillIn.symbol)
        }
        return (record.palette.color, SpendDrillIn.symbol(for: record, in: SpendDrillIn.activeSymbols(picker)))
    }
}

/// The category's style, recomputed only when the ledger or the data changed
/// (`dataRevision` is bumped by every change of `model.data`, which holds the
/// categories and budget limits the breakdown reads) or the route is another.
/// A plain reference held in `@State`, so reading it in `body` is not an
/// observed change.
private final class StyleCache {
    private var key: Key?
    private var cached: (Color, String)?

    private struct Key: Equatable {
        let drillIn: SpendDrillIn
        let ledgerRevision: Int
        let dataRevision: Int
    }

    func style(
        for drillIn: SpendDrillIn, ledgerRevision: Int, dataRevision: Int, compute: () -> (Color, String)
    ) -> (Color, String) {
        let wanted = Key(drillIn: drillIn, ledgerRevision: ledgerRevision, dataRevision: dataRevision)
        if let cached, key == wanted { return cached }
        let style = compute()
        cached = style
        key = wanted
        return style
    }
}

/// `_buildSummaryCard` (:159-235) as a plain card (Flutter tints it with the
/// category colour): "TOTAL SPENT", the total with two decimals, the month
/// and count pills in the category colour, and the 56pt tile.
private struct SummaryCard: View {
    let total: String
    let month: DartDateTime
    let count: Int
    let color: Color
    let symbol: String

    var body: some View {
        let (monthText, countText) = MonthListCopy.drillInPills(month: month, count: count)
        GlowCard {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TOTAL SPENT")
                        .textStyle(.eyebrow)
                        .foregroundStyle(BudgieColor.textSecondary)
                    Text(total)
                        .textStyle(.heroSmall)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.3)
                        .padding(.top, 10)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Metrics.spacingS) { pills(monthText, countText) }
                        VStack(alignment: .leading, spacing: Metrics.spacingS) { pills(monthText, countText) }
                    }
                    .padding(.top, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                IconTile(symbol: symbol, color: color, size: 56, radius: 18, iconSize: 28)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Total spent \(total), \(monthText), \(countText)")
        .accessibilityIdentifier("spend.drillIn.summary")
    }

    @ViewBuilder
    private func pills(_ month: String, _ count: String) -> some View {
        PillChip(label: month, color: color, textColor: BudgieColor.legible(color))
        PillChip(label: count, color: color, textColor: BudgieColor.legible(color))
    }
}

/// `_TransactionRow` (:236-330) as a SEE ALL row (padding 12): the category
/// tile in its Spend colour, the description (and the recurrence glyph),
/// the `MMMd` date, and the unsigned two-decimal amount (Flutter's; the
/// page lists only expenses).
private struct ExpenseRow: View {
    let record: TransactionRecord
    let color: Color
    let symbol: String
    let formatter: MoneyFormatter
    let onTap: () -> Void

    var body: some View {
        let amount = formatter.format(record.amount)
        Button(action: onTap) {
            TransactionRowLayout(
                textMinWidth: 56, plainSubtitleAndAmount: true,
                title: record.description, isRecurring: record.isRecurring,
                subtitle: DartDateFormat.MMMd(record.date), amount: amount, amountColor: BudgieColor.textPrimary
            ) {
                IconTile(symbol: symbol, color: color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the Button itself, so VoiceOver keeps its activation.
        .accessibilityLabel(
            "\(record.description), \(amount), on \(DartDateFormat.yMMMMd(record.date))\(record.isRecurring ? ", recurring" : "")")
        .accessibilityHint("Double tap to edit, swipe left to delete")
        .accessibilityIdentifier("spend.drillIn.row")
    }
}
