import BudgieCore
import SwiftUI

// MARK: - Trend chart

/// `_AccountHistoryChart` (NW:1904-2136). Empty: a 200pt note.
struct AccountTrendChart: View {
    let name: String
    let history: [NetWorthSnapshotRecord]
    let color: Color
    let formatter: MoneyFormatter

    var body: some View {
        if let last = history.last {
            GlowCard(padding: 0) {
                VStack(alignment: .leading, spacing: Metrics.spacingM) {
                    HStack(spacing: Metrics.spacingS) {
                        VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                            Text("Trend")
                                .textStyle(.cardTitle)
                                .foregroundStyle(BudgieColor.textPrimary)
                                .accessibilityAddTraits(.isHeader)
                            Text(NetWorthText.trendRange(history))
                                .textStyle(.rowSubtitle)
                                .foregroundStyle(BudgieColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        PillChip(label: formatter.formatCompact(last.amount), color: color, style: .badgeSmall)
                            .accessibilityLabel("Latest \(formatter.formatCompact(last.amount))")
                    }
                    AccountTrendPlot(history: history, color: color, formatter: formatter)
                }
                .padding(EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20))
            }
            .accessibilityElement(children: .contain)
        } else {
            GlowCard(padding: 24) {
                Text("No chart data yet for \(name).")
                    .textStyle(.note)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
            .accessibilityIdentifier("worth.history.chartEmpty")
        }
    }
}

/// The line chart itself, drawn the way fl_chart 1.2.0 paints it: a 176pt
/// plot (200 minus the 24pt reserved for the bottom titles) with x = index
/// (0...max(1, n - 1); one snapshot is drawn twice, at 0 and 1), the padded
/// `NetWorthChartScale.account` y range, and in paint order the hairline
/// grid, the area (18% to 0 from the highest spot down), the main line
/// (3pt) and the last spot's dot. Lines have round caps and are curved with
/// fl_chart's cubic only when there are more than two snapshots.
///
/// Touch: see `ChartTouch` and PARITY_GAPS.md. The spot nearest in x shows
/// fl_chart's default indicators and the tooltip above it, drawn once
/// (fl_chart stacks one copy per line) and kept inside the plot horizontally.
struct AccountTrendPlot: View {
    let history: [NetWorthSnapshotRecord]
    let color: Color
    let formatter: MoneyFormatter

    @State private var touchX: CGFloat?
    @ScaledMetric(relativeTo: .caption) private var axisLabelHeight: CGFloat = 12
    /// `maxContentWidth` 120, scaled with the text.
    @ScaledMetric(relativeTo: .body) private var tooltipContentWidth: CGFloat = 120

    private static let plotHeight: CGFloat = 176

    var body: some View {
        let values = history.map(\.amount)
        // Non-empty: the card shows its note instead of an empty chart.
        let scale = NetWorthChartScale.account(values)!
        // `SideTitleWidget(space: 8)` under the plot; grows with the text.
        let titlesHeight = max(24, 8 + axisLabelHeight + 4)

        GeometryReader { proxy in
            let plot = CGSize(width: proxy.size.width, height: Self.plotHeight)
            let points = scale.points(values, size: plot)
            let touched = touchX.flatMap { NetWorthPresentation.nearestSpot(toX: $0, in: points) }

            ZStack(alignment: .topLeading) {
                layers(points: points, scale: scale, plot: plot, touched: touched)
                    .frame(width: plot.width, height: plot.height)
                    .contentShape(Rectangle())
                    .modifier(ChartTouch(touchX: $touchX))
                    .overlay {
                        if let touched {
                            // Single-snapshot charts duplicate the point at
                            // x = 1: clamp before indexing (NW:2108-2110).
                            TooltipLayout(anchor: points[touched], maxWidth: tooltipContentWidth + 32) {
                                tooltip(history[min(touched, history.count - 1)])
                            }
                            .allowsHitTesting(false)
                        }
                    }
                ForEach(NetWorthPresentation.accountAxisLabelIndices(count: history.count), id: \.self) { index in
                    Text(NetWorthText.trendAxisLabel(history[index].recordedAt))
                        .textStyle(.monoAxis)
                        .foregroundStyle(BudgieColor.textTertiary)
                        .fixedSize()
                        .position(x: points[index].x, y: plot.height + 8 + axisLabelHeight / 2)
                }
            }
        }
        .frame(height: Self.plotHeight + titlesHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Balance trend")
        .accessibilityValue(spokenSummary)
        .accessibilityIdentifier("worth.history.chart")
    }

    @ViewBuilder
    private func layers(points: [CGPoint], scale: NetWorthChartScale, plot: CGSize, touched: Int?) -> some View {
        let line = Path(
            smoothCurveThrough: points, smoothness: history.count > 2 ? NetWorthPresentation.curveSmoothness : 0)
        let topY = points.map(\.y).min() ?? 0
        ZStack(alignment: .topLeading) {
            Path { path in
                for value in scale.gridLines {
                    let y = scale.y(value, height: plot.height)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: plot.width, y: y))
                }
            }
            .stroke(BudgieColor.hairline, lineWidth: 1)
            // `generateBelowBarPath`: the line, down to the bottom at the last
            // spot, back along the bottom, up to the first spot. The gradient
            // spans the highest spot to the bottom (`drawBelowBar`).
            Path { path in
                path.addPath(line)
                if let first = points.first, let last = points.last {
                    path.addLine(to: CGPoint(x: last.x, y: plot.height))
                    path.addLine(to: CGPoint(x: first.x, y: plot.height))
                    path.addLine(to: first)
                    path.closeSubpath()
                }
            }
            .fill(LinearGradient(
                colors: [color.opacity(0.18), color.opacity(0)],
                startPoint: UnitPoint(x: 0.5, y: topY / plot.height), endPoint: UnitPoint(x: 0.5, y: 1)))
            line.stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            if let last = points.last {
                // `FlDotCirclePainter(radius 5, stroke 3)`: the ring is
                // centred 1.5pt outside the fill.
                Path(circleAt: last, radius: 6.5).stroke(color.opacity(0.5), lineWidth: 3)
                Path(circleAt: last, radius: 5).fill(BudgieColor.textPrimary)
            }
            if let touched {
                indicator(at: points[touched], plotHeight: plot.height)
            }
        }
    }

