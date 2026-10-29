import BudgieCore
import SwiftUI

/// The Home tab (`SpendingPage`, spending_page.dart:448-686): header with
/// the month pill and its wheel panel, the cash-flow ring, the income and
/// expense tiles, safe to spend, budgets and recent activity, with the add
/// button (whose form switches between expense and income) floating
/// bottom-trailing under the smaller voice button.
/// Everything is read from `model.ledger` except safe to spend, whose Core
/// calculation takes the transactions.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheet: HomeSheet?
    @State private var monthPanelOpen = false
    @State private var page: HomePage?
    /// A category picked in the quick-expense sheet; its form opens once
    /// that sheet has been dismissed.
    @State private var pendingQuickCategory: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                HomeMonthPanel(expanded: monthPanelOpen)
                if let data = model.data {
                    content(data)
                } else {
                    ProgressView().padding(.top, 48)
                }
            }
        }
        .background(BudgieColor.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $page) { _ in TransactionsView() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The mic over the add button, centred on it (Flutter's Column).
            // An inset follows the tab bar on any edge and clears the scroll.
            VStack(spacing: 12) {
                GlowFab(symbol: "mic.fill", size: Metrics.micFabSize, label: "Add by voice") {
                    model.pendingAdd = .voice
                }
                .accessibilityIdentifier("home.voice")
                GlowFab(label: "Add transaction") {
                    sheet = .add(.expense)
                } longPress: {
                    sheet = .quickExpense
                }
            }
            .padding(.trailing, Metrics.fabInset)
            .padding(.bottom, Metrics.fabInset)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .sheet(item: $sheet, onDismiss: openPendingQuickCategory) { item in
            switch item {
            case .add(let type):
                TransactionFormView(mode: .add(type))
            case .addExpense(let category):
                TransactionFormView(mode: .add(.expense), initialCategory: category)
            case .breakdown(let breakdown):
                SafeToSpendSheet(breakdown: breakdown, formatter: model.moneyFormatter)
            case .quickExpense:
                QuickExpenseSheet { pendingQuickCategory = $0 }
            case .edit(let record):
                TransactionFormView(mode: .edit(record))
            }
        }
    }

    private func openPendingQuickCategory() {
        guard let category = pendingQuickCategory else { return }
        pendingQuickCategory = nil
        sheet = .addExpense(category: category)
    }

    // MARK: - Header

    private var header: some View {
        BudgieHeader(showLogo: true, centerTrailing: true) {
            MonthPill(label: DartDateFormat.yMMMM(model.selectedMonth)) {
                // Explicit, so the sections below move with the panel.
                withAnimation(reduceMotion ? nil : Motion.easeInOut(0.25)) { monthPanelOpen.toggle() }
            }
            .accessibilityIdentifier("home.monthPill")
        } accessory: {
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(BudgieColor.textSecondary)
                    // The glyph's 36pt slot is unchanged; the tap area is
                    // the 44pt minimum, centred on it.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home.settings")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func content(_ data: FinancialData) -> some View {
        let calendar = model.calendar
        let month = model.selectedMonth
        let formatter = model.moneyFormatter
        let totals = model.ledger.summary(forMonth: month)
        let previous = HomeSummary.previousMonth(of: month, calendar: calendar)
        let previousTotals = model.ledger.summary(forMonth: previous)
        let previousName = DartDateFormat.MMMM(previous)
        let breakdown = Signpost.ui.withIntervalSignpost("home.safeToSpend") {
            SafeToSpend.calculate(
                transactions: data.transactions, templates: data.templates, budgetLimits: data.budgetLimits,
                savingsGoals: data.savingsGoals, month: month, asOf: model.now, wallClock: model.now, calendar: calendar)
        }

        // The six months ending at the selected one, oldest first.
        let trend = (0..<6).map { model.ledger.summary(forMonth: calendar.date(month.fields.year, month.fields.month - 5 + $0)) }

        HomeHero(income: totals.income, expenses: totals.expenses, formatter: formatter)

        HStack(spacing: 12) {
            FlowChip(
                label: "Income", amount: totals.income, trend: trend.map(\.income), line: BudgieColor.income,
                delta: HomeSummary.percentDelta(current: totals.income, previous: previousTotals.income),
                goodWhenUp: true, previousMonthName: previousName, formatter: formatter)
            FlowChip(
                label: "Expenses", amount: totals.expenses, trend: trend.map(\.expenses), line: BudgieColor.spent,
                delta: HomeSummary.percentDelta(current: totals.expenses, previous: previousTotals.expenses),
                goodWhenUp: false, previousMonthName: previousName, formatter: formatter)
        }
        .padding(.horizontal, Metrics.pageHorizontal)
        .padding(.top, 26)

        SafeToSpendCard(breakdown: breakdown, formatter: formatter) { sheet = .breakdown(breakdown) }
            .padding(.horizontal, Metrics.pageHorizontal)
            .padding(.top, 12)

        // Applies its own page padding.
        BudgetsSection()
            .padding(.top, Metrics.sectionGap)

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent activity", link: "See all", linkAccessibilityLabel: "See all transactions") {
                page = .transactions
            }
            RecentActivityCard(rows: model.ledger.recent(3), formatter: formatter) { sheet = .edit($0) }
        }
        .padding(.horizontal, Metrics.pageHorizontal)
        .padding(.top, Metrics.sectionGap)
    }
}

