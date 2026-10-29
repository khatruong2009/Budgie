import BudgieCore
import SwiftUI

/// The Spend tab (`CategoryPage`, category_page.dart): "Spending" with a
/// month pill, then the month's donut and its ranked category rows, or an
/// empty state. The month is local to the tab (never `model.selectedMonth`)
/// and defaults to the newest month with data. The breakdown is built once
/// per render from the ledger's month summaries, with no transaction scan.
struct SpendView: View {
    @Environment(AppModel.self) private var model

    /// The month the user picked; resolved against the available months on
    /// every render and ledger change (`SpendMonth.resolve`).
    @State private var month: DartDateTime?
    @State private var selectedSlice: Int?
    @State private var tailExpanded = false
    @State private var showsMonthSheet = false
    @State private var drillIn: SpendDrillIn?
    @State private var sheetOpens = 0
    @State private var monthPicks = 0
    @State private var rowTaps = 0

    var body: some View {
        let months = model.ledger.availableMonths
        let resolution = SpendMonth.resolve(selected: month, available: months)
        // A stale month renders as the resolved one right away; the state
        // catches up in `resolveMonth`.
        let selection = resolution.resetsSelection ? nil : selectedSlice
        let expanded = resolution.resetsSelection ? false : tailExpanded

        VStack(spacing: 0) {
            BudgieHeader(title: "Spending") {
                if let shown = resolution.month, !months.isEmpty {
                    MonthPill(label: DartDateFormat.MMMM(shown)) {
                        sheetOpens += 1
                        showsMonthSheet = true
                    }
                    .accessibilityIdentifier("spend.monthPill")
                }
            }
            if let data = model.data {
                if months.isEmpty {
                    emptyState(title: "No Expenses Yet", message: "Start tracking your expenses to see category breakdowns")
                } else if let shown = resolution.month {
                    content(data: data, month: shown, selection: selection, expanded: expanded)
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BudgieColor.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $drillIn) { CategoryTransactionsView(drillIn: $0) }
        .sheet(isPresented: $showsMonthSheet) {
            SpendMonthSheet(months: months, selected: resolution.month) { picked in
                monthPicks += 1
                month = picked
                selectedSlice = nil
                tailExpanded = false
            }
        }
        .onChange(of: model.ledgerRevision, initial: true) { _, _ in resolveMonth() }
        // MonthPill plays the light impact; Flutter adds a selection click
        // as the sheet opens, and another when a month is picked.
        .sensoryFeedback(.selection, trigger: sheetOpens)
        .sensoryFeedback(.selection, trigger: monthPicks)
        // Category, tail and "Show less" rows.
        .sensoryFeedback(.impact(weight: .light), trigger: rowTaps)
    }

    /// Flutter re-validates the month on every build (:40-58).
    private func resolveMonth() {
        let resolution = SpendMonth.resolve(selected: month, available: model.ledger.availableMonths)
        if resolution.month != month { month = resolution.month }
        if resolution.resetsSelection {
            selectedSlice = nil
            tailExpanded = false
        }
    }

    @ViewBuilder
    private func content(data: FinancialData, month: DartDateTime, selection: Int?, expanded: Bool) -> some View {
        let picker = data.categoryPicker(for: .expense)
        let breakdown = CategoryBreakdown.build(
            month: month, ledger: model.ledger, budgetLimits: data.budgetLimits,
            activeExpenseCategories: picker.map(\.name))
        if breakdown.showsEmptyState {
            emptyState(title: "No Expenses", message: "No expenses recorded for this month")
        } else {
            let symbols = SpendDrillIn.activeSymbols(picker)
            let formatter = model.moneyFormatter
            ScrollView {
                VStack(spacing: 0) {
                    DonutChart(breakdown: breakdown, formatter: formatter, selectedSlice: selection) { selectedSlice = $0 }
                        .frame(maxWidth: .infinity)
                    GlowListCard(rows: rows(breakdown, symbols: symbols, selection: selection, expanded: expanded, formatter: formatter))
                        .padding(.top, 20)
                }
                .padding(.horizontal, Metrics.pageHorizontal)
                .padding(.top, Metrics.spacingXL)
                // The scroll view already insets for the tab bar.
                .padding(.bottom, Metrics.pageHorizontal)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Ranked rows, then the tail row (collapsed) or "Show less" (expanded)
    /// when there are more than six categories (:257-273).
    private func rows(
        _ breakdown: CategoryBreakdown, symbols: [String], selection: Int?, expanded: Bool, formatter: MoneyFormatter
    ) -> [SpendListRow] {
        var rows = breakdown.visibleRecords(expanded: expanded).map { record in
            SpendListRow(
                kind: .record(
                    record, symbol: SpendDrillIn.symbol(for: record, in: symbols),
                    highlighted: CategoryBreakdown.isRowHighlighted(rank: record.rank, selectedSlice: selection)),
                formatter: formatter
            ) {
                rowTaps += 1
                drillIn = SpendDrillIn(
                    category: record.name, month: breakdown.month, palette: record.palette,
                    symbol: SpendDrillIn.symbol(for: record, in: symbols))
            }
        }
        if let tail = breakdown.tail {
            if expanded {
                rows.append(SpendListRow(kind: .collapse, formatter: formatter) {
                    rowTaps += 1
                    tailExpanded = false
                })
            } else {
                rows.append(SpendListRow(kind: .tail(tail), formatter: formatter) {
                    rowTaps += 1
                    tailExpanded = true
                })
            }
        }
        return rows
    }

    /// Both empty states fill the area under the header (:209-227).
    private func emptyState(title: String, message: String) -> some View {
        EmptyStateView(kind: .noData, symbol: "chart.pie", title: title, message: message)
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("spend.empty")
    }
}

/// The drill-in route: a category of a month, with the colour and icon it
/// had when pushed (used only if the category leaves the breakdown).
struct SpendDrillIn: Hashable {
    let category: String
    let month: DartDateTime
    let palette: SpendPaletteSlot
    let symbol: String

    /// SF Symbols of the active expense categories, indexed like
    /// `Record.activeIndex` (a repeated name keeps its first position, as
    /// in Dart's `expenseCategories` map).
    static func activeSymbols(_ picker: [CategoryInfo]) -> [String] {
        var seen = Set<[UInt16]>()
        return picker.compactMap { info in
            seen.insert(Array(info.name.utf16)).inserted ? CategoryCatalog.symbol(for: info.iconIdentifier) : nil
        }
    }

    /// Flutter's `expenseCategories[name]` icon by exact name, or the grid
    /// for a name that is not an active expense category (:92-103).
    static func symbol(for record: CategoryBreakdown.Record, in symbols: [String]) -> String {
        if let index = record.activeIndex, symbols.indices.contains(index) { return symbols[index] }
        return CategoryCatalog.symbol(for: "square_grid_2x2")
    }
}

extension SpendPaletteSlot {
    /// The slot's colour in the current theme (app_colors.dart): the rank
    /// palette tokens, `getChartColors` (light `categoryColors`, dark list),
    /// and `getDonutRemainder`.
    var color: Color {
        switch self {
        case .accent: BudgieColor.chartAccent
        case .income: BudgieColor.income
        case .danger: BudgieColor.danger
        case .warning: BudgieColor.warning
        case .info: BudgieColor.info
        case .pink: BudgieColor.pink
        case .chart(let index): BudgieColor.chartPalette[index % BudgieColor.chartPalette.count]
        case .remainder: BudgieColor.trackSecondary
        }
    }
}
