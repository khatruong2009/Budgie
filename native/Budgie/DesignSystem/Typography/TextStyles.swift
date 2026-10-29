import SwiftUI

/// One Flutter `TextStyle` (`theme/app_typography.dart`): face, size,
/// tracking, line height (`height`, a multiple of the size) and tabular
/// figures. Sizes scale with Dynamic Type relative to `relativeTo`.
struct TextSpec: Sendable {
    let face: BudgieFont
    let size: CGFloat
    var tracking: CGFloat = 0
    /// Flutter `height`: every line box is `round(size * height)` (see
    /// `textStyle`). Both faces' natural line height is 1.2 x size.
    var height: CGFloat = 1.2
    var tabular = false
    var uppercase = false
    var relativeTo: Font.TextStyle = .body
}

extension TextSpec {
    // MARK: Redesign

    static let hero = TextSpec(face: .gabaritoExtraBold, size: 58, tracking: -2, height: 1.0, tabular: true, relativeTo: .largeTitle)
    static let heroDecimals = TextSpec(face: .gabaritoBold, size: 32, height: 1.0, tabular: true, relativeTo: .largeTitle)
    static let heroMedium = TextSpec(face: .gabaritoExtraBold, size: 48, tracking: -1.8, height: 1.0, tabular: true, relativeTo: .largeTitle)
    static let heroSmall = TextSpec(face: .gabaritoExtraBold, size: 34, tracking: -1, height: 1.1, tabular: true, relativeTo: .largeTitle)
    static let pageTitle = TextSpec(face: .gabaritoExtraBold, size: 30, tracking: -0.9, relativeTo: .title)
    /// Sheet and dialog titles.
    static let sheetTitle = TextSpec(face: .gabaritoExtraBold, size: 24, tracking: -0.5, relativeTo: .title2)
    static let sectionHeader = TextSpec(face: .gabaritoBold, size: 21, tracking: -0.2, relativeTo: .title3)
    /// A section's text link ("See all", "Edit").
    static let textLink = TextSpec(face: .gabaritoSemiBold, size: 15, relativeTo: .subheadline)
    static let cardTitle = TextSpec(face: .gabaritoBold, size: 17, height: 1.25, relativeTo: .headline)
    static let goalTitle = TextSpec(face: .gabaritoBold, size: 18, tracking: -0.3, height: 1.25, relativeTo: .headline)
    static let rowTitle = TextSpec(face: .gabaritoSemiBold, size: 15, height: 1.25, relativeTo: .body)
    static let rowSubtitle = TextSpec(face: .gabaritoRegular, size: 12, height: 1.25, relativeTo: .caption)
    static let amount = TextSpec(face: .gabaritoBold, size: 16, tabular: true, relativeTo: .body)
    static let amountSmall = TextSpec(face: .gabaritoBold, size: 15, tabular: true, relativeTo: .body)
    static let chipAmount = TextSpec(face: .gabaritoBold, size: 24, tracking: -0.5, height: 1.15, tabular: true, relativeTo: .title2)
    static let metricAmount = TextSpec(face: .gabaritoExtraBold, size: 24, tracking: -0.5, height: 1.15, tabular: true, relativeTo: .title2)
    static let badge = TextSpec(face: .gabaritoBold, size: 12, relativeTo: .caption)
    static let badgeSmall = TextSpec(face: .gabaritoBold, size: 11, relativeTo: .caption2)
    static let eyebrow = TextSpec(face: .monoSemiBold, size: 11, tracking: 2.4, uppercase: true, relativeTo: .caption2)
    static let eyebrowTight = TextSpec(face: .monoSemiBold, size: 11, tracking: 2, uppercase: true, relativeTo: .caption2)
    static let monoLabel = TextSpec(face: .monoMedium, size: 11, tracking: 1, relativeTo: .caption2)
    static let monoLink = TextSpec(face: .monoSemiBold, size: 11, tracking: 1.5, relativeTo: .caption2)
    static let monoMetricLabel = TextSpec(face: .monoSemiBold, size: 10, tracking: 1.6, relativeTo: .caption2)
    static let monoAxis = TextSpec(face: .monoMedium, size: 10, relativeTo: .caption2)
    static let monoMonth = TextSpec(face: .monoMedium, size: 11, relativeTo: .caption2)

    // MARK: Legacy

    static let headingLarge = TextSpec(face: .gabaritoBold, size: 28, tracking: -0.3, relativeTo: .title)
    static let headingSmall = TextSpec(face: .gabaritoSemiBold, size: 20, tracking: -0.1, height: 1.3, relativeTo: .title3)
    static let bodyLarge = TextSpec(face: .gabaritoRegular, size: 17, tracking: -0.4, height: 1.5, relativeTo: .body)
    static let bodyMedium = TextSpec(face: .gabaritoRegular, size: 15, tracking: -0.2, height: 1.5, relativeTo: .subheadline)
    static let bodySmall = TextSpec(face: .gabaritoRegular, size: 13, tracking: -0.1, height: 1.4, relativeTo: .footnote)
    static let labelSmall = TextSpec(face: .gabaritoSemiBold, size: 13, tracking: -0.1, height: 1.3, relativeTo: .footnote)
    static let caption = TextSpec(face: .gabaritoRegular, size: 13, tracking: -0.1, height: 1.4, relativeTo: .footnote)
    /// `caption` at w600: form field labels (`ModernTextField`, the forms'
    /// wheel captions) and the recurring card's detail labels.
    static let captionStrong = TextSpec(face: .gabaritoSemiBold, size: 13, tracking: -0.1, height: 1.4, relativeTo: .footnote)
    static let numericMedium = TextSpec(face: .gabaritoSemiBold, size: 22, tracking: -0.2, height: 1.3, tabular: true, relativeTo: .title2)