/// The page Home pushes from SEE ALL. Pushed by item, never with
/// `navigationDestination(isPresented:)`: that form rebuilt the pushed page
/// each time an accessibility client read the screen, which kept the main
/// thread busy under XCUITest (see UI_SPEC "Shell").
private enum HomePage {
    case transactions
}

/// Home's sheets, one at a time.
enum HomeSheet: Identifiable {
    case add(TransactionType)
    /// The expense form with a category from the quick-expense sheet.
    case addExpense(category: String)
    case breakdown(SafeToSpendBreakdown)
    case quickExpense
    /// A Recent activity row's edit form, as SEE ALL opens it.
    case edit(TransactionRecord)

    var id: String {
        switch self {
        case .add(let type): "add-\(type.rawValue)"
        case .addExpense(let category): "add-expense-\(category)"
        case .breakdown: "breakdown"
        case .quickExpense: "quick-expense"
        case .edit(let record): "edit-\(record.id)"
        }
    }
}

// MARK: - Flow chips

/// One of the two month-over-month tiles (`_FlowChip`,
/// spending_page.dart:1465-1550): the label, the month's amount in whole
/// units, the change from the month before (good changes in the income
/// colour, bad ones in danger) and a six-month sparkline. Not tappable.
private struct FlowChip: View {
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

    /// `rowSubtitle` at 13, w600.
    private static let labelStyle = TextSpec(face: .gabaritoSemiBold, size: 13, height: 1.25, relativeTo: .footnote)

    private var deltaColor: Color {
        guard let delta else { return BudgieColor.textTertiary }
        if delta == 0 { return BudgieColor.textSecondary }
        return (delta > 0) == goodWhenUp ? BudgieColor.income : BudgieColor.danger
    }

    var body: some View {
        GlowCard(padding: 16, radius: Metrics.statCardRadius) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .textStyle(Self.labelStyle)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .singleLine()
                Text(HomeSummary.chipAmount(amount, formatter: formatter))
                    .textStyle(.chipAmount)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(.top, 8)
                Text(HomeSummary.deltaLabel(delta: delta, previousMonthName: previousMonthName))
                    .textStyle(.rowSubtitle)
                    .foregroundStyle(deltaColor)
                    .singleLine()
                    .padding(.top, 2)
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
private struct SafeToSpendCard: View {
    let breakdown: SafeToSpendBreakdown
    let formatter: MoneyFormatter
    let onTap: () -> Void

    @State private var taps = 0

    private static let titleText = TextSpec(face: .gabaritoSemiBold, size: 13, height: 1.25, relativeTo: .footnote)
    static let amountText = TextSpec(face: .gabaritoExtraBold, size: 32, tracking: -1, height: 1.05, tabular: true, relativeTo: .title)
    private static let subtitleText = TextSpec(face: .gabaritoRegular, size: 13, height: 1.25, relativeTo: .footnote)

    var body: some View {
        let card = HomeSummary.safeToSpendCard(breakdown, formatter: formatter)
        Button {
            taps += 1
            onTap()
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title)
                        .textStyle(Self.titleText)
                        .foregroundStyle(BudgieColor.featureSecondary)
                        .singleLine()
                    Text(card.amount)
                        .textStyle(Self.amountText)
                        .foregroundStyle(card.isOver ? BudgieColor.featureDanger : BudgieColor.featureAmount)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(card.subtitle)
                        .textStyle(Self.subtitleText)
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
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("home.safeToSpend")
    }
}

// MARK: - Recent activity

/// The newest three transactions of any month (`_RecentActivityCard`,
/// spending_page.dart:1706-1816). A row opens its edit form, like SEE ALL.
private struct RecentActivityCard: View {
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
                    .background(BudgieColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                Text("No transactions yet.")
                    .textStyle(Self.empty)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 24)
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
    @State private var taps = 0

    var body: some View {
        let isIncome = record.type == .income
        let day = DartDateFormat.MMMd(record.date)
        let copy = HomeSummary.recentRow(record, formatter: formatter)
        Button {
            taps += 1
            onTap()
        } label: {
            HStack(spacing: 12) {
                if isIncome {
                    IconTile(symbol: "arrow.down.left", color: BudgieColor.income)
                } else {
                    IconTile(category: model.categoryInfo(named: record.category, type: .expense))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(copy.title)
                            .textStyle(.rowTitle)
                            .foregroundStyle(BudgieColor.textPrimary)
                            .lineLimit(1)
                        if record.isRecurring { RecurrenceGlyph(size: 16).fixedSize() }
                    }
                    Text(copy.subtitle)
                        .textStyle(.rowSubtitle)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .singleLine()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(copy.amount)
                    .textStyle(.amountSmall)
                    .foregroundStyle(isIncome ? BudgieColor.income : BudgieColor.textPrimary)
                    .singleLine()
                    .layoutPriority(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
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
