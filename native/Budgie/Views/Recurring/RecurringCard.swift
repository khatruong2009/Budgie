import BudgieCore
import SwiftUI

/// A template card (`_RecurringTransactionListItem`,
/// recurring_transactions_page.dart:227-366) in the redesign's card language
/// (D15, REDESIGN_PLAN 4.7): a GlowCard whose header is a Recent activity
/// row (the category's 40pt tile, the description with the recurrence
/// glyph over the category, the amount); a hairline; the
/// "Pattern" and "Next Occurrence" columns; then Edit, Pause / Resume
/// (approved MVP extra, Flutter has none) and Delete. A paused card is
/// dimmed and badged "Paused", its buttons stay at full strength.
struct RecurringCard: View {
    let template: RecurringTemplate
    let onEdit: () -> Void
    let onToggleActive: () -> Void
    let onDelete: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let amount = model.moneyFormatter.format(template.amount)
        let next = DartDateFormat.MMMddyyyy(template.nextOccurrence)
        let pattern = template.pattern.displayName
        GlowCard(padding: Metrics.spacingM) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    header(amount: amount)
                    Hairline().padding(.vertical, Metrics.spacingM)
                    // Two columns; one above the other at accessibility text
                    // sizes, where half the width splits the words.
                    let columns =
                        dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: Metrics.spacingS))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: Metrics.spacingM))
                    columns {
                        detail(symbol: "repeat", label: "Pattern", value: pattern)
                        detail(symbol: "calendar", label: "Next Occurrence", value: next)
                    }
                }
                .opacity(template.isActive ? 1 : 0.65)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(template.description), \(template.type == .income ? "income" : "expense"), \(amount), "
                        + "\(template.category), \(pattern), next occurrence \(next)" + (template.isActive ? "" : ", paused"))
                .accessibilityIdentifier("recurring.summary")
                actions
                    .padding(.top, Metrics.spacingM)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recurring.card")
    }

    // MARK: - Pieces

    /// Tile, description (rowTitle) over category (rowSubtitle), amount
    /// (amountSmall). At accessibility text sizes the description keeps the
    /// row's width: it wraps freely, and the Paused chip and the amount move
    /// under it.
    private func header(amount: String) -> some View {
        let isIncome = template.type == .income
        let stacked = dynamicTypeSize.isAccessibilitySize
        let amountText = Text(amount)
            .textStyle(.amountSmall)
            .foregroundStyle(isIncome ? BudgieColor.income : BudgieColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        let pausedChip = PillChip(label: "Paused", color: BudgieColor.warning, style: .badgeSmall, horizontalPadding: 8, verticalPadding: 3)
            .fixedSize()
        return HStack(alignment: stacked ? .top : .center, spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                HStack(spacing: 6) {
                    Text(template.description)
                        .textStyle(.rowTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .lineLimit(stacked ? nil : 2)
                    RecurrenceGlyph(size: 16).fixedSize()
                    if !template.isActive && !stacked { pausedChip }
                }
                if !template.isActive && stacked { pausedChip }
                Text(template.category)
                    .textStyle(.rowSubtitle)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .lineLimit(stacked ? nil : 1)
                if stacked { amountText }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked { amountText.layoutPriority(1) }
        }
    }

    /// Flutter's detail item: a 20pt (`iconS`) icon, the `caption` w600
    /// label, the `bodySmall` value.
    private func detail(symbol: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
            HStack(spacing: Metrics.spacingXS) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 20)
                Text(label).textStyle(.captionStrong)
            }
            .foregroundStyle(BudgieColor.textSecondary)
            Text(value)
                .textStyle(.bodySmall)
                .foregroundStyle(BudgieColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row of three equal pills with their symbols; without the symbols
    /// when a label would not fit its third of the row (the outlined pill's
    /// 20pt insets leave about 64pt on an iPhone 17 Pro); stacked when even
    /// that does not fit (large text). At least 44pt tall, taller when the
    /// text needs it.
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            EqualWidthRow { buttons(symbols: true) }
            EqualWidthRow { buttons(symbols: false) }
            VStack(spacing: Metrics.spacingS) { buttons(symbols: true) }
        }
    }

    @ViewBuilder
    private func buttons(symbols: Bool) -> some View {
        PillButton(
            title: "Edit", symbol: symbols ? "pencil" : nil, minHeight: Metrics.pillButtonCompactHeight, action: onEdit)
            .accessibilityIdentifier("recurring.edit")
        PillButton(
            title: template.isActive ? "Pause" : "Resume",
            symbol: symbols ? (template.isActive ? "pause.fill" : "play.fill") : nil,
            color: template.isActive ? BudgieColor.warning : BudgieColor.income, minHeight: Metrics.pillButtonCompactHeight,
            action: onToggleActive
        )
        .accessibilityIdentifier("recurring.pause")
        PillButton(
            title: "Delete", symbol: symbols ? "trash" : nil, color: BudgieColor.danger,
            minHeight: Metrics.pillButtonCompactHeight, action: onDelete
        )
        .accessibilityIdentifier("recurring.delete")
    }

    /// The category's tile (found case-insensitively, archived included);
    /// Flutter's fallback icons otherwise (`shopping_bag`, `attach_money`),
    /// in accent or income.
    @ViewBuilder private var tile: some View {
        if let info = model.categoryInfo(named: template.category, type: template.type) {
            IconTile(category: info)
        } else if template.type == .income {
            IconTile(symbol: "dollarsign", color: BudgieColor.income)
        } else {
            IconTile(symbol: "bag.fill", color: BudgieColor.accent)
        }
    }
}

/// Its subviews in one row of equal widths, 8 apart. Its ideal width is the
/// widest subview's ideal times the count, so a `ViewThatFits` moves on
/// when a label would wrap in its equal share.
private struct EqualWidthRow: Layout {
    private let spacing = Metrics.spacingS

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = widest * CGFloat(subviews.count) + gaps
        }
        let share = ProposedViewSize(width: (width - gaps) / CGFloat(subviews.count), height: nil)
        let height = subviews.map { $0.sizeThatFits(share).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let share = (bounds.width - spacing * CGFloat(subviews.count - 1)) / CGFloat(subviews.count)
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: share, height: bounds.height))
            x += share + spacing
        }
    }
}
