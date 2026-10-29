import XCTest

/// The Worth tab end to end on a fresh install: the empty state, adding an
/// account, editing its balance from the row, the history page and its
/// editor, and deleting it again from the row's context menu. Also the port
/// of net_worth_page_widget_test.dart "can open and cancel the add account
/// dialog".
@MainActor
final class WorthUITests: XCTestCase {
    let app = XCUIApplication()

    private static let account = "UI Brokerage"

    override func setUp() async throws {
        continueAfterFailure = false
        app.launchEnvironment["BUDGIE_SKIP_ONBOARDING"] = "1"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Worth"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Worth"].tap()
    }

    /// Replaces a field's text (the editor prefills the balance). One
    /// delete at a time: the balance field regroups its commas on every
    /// edit, and a burst of deletes races that rewrite and loses keys
    /// ("1,000" kept "10", so "1250" became "101,250").
    private func replace(_ field: XCUIElement, with text: String) {
        field.tapSettled()
        for _ in 0..<20 {
            guard let value = field.value as? String, !value.isEmpty, value != field.placeholderValue else { break }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        field.typeSettled(text)
    }

    /// Scrolls the page until `element` is wholly above the floating tab
    /// bar. A fresh install's only account row sits almost entirely behind
    /// the bar, so XCUITest aims at the row's one visible corner: a tap
    /// there still reaches the row's button, but a long press there never
    /// starts the context menu and the button fires on release instead
    /// (the editor opens, not the menu).
    private func revealAboveTabBar(_ element: XCUIElement) {
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<3 where element.frame.maxY > tabBar.frame.minY {
            app.swipeUp()
        }
        XCTAssertLessThanOrEqual(element.frame.maxY, tabBar.frame.minY, "\(element) is behind the tab bar")
    }

    /// net_worth_page_widget_test.dart:18: the add button opens "Add
    /// account" with "Balance month", and Cancel closes it.
    func testAddAccountDialogOpensAndCancels() throws {
        let add = app.buttons["worth.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.element("worth.editor").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Add account"].exists)
        XCTAssertTrue(app.buttons["worth.editor.month"].exists)
        XCTAssertEqual(app.buttons["worth.editor.month"].label, "Balance month")
        let cancel = app.buttons["worth.editor.cancel"]
        XCTAssertTrue(cancel.exists)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.element("worth.editor").exists)
    }

    func testAccountLifecycle() throws {
        app.showDollarAmounts()
        app.tabBars.buttons["Worth"].tap()

        // Empty state.
        XCTAssertTrue(app.staticTexts["No net worth accounts yet"].waitForExistence(timeout: 10))

        // Add an account from the empty state.
        app.buttons["worth.empty.add"].tap()
        XCTAssertTrue(app.element("worth.editor").waitForExistence(timeout: 5))
        app.textFields["Account name"].enterText(Self.account)
        app.textFields["Asset balance"].enterText("1000")
        app.buttons["worth.editor.save"].tapSettled()
        let row = app.element("worth.account.\(Self.account)")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.element("worth.editor").exists)

        // Tap the row: the editor, prefilled; change the balance and save.
        revealAboveTabBar(row)
        row.tap()
        XCTAssertTrue(app.element("worth.editor").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Edit account"].exists)
        let balance = app.textFields["Asset balance"]
        XCTAssertEqual(balance.value as? String, "1,000")
        replace(balance, with: "1250")
        XCTAssertEqual(balance.value as? String, "1,250")
        app.buttons["worth.editor.save"].tapSettled()
        XCTAssertTrue(app.element("worth.editor").waitForNonExistence(timeout: 5))
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.label, "\(Self.account), $1,250")

        // Long-press: View History.
        revealAboveTabBar(row)
        row.press(forDuration: 1.0)
        let viewHistory = app.buttons["View History"]
        XCTAssertTrue(viewHistory.waitForExistence(timeout: 5))
        viewHistory.tap()
        XCTAssertTrue(app.element("worth.history.hero").waitForExistence(timeout: 5))

        // The history page's Edit opens the editor; Cancel closes it.
        app.buttons["worth.history.edit"].tap()
        XCTAssertTrue(app.element("worth.editor").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Edit account"].exists)
        app.buttons["worth.editor.cancel"].tap()
        XCTAssertTrue(app.element("worth.editor").waitForNonExistence(timeout: 5))

        // Back to Worth.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        // Long-press: Delete Account, confirmed.
        revealAboveTabBar(row)
        row.press(forDuration: 1.0)
        let deleteAction = app.buttons["Delete Account"]
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5))
        deleteAction.tap()
        let alert = app.alerts["Delete account?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()

        // Empty state again.
        XCTAssertTrue(app.staticTexts["No net worth accounts yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
    }
}
