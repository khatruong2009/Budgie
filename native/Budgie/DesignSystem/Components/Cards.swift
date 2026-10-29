import BudgieCore
import SwiftUI

/// Scales the label while pressed (GlowCard 0.98, PillButton 0.96, FAB 0.95).
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .motion(Motion.press, value: configuration.isPressed)
    }
}

/// The redesign's signature card (`glow_card.dart`): card surface, radius
/// 26, 1pt border, padding 20. The content sits inside the border as well
/// as the padding: Flutter's `Container` adds the border's width to its
/// padding, so every card is 2pt taller and wider than padding alone. With
/// `onTap` it presses to 0.98 with a light haptic; a long-press-only card
/// gets no press feedback, as in Flutter.
struct GlowCard<Content: View>: View {
    var padding: CGFloat = Metrics.cardPadding
    var radius: CGFloat = Metrics.cardRadius
    /// Overrides the surface (e.g. the completed-goal tint).
    var fill: AnyShapeStyle? = nil
    /// Overrides the 1pt border colour.
    var border: Color? = nil
    var onTap: (() -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @State private var taps = 0
    @State private var longPresses = 0
    @State private var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let card = content()
            .padding(padding + Metrics.borderThin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill ?? AnyShapeStyle(BudgieColor.card), in: shape)
            .overlay(shape.strokeBorder(border ?? BudgieColor.cardBorder, lineWidth: 1))
            .contentShape(shape)

        if let onLongPress {
            // Tap and long press are exclusive, like Flutter's GestureDetector.
            card
                .scaleEffect(pressed ? 0.98 : 1)
                .motion(Motion.press, value: pressed)
                .onTapGesture {
                    guard let onTap else { return }
                    taps += 1
                    onTap()
                }
                .onLongPressGesture(minimumDuration: 0.5) {
                    longPresses += 1
                    onLongPress()
                } onPressingChanged: { isPressing in
                    pressed = isPressing && onTap != nil
                }
                .sensoryFeedback(.impact(weight: .light), trigger: taps)
                .sensoryFeedback(.impact(weight: .medium), trigger: longPresses)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(onTap == nil ? [] : .isButton)
                .accessibilityAction { onTap?() }
                .accessibilityAction(named: "More actions") { onLongPress() }
        } else if let onTap {
            HapticButton(action: onTap) {
                card
            }
            .buttonStyle(PressScaleStyle(scale: 0.98))
        } else {
            card
        }
    }
}

extension View {
    /// The feature card (one per screen at most: Home's Safe to spend, the
    /// Goals summary, the Safe to spend sheet's total, the Settings brand
    /// card): `featureFill` with a 1pt `featureBorder`, radius 22, padding
    /// 18, full width. Text on it uses the `feature*` tokens.
    func featureCard(radius: CGFloat = Metrics.cardRadius, padding: CGFloat = 18) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(BudgieColor.featureFill, in: shape)
            .overlay(shape.strokeBorder(BudgieColor.featureBorder, lineWidth: Metrics.borderThin))
            .contentShape(shape)
    }
}

/// A GlowCard with 8pt padding and 1pt hairlines inset 12 between rows
/// (`GlowListCard`). `lazy` builds only the rows on screen (inside a scroll
/// view): for a list that can have hundreds of rows, like an account's
/// balance timeline (docs/PERFORMANCE.md).
struct GlowListCard<Row: View>: View {
    var radius: CGFloat = Metrics.cardRadius
    let rows: [Row]
    var lazy = false

    init(radius: CGFloat = Metrics.cardRadius, lazy: Bool = false, rows: [Row]) {
        self.radius = radius
        self.lazy = lazy
        self.rows = rows
    }

    var body: some View {
        GlowCard(padding: Metrics.listCardPadding, radius: radius) {
            if lazy {
                LazyVStack(spacing: 0) { content }
            } else {
                VStack(spacing: 0) { content }
            }
        }
    }

    @ViewBuilder private var content: some View {
        ForEach(rows.indices, id: \.self) { index in
            if index > 0 { Hairline().padding(.horizontal, Metrics.hairlineInset) }
            rows[index]
        }
    }
}

/// A 1pt list divider in the hairline colour.
struct Hairline: View {
    var body: some View {
        BudgieColor.hairline.frame(height: 1).accessibilityHidden(true)
    }
}

