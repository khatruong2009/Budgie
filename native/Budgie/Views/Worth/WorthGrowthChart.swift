import BudgieCore
import SwiftUI

/// The "Growth" card (`_GrowthChartCard`, NW:386-587): the title with the
/// mono 6M / 1Y / ALL pills, then the 180pt chart of the net worth history
/// (all of it, up to 24 points, whatever month is selected) and the first /
/// middle / last axis labels; "Add balance updates to build your growth
/// chart." without history. Changing the range clears the scrub selection.
struct WorthGrowthCard: View {
    /// Oldest first (`getNetWorthHistory(limit: 24)` reversed).
    let history: [NetWorthHistoryPoint]
    @Binding var range: NetWorthGrowthRange
    let calendar: DartCalendar
    let formatter: MoneyFormatter

    @State private var selected: Int?

    var body: some View {
        let points = range.filter(history, calendar: calendar)
        GlowCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // The pills drop under the title when the row is too narrow
                // for both (the largest text sizes).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) { growthTitle.frame(maxWidth: .infinity, alignment: .leading); growthRange }
                    VStack(alignment: .leading, spacing: Metrics.spacingS) { growthTitle; growthRange }
                }
                .padding(.horizontal, Metrics.spacingXS)
                if points.isEmpty {
                    Text("Add balance updates to build your growth chart.")
                        .textStyle(WorthStyle.note)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .padding(.top, 12)
                } else {
                    GrowthChart(points: points, selected: $selected, formatter: formatter)
                        .frame(height: 180)
                        .padding(.top, 12)
                    axisLabels(points)
                        .padding(.top, 6)
                }
            }
            .padding(EdgeInsets(top: 20, leading: 16, bottom: 12, trailing: 16))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("worth.growth")
    }

    private var growthTitle: some View {
        Text("Growth")
            .textStyle(.cardTitle)
            .foregroundStyle(BudgieColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private var growthRange: some View {
        SegmentedPills(items: NetWorthGrowthRange.allCases.map(\.label), selection: rangeIndex, mono: true)
            .accessibilityIdentifier("worth.growth.range")
    }

    /// Only a change of range clears the selection (Flutter fires
    /// `onChanged` for another segment only).
    private var rangeIndex: Binding<Int> {
        Binding(
            get: { NetWorthGrowthRange.allCases.firstIndex(of: range) ?? 0 },
            set: { index in
                let picked = NetWorthGrowthRange.allCases[index]
                guard picked != range else { return }
                selected = nil
                range = picked
            })
    }

    /// `_AxisLabels`: `MAR '26` for the first, middle (more than two
    /// points) and last points, spread edge to edge rather than under their
    /// points; one point shows its label twice.
    private func axisLabels(_ points: [NetWorthHistoryPoint]) -> some View {
        let indices = NetWorthPresentation.growthAxisLabelIndices(count: points.count)
        return HStack(spacing: 0) {
            ForEach(Array(indices.enumerated()), id: \.offset) { position, index in
                if position > 0 { Spacer(minLength: 4) }
                Text(NetWorthText.axisLabel(points[index].date))
                    .textStyle(.monoAxis)
                    .foregroundStyle(BudgieColor.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Metrics.spacingXS)
        .accessibilityHidden(true)
    }
}

// MARK: - Chart

/// The chart box: the plot, the hover card over the scrubbed point, and the
/// scrub gesture. A 150ms long press selects the spot nearest horizontally
/// (no distance limit; PARITY_GAPS.md), moving updates it with
/// a selection tick per new spot, and lifting clears it; there are no taps,
/// so scrolling is untouched. VoiceOver reads a summary and steps through
/// the points with swipe up / down.
private struct GrowthChart: View {
    let points: [NetWorthHistoryPoint]
    @Binding var selected: Int?
    let formatter: MoneyFormatter

    @State private var size: CGSize = .zero
    /// The point VoiceOver has stepped to (nil: the summary).
    @State private var spokenIndex: Int?

    var body: some View {
        let values = points.map(\.netWorth)
        // `_selectedSpotIndex?.clamp(0, n - 1)`.
        let shown = selected.map { min(max($0, 0), points.count - 1) }
        ZStack {
            GrowthPlot(values: TrendValues(values: values), selected: shown)
                // fl_chart lerps between datasets of the same length; a new
                // length (range change) redraws at once.
                .id(values.count)
                .motion(.linear(duration: 0.15), value: TrendValues(values: values))
            if let shown {
                HoverCard(point: points[shown], formatter: formatter)
                    .modifier(HoverPlacement(alignment: NetWorthPresentation.hoverAlignment(index: shown, values: values)))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onGeometryChangeCompat { size = $0 }
        .modifier(ScrubGesture(onChanged: { scrub(to: $0, values: values) }, onEnded: { selected = nil }))
        .sensoryFeedback(.selection, trigger: selected) { _, new in new != nil }
        .accessibilityElement()
        .accessibilityLabel("Net worth growth")
        .accessibilityValue(spokenValue)
        .accessibilityAdjustableAction { direction in
            let last = points.count - 1
            switch direction {
            case .increment: spokenIndex = min((spokenIndex ?? -1) + 1, last)
            case .decrement: spokenIndex = max((spokenIndex ?? points.count) - 1, 0)
            @unknown default: break
            }
        }
        .onChange(of: points) { _, _ in spokenIndex = nil }
        .accessibilityIdentifier("worth.growth.chart")
    }

    private func scrub(to x: CGFloat, values: [Double]) {
        guard let scale = NetWorthChartScale.growth(values),
            let hit = NetWorthPresentation.nearestSpot(toX: x, in: scale.points(values, size: size))
        else { return }
        let index = min(hit, points.count - 1)
        if selected != index { selected = index }
    }

    /// "12 points, from March 5, 2026, $1,000.00, to ..." or one point.
    private var spokenValue: String {
        if let spokenIndex, points.indices.contains(spokenIndex) { return describe(points[spokenIndex]) }
        guard let first = points.first, let last = points.last else { return "" }
        let count = "\(points.count) \(points.count == 1 ? "point" : "points")"
        return "\(count), from \(NetWorthText.hoverTitle(first)), \(formatter.formatSigned(first.netWorth)), "
            + "to \(NetWorthText.hoverTitle(last)), \(formatter.formatSigned(last.netWorth))"
    }

    private func describe(_ point: NetWorthHistoryPoint) -> String {
        "\(NetWorthText.hoverTitle(point)), net worth \(formatter.formatSigned(point.netWorth)), "
            + "assets \(formatter.formatSigned(point.assets)), liabilities \(formatter.formatSigned(point.liabilities))"
            + (point.granularity == .month ? ", monthly snapshot" : "")
    }
}

/// The plot, painted the way fl_chart 1.2.0 paints `_NetWorthLineChart`
/// (NW:590-721): no titles or border, so the plot is the whole box; x is
/// the point index (first spot on the left edge, last on the right), y the
/// padded scale. In paint order: the hairline grid (multiples of a quarter
/// of the range counted from 0), the area under the main line (green 18%
/// to 0 over the rect from the topmost spot
/// down to the bottom), the main line (3pt green, even when net worth is
/// negative), then the dots (radius 5 with a 3pt ring outside) on the last
/// spot and the selected one: #F2F2FA with a green 50% ring on the last
/// spot while nothing is selected, else green with a green 25% ring. Lines
/// use fl_chart's cubic (smoothness 0.28, flat first tangent, overshoot
/// allowed) and round caps. Drawn 10pt beyond the box, since fl_chart does
/// not clip the end dot or caps. `values` animate as one vector, so the
/// scale and grid follow the spots.
private struct GrowthPlot: View, Animatable {
    nonisolated var values: TrendValues
    let selected: Int?

    nonisolated var animatableData: TrendValues {
        get { values }
        set { values = newValue }
    }

    private static let overhang: CGFloat = 10

    var body: some View {
        let values = values.values
        let selected = selected
        Canvas { context, size in
            let inset = Self.overhang
            let plot = CGSize(width: size.width - inset * 2, height: size.height - inset * 2)
            guard plot.width > 0, plot.height > 0, let scale = NetWorthChartScale.growth(values) else { return }
            let bottom = inset + plot.height
            let spots = scale.points(values, size: plot).map { CGPoint(x: $0.x + inset, y: $0.y + inset) }
            guard let first = spots.first, let last = spots.last else { return }
            let green = BudgieColor.income

            var grid = Path()
            for value in scale.gridLines {
                let y = inset + scale.y(value, height: plot.height)
                grid.move(to: CGPoint(x: inset, y: y))
                grid.addLine(to: CGPoint(x: inset + plot.width, y: y))
            }
            context.stroke(grid, with: .color(BudgieColor.hairline), lineWidth: 1)

            var curve = Path()
            curve.move(to: first)
            for (index, controls) in CashFlowMath.trendControlPoints(spots, smoothness: NetWorthPresentation.curveSmoothness)
                .enumerated()
            {
                curve.addCurve(to: spots[index + 1], control1: controls.0, control2: controls.1)
            }
            var area = curve
            area.addLine(to: CGPoint(x: last.x, y: bottom))
            area.addLine(to: CGPoint(x: first.x, y: bottom))
            area.addLine(to: first)
            area.closeSubpath()
            let top = spots.map(\.y).min() ?? bottom
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [green.opacity(0.18), green.opacity(0)]),
                    startPoint: CGPoint(x: first.x, y: top), endPoint: CGPoint(x: first.x, y: bottom)))
            context.stroke(curve, with: .color(green), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            let lastIndex = spots.count - 1
            for index in spots.indices where index == lastIndex || index == selected {
                let white = index == lastIndex && selected == nil
                let center = spots[index]
                // `FlDotCirclePainter`: the stroke circle at radius 5 + 3/2.
                context.stroke(
                    Path(ellipseIn: CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13)),
                    with: .color(green.opacity(white ? 0.5 : 0.25)), lineWidth: 3)
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                    with: .color(white ? BudgieColor.trendDot : green))
            }
        }
        .padding(-Self.overhang)
        .accessibilityHidden(true)
    }
}

/// Places the hover card like Flutter's `Align(Alignment(x, y))` inside the
/// chart box: the card's own size (at most 200 wide) positioned so that -1
/// / 1 put it flush with an edge.
private struct HoverPlacement: ViewModifier {
    let alignment: (x: Double, y: Double, useBottom: Bool)

    func body(content: Content) -> some View {
        FractionalAlign(x: alignment.x, y: alignment.y) { content }
    }
}

private struct FractionalAlign: Layout {
    let x: Double
    let y: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: min(200, bounds.width), height: bounds.height))
            let origin = CGPoint(
                x: bounds.minX + (bounds.width - size.width) * CGFloat(x + 1) / 2,
                y: bounds.minY + (bounds.height - size.height) * CGFloat(y + 1) / 2)
            subview.place(at: origin, proposal: ProposedViewSize(size))
        }
    }
}

