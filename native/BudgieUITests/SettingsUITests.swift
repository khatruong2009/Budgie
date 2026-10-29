import XCTest

/// Settings beyond what MVPFlowUITests covers (Dark, Euro, the Hide balances
/// switch): the Light and Auto theme pills, the Number format sheet and its
/// effect on Home's amounts, Hide balances masking Home and unmasking it
/// again, and the About rows that open Data diagnostics and Licences. App
/// lock is AppLockUITests'.
///
/// Regression group: sim A (BudgieAppTests + Recurring, Onboarding, MVPFlow,
/// Tabs, Insights, Voice, AppLock + this class). It sorts after
/// InsightsUITests, and writes no financial data: only the theme, the
/// number format and Hide balances, which every test puts back (Hide
/// balances off and US dollars are the baseline the money checks of the
/// later classes expect, so those are normalised, not restored to whatever
/// MVPFlowUITests left).
@MainActor
final class SettingsUITests: XCTestCase {
    let app = XCUIApplication()
    /// What `tearDown` puts back, set by the test that changed it.
    private var restoreTheme: String?
    private var restoreNumberFormat: String?
    private var unmaskOnTearDown = false

    override func setUp() async throws {
        continueAfterFailure = false
        app.budgie()
    }

    override func tearDown() async throws {
        if restoreTheme != nil || restoreNumberFormat != nil || unmaskOnTearDown {
            // From a known state: a failure may have left a sheet open.
            app.terminate()
            app.budgie()
            app.openSettings()
            if let theme = restoreTheme {
                pickTheme(theme)
            }
            if let format = restoreNumberFormat {
                chooseNumberFormat(format)
            }
            if unmaskOnTearDown {
                let hide = app.switches["settings.hideBalances"]
                if hide.value as? String == "1" { hide.tapSettled() }
                _ = hide.waitForValue("0")
            }
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func pickTheme(_ name: String) {
        let pill = app.buttons[name].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "\(name) pill")
        pill.tapSettled()
        XCTAssertTrue(pill.wait(for: \.isSelected, toEqual: true, timeout: 5), "\(name) selected")
    }

    /// The theme pill that is selected now.
    private func selectedTheme() -> String {
        ["Light", "Dark", "Auto"].first { app.buttons[$0].firstMatch.isSelected } ?? "Auto"
    }

    /// Opens the Number format sheet and picks `label`; the row's subtitle
    /// (its value) follows.
    private func chooseNumberFormat(_ label: String) {
        let row = app.buttons["settings.numberFormat"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tapSettled()
        XCTAssertTrue(app.staticTexts["Number format"].waitForExistence(timeout: 5), "Number format sheet")
        let choice = app.buttons[label]
        choice.tapSettled()
        XCTAssertTrue(choice.waitForNonExistence(timeout: 5), "sheet closed after \(label)")
        XCTAssertTrue(row.waitForValue(label), "Number format reads \(label)")
    }

    // MARK: - Tests

    /// Light and Auto, the pills MVPFlowUITests does not tap: exactly one is
    /// selected at a time.
    func testThemePillsSwitchBetweenLightDarkAndAuto() throws {
        app.openSettings()
        XCTAssertTrue(app.element("settings.theme").waitForExistence(timeout: 5))
        restoreTheme = selectedTheme()

        pickTheme("Light")
        XCTAssertFalse(app.buttons["Dark"].firstMatch.isSelected)
        XCTAssertFalse(app.buttons["Auto"].firstMatch.isSelected)

        pickTheme("Auto")
        XCTAssertFalse(app.buttons["Light"].firstMatch.isSelected)
        XCTAssertFalse(app.buttons["Dark"].firstMatch.isSelected)

        pickTheme("Dark")
        XCTAssertFalse(app.buttons["Light"].firstMatch.isSelected)
        XCTAssertFalse(app.buttons["Auto"].firstMatch.isSelected)
    }

    /// Number format: pick German, see the row's value and Home's amounts
    /// follow (the currency symbol moves behind the number), then back.
    func testNumberFormatSheetChangesHowAmountsAreWritten() throws {
        app.showDollarAmounts()
        app.openSettings()
        let row = app.buttons["settings.numberFormat"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let original = row.value as? String ?? "Match device"
        restoreNumberFormat = original

        chooseNumberFormat("German (Germany)")

        // Home's cash-flow legend reads "Spent, 0,00 $, Kept, 0,00 $": the
        // symbol follows the number after a no-break space.
        app.goToHomeRoot()
        let gauge = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Spent,'")).firstMatch
        XCTAssertTrue(gauge.waitForExistence(timeout: 5))
        XCTAssertTrue(gauge.label.contains("\u{00A0}$"), "German amounts put $ after the number: \(gauge.label)")

        app.openSettings()
        chooseNumberFormat("English (United States)")
        app.goToHomeRoot()
        XCTAssertTrue(gauge.waitUntil("label CONTAINS %@", ["$0"]), "US amounts put $ first: \(gauge.label)")

        app.openSettings()
        chooseNumberFormat(original)
        restoreNumberFormat = nil
    }

    /// Hide balances masks Home's amounts with dots, and turning it off
    /// shows them again.
    func testHideBalancesMasksAndUnmasksHome() throws {
        app.showDollarAmounts()
        app.goToHomeRoot()
        let hero = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Cash flow, '")).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.label.contains("$"), "amounts shown: \(hero.label)")
        let gauge = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Spent,'")).firstMatch
        XCTAssertTrue(gauge.label.contains("$"))

        unmaskOnTearDown = true
        app.openSettings()
        let hide = app.switches["settings.hideBalances"]
        hide.tapSettled()
        XCTAssertTrue(hide.waitForValue("1"), "Hide balances on")

        app.goToHomeRoot()
        let dots = "\u{2022}\u{2022}\u{2022}\u{2022}"
        XCTAssertTrue(hero.waitUntil("label CONTAINS %@", [dots]), "hero masked: \(hero.label)")
        XCTAssertFalse(hero.label.contains("$"))
        XCTAssertTrue(gauge.waitUntil("label CONTAINS %@", [dots]), "gauge masked: \(gauge.label)")
        XCTAssertFalse(gauge.label.contains("$"))

        app.openSettings()
        hide.tapSettled()
        XCTAssertTrue(hide.waitForValue("0"), "Hide balances off")
        unmaskOnTearDown = false

        app.goToHomeRoot()
        XCTAssertTrue(hero.waitUntil("label CONTAINS %@", ["$"]), "hero unmasked: \(hero.label)")
        XCTAssertFalse(hero.label.contains(dots))
    }

    /// About: Version, Data diagnostics and Licences open their pages and
    /// come back.
    func testAboutRowsOpenDiagnosticsAndLicences() throws {
        app.openSettings()

        let version = app.labelled(exactly: "Version")
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue((version.value as? String ?? "").hasPrefix("Budgie "), "version value: \(String(describing: version.value))")

        let diagnostics = app.buttons["settings.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5) || scrollTo(diagnostics))
        if !diagnostics.isHittable { _ = scrollTo(diagnostics) }
        diagnostics.tapSettled()
        XCTAssertTrue(app.staticTexts["Transactions"].waitForExistence(timeout: 5), "Data diagnostics page")
        XCTAssertTrue(app.staticTexts["Unreadable rows kept"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let licences = app.buttons["settings.licences"]
        XCTAssertTrue(licences.waitForExistence(timeout: 5))
        if !licences.isHittable { _ = scrollTo(licences) }
        licences.tapSettled()
        XCTAssertTrue(app.navigationBars["Licences"].waitForExistence(timeout: 5), "Licences page")
        XCTAssertTrue(app.staticTexts["Gabarito"].exists)
        XCTAssertTrue(app.staticTexts["Spline Sans Mono"].exists || scrollTo(app.staticTexts["Spline Sans Mono"]))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["settings.licences"].waitForExistence(timeout: 5), "back on Settings")
    }

    /// Scrolls the page up until `element` is hittable (Settings is longer
    /// than the screen).
    @discardableResult
    private func scrollTo(_ element: XCUIElement) -> Bool {
        for _ in 0..<5 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