    /// The text style the size scales with. `.caption2` is the one style that
    /// is 11pt from the smallest size up to Large, so the Dynamic Type audit
    /// reads text scaled with it as only partly supporting Dynamic Type;
    /// `.caption` is 12pt at Large and grows from there. Scaling is a ratio to
    /// the size at Large, so either gives `size` at the default setting and the
    /// two grow alike above it.
    var scalingStyle: Font.TextStyle { relativeTo == .caption2 ? .caption : relativeTo }

    /// The font alone (for places that take a `Font`, e.g. `Text` concatenation).
    func font(scaledSize: CGFloat? = nil) -> Font {
        let font = Font.custom(face.postScriptName, size: scaledSize ?? size, relativeTo: scalingStyle)
        return tabular ? font.monospacedDigit() : font
    }
}

extension View {
    /// Applies a Flutter text style: face, Dynamic Type size, tracking,
    /// tabular figures, and the line box Flutter gives it in the app.
    ///
    /// SkParagraph makes every line `round(size * height)` points tall
    /// (rounded per line, to whole points). The app's styles inherit
    /// `leadingDistribution: even` from Material's `Typography` (no style
    /// sets it), so the difference from the face's natural line height
    /// (1.2 x size) is split half above and half below the glyphs, the
    /// first line's ascent and last line's descent included, and the
    /// rounding lands below. So one line is `round(size * height)` tall and
    /// N lines N times that, with the baselines where Flutter draws them.
    /// Heights under 1.2 (the hero styles, single line) trim the frame the
    /// same way.
    func textStyle(_ spec: TextSpec) -> some View {
        modifier(TextStyleModifier(spec: spec))
    }
}

extension View {
    /// One line, as designed (Flutter's `maxLines: 1`), at every size up to
    /// the accessibility sizes; there the text may wrap instead of being cut
    /// off with an ellipsis. The default look is unchanged.
    func singleLine() -> some View { modifier(SingleLineModifier()) }
}

private struct SingleLineModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        // Only at accessibility sizes does it set a scale factor, so a
        // `minimumScaleFactor` given by the caller still applies below them.
        if typeSize.isAccessibilitySize {
            content.lineLimit(3).minimumScaleFactor(0.6)
        } else {
            content.lineLimit(1)
        }
    }
}

extension View {
    /// Text with no line limit at the regular sizes (as designed); at
    /// accessibility sizes at most two lines, shrunk if need be so that no
    /// word is broken in the middle (a long word in a narrow chip or card
    /// otherwise wraps letter by letter).
    func wrapsWords() -> some View { modifier(WrapsWordsModifier()) }
}

private struct WrapsWordsModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.lineLimit(2).minimumScaleFactor(0.5)
        } else {
            content
        }
    }
}

extension TextSpec {
    /// Flutter's line box at a (Dynamic Type) size: `size * height`,
    /// rounded to whole points as SkParagraph does.
    func lineHeight(scaledSize: CGFloat) -> CGFloat {
        (scaledSize * height).rounded()
    }
}

extension BudgieFont {
    /// The face's natural line height (ascender + descender + line gap) as a
    /// multiple of its size: 1.2 for both Gabarito and Spline Sans Mono.
    fileprivate var naturalLineHeight: CGFloat { Self.measured[self] ?? 1.2 }

    private static let measured: [BudgieFont: CGFloat] = Dictionary(
        uniqueKeysWithValues: allCases.compactMap { face in
            guard let font = UIFont(name: face.postScriptName, size: 100) else { return nil }
            return (face, (font.ascender - font.descender + font.leading) / 100)
        })
}

private struct TextStyleModifier: ViewModifier {
    let spec: TextSpec
    @ScaledMetric private var scaledSize: CGFloat
    @Environment(\.displayScale) private var displayScale

    init(spec: TextSpec) {
        self.spec = spec
        _scaledSize = ScaledMetric(wrappedValue: spec.size, relativeTo: spec.scalingStyle)
    }

    func body(content: Content) -> some View {
        let natural = scaledSize * spec.face.naturalLineHeight
        let line = spec.lineHeight(scaledSize: scaledSize)
        // Half of the unrounded leading goes above the first line.
        let top = (scaledSize * spec.height - natural) / 2
        // SwiftUI rounds a Text's height up to the pixel grid; take that
        // back out of the bottom so the frame is exactly Flutter's.
        let pixelRounding = (natural * displayScale - 0.001).rounded(.up) / displayScale - natural
        let font = Font.custom(spec.face.postScriptName, fixedSize: scaledSize)
        content
            .font(spec.tabular ? font.monospacedDigit() : font)
            .tracking(spec.tracking)
            .textCase(spec.uppercase ? .uppercase : nil)
            .lineSpacing(max(0, line - natural))
            .padding(.top, top)
            .padding(.bottom, line - natural - top - max(0, pixelRounding))
    }
}