/// `_NetWorthHoverCard` (NW:722-817): the point's date (`MMMM y` for a
/// compressed month), its net worth (green or rose), the assets and
/// liabilities with 6pt dots, and "Monthly snapshot" for a month point.
private struct HoverCard: View {
    @Environment(\.colorScheme) private var scheme
    let point: NetWorthHistoryPoint
    let formatter: MoneyFormatter

    /// `rowSubtitle` at 11: w600 (title) and w400 (rows).
    private static let title = TextSpec(face: .gabaritoSemiBold, size: 11, height: 1.25, relativeTo: .caption2)
    private static let row = TextSpec(face: .gabaritoRegular, size: 11, height: 1.25, relativeTo: .caption2)
    /// `monoLabel` at 9.
    private static let snapshot = TextSpec(face: .monoMedium, size: 9, tracking: 1, relativeTo: .caption2)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Text(NetWorthText.hoverTitle(point)).textStyle(Self.title).foregroundStyle(BudgieColor.textSecondary)
            Text(formatter.formatSigned(point.netWorth))
                .textStyle(.amount)
                .foregroundStyle(point.netWorth >= 0 ? BudgieColor.income : BudgieColor.danger)
                .padding(.top, Metrics.spacingXS)
            row("Assets", point.assets, dot: BudgieColor.income).padding(.top, 6)
            row("Liabilities", point.liabilities, dot: BudgieColor.danger).padding(.top, Metrics.spacingXXS)
            if point.granularity == .month {
                Text("Monthly snapshot")
                    .textStyle(Self.snapshot)
                    .foregroundStyle(BudgieColor.textTertiary)
                    .padding(.top, 6)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        // Its tallest form (a month point) must fit the 180pt chart box:
        // at xxxLarge it is about 150pt; larger sizes stop scaling here.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        // Flutter adds the 1pt border to the padding.
        .padding(.horizontal, 14 + Metrics.borderThin)
        .padding(.vertical, 10 + Metrics.borderThin)
        .background(BudgieColor.chipSurface, in: shape)
        .overlay(shape.strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderThin))
        .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.12), radius: 10, y: 8)
        .accessibilityHidden(true)
    }

    private func row(_ label: String, _ value: Double, dot: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text("\(label)  \(formatter.formatSigned(value))")
                .textStyle(Self.row)
                .foregroundStyle(BudgieColor.textSecondary)
        }
    }
}

