import BudgieCore
import SwiftUI

/// The "SEE ALL" page pushed from Home (`transaction_page.dart`): a strip of
/// month chips, that month's summary card, and its transactions grouped by
/// day under pinned date headers, each day's rows in one card with hairlines
/// between them. Rows open the edit form and swipe to delete behind a
/// confirmation.
///
/// The selected month is local to the page (it does not follow
/// `model.selectedMonth`). Everything is read from `model.ledger`, which is
/// rebuilt off the main thread after each change, so nothing here re-scans
/// the transactions.
struct TransactionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The month the user tapped. `nil` (or a month that no longer has
    /// transactions) means the newest available month.
    @State private var chosenMonth: DartDateTime?
    @State private var editing: TransactionRecord?
    @State private var showingAdd = false
    @State private var pendingDelete: TransactionRecord?
    @State private var monthTaps = 0
    @State private var rowTaps = 0
    @State private var deleteConfirms = 0

    var body: some View {
        let ledger = model.ledger
        let months = ledger.availableMonths
        let month = effectiveMonth(in: months)
        let formatter = model.moneyFormatter

        Group {
            if let month {
                VStack(spacing: 0) {
                    MonthStrip(months: months, selected: month) { picked in
                        monthTaps += 1
                        chosenMonth = picked
                    }
                    // A scroll view extends under the trailing and leading
                    // safe area (the 27.1 rail); clip the chips to this
                    // page's width.
                    .clipped()
                    SummaryCard(summary: ledger.summary(forMonth: month), formatter: formatter)
                        .padding(.horizontal, Metrics.pageHorizontal)
                        .frame(maxWidth: Metrics.maxContentWidth)
                        .frame(maxWidth: .infinity)
                    monthContent(rows: ledger.newestFirst(inMonth: month), formatter: formatter)
                        .padding(.top, Metrics.spacingM)
                }
            } else {
                EmptyStateView(
                    kind: .noData, symbol: "dollarsign.circle", title: MonthListCopy.noTransactionsTitle,
                    message: MonthListCopy.noTransactionsMessage,
                    actionTitle: "Add Transaction"
                ) { showingAdd = true }
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BudgieColor.background)
        .budgiePushedTitle("Transactions", style: .sectionHeader)
        .onChange(of: model.ledgerRevision) { _, _ in
            // The chosen month lost its last row: leave it for good rather
            // than snapping back to it if a row is added there later.
            if let chosenMonth, !model.ledger.availableMonths.contains(chosenMonth) { self.chosenMonth = nil }
        }
        .sheet(item: $editing) { record in
            TransactionFormView(mode: .edit(record))
        }
        .sheet(isPresented: $showingAdd) {
            TransactionFormView(mode: .add(.expense))
        }
        .alert(
            "Delete Transaction", isPresented: Binding(isPresent: $pendingDelete), presenting: pendingDelete
        ) { record in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteConfirms += 1
                Task {
                    // Already gone (deleted elsewhere, rejected): nothing failed.
                    switch await model.deleteTransaction(id: record.id) {
                    case .saved: model.showToast(.transactionDeleted)
                    case .failed: model.showToast(.saveFailed)
                    case .rejected: break
                    }
                }
            }
        } message: { _ in
            Text("Are you sure you want to delete this transaction?")
        }
        .sensoryFeedback(.selection, trigger: monthTaps)
        .sensoryFeedback(.impact(weight: .light), trigger: rowTaps)
        .sensoryFeedback(.impact(weight: .heavy), trigger: deleteConfirms)
    }

    // MARK: - State

    /// The chosen month if it still has transactions, else the newest.
    private func effectiveMonth(in months: [DartDateTime]) -> DartDateTime? {
        if let chosenMonth, months.contains(chosenMonth) { return chosenMonth }
        return months.first
    }

    // MARK: - List

    @ViewBuilder
    private func monthContent(rows: ArraySlice<LedgerRow>, formatter: MoneyFormatter) -> some View {
        if rows.isEmpty {
            EmptyStateView(kind: .noData, symbol: "tray", title: MonthListCopy.emptyMonthTitle, message: MonthListCopy.emptyMonthMessage)
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(MonthListCopy.dayGroups(from: rows)) { group in
                        Section {
                            dayCard(group, formatter: formatter)
                                .padding(.horizontal, Metrics.pageHorizontal)
                                .padding(.bottom, Metrics.spacingS)
                        } header: {
                            DateHeader(title: group.title)
                        }
                    }
                }
                // The scroll view already insets its content for the tab bar
                // and home indicator; this is only breathing room.
                .padding(.bottom, Metrics.spacingS)
                .frame(maxWidth: Metrics.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// One day's rows in a card, a hairline between them. The swipe slides a
    /// row (on the card fill) over the delete background; the card clips it
    /// at its edge.
    private func dayCard(_ group: MonthListCopy.DayGroup, formatter: MoneyFormatter) -> some View {
        GlowCard(padding: Metrics.listCardPadding) {
            LazyVStack(spacing: 0) {
                ForEach(group.rows) { row in
                    // One child per record lets the lazy stack defer offscreen rows,
                    // including each row's optional divider.
                    VStack(spacing: 0) {
                        if row.id != group.rows.first?.id { Hairline().padding(.horizontal, Metrics.hairlineInset) }
                        SwipeToDeleteRow {
                            pendingDelete = row.record
                        } content: {
                            TransactionRow(record: row.record, formatter: formatter) {
                                rowTaps += 1
                                editing = row.record
                            }
                            .background(BudgieColor.card)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

// MARK: - Summary card

private struct SummaryCard: View {
    let summary: MonthSummary
    let formatter: MoneyFormatter

    /// Flutter `AppTypography.amount` at 20.
    private static let amountText = TextSpec(face: .gabaritoBold, size: 20, tabular: true, relativeTo: .title3)
    /// `rowSubtitle` at 13, w600 (the Income / Expenses labels).
    private static let labelText = TextSpec(face: .gabaritoSemiBold, size: 13, height: 1.25, relativeTo: .footnote)
    /// `rowTitle` at 16, w700.
    private static let netLabel = TextSpec(face: .gabaritoBold, size: 16, height: 1.25, relativeTo: .body)

    var body: some View {
        let net = summary.net
        let (income, expenses, netText) = MonthListCopy.summary(summary, formatter: formatter)
        GlowCard(padding: Metrics.spacingM) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 0) {
                    figure("Income", income, BudgieColor.income)
                    figure("Expenses", expenses, BudgieColor.danger)
                }
                // Flutter `Divider(height: 24)`: the line centred in 24pt.
                Hairline().padding(.vertical, 11.5)
                HStack(spacing: Metrics.spacingS) {
                    Text("Net Cash Flow")
                        .textStyle(Self.netLabel)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .wrapsWords()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(netText)
                        .textStyle(Self.amountText)
                        .foregroundStyle(net >= 0 ? BudgieColor.income : BudgieColor.danger)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Income \(income). Expenses \(expenses). Net cash flow \(netText).")
    }

    private func figure(_ title: String, _ amount: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXS) {
            Text(title).textStyle(Self.labelText).foregroundStyle(BudgieColor.textSecondary)
            Text(amount)
                .textStyle(Self.amountText)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Date header

/// A pinned 48pt header in the page background so scrolled rows hide behind
/// it, holding a left-aligned mono pill.
private struct DateHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .textStyle(.monoLabel)
            .foregroundStyle(BudgieColor.textSecondary)
            .padding(.horizontal, Metrics.spacingM)
            .padding(.vertical, Metrics.spacingXS)
            .background(BudgieColor.chipSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(BudgieColor.cardBorder, lineWidth: 1))
            .padding(.horizontal, Metrics.pageHorizontal)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(BudgieColor.background)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row

/// A row like Home's Recent activity: the category's 40pt tile, the title
/// with an inline recurrence glyph, "Category • Mon d" and the signed amount
/// (income in `income`, expenses in `textPrimary`).
private struct TransactionRow: View {
    @Environment(AppModel.self) private var model
    let record: TransactionRecord
    let formatter: MoneyFormatter
    let onTap: () -> Void

    var body: some View {
        let isIncome = record.type == .income
        let info = model.categoryInfo(named: record.category, type: record.type)
        let amount = MonthListCopy.rowAmount(record, formatter: formatter)
        let signed = formatter.formatSigned(isIncome ? record.amount : -record.amount, plusForPositive: true)

        Button(action: onTap) {
            TransactionRowLayout(
                titleLines: nil, titleAlignment: .leading,
                title: record.description, isRecurring: record.isRecurring,
                subtitle: MonthListCopy.rowSubtitle(record), amount: signed,
                amountColor: isIncome ? BudgieColor.income : BudgieColor.textPrimary
            ) {
                IconTile(category: info)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On the Button itself, so VoiceOver keeps its activation.
        .accessibilityLabel(
            "\(record.description), \(isIncome ? "income" : "expense") \(amount), category \(record.category), on \(DartDateFormat.yMMMMd(record.date))"
                + (record.isRecurring ? ", recurring" : "")
        )
        .accessibilityHint("Double tap to edit, swipe left to delete")
    }
}