/// Tinted rounded-square icon (`IconTile`): colour at 13%, 40pt radius 14
/// (44pt radius 16), 20pt symbol.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 40
    var radius: CGFloat? = nil
    var iconSize: CGFloat = 20
    /// Overrides the tint (e.g. the grey tail row).
    var background: Color? = nil

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(
                background ?? color.opacity(0.13),
                in: RoundedRectangle(cornerRadius: radius ?? (size >= 44 ? 16 : 14), style: .continuous))
            .accessibilityHidden(true)
    }
}

extension IconTile {
    /// The tile for a category definition (its icon and colour token);
    /// a name without a definition gets the default grid in accent.
    init(category info: CategoryInfo?, size: CGFloat = 40, radius: CGFloat? = nil, iconSize: CGFloat = 20) {
        self.init(
            symbol: CategoryCatalog.symbol(for: info?.iconIdentifier ?? ""),
            color: BudgieColor.category(info?.colorToken ?? "accent"), size: size, radius: radius, iconSize: iconSize)
    }
}

/// The inside of a transaction row: tile, title (with the recurrence mark),
/// subtitle and a trailing amount that keeps its own width. Presentational
/// only; the button, accessibility and data stay with the row.
struct TransactionRowLayout<Tile: View>: View {
    var titleLines: Int? = 1
    /// Set on a title that names its alignment (`.multilineTextAlignment`).
    var titleAlignment: TextAlignment? = nil
    /// The text column's minimum width, when it has one.
    var textMinWidth: CGFloat? = nil
    /// A subtitle with no line limit and an amount limited to `lineLimit(1)`,
    /// instead of both being `singleLine()`.
    var plainSubtitleAndAmount = false
    let title: String
    let isRecurring: Bool
    let subtitle: String
    let amount: String
    let amountColor: Color
    @ViewBuilder let tile: Tile

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    titleText
                    if isRecurring { RecurrenceGlyph(size: 16).fixedSize() }
                }
                subtitleText
            }
            .frame(minWidth: textMinWidth, maxWidth: .infinity, alignment: .leading)
            amountText
                .layoutPriority(1)
        }
        .padding(12)
    }

    @ViewBuilder private var titleText: some View {
        let text = Text(title)
            .textStyle(.rowTitle)
            .foregroundStyle(BudgieColor.textPrimary)
            .lineLimit(titleLines)
        if let titleAlignment {
            text.multilineTextAlignment(titleAlignment)
        } else {
            text
        }
    }

    @ViewBuilder private var subtitleText: some View {
        let text = Text(subtitle)
            .textStyle(.rowSubtitle)
            .foregroundStyle(BudgieColor.textSecondary)
        if plainSubtitleAndAmount {
            text
        } else {
            text.singleLine()
        }
    }

    @ViewBuilder private var amountText: some View {
        let text = Text(amount)
            .textStyle(.amountSmall)
            .foregroundStyle(amountColor)
        if plainSubtitleAndAmount {
            text.lineLimit(1)
        } else {
            text.singleLine()
        }
    }
}

/// A card of option rows with a hairline between them, as in the picker
/// sheets: `count` rows built by index.
struct OptionListCard<Row: View>: View {
    let count: Int
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        GlowCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    if index > 0 { Hairline() }
                    row(index)
                }
            }
            .padding(.horizontal, Metrics.spacingM)
            .padding(.vertical, Metrics.spacingXXS)
        }
    }
}

/// A picker row: the option (15 w600, w700 when `boldWhenSelected` and
/// selected) and an accent check on the selected one, at least 48 tall.
/// `fillsWidth` gives the row `maxWidth: .infinity`; `explicitLabel` labels
/// it with the title alone (so the check is not read).
struct OptionRow: View {
    let title: String
    let selected: Bool
    var boldWhenSelected = false
    var hidesCheckFromVoiceOver = true
    var fillsWidth = false
    var explicitLabel = false
    var identifier: String? = nil
    let action: () -> Void

    /// `rowTitle` with w700.
    private static let selectedStyle = TextSpec(face: .gabaritoBold, size: 15, height: 1.25, relativeTo: .body)

    var body: some View {
        let base = button.accessibilityAddTraits(selected ? .isSelected : [])
        if let identifier {
            base.accessibilityIdentifier(identifier)
        } else {
            base
        }
    }

    @ViewBuilder private var button: some View {
        let plain = Button(action: action) {
            HStack(spacing: 14) {
                Text(title)
                    .textStyle(boldWhenSelected && selected ? Self.selectedStyle : .rowTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(BudgieColor.accent)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(hidesCheckFromVoiceOver)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: Metrics.formRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if explicitLabel {
            plain.accessibilityLabel(title)
        } else {
            plain
        }
    }
}
