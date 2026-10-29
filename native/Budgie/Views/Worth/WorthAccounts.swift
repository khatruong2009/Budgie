import BudgieCore
import SwiftUI

// MARK: - Toggle (NW:938-1025)

/// "Assets" / "Liabilities" as two equal segments on the track, the
/// selected one in the selection fill. Tapping the selected segment does
/// nothing; a switch ticks.
struct AccountsToggle: View {
    @Binding var isAssetsTab: Bool

    var body: some View {
        HStack(spacing: Metrics.spacingXS) {
            chip("Assets", assets: true)
            chip("Liabilities", assets: false)
        }
        .padding(Metrics.spacingXS)
        .background(BudgieColor.track, in: Capsule())
        .sensoryFeedback(.selection, trigger: isAssetsTab)
    }

    private func chip(_ title: String, assets: Bool) -> some View {
        let selected = isAssetsTab == assets
        return Button {
            if !selected { isAssetsTab = assets }
        } label: {
            Text(title)
                .textStyle(selected ? WorthStyle.chipBold : WorthStyle.chip)
                .foregroundStyle(selected ? BudgieColor.selectionText : BudgieColor.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(selected ? BudgieColor.selectionFill : .clear, in: Capsule())
                .contentShape(Capsule())
                // The segment draws 40pt tall; the tap area is 44.
                .tapArea(vertical: 2)
        }
        .buttonStyle(.plain)
        .motion(Motion.segment, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(assets ? "worth.toggle.assets" : "worth.toggle.liabilities")
    }
}

// MARK: - Accounts list (NW:1029-1091)

/// The active side's accounts that have a value in the month (amount desc,
/// then name), in one list card; a centred note when there are none.
struct WorthAccountsList: View {
    let entries: [NetWorthEntryRecord]
    let month: DartDateTime
    let isAssetsTab: Bool
    let formatter: MoneyFormatter
    let rowStats: (NetWorthEntryRecord) -> NetWorthAccountRowStats
    let onViewHistory: (NetWorthEntryRecord) -> Void
    let onEdit: (NetWorthEntryRecord) -> Void
    let onDelete: (NetWorthEntryRecord) -> Void

    var body: some View {
        if entries.isEmpty {
            GlowCard {
                Text(NetWorthText.emptyList(isAssetsTab: isAssetsTab, month: month))
                    .textStyle(WorthStyle.note)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.spacingM)
            }
            .accessibilityIdentifier("worth.accounts.empty")
        } else {
            // Unkeyed rows, as Flutter's Column: a row's bar tweens from the
            // value its slot showed before (tab or month switch).
            GlowListCard(rows: entries.map { entry in
                AccountRow(
                    entry: entry, stats: rowStats(entry), isAssetsTab: isAssetsTab, formatter: formatter,
                    onViewHistory: { onViewHistory(entry) }, onEdit: { onEdit(entry) }, onDelete: { onDelete(entry) })
            })
        }
    }
}

/// One account (`_AccountRow`, NW:1095-1226): the keyword icon on a tile
/// tinted by the account's type, the name over its share of the tab's
/// total, the whole-unit amount over the change against the previous
/// snapshot (green when good for the type, tertiary "—" when there is
/// none), and a 6pt share bar. A tap opens the account editor, as in
/// Flutter; the context menu has Flutter's long-press sheet actions (Edit
/// Balance, View History, Delete Account).
struct AccountRow: View {
    let entry: NetWorthEntryRecord
    let stats: NetWorthAccountRowStats
    let isAssetsTab: Bool
    let formatter: MoneyFormatter
    let onViewHistory: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var taps = 0

    var body: some View {
        let tint = entry.type == .asset ? BudgieColor.income : BudgieColor.danger
        let changeColor = stats.changeIsFavorable.map { $0 ? BudgieColor.income : BudgieColor.danger } ?? BudgieColor.textTertiary
        let amount = formatter.formatSigned(stats.amount, decimalDigits: 0)
        let share = NetWorthText.rowShare(stats.share, isAssetsTab: isAssetsTab)
        let change = NetWorthText.rowChange(stats.percentChange)
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous)
        Button {
            taps += 1
            onEdit()
        } label: {
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    IconTile(symbol: NetWorthAccountIcon(name: entry.name, type: entry.type).symbol, color: tint, size: 44)
                    VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                        Text(entry.name)
                            .textStyle(.rowTitle)
                            .foregroundStyle(BudgieColor.textPrimary)
                            .singleLine()
                        Text(share)
                            .textStyle(.rowSubtitle)
                            .foregroundStyle(BudgieColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    VStack(alignment: .trailing, spacing: Metrics.spacingXXS) {
                        Text(amount).textStyle(.amount).foregroundStyle(BudgieColor.textPrimary)
                        Text(change).textStyle(.badge).foregroundStyle(changeColor)
                    }
                    .padding(.leading, Metrics.spacingS)
                }
                GlowProgressBar(value: stats.share, height: 6, color: tint)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            // The card's own fill, so the context menu lifts an opaque row.
            .background(BudgieColor.card, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .contentShape(.contextMenuPreview, shape)
        .contextMenu {
            Button("Edit Balance", systemImage: "pencil", action: onEdit)
            Button("View History", systemImage: "chart.bar", action: onViewHistory)
            Button("Delete Account", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityLabel("\(entry.name), \(amount)")
        .accessibilityValue(
            "\(share), \(stats.percentChange == nil ? "no earlier balance" : "change \(change)")")
        .accessibilityHint("Edits the balance")
        .accessibilityAction(named: "View History", onViewHistory)
        .accessibilityAction(named: "Delete Account", onDelete)
        .accessibilityIdentifier("worth.account.\(entry.name)")
    }
}

extension NetWorthAccountIcon {
    /// The SF Symbol for Flutter's Material icon (spec 05 section 1.6.1, D3).
    var symbol: String {
        switch self {
        case .accountBalance: "building.columns"
        case .savings: "banknote"
        case .trendingUp: "chart.line.uptrend.xyaxis"
        case .home: "house"
        case .accountBalanceWallet: "wallet.pass"
        case .northEast: "arrow.up.right"
        case .attachMoney: "dollarsign"
        case .southWest: "arrow.down.left"
        }
    }
}
