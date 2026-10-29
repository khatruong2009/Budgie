import SwiftUI
import UIKit

/// The app palette, resolved per light/dark trait so sheets and overridden
/// interface styles pick the right value: "Paper" in light mode (warm paper,
/// ink, deep green, terracotta) and "Midnight" in dark mode (near-black,
/// mint, coral, lilac). This is the owner-approved redesign of 2026-10-03
/// (PARITY_GAPS "Visual redesign"), not Flutter's palette. Every text token
/// reaches WCAG AA (4.5:1) on every surface it sits on (ColorContrastTests).
/// Values are 0xRRGGBB, or 0xAARRGGBB where a token is translucent.
enum BudgieColor {
    // Surfaces
    static let background = dynamic(light: 0xF3EFE6, dark: 0x07090D)
    static let card = dynamic(light: 0xFBF9F4, dark: 0x11151C)
    static let chipSurface = dynamic(light: 0xEAE4D7, dark: 0x161B24)
    /// `MonthPill`'s border: white 8% dark, black 8% light (not `cardBorder`).
    static let pillBorder = overlay(dark: 0.08, light: 0.08)
    static let cardBorder = dynamic(light: 0xFFDC_D4C4, dark: 0x12FF_FFFF, alpha: true)
    static let hairline = dynamic(light: 0xFFE6_DFD1, dark: 0x0FFF_FFFF, alpha: true)
    static let border = dynamic(light: 0xFFDC_D4C4, dark: 0x12FF_FFFF, alpha: true)
    static let track = dynamic(light: 0xE4DDCE, dark: 0x161B24)
    static let trackSecondary = dynamic(light: 0xCFC6B4, dark: 0x2A3140)
    static let donutRemainder = dynamic(light: 0xCFC6B4, dark: 0x2A3140)
    /// Text fields, form rows and the date tile, on a card or sheet.
    static let fieldFill = dynamic(light: 0xF3EFE6, dark: 0x0B0E14)
    /// The dimmed backdrop behind a dialog: ink 38% light, black 55% dark.
    static let scrim = dynamic(light: 0x611A_1A17, dark: 0x8C00_0000, alpha: true)

