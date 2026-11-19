import SwiftUI

/// The brand screen shown while the store opens (`_OpeningScreen`): the
/// 120pt mark centred on the page background (both palettes, redesign 4.7;
/// no glows). Over 1.4s the mark lifts to 1.03, "Budgie" and "BUDGET IN
/// BALANCE" fade up, then three dots pulse. Reduce Motion shows the final
/// state without the pulse.
/// The mark starts at the window centre, where the launch screen draws it,
/// and glides to the centre of the horizontal safe area (the Duo's status
/// column or rail) as it lifts, so the handoff doesn't jump.
struct OpeningView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let logoSize: CGFloat = 120

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let elapsed = reduceMotion ? 10 : context.date.timeIntervalSince(start)
            let t = min(elapsed / 1.4, 1)
            GeometryReader { geometry in
                let size = geometry.size
                let insets = geometry.safeAreaInsets
                let windowHeight = size.height + insets.top + insets.bottom
                let rise = FlutterCurve.interval(t, 0, 0.55, FlutterCurve.easeOutCubic)
                let lift = 1 + 0.03 * rise
                let nameIn = FlutterCurve.interval(t, 0.2, 0.55, FlutterCurve.easeOut)
                let nameRise = 1 - FlutterCurve.interval(t, 0.2, 0.55, FlutterCurve.easeOutCubic)
                let taglineIn = FlutterCurve.interval(t, 0.35, 0.7, FlutterCurve.easeOut)
                let taglineRise = 1 - FlutterCurve.interval(t, 0.35, 0.7, FlutterCurve.easeOutCubic)
                let loaderIn = FlutterCurve.interval(t, 0.8, 1, FlutterCurve.easeOut)
                // Laid out in the safe area. The window's centre, in this
                // view's coordinates, is where the launch screen draws the mark.
                let windowCenter = CGPoint(
                    x: (size.width + insets.trailing - insets.leading) / 2,
                    y: windowHeight / 2 - insets.top)
                // Horizontally the safe area's centre; vertically the
                // window's, as on every iPhone.
                let center = CGPoint(x: size.width / 2, y: windowCenter.y)
                let logoX = windowCenter.x + (center.x - windowCenter.x) * rise

                ZStack {
                    BudgieColor.background.ignoresSafeArea()
                    Image("logo")
                        .resizable().scaledToFit()
                        .frame(width: Self.logoSize, height: Self.logoSize)
                        .scaleEffect(lift)
                        .position(x: logoX, y: center.y)
                    VStack(spacing: Metrics.spacingS) {
                        Text("Budgie")
                            .textStyle(.pageTitle)
                            .foregroundStyle(BudgieColor.textPrimary)
                            .opacity(nameIn)
                            .offset(y: 0.35 * 34 * nameRise)
                        Text("BUDGET IN BALANCE")
                            .textStyle(.eyebrow)
                            .tracking(2.8)
                            .foregroundStyle(BudgieColor.textSecondary)
                            .opacity(taglineIn)
                            .offset(y: 0.5 * 13 * taglineRise)
                    }
                    .frame(width: size.width)
                    .position(x: center.x, y: center.y + Self.logoSize / 2 + Metrics.spacingL + 30)
                    dots(phase: reduceMotion ? nil : elapsed.truncatingRemainder(dividingBy: 1.2) / 1.2)
                        .opacity(loaderIn)
                        .position(x: center.x, y: windowHeight * 0.92 - insets.top)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Budgie is opening")
    }

    /// `_PulsingDots`: 7pt accent dots, opacity 0.25-1 on a wave offset by
    /// a third of the 1.2s cycle each.
    private func dots(phase: Double?) -> some View {
        HStack(spacing: Metrics.spacingS) {
            ForEach(0..<3, id: \.self) { index in
                let wave = phase.map { (sin(($0 - Double(index) / 3) * 2 * .pi) + 1) / 2 } ?? 0.6
                Circle().fill(BudgieColor.accent).frame(width: 7, height: 7).opacity(0.25 + 0.75 * wave)
            }
        }
    }
}
