import Foundation

/// The 0xRRGGBB values of the palette tokens the widget also draws, shared by
/// `BudgieColor` (app) and `WidgetPalette` (widget): "Paper" in light mode,
/// "Midnight" in dark mode.
enum PaletteHex {
    struct Pair: Sendable {
        let light: UInt32
        let dark: UInt32
    }

    /// `BudgieColor.card`, the widget background.
    static let card = Pair(light: 0xFBF9F4, dark: 0x11151C)
    static let textPrimary = Pair(light: 0x1A1A17, dark: 0xEEF1F5)
    static let textSecondary = Pair(light: 0x5C584F, dark: 0x9AA3B2)
    static let accent = Pair(light: 0x1D6646, dark: 0xB3ADFF)
    static let onAccent = Pair(light: 0xFFFFFF, dark: 0x0B0B14)
    static let income = Pair(light: 0x1D6646, dark: 0x5EE6B0)
    static let danger = Pair(light: 0xA63D24, dark: 0xFF8B7B)
    static let incomeFixed = Pair(light: 0x1D6646, dark: 0x0E6B4C)
    static let expenseFixed = Pair(light: 0xA63D24, dark: 0xA3372A)
}
