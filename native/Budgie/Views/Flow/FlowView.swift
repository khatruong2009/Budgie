import BudgieCore
import SwiftUI

/// The Flow tab (Flutter `HistoryPage`, history_page.dart:32-437): header
/// with the chart-range pill, the metric strip, the Insights slot, the net
/// cash flow bars, year over year, the 12-month trend, and the three newest
/// transactions with SEE ALL. Every figure comes from `model.ledger` through
/// `CashFlowMath`. The range (3/6/12, default 6) is page state and drives
/// only the bars and the metric strip; the month is `model.selectedMonth`.
struct FlowView: View {
    @Environment(AppModel.self) private var model
    @State private var rangeMonths = CashFlowMath.defaultRange
    @State private var sheet: FlowSheet?
    @State private var page: FlowPage?
    @State private var pillTaps = 0
    /// Range tile taps: Flutter's `selectionClick` fires on every tile tap,
    /// the already-selected one included.
    @State private var rangePicks = 0

    var body: some View {
        let formatter = model.moneyFormatter
        let month = model.selectedMonth
        let window = CashFlowMath.chartWindow(model.ledger.netCashFlowHistory, selectedMonth: month, months: rangeMonths)
        ScrollView {
            VStack(spacing: 0) {
                BudgieHeader(title: "Cash flow") { rangePill }

                MetricStrip(metrics: CashFlowMath.metrics(window), formatter: formatter)
                    .padding(.horizontal, Metrics.pageHorizontal)
                    .padding(.top, Metrics.spacingL)
                    .padding(.bottom, Metrics.spacingM)

                // Flutter keeps a 16pt gap on each side of the slot, so an
                // empty slot leaves 32pt between the strip and the chart.
                FlowInsightsSlot()

                VStack(spacing: Metrics.spacingM) {
                    NetCashFlowCard(window: window, selectedMonth: month, formatter: formatter) { entry in
                        sheet = .month(CashFlowMath.MonthDetail(entry: entry))
                    }
                    YearOverYearCard(yoy: CashFlowMath.yearOverYear(model.ledger, selectedMonth: month))
                    TrendCard(series: CashFlowMath.trendSeries(model.ledger, selectedMonth: month), formatter: formatter)
                }
                .padding(.horizontal, Metrics.pageHorizontal)
                .padding(.top, Metrics.spacingM)

                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Transactions", link: "See all", linkAccessibilityLabel: "See all transactions") {
                        page = .transactions
                    }
                    TransactionsPreviewCard(rows: model.ledger.recent(3), formatter: formatter) { page = .transactions }
                }
                .padding(.horizontal, Metrics.pageHorizontal)
                .padding(.top, Metrics.spacingM)
            }
            .padding(.bottom, Metrics.spacingL)
        }
        .background(BudgieColor.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $page) { _ in FlowTransactionsView() }
        .sensoryFeedback(.selection, trigger: rangePicks)
        .sheet(item: $sheet) { item in
            switch item {
            case .range:
                RangeSheet(selected: rangeMonths) { months in
                    rangePicks += 1
                    rangeMonths = months
                    sheet = nil
                }
            case .month(let detail):
                MonthDetailSheet(detail: detail, formatter: model.moneyFormatter)
            }
        }
    }

    /// The header's `MonthPill` showing the chart range; opens the range
    /// sheet with a light haptic.
    private var rangePill: some View {
        Button {
            pillTaps += 1
            sheet = .range
        } label: {
            MonthPill(label: CashFlowMath.rangeLabel(rangeMonths))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: pillTaps)
        .accessibilityLabel("Chart range")
        .accessibilityValue(CashFlowMath.rangeLabel(rangeMonths))
        .accessibilityHint("Chooses how many months the chart and the averages cover")
        .accessibilityIdentifier("flow.rangePill")
    }
}

/// The page Flow pushes from SEE ALL and the preview rows. Pushed by item,
/// never with `navigationDestination(isPresented:)` (see UI_SPEC "Shell").
private enum FlowPage {
    case transactions
}

/// The Flow tab's sheets, one at a time.
enum FlowSheet: Identifiable {
    case range
    case month(CashFlowMath.MonthDetail)

