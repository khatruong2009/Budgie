import BudgieCore
import SwiftUI

/// The pieces of the account history page (net_worth_page.dart:1577-2136).

enum AccountHistoryText {
    /// `amount` at 17 (the stat card values).
    static let statValue = TextSpec(face: .gabaritoBold, size: 17, tabular: true, relativeTo: .body)
    /// `rowSubtitle` at 11, w600 (the chart tooltip's date).
    static let tooltipDate = TextSpec(face: .gabaritoSemiBold, size: 11, height: 1.25, relativeTo: .caption2)
}

// MARK: - Hero

/// `_AccountHistoryHeroCard` (NW:1577-1762) as a plain card (padding 24;
/// Flutter washes it with the account colour, REDESIGN_PLAN 4.7): the
/// type's tinted arrow tile, "Balance history" over the last update, the
/// type badge, CURRENT BALANCE, the signed balance and the meta chips.
struct AccountHistoryHeroCard: View {
    let type: NetWorthEntryType
    let color: Color
    let history: NetWorthAccountHistory
    let formatter: MoneyFormatter

    private struct MetaChip {
        let symbol: String
        let label: String
        let color: Color
        let background: Color
    }

    var body: some View {
        let isAsset = type == .asset
        let balance = formatter.formatSigned(history.latestAmount)
        let lastUpdate = NetWorthText.lastUpdate(history.latest?.recordedAt)
        let chips = metaChips

        GlowCard(padding: 24) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    IconTile(symbol: isAsset ? "arrow.up.right" : "arrow.down.left", color: color, size: 48, iconSize: 24)
                        .padding(.trailing, Metrics.spacingM)
                    VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                        Text("Balance history")
                            .textStyle(.cardTitle)
                            .foregroundStyle(BudgieColor.textPrimary)
                        Text(lastUpdate)
                            .textStyle(.rowSubtitle)
                            .foregroundStyle(BudgieColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PillChip(
                        label: isAsset ? "Asset" : "Liability", color: color, textColor: BudgieColor.legible(color),
                        style: .badgeSmall)
                }
                Text("CURRENT BALANCE")
                    .textStyle(.eyebrow)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .padding(.top, Metrics.spacingL)
                // `FittedBox(scaleDown)`: one line, shrunk to fit.
                Text(balance)
                    .textStyle(.heroSmall)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(.top, 6)
                // `Wrap(spacing: 8, runSpacing: 8)` of at most three chips.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Metrics.spacingS) { chipViews(chips[...]) }
                    VStack(alignment: .leading, spacing: Metrics.spacingS) {
                        HStack(spacing: Metrics.spacingS) { chipViews(chips.prefix(2)) }
                        chipViews(chips.dropFirst(2))
                    }
                    VStack(alignment: .leading, spacing: Metrics.spacingS) { chipViews(chips[...]) }
                }
                .padding(.top, Metrics.spacingM)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([isAsset ? "Asset balance history" : "Liability balance history", "Current balance \(balance)", lastUpdate]
                + chips.map(\.label)).joined(separator: ". "))
        .accessibilityIdentifier("worth.history.hero")
    }

    /// The snapshot count (neutral), then "vs prior" coloured by the sign
    /// of the change and "overall" coloured by whether it is good for the
    /// type (so the two disagree for liabilities, as in Flutter).
    private var metaChips: [MetaChip] {
        // Flutter: white 6% (dark) / black 5% (light); the hairline token
        // is the same in dark and within 1% in light.
        var chips = [
            MetaChip(
                symbol: "calendar", label: NetWorthText.snapshotCount(history.chart.count), color: BudgieColor.textPrimary,
                background: BudgieColor.hairline)
        ]
        if let change = history.changeFromPrevious {
            let tint = change >= 0 ? BudgieColor.income : BudgieColor.danger
            chips.append(MetaChip(
                symbol: change >= 0 ? "arrow.up.right" : "arrow.down.left",
                label: formatter.formatCompactDelta(change) + " vs prior", color: tint, background: tint.opacity(0.14)))
        }
        if let total = history.totalChange {
            let positive = history.totalChangeIsPositive == true
            let tint = positive ? BudgieColor.income : BudgieColor.danger
            chips.append(MetaChip(
                symbol: positive ? "arrow.up.right" : "arrow.down.left",
                label: formatter.formatCompactDelta(total) + " overall", color: tint, background: tint.opacity(0.14)))
        }
        return chips
    }

    /// `_metaChip`: padding 10 x 6, capsule, 14pt icon, 6, `badgeSmall`.
    private func chipViews(_ chips: ArraySlice<MetaChip>) -> some View {
        ForEach(chips.indices, id: \.self) { index in
            let chip = chips[index]
            HStack(spacing: 6) {
                Image(systemName: chip.symbol).font(.system(size: 12, weight: .medium))
                Text(chip.label).textStyle(.badgeSmall).lineLimit(1)
            }
            .foregroundStyle(chip.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(chip.background, in: Capsule())
            .fixedSize()
        }
    }
}