// MARK: - Scrub gesture

/// fl_chart's `longPressDuration: 150ms` scrub: `onChanged` with the touch's
/// x in the chart from the moment the press is recognised (Flutter selects
/// at long-press start, before any movement), `onEnded` when it lifts or is
/// cancelled. On iOS 18+ a UIKit long press (which any scroll made before
/// the 150ms wins over); iOS 17 keeps a SwiftUI long press sequenced before
/// a drag, and takes the location at recognition from a zero-distance drag
/// running alongside (the sequenced drag has none until the finger moves).
private struct ScrubGesture: ViewModifier {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    @GestureState private var scrubX: CGFloat?
    @State private var touchX: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(ChartLongPress(onChanged: onChanged, onEnded: onEnded))
        } else {
            content
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { touchX = $0.location.x }
                        .onEnded { _ in touchX = nil })
                .gesture(
                    LongPressGesture(minimumDuration: 0.15)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .updating($scrubX) { [touchX] value, state, _ in
                            if case .second(true, let drag) = value, let x = drag?.location.x ?? touchX { state = x }
                        }
                )
                .onChange(of: scrubX) { _, x in
                    if let x { onChanged(x) } else { onEnded() }
                }
        }
    }
}

@available(iOS 18.0, *)
private struct ChartLongPress: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let press = UILongPressGestureRecognizer()
        press.minimumPressDuration = 0.15
        return press
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: onChanged(context.converter.localLocation.x)
        case .ended, .cancelled, .failed: onEnded()
        default: break
        }
    }
}
