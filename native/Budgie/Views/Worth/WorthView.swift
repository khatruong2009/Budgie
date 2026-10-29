import BudgieCore
import SwiftUI

/// The Worth tab (`NetWorthPage`, net_worth_page.dart:23-251): the "Net
/// worth" header, the month chip strip (D13) bound to the persisted
/// `selectedNetWorthMonth`, the hero, the growth chart, the assets vs
/// liabilities split, the Assets / Liabilities toggle and that side's
/// accounts, with the add button floating bottom-trailing. Without any
/// account it shows the empty card instead. The Assets tab and the 1Y range
/// are view state, as in Flutter.
///
/// Every mutation is an awaited `AppModel` call; the account editor is a
/// centred `budgieDialog` like Flutter's `showDialog`.
struct WorthView: View {
    @Environment(AppModel.self) private var model
    @State private var isAssetsTab = true
    @State private var range: NetWorthGrowthRange = .oneYear
    @State private var editor: AccountEditorRequest?
    @State private var pendingDelete: NetWorthEntryRecord?
    @State private var historyEntryID: String?
    @State private var monthTaps = 0

    var body: some View {
        Group {
            if let data = model.data {
                if data.hasNetWorthEntries {
                    populated(data)
                } else {
                    empty
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(BudgieColor.background)
        // Flutter's page sits in a `SafeArea`: scrolled content ends below
        // the status bar, which keeps the page background.
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 0)
                .background(BudgieColor.background.ignoresSafeArea(edges: .top))
                .accessibilityHidden(true)
        }
        .toolbar(.hidden, for: .navigationBar)
        .floatingActionInset(visible: model.data != nil) {
            // The populated page passes the active tab's type; the empty
            // state leaves it unset (asset), as Flutter.
            GlowFab(label: "Add account") {
                openEditor(entry: nil, type: model.hasNetWorthEntries && !isAssetsTab ? .liability : .asset)
            }
            .accessibilityIdentifier("worth.add")
        }
        .navigationDestination(item: $historyEntryID) { id in AccountHistoryView(entryID: id) }
        .budgieDialog(item: $editor, padding: 0) { request in
            AccountEditorDialog(request: request) { editor = nil }
        }
        .alert("Delete account?", isPresented: Binding(isPresent: $pendingDelete), presenting: pendingDelete) { entry in
            Button("Cancel", role: .cancel) {}
            // Flutter's accent TextButton: a plain role, as on the history page.
            Button("Delete") {
                Task { await delete(entry) }
            }
        } message: { entry in
            Text(NetWorthText.deleteAccountMessage(name: entry.name))
        }
        .sensoryFeedback(.selection, trigger: monthTaps)
    }

    // MARK: - Empty state (NW:198-251)

    private var empty: some View {
        ScrollView {
            VStack(spacing: 0) {
                BudgieHeader(title: "Net worth")
                EmptyStateView(
                    symbol: "chart.line.uptrend.xyaxis",
                    title: "No net worth accounts yet",
                    message: "Create your first asset or liability to start tracking net worth over time.",
                    actionTitle: "Add account", actionIdentifier: "worth.empty.add",
                    horizontalInset: 0
                ) {
                    openEditor(entry: nil, type: .asset)
                }
                .padding(EdgeInsets(top: 8 + 48, leading: Metrics.pageHorizontal, bottom: 0, trailing: Metrics.pageHorizontal))
            }
        }
    }

    // MARK: - Populated page (NW:87-190)

    private func populated(_ data: FinancialData) -> some View {
        let calendar = model.calendar
        let month = model.selectedNetWorthMonth
        let formatter = model.moneyFormatter
        let assets = data.totalAssets(forMonth: month)
        let liabilities = data.totalLiabilities(forMonth: month)
        let type: NetWorthEntryType = isAssetsTab ? .asset : .liability
        let entries = data.netWorthEntries(forMonth: month, type: type)
        let total = isAssetsTab ? assets : liabilities

        return ScrollView {
            VStack(spacing: 0) {
                BudgieHeader(title: "Net worth")
                MonthStrip(months: model.netWorthAvailableMonths, selected: month) { picked in
                    monthTaps += 1
                    Task { await select(picked) }
                }
                // Keep the chips out of the trailing safe area (the 27.1
                // rail's status column), as on SEE ALL.
                .clipped()
                WorthHero(month: month, netWorth: assets - liabilities, change: model.netWorthChange(forMonth: month), formatter: formatter)
                    .padding(EdgeInsets(top: 16, leading: 24, bottom: 0, trailing: 24))
                WorthGrowthCard(
                    history: Array(model.netWorthHistory.reversed()), range: $range, calendar: calendar, formatter: formatter)
                    .padding(.horizontal, Metrics.pageHorizontal)
                    .padding(.top, Metrics.spacingL)
                WorthSplitCard(assets: assets, liabilities: liabilities, formatter: formatter)
                    .padding(.horizontal, Metrics.pageHorizontal)
                    .padding(.top, Metrics.spacingM)
                AccountsToggle(isAssetsTab: $isAssetsTab)
                    .padding(.horizontal, Metrics.pageHorizontal)
                    .padding(.top, Metrics.spacingL)
                WorthAccountsList(
                    entries: entries, month: month, isAssetsTab: isAssetsTab, formatter: formatter,
                    rowStats: { $0.rowStats(forMonth: month, categoryTotal: total, calendar: calendar) },
                    onViewHistory: { historyEntryID = $0.id },
                    onEdit: { openEditor(entry: $0, type: $0.type) },
                    onDelete: { pendingDelete = $0 })
                    .padding(.horizontal, Metrics.pageHorizontal)
                    .padding(.top, Metrics.spacingM)
            }
        }
    }

    // MARK: - Actions

    private func openEditor(entry: NetWorthEntryRecord?, type: NetWorthEntryType) {
        editor = AccountEditorRequest(
            month: model.selectedNetWorthMonth, entry: entry, initialType: type, calendar: model.calendar)
    }

    /// `selectNetWorthMonth` persists even a re-tapped month (as Flutter);
    /// a failed write keeps the month in memory and says so.
    private func select(_ month: DartDateTime) async {
        if !(await model.selectNetWorthMonth(month)) { model.showToast(.saveFailed) }
    }

    private func delete(_ entry: NetWorthEntryRecord) async {
        // Already gone (deleted elsewhere): nothing failed.
        guard model.netWorthEntry(id: entry.id) != nil else { return }
        if !(await model.deleteNetWorthEntry(id: entry.id)) { model.showToast(.saveFailed) }
    }
}

/// Private text styles of the Worth views, built from the bundled faces.
enum WorthStyle {
    /// `rowSubtitle` w600 (labels).
    static let label = TextSpec(face: .gabaritoSemiBold, size: 12, height: 1.25, relativeTo: .caption)
    /// `rowTitle` at 14, w700 or w600 (toggles and dialog buttons).
    static let chipBold = TextSpec(face: .gabaritoBold, size: 14, height: 1.25, relativeTo: .subheadline)
    static let chip = TextSpec(face: .gabaritoSemiBold, size: 14, height: 1.25, relativeTo: .subheadline)
}

// MARK: - Hero

/// `_NetWorthHero` (NW:255-320), centred: the `TOTAL · MONTH YEAR` eyebrow,
/// the net worth as a rolling odometer in heroMedium, and the delta pill
/// when the month has a change. The odometer
/// rolls the rounded whole-unit amount in the base currency, with a leading
/// "-" when negative; Flutter's widget truncates the fraction and
/// hard-codes "$" (D6). Hide balances shows dots, as Home's hero does.
struct WorthHero: View {
    let month: DartDateTime
    let netWorth: Double
    let change: Double?
    let formatter: MoneyFormatter

