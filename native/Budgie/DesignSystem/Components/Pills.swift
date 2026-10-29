import SwiftUI

extension View {
    /// Grows a control's tap area, and with it its accessibility frame, by
    /// `horizontal` and `vertical` points on each side (WCAG 2.5.8 / HIG:
    /// 44 x 44pt) without moving anything: the growth is transparent and is
    /// taken back out of the layout, so the control draws and lays out as
    /// before. Apply it to a Button's label.
    func tapArea(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }
}

/// Small badge (`PillChip`): tinted (colour at 14%) or outlined (colour at
/// 40%), optional 15pt symbol, badge text in the colour.
struct PillChip: View {
    let label: String
    let color: Color
    /// The label's colour when it differs from the tint's `color` (a category
    /// colour that is too pale to read as text; see `BudgieColor.legible`).
    var textColor: Color? = nil
    var outlined = false
    var symbol: String? = nil
    var style: TextSpec = .badge
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 5
    var action: (() -> Void)? = nil

    @State private var taps = 0

    var body: some View {
        let chip = HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).accessibilityHidden(true)
            }
            Text(label).textStyle(style)
        }
        .foregroundStyle(textColor ?? color)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(outlined ? Color.clear : color.opacity(0.14), in: Capsule())
        .overlay { if outlined { Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1) } }

        if let action {
            Button {
                taps += 1
                action()
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
        } else {
            chip
        }
    }
}

/// Capsule button (`PillButton`): 52pt outlined (no fill, a 1.5pt card
/// border, the label in `color`), or 44pt filled with `color` (accent by
/// default) and an on-accent label; sheets' full-width primary passes
/// `height: Metrics.pillButtonHeight` (52). Presses to 0.96 with a light
/// haptic.
struct PillButton: View {
    let title: String
    var symbol: String? = nil
    var color: Color = BudgieColor.accent
    var filled = false
    var height: CGFloat? = nil
    /// Instead of a fixed height: at least this tall, growing with the
    /// label at large Dynamic Type sizes.
    var minHeight: CGFloat? = nil
    /// A write is awaited: a spinner over a capsule in `color`. The caller
    /// disables the button.
    var loading = false
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        let foreground = filled ? BudgieColor.onAccent : color
        Button {
            taps += 1
            action()
        } label: {
            HStack(spacing: filled ? 6 : 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: filled ? 16 : 18, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.custom(BudgieFont.gabaritoBold.postScriptName, size: filled ? 14 : 15, relativeTo: .body))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 20)
            .padding(.vertical, minHeight == nil ? 0 : Metrics.spacingS)
            .frame(maxWidth: .infinity)
            .frame(height: minHeight == nil ? height ?? (filled ? Metrics.pillButtonCompactHeight : Metrics.pillButtonHeight) : nil)
            .frame(minHeight: minHeight)
            .background(filled ? color : Color.clear, in: Capsule())
            .overlay { if !filled { Capsule().strokeBorder(BudgieColor.cardBorder, lineWidth: Metrics.borderMedium) } }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .overlay {
            if loading {
                Capsule().fill(color)
                ProgressView().tint(BudgieColor.onAccent)
            }
        }
    }
}

/// Segmented capsule control (`SegmentedPillControl`): a track with the
/// active segment in the selection fill (Settings theme), or the mono
/// variant with no track and an accent-tint active segment (chart range
/// pills). `fillWidth` stretches the segments equally across the width the
/// control is given (the add form's 176pt Expense / Income switch).
struct SegmentedPills: View {
    let items: [String]
    @Binding var selection: Int
    var mono = false
    var fillWidth = false

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: mono ? 4 : 0) {
            ForEach(items.indices, id: \.self) { index in
                let selected = index == selection
                Button {
                    selection = index
                } label: {
                    Text(items[index])
                        .font(labelFont(selected: selected))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .tracking(0)
                        .foregroundStyle(
                            selected ? (mono ? BudgieColor.accent : BudgieColor.selectionText) : BudgieColor.dockInactiveIcon)
                        .padding(.horizontal, mono ? 11 : 12)
                        .padding(.vertical, mono ? 5 : 6)
                        .frame(maxWidth: fillWidth ? .infinity : nil, maxHeight: fillWidth ? .infinity : nil)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(mono ? BudgieColor.accent.opacity(0.18) : BudgieColor.selectionFill)
                                    .matchedGeometryEffect(id: "active", in: namespace)
                            }
                        }
                        // The capsule draws 23-26pt tall; the tap area is 44.
                        .tapArea(horizontal: mono ? 4 : 0, vertical: mono ? 11 : 9)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(mono ? 0 : 3)
        .background { if !mono { Capsule().fill(BudgieColor.track) } }
        // A container, so an identifier or label given to the control does
        // not replace its segments' own elements.
        .accessibilityElement(children: .contain)
        .motion(Motion.segment, value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func labelFont(selected: Bool) -> Font {
        if mono { return .custom(BudgieFont.monoSemiBold.postScriptName, size: 11, relativeTo: .caption) }
        return .custom((selected ? BudgieFont.gabaritoBold : .gabaritoSemiBold).postScriptName, size: 12, relativeTo: .caption)
    }
}

/// Month/range selector pill (`MonthPill`, budgie_header.dart:80-132):
/// chip surface and a 1pt 8% border around padding 16 x 9 (Flutter's
/// Container adds the border's width to the padding), the label in
/// `rowTitle` at 14 (w600, height 1.25) and a 16pt `expand_more` chevron,
/// 6 apart. `dimmed` greys the label for a pill whose choice is no longer
/// applied (the SEE ALL month after the dates changed).
struct MonthPill: View {
    let label: String
    var dimmed = false
    var action: (() -> Void)? = nil

    @State private var taps = 0

    /// `rowTitle` with fontSize 14.
    private static let labelText = TextSpec(face: .gabaritoSemiBold, size: 14, height: 1.25, relativeTo: .subheadline)

    var body: some View {
        let pill = HStack(spacing: 6) {
            Text(label)
                .textStyle(Self.labelText)
                .foregroundStyle(dimmed ? BudgieColor.textSecondary : BudgieColor.textPrimary)
                // One line, shrunk if it must be: "6 months" must not break
                // letter by letter at the largest text sizes.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            // Material `expand_more_rounded` 16 / w500: a small chevron in a 16pt box.
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(BudgieColor.textSecondary)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16 + Metrics.borderThin)
        .padding(.vertical, 9 + Metrics.borderThin)
        .background(BudgieColor.chipSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(BudgieColor.pillBorder, lineWidth: Metrics.borderThin))

        if let action {
            Button {
                taps += 1
                action()
            } label: {
                // The pill draws 38pt tall; the tap area is 44.
                pill.tapArea(vertical: 3)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .light), trigger: taps)
            .accessibilityHint("Choose a month")
        } else {
            pill
        }
    }
}
