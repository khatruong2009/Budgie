import BudgieCore
import SwiftUI

/// Clamps a fraction to 0...1; NaN is 0 (Flutter's progress widgets).
private func unit(_ value: Double) -> Double {
    value.isNaN ? 0 : min(max(value, 0), 1)
}

/// Capsule progress bar (`GlowProgressBar`) that grows
/// from 0 on first appearance over 800ms (instant under Reduce Motion).
/// Heights: 8 budgets, 6 categories, 12-16 comparisons, 14 the Home gauge.
struct GlowProgressBar: View {
    let value: Double
    var height: CGFloat = 8
    var color: Color = BudgieColor.accent
    var track: Color? = nil
    /// End-of-fill thumb dot (the Home gauge).
    var showThumb = false
    /// 1pt border colour around the track.
    var trackBorder: Color? = nil
    /// Gap between track edge and fill (the Home gauge uses 2).
    var fillInset: CGFloat = 0
    var animate = true

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let target = unit(value)
        let shown = appeared || !animate ? target : 0
        GeometryReader { geometry in
            let border: CGFloat = trackBorder == nil ? 0 : 1
            let innerWidth = geometry.size.width - fillInset * 2 - border * 2
            let innerHeight = height - fillInset * 2 - border * 2
            let fillWidth = max(0, innerWidth * shown)
            ZStack(alignment: .leading) {
                Capsule().fill(track ?? BudgieColor.track)
                    .overlay { if let trackBorder { Capsule().strokeBorder(trackBorder, lineWidth: 1) } }
                if shown > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: fillWidth, height: innerHeight)
                        .offset(x: fillInset + border)
                    if showThumb {
                        // Inside the border box, as Flutter lays it out
                        // (glow_progress_bar.dart:94-96): centred on the
                        // fill's end, clamped to [inset, box + inset - height].
                        let minX = fillInset
                        let maxX = geometry.size.width - border * 2 + fillInset - height
                        if maxX > minX {
                            Circle()
                                .fill(scheme == .dark ? Color(hex: 0xF2F2FA) : .white)
                                .overlay { if scheme != .dark { Circle().strokeBorder(color.opacity(0.6), lineWidth: 2) } }
                                .frame(width: height, height: height)
                                .offset(x: border + min(max(fillInset + fillWidth - height / 2, minX), maxX))
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .motion(Motion.progress, value: shown)
        .onAppear {
            guard !appeared else { return }
            Motion.animate(Motion.progress, reduceMotion: reduceMotion) { appeared = true }
        }
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((target * 100).rounded())) percent"))
    }
}

/// Assets/liabilities split (`SplitGlowBar`): income left, danger right,
/// 3pt gap; a single bar at 0 or 1.
struct SplitGlowBar: View {
    /// assets / (assets + liabilities).
    let assetsFraction: Double
    var height: CGFloat = 16

    var body: some View {
        let fraction = unit(assetsFraction)
        GeometryReader { geometry in
            if fraction >= 1 || fraction <= 0 {
                segment(fraction >= 1 ? BudgieColor.income : BudgieColor.danger)
            } else {
                // Flex weights rounded to thousandths, as Flutter's `flex`.
                let flex = NetWorthPresentation.splitFlex(fraction)
                let available = geometry.size.width - 3
                HStack(spacing: 3) {
                    segment(BudgieColor.income)
                        .frame(width: available * CGFloat(flex.assets) / CGFloat(flex.assets + flex.liabilities))
                    segment(BudgieColor.danger)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func segment(_ color: Color) -> some View {
        Capsule().fill(color)
    }
}

/// Conic progress ring (`ProgressRing`): track ring, fill arc from 12
/// o'clock with butt caps, inner disc; grows from
/// 0 over 900ms (instant under Reduce Motion). 72/8 summary, 84/9 goals.
struct ProgressRing<Center: View>: View {
    let value: Double
    var size: CGFloat = 84
    var thickness: CGFloat = 9
    var color: Color = BudgieColor.accent
    var track: Color = BudgieColor.track
    var inner: Color? = nil
    @ViewBuilder var center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let target = unit(value)
        let t = appeared ? target : 0
        ZStack {
            Circle()
                .inset(by: thickness / 2)
                .stroke(track, lineWidth: thickness)
            Circle()
                .inset(by: thickness / 2)
                .trim(from: 0, to: t)
                .stroke(color, style: StrokeStyle(lineWidth: thickness, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle()
                .fill(inner ?? BudgieColor.card)
                .padding(thickness)
            center()
        }
        .frame(width: size, height: size)
        .motion(Motion.ring, value: t)
        .onAppear {
            guard !appeared else { return }
            Motion.animate(Motion.ring, reduceMotion: reduceMotion) { appeared = true }
        }
    }
}
