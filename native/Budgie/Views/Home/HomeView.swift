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
        .floatingActionInset {
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
                    .font(.system(size: Metrics.iconS, weight: .medium))
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
