import XCTest

/// Quick actions, widget taps and deep links open the add form on top of
/// whatever is showing (Flutter pushes it on the root navigator, D14):
/// with nothing presented, over an edit form and its date picker, over an
/// alert and over a centred dialog. Closing it leaves the user's own sheet
/// or dialog as it was, and every later route opens too (a refused
/// presentation used to block them all). Fresh install, no data needed.
@MainActor
final class RouteOverPresentationUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        app.budgie()
    }

    private func title(_ text: String) -> XCUIElement {
        app.staticTexts[text]
    }

    /// Asserts the add form `formTitle` is on screen, then cancels it.
    private func expectAddFormThenCancel(_ formTitle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(title(formTitle).waitForExistence(timeout: 10), "\(formTitle) not shown", file: file, line: line)
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), file: file, line: line)
        cancel.tap()
        XCTAssertTrue(title(formTitle).waitForNonExistence(timeout: 5), "\(formTitle) did not close", file: file, line: line)
    }

    func testRoutesOpenOverWhateverIsPresented() throws {
        // Nothing presented: the route opens the form and it saves.
        app.route("budgetapp://add-income")
        XCTAssertTrue(title("Add Income").waitForExistence(timeout: 10))
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        // The routed form's own date picker sheet works as anywhere else.
        app.buttons["Date"].tap()
        let pickerCancel = app.buttons["datePicker.cancel"]
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 5))
        pickerCancel.tap()
        XCTAssertTrue(pickerCancel.waitForNonExistence(timeout: 5))
        app.textFields["Description"].enterText("Routed income")
        amount.enterText("5")
        app.buttons["Add"].tapSettled()
        XCTAssertTrue(title("Add Income").waitForNonExistence(timeout: 5))
        // Home rows are combined accessibility elements, not buttons.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Routed income'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the routed form saved")

        // Over an edit form (Home > SEE ALL > row) and its date picker.
        app.buttons["See all transactions"].firstMatch.tap()
        let listed = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Routed income'")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 10))
        listed.tap()
        XCTAssertTrue(title("Edit Income").waitForExistence(timeout: 5))
        app.buttons["Date"].tap()
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 5))

        app.route("budgetapp://add-expense")
        XCTAssertTrue(title("Add Expense").waitForExistence(timeout: 10))
        XCTAssertFalse(pickerCancel.exists, "VoiceOver reaches only the form, not the picker beneath it")
        expectAddFormThenCancel("Add Expense")
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 5), "the date picker is still open")
        XCTAssertTrue(pickerCancel.isHittable, "the date picker is on top again")

        // A second route opens as well.
        app.route("budgetapp://add-income")
        expectAddFormThenCancel("Add Income")
        XCTAssertTrue(pickerCancel.isHittable)
        pickerCancel.tap()
        XCTAssertTrue(pickerCancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(title("Edit Income").exists, "the edit form is still open")

        // Over the edit form's delete alert.
        app.buttons["Delete Transaction"].tap()
        let alert = app.alerts["Delete Transaction"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        app.route("budgetapp://add-expense")
        expectAddFormThenCancel("Add Expense")
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the alert is still up")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(title("Edit Income").exists, "the edit form is still open")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(title("Edit Income").waitForNonExistence(timeout: 5))

        // Over a centred dialog (Goals > add goal).
        app.tabBars.buttons["Goals"].tap()
        app.buttons["goals.fab"].tap()
        let goalName = app.textFields["Goal name"]
        XCTAssertTrue(goalName.waitForExistence(timeout: 5))
        goalName.enterText("Kept")
        app.route("budgetapp://add-income")
        XCTAssertTrue(title("Add Income").waitForExistence(timeout: 10))

        // A route while a routed form is open stacks another form on it.
        app.route("budgetapp://add-expense")
        expectAddFormThenCancel("Add Expense")
        expectAddFormThenCancel("Add Income")
        XCTAssertTrue(goalName.waitForExistence(timeout: 5), "the goal dialog is still open")
        XCTAssertEqual(goalName.value as? String, "Kept", "the half-filled dialog kept its text")
    }
}
