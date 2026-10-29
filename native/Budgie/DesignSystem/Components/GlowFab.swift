import SwiftUI

/// The 54pt accent FAB (`glow_fab.dart`): accent circle with a soft drop
/// shadow; scales in on appear (300ms easeOutBack), presses to 0.95, and a
/// tap fires a 500ms burst (a ping ring expanding to 1.7x and fading, the
/// icon popping by up to 22% with sin(pi t)). Reduce Motion
/// skips the entry and the burst.
struct GlowFab: View {
    var symbol = "plus"
    var size: CGFloat = Metrics.fabSize
    let label: String
    let action: () -> Void
    var longPress: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var bursts = 0
    @State private var taps = 0
    @State private var longPresses = 0
    @State private var pressed = false

    var body: some View {
        // The face scales in and presses; the hit target underneath stays
        // full size, so a tap during the entry animation still lands here
        // rather than on whatever the FAB covers.
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                Color.clear
                    .frame(width: size, height: size)
                    .keyframeAnimator(initialValue: 0.0, trigger: bursts) { _, t in
                        FabFace(symbol: symbol, size: size, t: t)
                    } keyframes: { _ in
                        LinearKeyframe(1.0, duration: 0.5)
                        MoveKeyframe(0.0)
                    }
                    .scaleEffect(pressed ? 0.95 : 1)
                    .motion(Motion.press, value: pressed)
                    .scaleEffect(entered ? 1 : 0.001)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard !entered else { return }
                Motion.animate(Motion.easeOutBack(0.3), reduceMotion: reduceMotion) { entered = true }
            }
            .contentShape(Circle())
            .onTapGesture {
                taps += 1
                if !reduceMotion { bursts += 1 }
                action()
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                guard let longPress else { return }
                longPresses += 1
                longPress()
            } onPressingChanged: { pressed = $0 }
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
            .sensoryFeedback(.selection, trigger: longPresses)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .modifier(OptionalAccessibilityAction(name: "More options", action: longPress))
    }
}

/// The FAB at burst progress `t` (0 = at rest).
private struct FabFace: View {
    let symbol: String
    let size: CGFloat
    let t: Double

    var body: some View {
        let ping = FlutterCurve.easeOut(t)
        let flare = sin(.pi * t)
        let accent = BudgieColor.accent
        ZStack {
            if t > 0 && t < 1 {
                Circle()
                    .strokeBorder(accent.opacity(0.55 * (1 - ping)), lineWidth: 2)
                    .frame(width: size, height: size)
                    .scaleEffect(1 + 0.7 * ping)
                    .allowsHitTesting(false)
            }
            Circle()
                .fill(accent)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            // Flutter draws `add_rounded` at 0.48 x size / w500, but that glyph
            // fills only about 56% of its box, where SF "plus" fills about
            // 81%: 0.36 x size at regular weight draws the same plus.
            let plus = symbol == "plus"
            Image(systemName: symbol)
                .font(.system(size: (size * (plus ? 0.36 : 0.48)).rounded(), weight: plus ? .regular : .medium))
                .foregroundStyle(BudgieColor.onAccent)
                .scaleEffect(1 + 0.22 * flare)
        }
    }
}

/// An accessibility action only when there is something to perform.
struct OptionalAccessibilityAction: ViewModifier {
    let name: String
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action { content.accessibilityAction(named: name, action) } else { content }
    }
}
