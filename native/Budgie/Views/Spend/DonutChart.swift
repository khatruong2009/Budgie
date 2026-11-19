import BudgieCore
import SwiftUI

/// The Spend donut (`CategoryDonutChart`, widgets/category_donut_chart.dart):
/// a 240pt ring of the month's slices over the accent glow, with the total
/// (or the selected slice) in the centre disc. Geometry, hit testing and
/// the sweep maths come from `DonutGeometry`.
///
/// The whole square takes taps (on tap-up, like Flutter's `onTapUp`); a tap
/// selects, deselects or does nothing, and only a change plays the
/// selection haptic. The ring sweeps in from 12 o'clock over 500 ms when it
/// first appears and when the month changes, never on a selection or data
/// change; under Reduce Motion it is drawn whole.
struct DonutChart: View {
    let breakdown: CategoryBreakdown
    let formatter: MoneyFormatter
    let selectedSlice: Int?
    let onSelect: (Int?) -> Void

    @State private var selectionChanges = 0

    private static let size = CGFloat(DonutGeometry.size)
    /// The centre disc's diameter: 240 - 2 x 38 = 164.
    private static let discDiameter = size - 2 * CGFloat(DonutGeometry.centreDiscInset)

    var body: some View {
        let geometry = breakdown.donut
        ZStack {
            DonutRing(geometry: geometry, colors: breakdown.slices.map(\.palette.color), selectedIndex: selectedSlice)
                // A new month is a new ring: its sweep starts again from 0.
                .id(breakdown.month)
            Circle()
                .fill(BudgieColor.background)
                .frame(width: Self.discDiameter, height: Self.discDiameter)
            DonutCentreLabel(label: breakdown.centreLabel(selectedSlice: selectedSlice), formatter: formatter)
                .frame(width: Self.discDiameter, height: Self.discDiameter)
                .allowsHitTesting(false)
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            let size = CGSize(width: Self.size, height: Self.size)
            switch geometry.tap(at: value.location, in: size, selectedIndex: selectedSlice) {
            case .select(let index): select(index)
            case .deselect: select(nil)
            case .ignore: break
            }
        })
        .sensoryFeedback(.selection, trigger: selectionChanges)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spending by category")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Swipe up or down to select a category")
        .accessibilityAdjustableAction { direction in
            let last = breakdown.slices.count - 1
            guard last >= 0 else { return }
            let current = selectedSlice.flatMap { breakdown.slices.indices.contains($0) ? $0 : nil }
            switch direction {
            case .increment: select(current.map { min($0 + 1, last) } ?? 0)
            case .decrement: select(current.flatMap { $0 > 0 ? $0 - 1 : nil })
            @unknown default: break
            }
        }
        .accessibilityIdentifier("spend.donut")
    }

    private func select(_ index: Int?) {
        guard index != selectedSlice else { return }
        selectionChanges += 1
        onSelect(index)
    }

    /// No semantics in Flutter; VoiceOver reads the centre: the total and
    /// its change, or "<name>, <amount>, <percent>" for the selected slice.
    private var accessibilityValue: String {
        switch breakdown.centreLabel(selectedSlice: selectedSlice) {
        case .total(let total, let delta):
            let spent = "Spent \(formatter.format(total, decimalDigits: 0))"
            guard let delta else { return spent }
            switch delta.direction {
            case .up: return "\(spent), up \(delta.text)"
            case .down: return "\(spent), down \(delta.text)"
            case .neutral: return "\(spent), \(delta.text)"
            }
        case .slice(_, let value, let percentText):
            // The original name, not the uppercased eyebrow.
            let name = selectedSlice.map { breakdown.slices[$0].label } ?? ""
            return "\(name), \(formatter.format(value, decimalDigits: 0)), \(percentText)"
        }
    }
}

/// Owns the sweep progress for one month (re-created by `.id` when the
/// month changes, so it starts at 0 again). Appearing again after a pop or
/// a tab switch finds it already at 1 and does not replay.
private struct DonutRing: View {
    let geometry: DonutGeometry
    let colors: [Color]
    let selectedIndex: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = 0.0

