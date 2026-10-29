import BudgieCore
import SwiftUI

// MARK: - Flow chips

/// One of the two month-over-month tiles (`_FlowChip`,
/// spending_page.dart:1465-1550): the label, the month's amount in whole
/// units, the change from the month before (good changes in the income
/// colour, bad ones in danger) and a six-month sparkline. Not tappable.
struct FlowChip: View {
    let label: String
    let amount: Double
    /// The six months ending at this one, oldest first.
    let trend: [Double]
    let line: Color
    let delta: Double?
    /// Income: a rise is good. Expenses: a fall is good.
    let goodWhenUp: Bool
    let previousMonthName: String
    let formatter: MoneyFormatter

    private var deltaColor: Color {
        guard let delta else { return BudgieColor.textTertiary }
        if delta == 0 { return BudgieColor.textSecondary }
        return (delta > 0) == goodWhenUp ? BudgieColor.income : BudgieColor.danger
    }

    var body: some View {
        GlowCard(padding: 16, radius: Metrics.statCardRadius) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .textStyle(.noteStrong)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .singleLine()
                Text(HomeSummary.chipAmount(amount, formatter: formatter))
                    .textStyle(.chipAmount)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(.top, Metrics.spacingS)
                Text(HomeSummary.deltaLabel(delta: delta, previousMonthName: previousMonthName))
                    .textStyle(.rowSubtitle)
                    .foregroundStyle(deltaColor)
                    .singleLine()
                    .padding(.top, Metrics.spacingXXS)
                Sparkline(values: trend, color: line)
                    .frame(height: 28)
                    .padding(.top, 10)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A line through `values`, scaled to their range (flat and centred when
/// they are all equal).
private struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let span = high - low
            let inset: CGFloat = 2
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let share = span > 0 ? (value - low) / span : 0.5
                let y = inset + (size.height - inset * 2) * (1 - share)
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Safe to spend

/// The safe-to-spend card (`_SafeToSpendCard`, spending_page.dart:1222-1328),
/// Home's feature card: the title, the amount and the daily allowance on
/// the feature fill, with a chevron; tap opens the breakdown. An
/// over-committed month reads "Projected shortfall" with the positive
/// shortfall in danger.
struct SafeToSpendCard: View {
    let breakdown: SafeToSpendBreakdown
    let formatter: MoneyFormatter
    let onTap: () -> Void

    static let amountText = TextSpec(face: .gabaritoExtraBold, size: 32, tracking: -1, height: 1.05, tabular: true, relativeTo: .title)

    var body: some View {
        let card = HomeSummary.safeToSpendCard(breakdown, formatter: formatter)
        HapticButton(action: onTap) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                    Text(card.title)
                        .textStyle(.noteStrong)
                        .foregroundStyle(BudgieColor.featureSecondary)
                        .singleLine()
                    Text(card.amount)
                        .textStyle(Self.amountText)
                        .foregroundStyle(card.isOver ? BudgieColor.featureDanger : BudgieColor.featureAmount)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(card.subtitle)
                        .textStyle(.note)
                        .foregroundStyle(BudgieColor.featureSecondary)
                        .wrapsWords()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(BudgieColor.featureText)
                    .frame(width: 38, height: 38)
                    .background(BudgieColor.featureControl, in: Circle())
                    .accessibilityHidden(true)
            }
            .featureCard()
        }
        .buttonStyle(PressScaleStyle(scale: 0.98))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home.safeToSpend")
    }
}

// MARK: - Recent activity

/// The newest three transactions of any month (`_RecentActivityCard`,
/// spending_page.dart:1706-1816). A row opens its edit form, like SEE ALL.
struct RecentActivityCard: View {
    let rows: ArraySlice<LedgerRow>
    let formatter: MoneyFormatter
    let onSelect: (TransactionRecord) -> Void

    /// `rowSubtitle` at 14.
    private static let empty = TextSpec(face: .gabaritoRegular, size: 14, height: 1.25, relativeTo: .subheadline)

    var body: some View {
        if rows.isEmpty {
            // The empty-state pattern (dashed card, accent tile) in a compact
            // form: a full 72pt tile and padding is too heavy under the hero.
            let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(BudgieColor.accent)
                    .frame(width: 48, height: 48)
                    .background(BudgieColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous))
                    .accessibilityHidden(true)
                Text("No transactions yet.")
                    .textStyle(Self.empty)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, Metrics.spacingL)
            .padding(.horizontal, Metrics.spacingL)
            .frame(maxWidth: .infinity)
            .overlay(shape.strokeBorder(BudgieColor.textTertiary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .accessibilityElement(children: .combine)
        } else {
            GlowListCard(rows: rows.map { row in
                RecentRow(record: row.record, formatter: formatter) { onSelect(row.record) }
            })
        }
    }
}

private struct RecentRow: View {
    let record: TransactionRecord
    let formatter: MoneyFormatter
    let onTap: () -> Void

    @Environment(AppModel.self) private var model
    var body: some View {
        let isIncome = record.type == .income
        let day = DartDateFormat.MMMd(record.date)
        let copy = HomeSummary.recentRow(record, formatter: formatter)
        HapticButton(action: onTap) {
            TransactionRowLayout(
                title: copy.title, isRecurring: record.isRecurring, subtitle: copy.subtitle,
                amount: copy.amount, amountColor: isIncome ? BudgieColor.income : BudgieColor.textPrimary
            ) {
                if isIncome {
                    IconTile(symbol: "arrow.down.left", color: BudgieColor.income)
                } else {
                    IconTile(category: model.categoryInfo(named: record.category, type: .expense))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Flutter's label is "description, category, day, type amount";
        // VoiceOver reads the label then the value, so this sounds the
        // same while the description stays findable on its own.
        .accessibilityLabel(copy.title)
        .accessibilityValue(
            "\(record.category), \(day), \(isIncome ? "income" : "expense") \(formatter.format(record.amount))"
                + (record.isRecurring ? ", recurring" : ""))
        .accessibilityHint("Double tap to edit")
    }
}