    var id: String {
        switch self {
        case .range: "range"
        case .month(let detail): "month-\(DartDateFormat.yyyyMM(detail.entry.month))"
        }
    }
}

/// Flutter's `LocalInsightsSection` (local_insights_section.dart:95-133,
/// placed at hp:78-81) between the metric strip and the net cash flow card:
/// "Insights", 12, one to three `InsightCard`s 10 apart, 8, the caption.
/// With no cards it takes no space, leaving the two 16pt gaps (32pt).
/// Cards are keyed by position: two can share an id.
struct FlowInsightsSlot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let insights = model.insights
        // One container for both states, so the refreshes below are attached
        // once: a Group would hand them to each child and run them again
        // whenever the slot switches between empty and cards.
        VStack(spacing: 0) {
            if insights.isEmpty {
                // Zero height; the page's spacing around it stays.
                Color.clear.frame(height: 0)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Insights")
                    VStack(spacing: 10) {
                        ForEach(Array(insights.enumerated()), id: \.offset) { _, insight in
                            InsightCard(
                                insight: insight, onSnooze: { model.snoozeInsight(id: insight.id) },
                                onDismiss: { model.dismissInsight(id: insight.id) })
                        }
                    }
                    .padding(.top, 12)
                    Text("Calculated privately on this device \u{B7} Not financial advice")
                        .textStyle(.caption)
                        .foregroundStyle(BudgieColor.textTertiary)
                        .padding(.top, Metrics.spacingS)
                }
                .padding(.horizontal, Metrics.pageHorizontal)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("flow.insights")
            }
        }
        // Flutter derives the cards at every build with `DateTime.now()`:
        // a snooze can end, or the day (budget pace) move, while away. A
        // refresh with unchanged inputs (the first visit after launch)
        // computes nothing.
        .onAppear { model.refreshInsights() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshInsights() }
        }
    }
}

// MARK: - Metric strip

/// The two equal-height chips (`_buildMetricStrip`, hp:208-242): average
/// saved per month and savings rate over the chart window.
struct MetricStrip: View {
    let metrics: CashFlowMath.Metrics
    let formatter: MoneyFormatter

    var body: some View {
        HStack(spacing: 12) {
            MetricChip(
                label: "AVG SAVED / MO", spokenLabel: "Average saved per month",
                value: CashFlowMath.avgSavedText(metrics.avgSaved, formatter: formatter),
                color: metrics.avgSavedIsPositive ? BudgieColor.income : BudgieColor.danger)
                .accessibilityIdentifier("flow.metric.avgSaved")
            MetricChip(
                label: "SAVINGS RATE", spokenLabel: "Savings rate", value: CashFlowMath.savingsRateText(metrics.savingsRate),
                color: metrics.savingsRateIsPositive ? BudgieColor.income : BudgieColor.danger)
                .accessibilityIdentifier("flow.metric.savingsRate")
        }
        // Flutter's IntrinsicHeight: both chips take the taller one's height.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// `_MetricChip` (hp:625-660): GlowCard radius 22, padding 16; mono label,
/// 8, the value in metricAmount. Long values wrap (Flutter does not scale
/// them down).
private struct MetricChip: View {
    let label: String
    let spokenLabel: String
    let value: String
    let color: Color

    var body: some View {
        GlowCard(padding: 16, radius: Metrics.statCardRadius) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text(label)
                    .textStyle(.monoMetricLabel)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .wrapsWords()
                Text(value)
                    .textStyle(.metricAmount)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityValue(value)
    }
}

// MARK: - Shared

/// `_EmptyChartMessage` (hp:1222-1241): rowSubtitle at 13, secondary,
/// inset 12 on every side.
struct FlowEmptyMessage: View {
    let text: String

    /// `rowSubtitle` at 13.
    private static let style = TextSpec(face: .gabaritoRegular, size: 13, height: 1.25, relativeTo: .footnote)

    var body: some View {
        Text(text)
            .textStyle(Self.style)
            .foregroundStyle(BudgieColor.textSecondary)
            .padding(12)
    }
}
