import BudgieCore
import SwiftUI

/// One account's balance history (`_AccountHistoryPage`,
/// net_worth_page.dart:1370-1575), pushed from a Worth row (system back,
/// D2): the hero card, the CURRENT / PEAK / LOW cards, the trend chart and
/// the timeline of balance updates newest first, each deletable behind
/// Flutter's confirmation. Every value is all-time, independent of the
/// selected month. The bar's Edit opens the account editor for the
/// selected Worth month (`model.selectedNetWorthMonth`), as Flutter's does.
///
/// Live: it reads the entry from the model on every change, so an edit or
/// delete elsewhere shows at once. When the account disappears (deleted
/// elsewhere, or a restore without it) the page shows a closed state
/// instead of Flutter's stale name over empty cards; deleting it from this
/// page pops back to Worth, as Flutter does.
struct AccountHistoryView: View {
    let entryID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pendingSnapshot: PendingSnapshot?
    @State private var confirmingAccountDelete = false
    @State private var editor: AccountEditorRequest?
    /// Set once this page's own account delete removed the entry, so the
    /// pop does not flash the closed state.
    @State private var closing = false

    /// The snapshot awaiting confirmation, with the name the dialog shows.
    private struct PendingSnapshot {
        let snapshot: NetWorthSnapshotRecord
        let name: String
    }