    // Text
    static let textPrimary = dynamic(light: 0x1A1A17, dark: 0xEEF1F5)
    static let textSecondary = dynamic(light: 0x5C584F, dark: 0x9AA3B2)
    static let textTertiary = dynamic(light: 0x625E56, dark: 0x8C95A5)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0B0B14)

    // Semantic
    /// Links, selection and the add button: deep green in light mode, lilac
    /// in dark mode.
    static let accent = dynamic(light: 0x1D6646, dark: 0xB3ADFF)
    /// Income, money kept and good changes.
    static let income = dynamic(light: 0x1D6646, dark: 0x5EE6B0)
    /// Money spent on charts (Home's ring, legend and Expenses sparkline):
    /// terracotta in light mode (owner's call 2026-10-04; was ink), coral
    /// in dark mode.
    static let spent = dynamic(light: 0xA63D24, dark: 0xFF8B7B)
    /// Expense, over-limit and errors (`getDanger`).
    static let danger = dynamic(light: 0xA63D24, dark: 0xFF8B7B)
    static let warning = dynamic(light: 0x7E5300, dark: 0xFFC861)
    /// A `Toggle`'s tint when on.
    static let switchOn = dynamic(light: 0x1D6646, dark: 0x5EE6B0)
    static let info = dynamic(light: 0x1F5F99, dark: 0x7CC8FF)
    static let purple = dynamic(light: 0x5B47B8, dark: 0xB3ADFF)
    static let pink = dynamic(light: 0x7F3B6B, dark: 0xF7A1D8)
    static let cyan = dynamic(light: 0x176464, dark: 0x4FD1C5)
    /// The strong fill behind a white label (the month chip, the sheet
    /// buttons): ink in light mode, a deep lilac in dark mode.
    static let primary = dynamic(light: 0x1A1A17, dark: 0x4A43C4)
    /// The forms' category wheel tiles, behind a white symbol: the first stop
    /// of the income and expense button fills.
    static let expenseFixed = dynamic(light: 0xA63D24, dark: 0xA3372A)
    static let incomeFixed = dynamic(light: 0x1D6646, dark: 0x0E6B4C)

    // Selection (month chips, segmented toggles): an ink chip with a paper
    // label in light mode, a lilac tint with a lilac label in dark mode.
    static let selectionFill = dynamic(light: 0xFF1A_1A17, dark: 0x29B3_ADFF, alpha: true)
    static let selectionText = dynamic(light: 0xF3EFE6, dark: 0xB3ADFF)
    static let selectionBorder = dynamic(light: 0xFF1A_1A17, dark: 0x66B3_ADFF, alpha: true)

    // The feature card (Home's Safe to spend, the Goals summary): an ink
    // block in light mode, a mint-tinted tile in dark mode.
    static let featureFill = dynamic(light: 0x1A1A17, dark: 0x10231F)
    static let featureBorder = dynamic(light: 0xFF1A_1A17, dark: 0x475E_E6B0, alpha: true)
    static let featureText = dynamic(light: 0xF3EFE6, dark: 0xEEF1F5)
    static let featureSecondary = dynamic(light: 0xC2BBAA, dark: 0x9AA3B2)
    /// The feature card's figure: paper on ink, mint on the dark tile.
    static let featureAmount = dynamic(light: 0xF3EFE6, dark: 0x5EE6B0)
    /// A shortfall on the feature card.
    static let featureDanger = dynamic(light: 0xF0A08C, dark: 0xFF8B7B)
    /// The feature card's chevron circle and ring track.
    static let featureControl = dynamic(light: 0x1FF3_EFE6, dark: 0x0FFF_FFFF, alpha: true)
    /// The feature card's progress ring.
    static let featureRing = dynamic(light: 0x8ED0AA, dark: 0x5EE6B0)

    // Flow charts
    /// The net cash flow bars' zero baseline: white 12% dark, black 12% light.
    static let chartBaseline = overlay(dark: 0.12, light: 0.12)
    /// The trend's dashed zero line: white 8% dark, black 12% light.
    static let chartZeroLine = overlay(dark: 0.08, light: 0.12)
    /// The end dot on the trend and growth lines.
    static let trendDot = textPrimary

    // Worth editor dialog
    /// The 32pt close circle: white 8% dark, black 6% light.
    static let dialogCloseFill = overlay(dark: 0.08, light: 0.06)

    // Settings
    /// The Version row's icon.
    static let versionIcon = textSecondary
    /// The Version row's tile: white 6% dark, black 6% light.
    static let versionTile = overlay(dark: 0.06, light: 0.06)

    /// The segmented pills' unselected label (on the track).
    static let dockInactiveIcon = textSecondary

    // Button fills (topLeading to bottomTrailing). They sit behind white
    // labels (the form and sheet buttons), so both stops pass AA against
    // white; the stops are close, so the fills read as flat.
    static let incomeStops = stops(light: (0x1D6646, 0x247755), dark: (0x0E6B4C, 0x127D59))
    static let expenseStops = stops(light: (0xA63D24, 0xB5482D), dark: (0xA3372A, 0xB8432F))

    /// The 14-colour chart and category palette: the seven category hues,
    /// then a lighter (light mode) or paler (dark mode) set of the same.
    static let chartPalette: [Color] = zip(
        [0x1D6646, 0x5B47B8, 0xA63D24, 0x7E5300, 0x1F5F99, 0x7F3B6B, 0x176464, 0x4E8F6F, 0x8676D1, 0xC96A50, 0xA8801F,
         0x4E86BD, 0xA86394, 0x3F8C8C],
        [0x5EE6B0, 0xB3ADFF, 0xFF8B7B, 0xFFC861, 0x7CC8FF, 0xF7A1D8, 0x4FD1C5, 0xA3F0D2, 0xD6D2FF, 0xFFB8AD, 0xFFDE9C,
         0xB4DFFF, 0xFAC8E8, 0x93E4DB]
    ).map { dynamic(light: $0, dark: $1) }

    // The Spend donut's rank palette: the slices are graphics, not text.
    static let chartAccent = purple
    static let chartIncome = income
    static let chartDanger = danger
    static let chartWarning = warning

    /// A category `colorToken` (`category_settings_page.dart` `_tokenColor`);
    /// unknown tokens use the accent.
    static func category(_ token: String) -> Color {
        switch token {
        case "green": income
        case "blue": info
        case "orange": warning
        case "red": danger
        case "purple": purple
        case "pink": pink
        case "cyan": cyan
        default: accent
        }
    }

    /// A category or chart colour as text on its own tint (the colour at up
    /// to 18% over the card): the colour itself when that reaches 4.5:1, else
    /// the colour mixed towards the primary text colour until it does. The
    /// palette includes teals, pinks and light blues that cannot be read as
    /// text on a pale tint.
    /// `tint` is the strongest share of the colour behind the text: 0.18 for
    /// a chip on a card, 0.35 for a chip on a tinted card.
    static func legible(_ color: Color, tint: Double = 0.18) -> Color {
        Color(UIColor { traits in
            let base = UIColor(color).resolvedColor(with: traits)
            let card = UIColor(BudgieColor.card).resolvedColor(with: traits)
            let ink = UIColor(textPrimary).resolvedColor(with: traits)
            return LegibleColor.mix(base, towards: ink, on: card, tint: tint)
        })
    }

    static func dynamic(light: UInt32, dark: UInt32, alpha: Bool = false) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: alpha) : UIColor(hex: light, alpha: alpha) })
    }

    /// Flutter's `Colors.white` (dark) / `Colors.black` (light) at an alpha.
    private static func overlay(dark: CGFloat, light: CGFloat) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: dark) : UIColor(white: 0, alpha: light) })
    }

    private static func stops(light: (UInt32, UInt32), dark: (UInt32, UInt32)) -> [Color] {
        [dynamic(light: light.0, dark: dark.0), dynamic(light: light.1, dark: dark.1)]
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension UIColor {
    /// `hex` is 0xRRGGBB, or 0xAARRGGBB when `alpha` is true.
    convenience init(hex: UInt32, alpha: Bool = false) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha ? CGFloat((hex >> 24) & 0xFF) / 255 : 1)
    }
}

/// The arithmetic behind `BudgieColor.legible`.
private enum LegibleColor {
    static func mix(_ base: UIColor, towards ink: UIColor, on card: UIColor, tint: Double) -> UIColor {
        for step in 0...20 {
            let candidate = blend(base, ink, Double(step) / 20)
            if contrast(candidate, tinted(candidate, over: card, alpha: tint)) >= 4.5 { return candidate }
        }
        return ink
    }

    private static func components(_ color: UIColor) -> (Double, Double, Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    private static func blend(_ a: UIColor, _ b: UIColor, _ t: Double) -> UIColor {
        let (ar, ag, ab) = components(a), (br, bg, bb) = components(b)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t, blue: ab + (bb - ab) * t, alpha: 1)
    }

    private static func tinted(_ color: UIColor, over card: UIColor, alpha: Double) -> UIColor { blend(card, color, alpha) }

    private static func luminance(_ color: UIColor) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = components(color)
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
