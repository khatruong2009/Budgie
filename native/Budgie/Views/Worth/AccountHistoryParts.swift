import BudgieCore
import SwiftUI

/// The pieces of the account history page (net_worth_page.dart:1577-2136).

enum AccountHistoryText {
    /// `rowSubtitle` at 13 (the empty timeline and chart notes).
    static let note = TextSpec(face: .gabaritoRegular, size: 13, height: 1.25, relativeTo: .footnote)
    /// `amount` at 17 (the stat card values).
    static let statValue = TextSpec(face: .gabaritoBold, size: 17, tabular: true, relativeTo: .body)
    /// `rowSubtitle` at 11, w600 (the chart tooltip's date).
    static let tooltipDate = TextSpec(face: .gabaritoSemiBold, size: 11, height: 1.25, relativeTo: .caption2)
}

// MARK: - Hero

/// `_AccountHistoryHeroCard` (NW:1577-1762) as a plain card (padding 24;
/// Flutter washes it with the account colour, REDESIGN_PLAN 4.7): the
/// type's tinted arrow tile, "Balance history" over the last update, the
/// type badge, CURRENT BALANCE, the signed balance and the meta chips.
struct AccountHistoryHeroCard: View {
    let type: NetWorthEntryType
    let color: Color
    let history: NetWorthAccountHistory
    let formatter: MoneyFormatter

    private struct MetaChip {
        let symbol: String
        let label: String
        let color: Color
        let background: Color
    }

    var body: some View {
        let isAsset = type == .asset
        let balance = formatter.formatSigned(history.latestAmount)
        let lastUpdate = NetWorthText.lastUpdate(history.latest?.recordedAt)
        let chips = metaChips

        GlowCard(padding: 24) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    IconTile(symbol: isAsset ? "arrow.up.right" : "arrow.down.left", color: color, size: 48, iconSize: 24)
                        .padding(.trailing, Metrics.spacingM)
                    VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                        Text("Balance history")
                            .textStyle(.cardTitle)
                            .foregroundStyle(BudgieColor.textPrimary)
                        Text(lastUpdate)
                            .textStyle(.rowSubtitle)
                            .foregroundStyle(BudgieColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    PillChip(
                        label: isAsset ? "Asset" : "Liability", color: color, textColor: BudgieColor.legible(color),
                        style: .badgeSmall)
                }
                Text("CURRENT BALANCE")
                    .textStyle(.eyebrow)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .padding(.top, Metrics.spacingL)
                // `FittedBox(scaleDown)`: one line, shrunk to fit.
                Text(balance)
                    .textStyle(.heroSmall)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(.top, 6)
                // `Wrap(spacing: 8, runSpacing: 8)` of at most three chips.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Metrics.spacingS) { chipViews(chips[...]) }
                    VStack(alignment: .leading, spacing: Metrics.spacingS) {
                        HStack(spacing: Metrics.spacingS) { chipViews(chips.prefix(2)) }
                        chipViews(chips.dropFirst(2))
                    }
                    VStack(alignment: .leading, spacing: Metrics.spacingS) { chipViews(chips[...]) }
                }
                .padding(.top, Metrics.spacingM)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([isAsset ? "Asset balance history" : "Liability balance history", "Current balance \(balance)", lastUpdate]
                + chips.map(\.label)).joined(separator: ". "))
        .accessibilityIdentifier("worth.history.hero")
    }

    /// The snapshot count (neutral), then "vs prior" coloured by the sign
    /// of the change and "overall" coloured by whether it is good for the
    /// type (so the two disagree for liabilities, as in Flutter).
    private var metaChips: [MetaChip] {
        // Flutter: white 6% (dark) / black 5% (light); the hairline token
        // is the same in dark and within 1% in light.
        var chips = [
            MetaChip(
                symbol: "calendar", label: NetWorthText.snapshotCount(history.chart.count), color: BudgieColor.textPrimary,
                background: BudgieColor.hairline)
        ]
        if let change = history.changeFromPrevious {
            let tint = change >= 0 ? BudgieColor.income : BudgieColor.danger
            chips.append(MetaChip(
                symbol: change >= 0 ? "arrow.up.right" : "arrow.down.left",
                label: formatter.formatCompactDelta(change) + " vs prior", color: tint, background: tint.opacity(0.14)))
        }
        if let total = history.totalChange {
            let positive = history.totalChangeIsPositive == true
            let tint = positive ? BudgieColor.income : BudgieColor.danger
            chips.append(MetaChip(
                symbol: positive ? "arrow.up.right" : "arrow.down.left",
                label: formatter.formatCompactDelta(total) + " overall", color: tint, background: tint.opacity(0.14)))
        }
        return chips
    }

    /// `_metaChip`: padding 10 x 6, capsule, 14pt icon, 6, `badgeSmall`.
    private func chipViews(_ chips: ArraySlice<MetaChip>) -> some View {
        ForEach(chips.indices, id: \.self) { index in
            let chip = chips[index]
            HStack(spacing: 6) {
                Image(systemName: chip.symbol).font(.system(size: 12, weight: .medium))
                Text(chip.label).textStyle(.badgeSmall).lineLimit(1)
            }
            .foregroundStyle(chip.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(chip.background, in: Capsule())
            .fixedSize()
        }
    }
}

