import SwiftUI

// The Settings page's building blocks (settings_page.dart:1064-1310).

/// `_BrandCard` (sp:1064-1131) as the feature card (REDESIGN_PLAN 4.2): the
/// 52pt mark, "Budgie" 20 w800 and the tagline 13 on the feature tokens.
/// Not interactive.
struct SettingsBrandCard: View {
    private static let titleText = TextSpec(face: .gabaritoExtraBold, size: 20, tracking: -0.3, height: 1.25, relativeTo: .title3)
    private static let taglineText = TextSpec(face: .gabaritoRegular, size: 13, height: 1.25, relativeTo: .footnote)

    var body: some View {
        HStack(spacing: Metrics.spacingM) {
            Image("logo")
                .resizable().scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous))
            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                Text("Budgie")
                    .textStyle(Self.titleText)
                    .foregroundStyle(BudgieColor.featureText)
                Text("Make every dollar count")
                    .textStyle(Self.taglineText)
                    .foregroundStyle(BudgieColor.featureSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .featureCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Budgie, Make every dollar count")
    }
}

/// `_SectionEyebrow` (sp:1134-1152) in the redesign: mono 11 w600, +0.16em,
/// uppercase, secondary; inset 24 (the card's edge plus 4), 26 above.
struct SettingsEyebrow: View {
    let title: String

    private static let text = TextSpec(face: .monoSemiBold, size: 11, tracking: 1.76, uppercase: true, relativeTo: .caption2)