    var body: some View {
        let label = formatter.formatSigned(netWorth, decimalDigits: 0)
        VStack(spacing: 0) {
            Text(NetWorthText.heroEyebrow(month: month))
                .textStyle(.eyebrow)
                .foregroundStyle(BudgieColor.textSecondary)
                .multilineTextAlignment(.center)
                .wrapsWords()
                .accessibilityAddTraits(.isHeader)
            Group {
                if formatter.hideBalances {
                    // Dots have no digits to roll.
                    Text(label)
                        .textStyle(.heroMedium)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .singleLine()
                } else {
                    RollingAmount(text: label, color: BudgieColor.textPrimary, style: .heroMedium)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NetWorthText.heroAccessibilityLabel(netWorth: netWorth, formatter: formatter))
            .accessibilityIdentifier("worth.hero")
            if let change {
                DeltaPill(change: change, previousNetWorth: netWorth - change, formatter: formatter)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// `_DeltaPill` (NW:324-382): tinted capsule, trend symbol and
/// `+$4,120 · +2.3% this month` on one line.
private struct DeltaPill: View {
    let change: Double
    let previousNetWorth: Double
    let formatter: MoneyFormatter

    /// `badge` at 13.
    private static let text = TextSpec(face: .gabaritoBold, size: 13, relativeTo: .footnote)

    var body: some View {
        let color = change >= 0 ? BudgieColor.income : BudgieColor.danger
        let label = NetWorthText.deltaPill(change: change, previousNetWorth: previousNetWorth, formatter: formatter)
        HStack(spacing: 6) {
            // Material `trending_up/down_rounded` 15 / w500.
            Image(systemName: change >= 0 ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 15, height: 15)
                .accessibilityHidden(true)
            Text(label)
                .textStyle(Self.text)
                .singleLine()
                .truncationMode(.tail)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, Metrics.spacingS)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.replacingOccurrences(of: " \u{00B7} ", with: ", "))
        .accessibilityIdentifier("worth.delta")
    }
}

// MARK: - Assets vs liabilities (NW:840-934)

/// A two-column legend of whole-unit totals over the split bar (the assets'
/// share of assets + liabilities, all assets when both are 0).
struct WorthSplitCard: View {
    let assets: Double
    let liabilities: Double
    let formatter: MoneyFormatter

    private static let amountText = TextSpec(face: .monoSemiBold, size: 17, height: 1.25, tabular: true, relativeTo: .body)

    var body: some View {
        let assetsText = formatter.formatSigned(assets, decimalDigits: 0)
        let liabilitiesText = formatter.formatSigned(liabilities, decimalDigits: 0)
        GlowCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    legend("Assets", assetsText, dot: BudgieColor.income, alignment: .leading)
                    legend("Liabilities", liabilitiesText, dot: BudgieColor.danger, alignment: .trailing)
                }
                SplitGlowBar(
                    assetsFraction: NetWorthPresentation.splitFraction(assets: assets, liabilities: liabilities), height: 12
                )
                .padding(.top, 14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assets \(assetsText), liabilities \(liabilitiesText)")
        .accessibilityIdentifier("worth.split")
    }

    private func legend(_ label: String, _ amount: String, dot: Color, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Metrics.spacingXS) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(label).textStyle(WorthStyle.label).foregroundStyle(BudgieColor.textSecondary)
            }
            Text(amount)
                .textStyle(Self.amountText)
                .foregroundStyle(BudgieColor.textPrimary)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

/// What the account editor opens with (`_showNetWorthEditor`): the page's
/// selected month, the account when editing, and the type to start on.
struct AccountEditorRequest: Identifiable {
    let id = UUID()
    let month: DartDateTime
    let entry: NetWorthEntryRecord?
    let initialType: NetWorthEntryType
    let calendar: DartCalendar
}
