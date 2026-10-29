import BudgieCore
import SwiftUI

/// The horizontal month chip strip (`MonthSelector`, month_selector.dart),
/// shared by the SEE ALL page and the Worth tab (D13): capsule chips 8
/// apart reading "Sep 2026", list padding 16 x 8, newest month first. The
/// selected chip is centred when the strip appears (without animation) and
/// whenever the selection changes (300ms easeOut, none under Reduce
/// Motion), and again when the strip's width changes (a fold or resize; it
/// would otherwise keep its old offset).
/// The caller owns the tap haptic and the selection.
struct MonthStrip: View {
    let months: [DartDateTime]
    let selected: DartDateTime
    let onSelect: (DartDateTime) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Metrics.spacingS) {
                    ForEach(months, id: \.self) { month in
                        MonthChip(month: month, isSelected: month == selected) { onSelect(month) }
                            .id(month)
                    }
                }
                .padding(.horizontal, Metrics.spacingM)
                .padding(.vertical, Metrics.spacingS)
            }
            // A horizontal scroll view takes all the height it is offered.
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChangeCompat { size in
                let previous = width
                width = size.width
                guard previous != nil, previous != size.width else { return }
                Motion.animate(Motion.easeOut(Motion.normal), reduceMotion: reduceMotion) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { _, month in
                Motion.animate(Motion.easeOut(Motion.normal), reduceMotion: reduceMotion) {
                    proxy.scrollTo(month, anchor: .center)
                }
            }
        }
    }
}

private struct MonthChip: View {
    let month: DartDateTime
    let isSelected: Bool
    let action: () -> Void

    private static let text = TextSpec(face: .gabaritoSemiBold, size: 14, height: 1.25, relativeTo: .subheadline)

    var body: some View {
        Button(action: action) {
            Text("\(DartDateFormat.MMM(month)) \(DartDateFormat.y(month))")
                .textStyle(Self.text)
                .foregroundStyle(isSelected ? BudgieColor.selectionText : BudgieColor.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(isSelected ? BudgieColor.selectionFill : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(isSelected ? BudgieColor.selectionBorder : BudgieColor.cardBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .motion(Motion.easeOut(Motion.fast), value: isSelected)
        .accessibilityLabel("\(DartDateFormat.MMMM(month)) \(DartDateFormat.y(month))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