    /// `defaultTouchedIndicators`: a 4pt butt-capped line from the bottom
    /// up to the dot's lower edge, then the dot (radius 7.2), in the line's
    /// colour.
    private func indicator(at point: CGPoint, plotHeight: CGFloat) -> some View {
        let dotRadius: CGFloat = 7.2
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: point.x, y: plotHeight))
                path.addLine(to: CGPoint(x: point.x, y: min(plotHeight, point.y + dotRadius)))
            }
            .stroke(color, lineWidth: 4)
            Path(circleAt: point, radius: dotRadius).fill(color)
        }
    }

    /// `LineTooltipItem('{yMMMd}\n', ...)` with the signed amount: centred
    /// text, padding 16 x 8, radius 4, chip surface.
    private func tooltip(_ snapshot: NetWorthSnapshotRecord) -> some View {
        VStack(spacing: 0) {
            Text(DartDateFormat.yMMMd(snapshot.recordedAt))
                .textStyle(AccountHistoryText.tooltipDate)
                .foregroundStyle(BudgieColor.textSecondary)
            Text(formatter.formatSigned(snapshot.amount))
                .textStyle(.amount)
                .foregroundStyle(BudgieColor.textPrimary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Metrics.spacingM)
        .padding(.vertical, Metrics.spacingS)
        .background(BudgieColor.chipSurface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    /// "3 balance updates from Jan 20, 2026, $1,000.00, to Mar 5, 2026,
    /// $1,500.00" (masked under Hide balances).
    private var spokenSummary: String {
        guard let first = history.first, let last = history.last else { return "" }
        func point(_ snapshot: NetWorthSnapshotRecord) -> String {
            "\(DartDateFormat.yMMMd(snapshot.recordedAt)), \(formatter.formatSigned(snapshot.amount))"
        }
        if history.count == 1 { return "1 balance update, \(point(first))" }
        return "\(history.count) balance updates from \(point(first)), to \(point(last))"
    }
}

/// The trend chart's touch: the finger's x while it is down on the plot,
/// nil once lifted. A mostly vertical drag scrolls the page and clears it, as
/// Flutter's scroll view wins the gesture arena. iOS 18+ uses a UIKit press
/// (the tooltip shows at touch-down); iOS 17 a simultaneous SwiftUI drag.
private struct ChartTouch: ViewModifier {
    @Binding var touchX: CGFloat?
    @State private var scrolled = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(ScrubPress { touchX = $0 })
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = value.translation
                        if !scrolled, abs(t.height) > 10, abs(t.height) >= abs(t.width) { scrolled = true }
                        touchX = scrolled ? nil : value.location.x
                    }
                    .onEnded { _ in
                        scrolled = false
                        touchX = nil
                    })
        }
    }
}

@available(iOS 18.0, *)
private struct ScrubPress: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat?) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.cancelsTouchesInView = false
        press.delegate = context.coordinator
        return press
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            context.coordinator.start = recognizer.location(in: recognizer.view)
            context.coordinator.scrollPan = nil
            onChange(context.converter.localLocation.x)
        case .changed:
            if let pan = context.coordinator.scrollPan, pan.state == .began || pan.state == .changed {
                // The page is scrolling: end the touch (cancels the press).
                recognizer.isEnabled = false
                recognizer.isEnabled = true
                onChange(nil)
            } else {
                onChange(context.converter.localLocation.x)
            }
        default:
            onChange(nil)
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint = .zero
        weak var scrollPan: UIGestureRecognizer?

        /// Asked when the scroll view's pan wants to begin while the press
        /// is down: only a mostly vertical movement may scroll.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            guard other.view is UIScrollView, other is UIPanGestureRecognizer else { return false }
            let point = gestureRecognizer.location(in: gestureRecognizer.view)
            guard abs(point.y - start.y) >= abs(point.x - start.x) else { return false }
            scrollPan = other
            return true
        }
    }
}

/// Places the tooltip as fl_chart does: centred on `anchor` (plot
/// coordinates), its bottom 16pt (`tooltipMargin`) above it, laid out at most
/// `maxWidth` wide, then shifted to stay inside the plot horizontally.
private struct TooltipLayout: Layout {
    let anchor: CGPoint
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let tooltip = subviews.first else { return }
        let offer = ProposedViewSize(width: maxWidth, height: nil)
        let size = tooltip.sizeThatFits(offer)
        let left = min(max(anchor.x - size.width / 2, 0), max(0, bounds.width - size.width))
        tooltip.place(
            at: CGPoint(x: bounds.minX + left, y: bounds.minY + anchor.y - 16 - size.height), anchor: .topLeading,
            proposal: ProposedViewSize(width: size.width, height: size.height))
    }
}
