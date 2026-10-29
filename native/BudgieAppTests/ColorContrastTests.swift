import SwiftUI
import UIKit
import XCTest

@testable import Runner

/// WCAG 2.x contrast of the colour tokens against every surface they sit on,
/// light and dark (owner-approved change of 2026-09-30, see PARITY_GAPS
/// "Colour tokens"). Text must reach 4.5:1 (AA); the pairs here are the ones
/// the accessibility audit flagged and that were fixed, so a regression in a
/// token fails here before it fails the audit.
@MainActor
final class ColorContrastTests: XCTestCase {
    private typealias RGB = (r: Double, g: Double, b: Double)

    private func resolve(_ color: Color, dark: Bool) -> RGB {
        rgb(UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light)), over: nil)
    }

    /// The colour's RGB; a translucent colour is composited over `background`.
    private func rgb(_ color: UIColor, over background: RGB?) -> RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        guard let background, a < 1 else { return (r, g, b) }
        return (r * a + background.r * (1 - a), g * a + background.g * (1 - a), b * a + background.b * (1 - a))
    }

    private func mix(_ foreground: RGB, over background: RGB, alpha: Double) -> RGB {
        (
            foreground.r * alpha + background.r * (1 - alpha), foreground.g * alpha + background.g * (1 - alpha),
            foreground.b * alpha + background.b * (1 - alpha)
        )
    }

    private func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private let white: RGB = (1, 1, 1)
    private let aa = 4.5

    private func surfaces(dark: Bool) -> [(name: String, color: RGB)] {
        [
            ("background", resolve(BudgieColor.background, dark: dark)), ("card", resolve(BudgieColor.card, dark: dark)),
            ("chipSurface", resolve(BudgieColor.chipSurface, dark: dark)),
        ]
    }

    private func assertAtLeast(_ target: Double, _ foreground: RGB, _ background: RGB, _ what: String) {
        let value = ratio(foreground, background)
        XCTAssertGreaterThanOrEqual(value, target, "\(what): \(String(format: "%.2f", value)):1 < \(target):1")
    }

    /// Text tokens on the surfaces (page, card, chip) in both modes.
    func testTextTokensPassOnTheSurfaces() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let tokens: [(String, Color)] = [
                ("textPrimary", BudgieColor.textPrimary), ("textSecondary", BudgieColor.textSecondary),
                ("textTertiary", BudgieColor.textTertiary), ("accent", BudgieColor.accent), ("income", BudgieColor.income),
                ("danger", BudgieColor.danger), ("warning", BudgieColor.warning),
            ]
            for (name, color) in tokens {
                for surface in surfaces(dark: dark) {
                    assertAtLeast(aa, resolve(color, dark: dark), surface.color, "\(mode) \(name) on \(surface.name)")
                }
            }
        }
    }

    /// Text in form fields and rows (`BudgieField`, `FormRow`), on `fieldFill`.
    func testTextTokensPassOnFieldFill() {
        for dark in [false, true] {
            let fill = resolve(BudgieColor.fieldFill, dark: dark)
            let tokens: [(String, Color)] = [
                ("textPrimary", BudgieColor.textPrimary), ("textSecondary", BudgieColor.textSecondary),
                ("textTertiary", BudgieColor.textTertiary), ("accent", BudgieColor.accent), ("danger", BudgieColor.danger),
            ]
            for (name, color) in tokens {
                assertAtLeast(aa, resolve(color, dark: dark), fill, "\(dark ? "dark" : "light") \(name) on fieldFill")
            }
        }
    }

    /// Coloured text on its own tint (chips and tiles fill a colour at 10-14%).
    func testColouredTextPassesOnItsOwnTint() {
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let tokens: [(String, Color)] = [
                ("accent", BudgieColor.accent), ("income", BudgieColor.income), ("danger", BudgieColor.danger),
                ("warning", BudgieColor.warning),
            ]
            for (name, color) in tokens {
                let foreground = resolve(color, dark: dark)
                for base in [resolve(BudgieColor.background, dark: dark), resolve(BudgieColor.card, dark: dark)] {
                    for alpha in [0.10, 0.14] {
                        assertAtLeast(aa, foreground, mix(foreground, over: base, alpha: alpha), "\(mode) \(name) on its \(alpha) tint")
                    }
                }
            }
        }
    }

    /// The unselected segmented pill label on its track, and the month
    /// chip's muted label.
    func testDockInactiveOnTheTrack() {
        for dark in [false, true] {
            assertAtLeast(
                aa, resolve(BudgieColor.dockInactiveIcon, dark: dark), resolve(BudgieColor.track, dark: dark),
                "\(dark ? "dark" : "light") dockInactiveIcon on track")
        }
    }

    /// Labels on filled accent, income and danger (the filled pill, the toasts,
    /// the Worth editor's Add / Save), the on-accent colour in each mode.
    func testOnAccentLabelsOnFills() {
        for dark in [false, true] {
            let onAccent = resolve(BudgieColor.onAccent, dark: dark)
            for (name, fill) in [("accent", BudgieColor.accent), ("income", BudgieColor.income), ("danger", BudgieColor.danger)] {
                assertAtLeast(aa, onAccent, resolve(fill, dark: dark), "\(dark ? "dark" : "light") onAccent on \(name)")
            }
        }
    }

    /// The month chip (white, 0.9 white on the primary gradient to 80%).
    func testMonthChipLabelOnPrimary() {
        let primary = resolve(BudgieColor.primary, dark: false)
        assertAtLeast(aa, mix(white, over: primary, alpha: 0.9), primary, "0.9 white on primary")
        assertAtLeast(aa, white, primary, "white on primary")
    }

    /// The translucent tokens (0xAARRGGBB) show in both modes: an opaque
    /// value written as 0xRRGGBB would read its red byte as the alpha.
    func testTranslucentTokensAreVisible() {
        let tokens: [(String, Color)] = [
            ("cardBorder", BudgieColor.cardBorder), ("hairline", BudgieColor.hairline),
            ("selectionFill", BudgieColor.selectionFill), ("selectionBorder", BudgieColor.selectionBorder),
            ("featureBorder", BudgieColor.featureBorder), ("featureControl", BudgieColor.featureControl),
            ("scrim", BudgieColor.scrim),
        ]
        for dark in [false, true] {
            for (name, color) in tokens {
                var alpha: CGFloat = 0
                UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
                    .getRed(nil, green: nil, blue: nil, alpha: &alpha)
                XCTAssertGreaterThanOrEqual(alpha, 0.05, "\(dark ? "dark" : "light") \(name) is invisible")
            }
        }
    }

    /// The selected chip's and segment's label on the selection fill, which
    /// is translucent in dark mode (composited over the page and the track).
    func testSelectionLabelOnItsFill() {
        for dark in [false, true] {
            let fill = UIColor(BudgieColor.selectionFill).resolvedColor(
                with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            for (name, base) in [("background", BudgieColor.background), ("track", BudgieColor.track)] {
                assertAtLeast(
                    aa, resolve(BudgieColor.selectionText, dark: dark), rgb(fill, over: resolve(base, dark: dark)),
                    "\(dark ? "dark" : "light") selectionText on selectionFill over \(name)")
            }
        }
    }

    /// Text on the feature card (Home's Safe to spend, the Goals summary).
    func testFeatureCardText() {
        for dark in [false, true] {
            let fill = resolve(BudgieColor.featureFill, dark: dark)
            let tokens: [(String, Color)] = [
                ("featureText", BudgieColor.featureText), ("featureSecondary", BudgieColor.featureSecondary),
                ("featureAmount", BudgieColor.featureAmount), ("featureDanger", BudgieColor.featureDanger),
            ]
            for (name, color) in tokens {
                assertAtLeast(aa, resolve(color, dark: dark), fill, "\(dark ? "dark" : "light") \(name) on featureFill")
            }
        }
    }

    /// The buttons' white labels on both stops of the form and sheet gradients.
    func testWhiteLabelsOnTheButtonGradients() {
        let gradients: [(String, [Color])] = [
            ("income", BudgieColor.incomeStops), ("expense", BudgieColor.expenseStops),
        ]
        for dark in [false, true] {
            for (name, stops) in gradients {
                for (index, stop) in stops.enumerated() {
                    assertAtLeast(aa, white, resolve(stop, dark: dark), "\(dark ? "dark" : "light") white on \(name) stop \(index)")
                }
            }
        }
    }

    /// Every chart colour, made `legible`, reads on its own 18% tint.
    func testLegibleChartColoursReadOnTheirTint() {
        for dark in [false, true] {
            let card = resolve(BudgieColor.card, dark: dark)
            for (index, color) in BudgieColor.chartPalette.enumerated() {
                for tint in [0.18, 0.35] {
                    let text = resolve(BudgieColor.legible(color, tint: tint), dark: dark)
                    assertAtLeast(
                        aa, text, mix(resolve(color, dark: dark), over: card, alpha: tint),
                        "\(dark ? "dark" : "light") chart colour \(index) made legible on a \(tint) tint")
                }
            }
        }
    }
}