// MARK: - Stat card

/// `_AccountHistoryStatCard` (NW:1764-1800): GlowCard radius 22, padding
/// 16, the mono label, 8, the compact value in `amount` at 17.
struct AccountHistoryStatCard: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        GlowCard(padding: 16, radius: Metrics.statCardRadius) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text(label)
                    .textStyle(.monoMetricLabel)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(value)
                    .textStyle(AccountHistoryText.statValue)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized) \(value)")
    }
}

// MARK: - Timeline row

/// `_AccountHistoryTimelineRow` (NW:1802-1902) as a list row (REDESIGN_PLAN
/// 4.7): padding 12, a 40pt calendar tile in the account colour (Flutter: a
/// 12pt dot), 12, the `yMMMd` date over the `jm` time, 8, the signed amount
/// over the compact change from the next older update (green when good for
/// the type), 4, then the 48pt trash button, disabled (tertiary) while it
/// is the only update.
struct AccountTimelineRow: View {
    let snapshot: NetWorthSnapshotRecord
    let delta: Double?
    let deltaIsFavorable: Bool?
    let color: Color
    let canDelete: Bool
    let formatter: MoneyFormatter
    let onDelete: () -> Void

    @ScaledMetric(relativeTo: .body) private var trashSize: CGFloat = 16

    var body: some View {
        let date = DartDateFormat.yMMMd(snapshot.recordedAt)
        let time = DartDateFormat.jm(snapshot.recordedAt)
        let amount = formatter.formatSigned(snapshot.amount)
        let change = delta.map(formatter.formatCompactDelta)
        let changeColor = deltaIsFavorable.map { $0 ? BudgieColor.income : BudgieColor.danger } ?? BudgieColor.textSecondary

        HStack(spacing: 0) {
            HStack(spacing: 0) {
                IconTile(symbol: "calendar", color: color)
                    .padding(.trailing, 12)
                VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                    Text(date)
                        .textStyle(.rowTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                    Text(time)
                        .textStyle(.rowSubtitle)
                        .foregroundStyle(BudgieColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Metrics.spacingXXS) {
                    Text(amount)
                        .textStyle(.amountSmall)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let change {
                        Text(change)
                            .textStyle(.badge)
                            .foregroundStyle(changeColor)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, Metrics.spacingS)
                .layoutPriority(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([date, time, amount].joined(separator: ", ") + (change.map { ", change \($0)" } ?? ""))
            .accessibilityActions {
                if canDelete { Button("Delete", action: onDelete) }
            }
            .accessibilityIdentifier("worth.history.timeline.row")
            Button(action: onDelete) {
                // Material `delete_rounded` 18 / w500 in a 48pt IconButton.
                Image(systemName: "trash.fill")
                    .font(.system(size: trashSize, weight: .medium))
                    .foregroundStyle(canDelete ? BudgieColor.danger : BudgieColor.textTertiary)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .padding(.leading, Metrics.spacingXS)
            .help(canDelete ? "Delete this balance update" : "Keep at least one balance update")
            .accessibilityLabel(canDelete ? "Delete this balance update" : "Keep at least one balance update")
            .accessibilityIdentifier("worth.history.timeline.delete")
        }
        .padding(12)
    }
}
