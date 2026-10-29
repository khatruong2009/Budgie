import BudgieCore
import SwiftUI

/// The month picker under Home's pill (spending_page.dart:1001-1054): a
/// card with a 128pt wheel of the twelve month names, clipped to its
/// height like Flutter's `AnimatedSize` (the caller toggles `expanded` in a
/// 250ms easeInOut transaction, none under Reduce Motion). The wheel always shows `model.selectedMonth`
/// (Flutter's wheel keeps its first month), and a year stepper above it
/// changes the year while keeping the month (D13; Flutter's Home cannot
/// change the year).
struct HomeMonthPanel: View {
    let expanded: Bool

    @Environment(AppModel.self) private var model
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        panel
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChangeCompat { naturalHeight = $0.height }
            .frame(height: expanded ? naturalHeight : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(expanded)
            .accessibilityHidden(!expanded)
    }

    private var panel: some View {
        GlowCard(padding: 0) {
            VStack(spacing: 0) {
                YearStepper()
                Hairline().padding(.horizontal, Metrics.spacingM)
                MonthWheel()
            }
            .padding(.vertical, Metrics.spacingS)
        }
        .padding(EdgeInsets(top: 12, leading: Metrics.pageHorizontal, bottom: 0, trailing: Metrics.pageHorizontal))
    }
}

/// Previous year, the year, next year. Stepping keeps the month.
private struct YearStepper: View {
    @Environment(AppModel.self) private var model
    @State private var taps = 0

    var body: some View {
        let month = model.selectedMonth
        HStack(spacing: 0) {
            button("chevron.left", label: "Previous year", identifier: "home.monthPanel.prevYear") { step(month, by: -1) }
            Text(DartDateFormat.y(month))
                .textStyle(.rowTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Year \(DartDateFormat.y(month))")
                .accessibilityIdentifier("home.monthPanel.year")
            button("chevron.right", label: "Next year", identifier: "home.monthPanel.nextYear") { step(month, by: 1) }
        }
        .padding(.horizontal, Metrics.spacingS)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }

    private func button(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BudgieColor.textSecondary)
                .frame(width: Metrics.touchTarget, height: 36)
                // 36pt tall; the tap area is 44.
                .tapArea(vertical: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func step(_ month: DartDateTime, by years: Int) {
        taps += 1
        let f = month.fields
        model.selectMonth(model.calendar.date(f.year + years, f.month))
    }
}

/// The month wheel (`CupertinoPicker` with its SDK defaults: itemExtent 34,
/// diameterRatio 1.07, squeeze 1.45, off-centre rows at 0.447 opacity, a
/// `chipSurface` band inset 9 with radius 12) in a 128pt box, so about
/// five rows show. A snapping scroll view whose rows are laid out 34 apart
/// and painted where Flutter's `ListWheelViewport` puts them on the drum
/// (compressed towards the centre and foreshortened, no 3D tilt); rows
/// beyond the band's reach are drawn outside the scroll bounds, so its clip
/// is off and the box clips instead. It is always bound to
/// `model.selectedMonth`: every centred-row change selects that month (live,
/// like Flutter's scroll-update reporting) with a selection tick, and an
/// outside change scrolls the wheel. Tapping a row scrolls to it. VoiceOver
/// sees one adjustable "Month" element.
private struct MonthWheel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var itemExtent: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 128
    /// The centred row (month index), as the scroll view reports it.
    @State private var centred: Int?
    @State private var ticks = 0

    /// Fixed English names, as Flutter's `_months` (spending_page.dart:34-47).
    private static let names = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November",
        "December",
    ]
    private static let row = TextSpec(face: .gabaritoSemiBold, size: 16, height: 1.25, relativeTo: .body)
    private nonisolated static let space = "monthWheel"