    var body: some View {
        Text(title)
            .textStyle(Self.text)
            .foregroundStyle(BudgieColor.textSecondary)
            // One line: at accessibility sizes "PERSONALIZATION" would
            // otherwise break mid-word.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(EdgeInsets(top: 26, leading: 24, bottom: 0, trailing: 24))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Material Symbols draw a 20pt icon inside ~2pt of padding, so its glyphs
/// look smaller than an SF Symbol at 20; these point sizes match the
/// Settings screenshots' glyphs (most ~15-17pt across; the file arrows 13).
enum SettingsGlyph {
    static let standard: CGFloat = 15
    /// Glyphs that fill their Material box (language, lock, timer, info).
    static let full: CGFloat = 17
    /// file_download / file_upload, drawn small in their box.
    static let small: CGFloat = 13
}

/// The rows' tile (REDESIGN_PLAN 4.2): 38pt, radius 12, the colour at 12%
/// unless `tile` overrides it.
private struct SettingsTile: View {
    let symbol: String
    let color: Color
    var tile: Color? = nil
    var iconSize = SettingsGlyph.standard

    var body: some View {
        IconTile(symbol: symbol, color: color, size: 38, radius: 12, iconSize: iconSize, background: tile ?? color.opacity(0.12))
    }
}

/// The rows' insets inside their section card (which pads 16 at the
/// sides): 12 above and below, 14 between the parts, at least 48 tall.
private extension View {
    func settingsRowInsets() -> some View {
        padding(.vertical, 12).frame(minHeight: Metrics.formRowHeight)
    }
}

/// `_SettingsRow` (sp:1227-1310): the tile, title (15 w600) and a one-line
/// subtitle (12 secondary; two lines at accessibility text sizes), then the
/// trailing view. With `action` the
/// whole row is a button (light
/// haptic, no visible press state, VoiceOver "title, subtitle"); without
/// one it is plain. While `busy` VoiceOver hears `busyLabel` ("Exporting",
/// "Importing", "Restoring") for the subtitle.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let color: Color
    var tile: Color? = nil
    var iconSize = SettingsGlyph.standard
    let title: String
    let subtitle: String
    var busy = false
    var busyLabel = "Exporting"
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        let row = HStack(spacing: 14) {
            SettingsTile(symbol: symbol, color: color, tile: tile, iconSize: iconSize)
            SettingsRowText(title: title, subtitle: subtitle, subtitleLines: 1)
            trailing()
        }
        .settingsRowInsets()
        .contentShape(Rectangle())

        if let action {
            HapticButton(action: action) {
                row
            }
            .buttonStyle(PressScaleStyle(scale: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(subtitle)
            .accessibilityAddTraits(.isButton)
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(busy ? busyLabel : subtitle)
        }
    }
}

extension SettingsRow where Trailing == SettingsChevron {
    /// A row that opens something: the chevron, or the spinner while `busy`.
    init(
        symbol: String, color: Color, tile: Color? = nil, iconSize: CGFloat = SettingsGlyph.standard, title: String,
        subtitle: String, busy: Bool = false, busyLabel: String = "Exporting", action: (() -> Void)?
    ) {
        self.init(
            symbol: symbol, color: color, tile: tile, iconSize: iconSize, title: title, subtitle: subtitle, busy: busy,
            busyLabel: busyLabel, action: action,
            trailing: { SettingsChevron(busy: busy) })
    }
}

/// A row whose only control is its switch (App lock, Hide balances): the
/// row body is not tappable (Flutter's `onTap: null`). The switch is tinted
/// `switchOn`. VoiceOver reads the switch as the title with the subtitle as
/// its hint.
struct SettingsToggleRow: View {
    let symbol: String
    let color: Color
    var iconSize = SettingsGlyph.standard
    let title: String
    let subtitle: String
    let isOn: Binding<Bool>
    var identifier: String

    var body: some View {
        HStack(spacing: 14) {
            SettingsTile(symbol: symbol, color: color, iconSize: iconSize)
            SettingsRowText(title: title, subtitle: subtitle, subtitleLines: 1)
                .accessibilityHidden(true)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(BudgieColor.switchOn)
                .accessibilityHint(subtitle)
                .accessibilityIdentifier(identifier)
        }
        .settingsRowInsets()
    }
}

/// `_ThemeRow` (sp:1156-1224): the moon tile, "Theme" with a subtitle that
/// wraps (no line limit), and the Light | Dark | Auto pills (about 170pt).
/// When the pills leave the text under 80pt (large text sizes) they move
/// under it.
struct SettingsThemeRow: View {
    @Binding var selection: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                tile
                text.frame(minWidth: 80, idealWidth: 80, maxWidth: .infinity)
                pills
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    tile
                    text
                }
                pills
            }
        }
        .settingsRowInsets()
    }

    private var tile: some View {
        SettingsTile(symbol: "moon", color: BudgieColor.accent)
    }

    private var text: some View {
        // No subtitle (owner's call, 2026-10-04): the pills say it.
        Text("Theme")
            .textStyle(.rowTitle)
            .foregroundStyle(BudgieColor.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Capped at AX2 so the three pills still fit the card's width.
    private var pills: some View {
        SegmentedPills(items: ["Light", "Dark", "Auto"], selection: $selection, fillWidth: true)
            .frame(width: 170)
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Theme mode")
            .accessibilityIdentifier("settings.theme")
    }
}

/// Title (`rowTitle`) over the subtitle (`rowSubtitle`, secondary), 2 apart.
/// A one-line subtitle gets a second line at accessibility text sizes,
/// where one line keeps only its first word or two (Flutter clips it).
private struct SettingsRowText: View {
    let title: String
    let subtitle: String
    let subtitleLines: Int?

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
            Text(title)
                .textStyle(.rowTitle)
                .foregroundStyle(BudgieColor.textPrimary)
            Text(subtitle)
                .textStyle(.rowSubtitle)
                .foregroundStyle(BudgieColor.textSecondary)
                .lineLimit(subtitleLines == 1 && typeSize.isAccessibilitySize ? 2 : subtitleLines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: subtitleLines == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The trailing chevron (secondary), or a 20pt progress indicator in the
/// accent while the row's action runs (Flutter: a ring in the text colour).
struct SettingsChevron: View {
    var busy = false

    var body: some View {
        if busy {
            ProgressView()
                .controlSize(.small)
                .tint(BudgieColor.accent)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BudgieColor.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
        }
    }
}
