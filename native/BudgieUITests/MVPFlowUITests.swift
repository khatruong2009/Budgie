import XCTest

/// End-to-end MVP flow on a fresh install (native/scripts/ui_flow.sh seeds
/// nothing, runs this, then checks the resulting store with the Flutter
/// models).
@MainActor
final class MVPFlowUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        app.launchEnvironment["BUDGIE_SKIP_ONBOARDING"] = "1"
        app.launch()
    }

    private func tab(_ name: String) {
        app.tabBars.buttons[name].tap()
    }

    /// Empties a focused field one delete at a time. Not the edit menu's
    /// Select All: that needs a long press to raise a system menu within a
    /// short wait, and when the menu is late the old step skipped it and
    /// typed after the old amount.
    private func clear(_ field: XCUIElement) {
        for _ in 0..<20 {
            guard let value = field.value as? String, !value.isEmpty, value != field.placeholderValue else { return }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
    }

    func testCoreFlow() throws {
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        for name in ["Worth", "Goals", "Spend", "Flow"] {
            XCTAssertTrue(app.tabBars.buttons[name].exists, "\(name) tab")
        }

        // Add an expense (the FAB opens the expense form).
        app.buttons["Add transaction"].tap()
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.enterText("12.34")
        app.textFields["Description"].enterText("UI test coffee")
        app.buttons["Add"].tapSettled()
        // Home's Recent activity shows it, and the row opens its edit form.
        let recent = app.buttons.containing(NSPredicate(format: "label CONTAINS 'UI test coffee'")).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tapSettled()
        XCTAssertTrue(app.buttons["Update"].waitForExistence(timeout: 5), "Recent activity row opens the edit form")
        XCTAssertEqual(app.textFields["Amount"].value as? String, "12.34")
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.buttons["Update"].waitForNonExistence(timeout: 5))

        // Edit it from the full list (SEE ALL).
        app.buttons["See all transactions"].firstMatch.tap()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS 'UI test coffee'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let editAmount = app.textFields["Amount"]
        XCTAssertTrue(editAmount.waitForExistence(timeout: 5))
        editAmount.tap()
        clear(editAmount)
        editAmount.typeSettled("20")
        XCTAssertEqual(editAmount.value as? String, "20")
        app.buttons["Update"].tapSettled()
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS '20.00'")).firstMatch.waitForExistence(timeout: 5))

        // Add a recurring template and pause it (Settings > Recurring).
        app.openSettings()
        app.buttons["Recurring transactions"].firstMatch.tap()
        app.buttons["Add recurring transaction"].tap()
        let recurringAmount = app.textFields["Amount"]
        XCTAssertTrue(recurringAmount.waitForExistence(timeout: 5))
        recurringAmount.enterText("900")
        app.textFields["Description"].enterText("UI rent")
        app.buttons["Save"].tapSettled()
        let template = app.descendants(matching: .any).matching(identifier: "recurring.card")
            .containing(NSPredicate(format: "label CONTAINS 'UI rent'")).firstMatch
        XCTAssertTrue(template.waitForExistence(timeout: 5))
        template.buttons["Pause"].tap()
        XCTAssertTrue(app.labelled(containing: "paused").waitForExistence(timeout: 5))

        // Net worth is empty on a fresh install.
        tab("Worth")
        XCTAssertTrue(app.staticTexts["No net worth accounts yet"].waitForExistence(timeout: 5))

        // Theme: the Light | Dark | Auto pills on the Theme row.
        app.openSettings()
        let dark = app.buttons["Dark"].firstMatch
        dark.tap()
        XCTAssertTrue(dark.wait(for: \.isSelected, toEqual: true, timeout: 5), "Dark selected")

        // Add an income from the add button's form, then delete it from SEE ALL.
        app.goToHomeRoot()
        app.buttons["Add transaction"].tap()
        XCTAssertTrue(app.textFields["Amount"].waitForExistence(timeout: 5))
        app.buttons["Income"].firstMatch.tapSettled()
        app.textFields["Amount"].enterText("5")
        app.textFields["Description"].enterText("To delete")
        app.buttons["Add"].tapSettled()
        app.buttons["See all transactions"].firstMatch.tap()
        let doomed = app.buttons.containing(NSPredicate(format: "label CONTAINS 'To delete'")).firstMatch
        XCTAssertTrue(doomed.waitForExistence(timeout: 5))
        doomed.swipeLeft()
        let confirm = app.alerts["Delete Transaction"].buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(doomed.waitForNonExistence(timeout: 5))

        // Settings last (they change how every amount above is formatted),
        // so ui_flow.sh's Dart check reads a non-default appSettings section.
        app.openSettings()
        let currency = app.buttons["settings.currency"]
        XCTAssertTrue(currency.waitForExistence(timeout: 5))
        currency.tap()
        let euro = app.buttons["Euro"]
        XCTAssertTrue(euro.waitForExistence(timeout: 5))
        euro.tap()
        XCTAssertTrue(euro.waitForNonExistence(timeout: 5), "currency sheet closed")
        XCTAssertEqual(currency.value as? String, "Euro (EUR)")

        let hide = app.switches["settings.hideBalances"]
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()
        let hidden = app.switches.matching(NSPredicate(format: "identifier == 'settings.hideBalances' AND value == '1'"))
        XCTAssertTrue(hidden.firstMatch.waitForExistence(timeout: 5), "Hide balances on")
    }
}
