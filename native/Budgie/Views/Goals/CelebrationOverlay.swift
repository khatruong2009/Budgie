import SwiftUI

/// The completion celebration (`_CompletionCelebration` and
/// `_CelebrationPainter`, savings_goals_page.dart:1547-1692), 1600ms linear:
/// the dialog scrim (Flutter: black at 34%), 18 dots flying out from the
/// centre (44 to 224pt, radii 3 / 4.5 / 6, success and accent alternating,
/// fading as they go)
/// under a "Goal complete" card that scales 0.7 to 1 with Flutter's
/// `easeOutBack` over the first 80%; everything fades out over the last
/// 25%. It never takes touches. The page skips it under Reduce Motion.
struct CelebrationOverlay: View {
    let name: String
    /// When it started (animation clock only).
    let start: Date

    static let duration = 1.6

    /// Flutter `Curves.easeOutBack`.
    private static let easeOutBack = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.175, y: 0.885), endControlPoint: UnitPoint(x: 0.32, y: 1.275))

    var body: some View {
        TimelineView(.animation) { context in
            let v = min(max(context.date.timeIntervalSince(start) / Self.duration, 0), 1)
            let fade = v < 0.75 ? 1 : min(max(1 - (v - 0.75) / 0.25, 0), 1)
            ZStack {
                BudgieColor.scrim.opacity(fade).ignoresSafeArea()
                Canvas { canvas, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let distance = 44 + 180 * v
                    for i in 0..<18 {
                        let angle = 2 * Double.pi / 18 * Double(i)
                        let radius = 3 + Double(i % 3) * 1.5
                        let point = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
                        let color = i.isMultiple(of: 2) ? BudgieColor.income : BudgieColor.accent
                        canvas.fill(
                            Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(color.opacity(1 - v)))
                    }
                }
                card.scaleEffect(0.7 + 0.3 * Self.easeOutBack.value(at: min(v, 0.8) / 0.8))
            }
            .opacity(fade)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Goal complete, \(name)")
        .accessibilityIdentifier("goals.celebration")
    }

    /// Hugs its content, as Flutter's centred card does, until a long name
    /// needs the full width.
    private var card: some View {
        ViewThatFits(in: .horizontal) {
            cardBody.fixedSize(horizontal: true, vertical: false)
            cardBody.padding(.horizontal, Metrics.pageHorizontal)
        }
    }

    private var cardBody: some View {
        GlowCard(padding: 24) {
            VStack(spacing: 0) {
                // Material `check_rounded` 34 / w500 draws a 22.5pt wide
                // tick; SF `checkmark` medium at 25 is 22.
                Image(systemName: "checkmark")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(BudgieColor.onAccent)
                    .frame(width: 72, height: 72)
                    .background(BudgieColor.income, in: Circle())
                Text("Goal complete")
                    .textStyle(.sheetTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Metrics.spacingM)
                Text(name)
                    .textStyle(.note)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
