import BudgieCore
import SwiftUI

/// The 'Net cash flow' card (`_buildNetCashFlowCard`, hp:244-276): title,
/// 20, then the bars, or 'No cash flow data yet.' when the window is empty.
struct NetCashFlowCard: View {
    let window: [MonthCashFlow]
    let selectedMonth: DartDateTime
    let formatter: MoneyFormatter
    let onSelect: (MonthCashFlow) -> Void

    var body: some View {
        GlowCard {
            VStack(alignment: .leading, spacing: 20) {
                Text("Net cash flow")
                    .textStyle(.cardTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if window.isEmpty {
                    FlowEmptyMessage(text: "No cash flow data yet.")
                } else {
                    NetCashFlowBars(window: window, selectedMonth: selectedMonth, formatter: formatter, onSelect: onSelect)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flow.netCashFlow")
    }
}

/// The hand-built bar chart (`_NetCashFlowBars`, hp:665-760; D16): a 190pt
/// band with the zero baseline at 116, one `barWidth` x 190 column per month
/// laid out like Flutter's `Row(spaceAround)`, geometry from
/// `CashFlowMath.barLayout` for the card's inner width. No animation, as in
/// Flutter. Each column is one VoiceOver element: "<Month year>, net <amount>".
private struct NetCashFlowBars: View {
    let window: [MonthCashFlow]
    let selectedMonth: DartDateTime
    let formatter: MoneyFormatter
    let onSelect: (MonthCashFlow) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let layout = CashFlowMath.barLayout(window, selectedMonth: selectedMonth, availableWidth: Double(width))
            let barWidth = CGFloat(layout.barWidth)
            let count = CGFloat(layout.bars.count)
            // spaceAround: each column gets an equal share of the free space,
            // half of it on either side.
            let gap = (width - barWidth * count) / count
            ZStack(alignment: .topLeading) {
                // Zero baseline, under the bars.
                BudgieColor.chartBaseline
                    .frame(width: width, height: 1)
                    .offset(y: CashFlowMath.barBaselineY)
                    .accessibilityHidden(true)
                ForEach(Array(layout.bars.enumerated()), id: \.element.entry.month) { index, bar in
                    NetCashFlowBarColumn(bar: bar, barWidth: barWidth, gap: gap, formatter: formatter) { onSelect(bar.entry) }
                        .offset(x: gap / 2 + CGFloat(index) * (barWidth + gap))
                }
            }
        }
        .frame(height: CashFlowMath.barChartHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Net cash flow by month")
    }
}

/// One month (`_NetCashFlowBar`, hp:762-879): the bar (radius 10), the
/// current month's glow and badge, and the month label in the bottom band.
/// The whole column is the tap target (the badge overhang is not); a tap
/// gives a light haptic and opens the month detail sheet.
private struct NetCashFlowBarColumn: View {
    let bar: CashFlowMath.Bar
    let barWidth: CGFloat
    /// The free space around the column (half of it on each side), which
    /// the tap area takes up so neighbouring columns do not overlap.
    let gap: CGFloat
    let formatter: MoneyFormatter
    let action: () -> Void

    @State private var taps = 0

    /// `badgeSmall` with w800.
    private static let badgeStyle = TextSpec(face: .gabaritoExtraBold, size: 11, relativeTo: .caption2)

    var body: some View {
        let height = CashFlowMath.barChartHeight
        let color = barColor
        let signed = CashFlowMath.badgeText(bar.entry.net, formatter: formatter)
        ZStack(alignment: .topLeading) {
            barShape(color)
                .offset(y: bar.top)
            if bar.isCurrent {
                // Centred in a box 4 bars wide starting 1.5 bars to the left.
                Text(signed)
                    .textStyle(Self.badgeStyle)
                    .foregroundStyle(BudgieColor.onAccent)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, Metrics.spacingXS)
                    .background(color, in: Capsule())
                    .frame(width: barWidth * 4)
                    .offset(x: -barWidth * 1.5, y: bar.badgeTop)
                    .allowsHitTesting(false)
            }
            Text(bar.monthLabel)
                .textStyle(.monoMonth)
                .foregroundStyle(bar.isCurrent ? BudgieColor.textPrimary : BudgieColor.textTertiary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: barWidth)
                .frame(height: height, alignment: .bottom)
        }
        .frame(width: barWidth, height: height, alignment: .topLeading)
        .tapArea(horizontal: max(0, gap / 2))
        .onTapGesture {
            taps += 1
            action()
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(DartDateFormat.yMMMM(bar.entry.month)), net \(signed)")
        .accessibilityAddTraits(bar.isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Shows the month's income and expenses")
        .accessibilityAction { action() }
        .accessibilityIdentifier("flow.bar.\(DartDateFormat.yyyyMM(bar.entry.month))")
    }

    /// Current month: income (or danger) at full strength with the glow
    /// (blur 20, alpha .6); others: income at 45% or danger at 60%.
    private var barColor: Color {
        if bar.isCurrent { return bar.isPositive ? BudgieColor.income : BudgieColor.danger }
        return bar.isPositive ? BudgieColor.income.opacity(0.45) : BudgieColor.danger.opacity(0.6)
    }

    private func barShape(_ color: Color) -> some View {
        // Flutter's `BorderRadius.circular(10)`; SwiftUI clamps the radius
        // on short bars as Flutter does.
        RoundedRectangle(cornerRadius: CashFlowMath.barCornerRadius, style: .circular)
            .fill(color)
            .frame(width: barWidth, height: CGFloat(bar.height))
    }
}