// MARK: - Stat card

/// `_AccountHistoryStatCard` (NW:1764-1800): GlowCard radius 22, padding
/// 16, the mono label, 8, the compact value in `amount` at 17.
struct AccountHistoryStatCard: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        GlowCard(padding: 16, radius: Metrics.statCardRadius) {
            VStack(alignment: .leading, spacing: Metrics.spacingS) {
                Text(label)
                    .textStyle(.monoMetricLabel)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(value)
                    .textStyle(AccountHistoryText.statValue)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized) \(value)")
    }
}

// MARK: - Trend chart

/// `_AccountHistoryChart` (NW:1904-2136). Empty: a 200pt note. Otherwise
/// padding (20, 20, 20, 16): "Trend" with the date range and the latest
/// compact amount, 16, then the 200pt chart.
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
                    .textStyle(AccountHistoryText.note)
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
/// (3pt), and the last spot's dot (`trendDot`, radius 5,
/// ring 3pt at 50% outside it). Lines have round caps and are curved with
/// fl_chart's cubic (smoothness 0.28) only when there are more than two
/// snapshots.
///
/// Touch (fl_chart's built-in handling, without its 48pt threshold, see
/// PARITY_GAPS.md): while a finger is down, the spot nearest in x shows fl_chart's default
/// indicators (a 4pt line up from the bottom and a dot, per line) and the
/// tooltip above it; lifting clears it. A mostly vertical drag scrolls the
/// page instead and clears it, as Flutter's scroll view wins the gesture
/// arena and cancels the chart's touch (`ChartTouch`). The tooltip is drawn
/// once (fl_chart stacks one copy per line) and kept inside the plot
/// horizontally.
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
        let line = Self.linePath(points, curved: history.count > 2)
        let topY = points.map(\.y).min() ?? 0
        let lineStyle = { (width: CGFloat) in StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .miter) }
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
            line.stroke(color, style: lineStyle(3))
            if let last = points.last {
                // `FlDotCirclePainter(radius 5, stroke 3)`: the ring is
                // centred 1.5pt outside the fill.
                Path(ellipseIn: CGRect(x: last.x - 6.5, y: last.y - 6.5, width: 13, height: 13))
                    .stroke(color.opacity(0.5), lineWidth: 3)
                Path(ellipseIn: CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10))
                    .fill(BudgieColor.trendDot)
            }
            if let touched {
                indicator(at: points[touched], plotHeight: plot.height, dotRadius: 7.2, color: color)
            }
        }
    }

    /// `defaultTouchedIndicators`: a 4pt butt-capped line from the bottom
    /// up to the dot's lower edge, then the dot (radius 7.2), in the line's
    /// colour.
    private func indicator(at point: CGPoint, plotHeight: CGFloat, dotRadius: CGFloat, color: Color) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: point.x, y: plotHeight))
                path.addLine(to: CGPoint(x: point.x, y: min(plotHeight, point.y + dotRadius)))
            }
            .stroke(color, lineWidth: 4)
            Path(ellipseIn: CGRect(
                x: point.x - dotRadius, y: point.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
                .fill(color)
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

    // MARK: Geometry (fl_chart)

    /// `generateNormalBarPath`: fl_chart's cubic through
    /// `CashFlowMath.trendControlPoints` (`curveSmoothness` 0.28; 0, i.e.
    /// straight segments, when the line is not curved).
    private static func linePath(_ points: [CGPoint], curved: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        let controls = CashFlowMath.trendControlPoints(
            points, smoothness: curved ? NetWorthPresentation.curveSmoothness : 0)
        for (index, control) in controls.enumerated() {
            path.addCurve(to: points[index + 1], control1: control.0, control2: control.1)
        }
        return path
    }
}

/// The trend chart's touch: the finger's x while it is down on the plot,
/// nil once lifted or once the page scrolls.
///
/// iOS 18+: a UIKit press that begins at touch-down (the tooltip shows at
/// once, as fl_chart's down event) and lets the scroll view's pan begin
/// alongside it only for a mostly vertical movement; when the page starts
/// scrolling the press cancels itself. A mostly horizontal movement keeps
/// the scroll view from starting, so scrubbing does not scroll. iOS 17
/// keeps a simultaneous SwiftUI drag, which coexists with scrolling there,
/// and drops the touch once the drag turns out vertical.
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

/// Places the tooltip as fl_chart does: centred on the spot (`anchor`, in
/// plot coordinates), its bottom 16pt (`tooltipMargin`) above it, laid out
/// at most `maxWidth` wide (content width plus padding); then shifted to
/// stay inside the plot horizontally (fl_chart's `fitInsideHorizontally`,
/// off in Flutter).
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

// MARK: - Timeline row

/// `_AccountHistoryTimelineRow` (NW:1802-1902) as a list row (REDESIGN_PLAN
/// 4.7): padding 12, a 40pt calendar tile in the account colour (Flutter: a
/// 12pt dot), 12, the `yMMMd` date over the `jm` time, 8, the signed amount
/// over the compact change from the next older update (green when good for
/// the type), 4, then the 48pt trash button, disabled (tertiary) while it
/// is the only update.
struct AccountTimelineRow: View {
    let snapshot: NetWorthSnapshotRecord
    let delta: Double?
    let deltaIsFavorable: Bool?
    let color: Color
    let canDelete: Bool
    let formatter: MoneyFormatter
    let onDelete: () -> Void

    @ScaledMetric(relativeTo: .body) private var trashSize: CGFloat = 16

    var body: some View {
        let date = DartDateFormat.yMMMd(snapshot.recordedAt)
        let time = DartDateFormat.jm(snapshot.recordedAt)
        let amount = formatter.formatSigned(snapshot.amount)
        let change = delta.map(formatter.formatCompactDelta)
        let changeColor = deltaIsFavorable.map { $0 ? BudgieColor.income : BudgieColor.danger } ?? BudgieColor.textSecondary

        HStack(spacing: 0) {
            HStack(spacing: 0) {
                IconTile(symbol: "calendar", color: color)
                    .padding(.trailing, 12)
                VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                    Text(date)
                        .textStyle(.rowTitle)
                        .foregroundStyle(BudgieColor.textPrimary)
                    Text(time)
                        .textStyle(.rowSubtitle)
                        .foregroundStyle(BudgieColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: Metrics.spacingXXS) {
                    Text(amount)
                        .textStyle(.amountSmall)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let change {
                        Text(change)
                            .textStyle(.badge)
                            .foregroundStyle(changeColor)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, Metrics.spacingS)
                .layoutPriority(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([date, time, amount].joined(separator: ", ") + (change.map { ", change \($0)" } ?? ""))
            .accessibilityActions {
                if canDelete { Button("Delete", action: onDelete) }
            }
            .accessibilityIdentifier("worth.history.timeline.row")
            Button(action: onDelete) {
                // Material `delete_rounded` 18 / w500 in a 48pt IconButton.
                Image(systemName: "trash.fill")
                    .font(.system(size: trashSize, weight: .medium))
                    .foregroundStyle(canDelete ? BudgieColor.danger : BudgieColor.textTertiary)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .padding(.leading, Metrics.spacingXS)
            .help(canDelete ? "Delete this balance update" : "Keep at least one balance update")
            .accessibilityLabel(canDelete ? "Delete this balance update" : "Keep at least one balance update")
            .accessibilityIdentifier("worth.history.timeline.delete")
        }
        .padding(12)
    }
}