    var body: some View {
        let extent = itemExtent
        let viewport = height
        let selected = model.selectedMonth.month - 1
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Self.names.indices, id: \.self) { index in
                    Text(Self.names[index])
                        .textStyle(Self.row)
                        .foregroundStyle(BudgieColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                        .frame(height: extent)
                        .contentShape(Rectangle())
                        .onTapGesture { scroll(to: index) }
                        .visualEffect { content, proxy in
                            let drum = Drum(rowMidY: proxy.frame(in: .named(Self.space)).midY, viewport: viewport, extent: extent)
                            return content
                                .scaleEffect(x: drum.scale, y: drum.scale * drum.cosine)
                                .offset(y: drum.offset)
                                .opacity(drum.opacity)
                        }
                        .id(index)
                }
            }
            .scrollTargetLayout()
        }
        // The viewport's own space (`.scrollView` is offset by the margins).
        .coordinateSpace(.named(Self.space))
        .contentMargins(.vertical, (viewport - extent) / 2, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centred)
        .scrollClipDisabled()
        .frame(height: viewport)
        .clipped()
        .background {
            // `CupertinoPickerDefaultSelectionOverlay`, on the chip token,
            // behind the rows (it is opaque).
            RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous)
                .fill(BudgieColor.chipSurface)
                .frame(height: extent)
                .padding(.horizontal, 9)
                .allowsHitTesting(false)
        }
        .onAppear { if centred != selected { centred = selected } }
        .onChange(of: centred) { _, index in
            guard let index, index != model.selectedMonth.month - 1 else { return }
            ticks += 1
            model.selectMonth(model.calendar.date(model.selectedMonth.year, index + 1))
        }
        .onChange(of: selected) { _, index in
            if centred != index { scroll(to: index) }
        }
        .sensoryFeedback(.selection, trigger: ticks)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Month")
        .accessibilityValue(Self.names[selected])
        .accessibilityIdentifier("home.monthWheel")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if selected < 11 { select(selected + 1) }
            case .decrement: if selected > 0 { select(selected - 1) }
            @unknown default: break
            }
        }
    }

    /// Flutter's tap-to-scroll: 300ms easeInOut (none under Reduce Motion).
    private func scroll(to index: Int) {
        withAnimation(reduceMotion ? nil : Motion.easeInOut(0.3)) { centred = index }
    }

    private func select(_ index: Int) {
        model.selectMonth(model.calendar.date(model.selectedMonth.year, index + 1))
    }
}

/// Where `RenderListWheelViewport` paints a row laid out `rowMidY` into the
/// viewport: its angle on the drum is its distance from the centre over the
/// viewport, times twice the largest visible angle, over the squeeze; it is
/// painted at `radius * sin(angle)`, `cos(angle)` tall, shrunk by the
/// perspective (0.003) for its depth, and dimmed to 0.447 outside the band.
private struct Drum {
    static let diameterRatio: CGFloat = 1.07
    static let squeeze: CGFloat = 1.45
    static let perspective: CGFloat = 0.003
    static let offCentreOpacity: CGFloat = 0.447
    static let maxAngle = asin(1 / diameterRatio)

    let offset: CGFloat
    let scale: CGFloat
    let cosine: CGFloat
    let opacity: CGFloat

    init(rowMidY: CGFloat, viewport: CGFloat, extent: CGFloat) {
        let distance = rowMidY - viewport / 2
        let angle = distance / viewport * 2 * Self.maxAngle / Self.squeeze
        guard abs(angle) < Self.maxAngle else {
            // Behind the drum.
            (offset, scale, cosine, opacity) = (0, 1, 1, 0)
            return
        }
        let radius = viewport * Self.diameterRatio / 2
        let depth = radius * (1 - cos(angle))
        let scale = 1 / (1 + Self.perspective * depth)
        let painted = radius * sin(angle) * scale
        let half = extent * cos(angle) * scale / 2
        // The share of the painted row inside the centre band.
        let inside = max(0, min(painted + half, extent / 2) - max(painted - half, -extent / 2))
        let share = half > 0 ? min(1, inside / (2 * half)) : 0
        self.offset = painted - distance
        self.scale = scale
        self.cosine = cos(angle)
        self.opacity = Self.offCentreOpacity + (1 - Self.offCentreOpacity) * share
    }
}