    var body: some View {
        // Under Reduce Motion the ring is whole from the first frame, even
        // the one before `onAppear` (a month change re-creates this view).
        DonutArcs(geometry: geometry, colors: colors, selectedIndex: selectedIndex, sweep: reduceMotion ? 1 : sweep)
            .onAppear {
                guard sweep < 1 else { return }
                let (x1, y1, x2, y2) = DonutGeometry.sweepCurve
                Motion.animate(
                    .timingCurve(x1, y1, x2, y2, duration: DonutGeometry.sweepDuration), reduceMotion: reduceMotion
                ) { sweep = 1 }
            }
    }
}

/// `_DonutPainter`: butt-capped arcs at the eased `sweep` (D16). The
/// selection jumps between thicknesses, as in Flutter (no tween).
private struct DonutArcs: View, Animatable {
    let geometry: DonutGeometry
    let colors: [Color]
    let selectedIndex: Int?
    var sweep: Double

    nonisolated var animatableData: Double {
        get { sweep }
        set { sweep = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for arc in geometry.arcs(in: size, sweep: sweep, selectedIndex: selectedIndex) where colors.indices.contains(arc.index) {
                var path = Path()
                // Flutter's angles: 0 at 3 o'clock, increasing clockwise on
                // screen, which is SwiftUI's `clockwise: false` in y-down space.
                path.addArc(
                    center: center, radius: arc.radius, startAngle: .radians(arc.startAngle),
                    endAngle: .radians(arc.endAngle), clockwise: false)
                context.stroke(path, with: .color(colors[arc.index]), style: StrokeStyle(lineWidth: arc.lineWidth, lineCap: .butt))
            }
        }
        .accessibilityHidden(true)
    }
}

/// `_CenterLabel` (:315-447): "SPENT", the whole-unit total and the delta
/// pill; or the selected slice's name, value and share of the month.
private struct DonutCentreLabel: View {
    let label: CategoryBreakdown.CentreLabel
    let formatter: MoneyFormatter

    /// `AppTypography.eyebrow` for text that is already uppercased
    /// (`DartString.uppercase`), so it is not cased again.
    private static let eyebrow = TextSpec(face: .monoSemiBold, size: 11, tracking: 2.4, relativeTo: .caption2)

    var body: some View {
        switch label {
        case .total(let total, let delta):
            VStack(spacing: 6) {
                Text("SPENT")
                    .textStyle(Self.eyebrow)
                    .foregroundStyle(BudgieColor.textSecondary)
                hero(total)
                if let delta { DeltaPill(delta: delta) }
            }
        case .slice(let title, let value, let percentText):
            VStack(spacing: 6) {
                // Flutter's `FittedBox(scaleDown)` has no floor.
                Text(title)
                    .textStyle(Self.eyebrow)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.05)
                hero(value)
                Text(percentText)
                    .textStyle(.rowSubtitle)
                    .foregroundStyle(BudgieColor.textSecondary)
            }
            .padding(.horizontal, 12)
        }
    }

    /// Whole units in heroSmall, scaled down to fit the disc.
    private func hero(_ value: Double) -> some View {
        Text(formatter.format(value, decimalDigits: 0))
            .textStyle(.heroSmall)
            .foregroundStyle(BudgieColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
    }
}

/// Month-over-month pill (`_buildDeltaPill`): up is danger with a
/// north-east arrow, down is income with a south-west arrow, under 0.5%
/// is neutral with a dash.
private struct DeltaPill: View {
    let delta: CategoryBreakdown.Delta

    var body: some View {
        let (color, symbol): (Color, String) =
            switch delta.direction {
            case .neutral: (BudgieColor.textSecondary, "minus")
            case .up: (BudgieColor.danger, "arrow.up.right")
            case .down: (BudgieColor.income, "arrow.down.left")
            }
        PillChip(label: delta.text, color: color, symbol: symbol, horizontalPadding: 9, verticalPadding: 3)
            .singleLine()
            .minimumScaleFactor(0.5)
    }
}