    var body: some View {
        let entry = model.netWorthEntry(id: entryID)
        Group {
            if let entry {
                content(entry)
            } else if closing {
                Color.clear
            } else {
                EmptyStateView(
                    kind: .noData, symbol: "tray", title: "Account deleted",
                    message: "This account is no longer tracked in your net worth.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("worth.history.missing")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BudgieColor.background)
        .navigationTitle(entry?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(BudgieColor.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(entry?.name ?? "")
                    .textStyle(.cardTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .singleLine()
                    .accessibilityAddTraits(.isHeader)
            }
            if let entry {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editor = AccountEditorRequest(
                            month: model.selectedNetWorthMonth, entry: entry, initialType: entry.type,
                            calendar: model.calendar)
                    } label: {
                        Image(systemName: "pencil").foregroundStyle(BudgieColor.textPrimary)
                    }
                    .accessibilityLabel("Edit balance")
                    .accessibilityIdentifier("worth.history.edit")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirmingAccountDelete = true
                    } label: {
                        Image(systemName: "trash").foregroundStyle(BudgieColor.danger)
                    }
                    .accessibilityLabel("Delete account")
                    .accessibilityIdentifier("worth.history.deleteAccount")
                }
            }
        }
        // `_showNetWorthEditor` from the bar's Edit (NW:1424-1436).
        .budgieDialog(item: $editor, padding: 0) { request in
            AccountEditorDialog(request: request) { editor = nil }
        }
        // `_confirmDeleteNetWorthSnapshot` (NW:2905-2938): Material
        // AlertDialog, both actions plain accent TextButtons (Delete is not
        // red), no haptics.
        .alert("Delete balance update?", isPresented: snapshotAlertBinding, presenting: pendingSnapshot) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Delete") {
                Task { await deleteSnapshot(pending.snapshot) }
            }
        } message: { pending in
            Text(NetWorthText.deleteSnapshotMessage(recordedAt: pending.snapshot.recordedAt, name: pending.name))
        }
        // `_confirmDeleteNetWorthEntry` (NW:2871-2903), then pop when the
        // entry is gone (NW:1444-1455).
        .alert("Delete account?", isPresented: $confirmingAccountDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete") {
                Task { await deleteAccount() }
            }
        } message: {
            Text(NetWorthText.deleteAccountMessage(name: entry?.name ?? ""))
        }
    }

    private func content(_ entry: NetWorthEntryRecord) -> some View {
        let history = NetWorthAccountHistory(history: model.netWorthEntryHistory(id: entryID), type: entry.type)
        let color = entry.type == .asset ? BudgieColor.income : BudgieColor.danger
        let formatter = model.moneyFormatter
        let count = history.chart.count

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AccountHistoryHeroCard(type: entry.type, color: color, history: history, formatter: formatter)
                HStack(alignment: .top, spacing: 8) {
                    AccountHistoryStatCard(label: "CURRENT", value: formatter.formatCompact(history.latestAmount), color: color)
                        .accessibilityIdentifier("worth.history.stat.current")
                    AccountHistoryStatCard(
                        label: "PEAK", value: history.peak.map(formatter.formatCompact) ?? "\u{2014}", color: color)
                        .accessibilityIdentifier("worth.history.stat.peak")
                    AccountHistoryStatCard(
                        label: "LOW", value: history.low.map(formatter.formatCompact) ?? "\u{2014}",
                        color: BudgieColor.textPrimary)
                        .accessibilityIdentifier("worth.history.stat.low")
                }
                .padding(.top, 16)
                AccountTrendChart(name: entry.name, history: history.chart, color: color, formatter: formatter)
                    .padding(.top, 16)
                HStack(spacing: 8) {
                    Text("Timeline")
                        .textStyle(.sectionHeader)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Text(NetWorthText.entryCount(count))
                        .textStyle(.rowSubtitle)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .accessibilityIdentifier("worth.history.timeline.count")
                }
                .padding(.horizontal, 4)
                .padding(.top, 24)
                timeline(history, name: entry.name, color: color, formatter: formatter)
                    .padding(.top, 12)
            }
            // Flutter's (20, 8, 20, 32); the scroll view's safe area keeps
            // the last row clear of the tab bar (Flutter's sits under the dock).
            .padding(EdgeInsets(top: 8, leading: Metrics.pageHorizontal, bottom: 32, trailing: Metrics.pageHorizontal))
            .frame(maxWidth: Metrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("worth.history")
    }

    @ViewBuilder
    private func timeline(_ history: NetWorthAccountHistory, name: String, color: Color, formatter: MoneyFormatter) -> some View {
        if history.timeline.isEmpty {
            GlowCard {
                Text("Add updates to this account to build a balance timeline.")
                    .textStyle(AccountHistoryText.note)
                    .foregroundStyle(BudgieColor.textSecondary)
            }
            .accessibilityIdentifier("worth.history.timeline.empty")
        } else {
            // The model allows deleting the last snapshot; the page does not.
            let canDelete = history.chart.count > 1
            GlowListCard(lazy: true, rows: history.timeline.map { item in
                AccountTimelineRow(
                    snapshot: item.snapshot, delta: item.delta, deltaIsFavorable: item.deltaIsFavorable, color: color,
                    canDelete: canDelete, formatter: formatter
                ) {
                    pendingSnapshot = PendingSnapshot(snapshot: item.snapshot, name: name)
                }
            })
        }
    }

    private var snapshotAlertBinding: Binding<Bool> {
        Binding(get: { pendingSnapshot != nil }, set: { if !$0 { pendingSnapshot = nil } })
    }

    /// Awaits the write; a failed one keeps the change in memory and says so.
    private func deleteSnapshot(_ snapshot: NetWorthSnapshotRecord) async {
        // Already gone (deleted elsewhere): nothing failed.
        guard model.netWorthEntryHistory(id: entryID).contains(where: { $0.recordedAt == snapshot.recordedAt }) else {
            return
        }
        let saved = await model.deleteNetWorthSnapshot(entryID: entryID, recordedAt: snapshot.recordedAt)
        if !saved { model.showToast(.saveFailed) }
    }

    /// Flutter pops whenever the entry is gone after the delete, even when
    /// the write failed (the change stays in memory).
    /// `closing` is set before the delete: the entry leaves memory at once,
    /// while the write is awaited, and the page must not show "Account
    /// deleted" meanwhile.
    private func deleteAccount() async {
        guard model.netWorthEntry(id: entryID) != nil else { return }
        closing = true
        let saved = await model.deleteNetWorthEntry(id: entryID)
        if !saved { model.showToast(.saveFailed) }
        if model.netWorthEntry(id: entryID) == nil {
            dismiss()
        } else {
            closing = false
        }
    }
}
