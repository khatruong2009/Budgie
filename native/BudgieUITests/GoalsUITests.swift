import XCTest

/// The Goals tab end to end on a fresh install: the empty state, adding a
/// goal, finishing it with Add money's "Finish goal" (the celebration
/// plays), renaming it from the actions sheet and deleting it again.
@MainActor
final class GoalsUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        app.launchEnvironment["BUDGIE_SKIP_ONBOARDING"] = "1"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Goals"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Goals"].tap()
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tapSettled()
        if let value = field.value as? String, !value.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeSettled(text)
    }

    /// Waits for a short-lived element by polling every 50 ms.
    /// `waitForExistence` first checks about a second in and then once a
    /// second, and the celebration is removed 1.6s after it starts: that
    /// first check landed about 1.6s after the submit tap, at the edge of
    /// the celebration's lifetime.
    private func waitForTransient(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists { return true }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    private func text(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testGoalLifecycle() throws {
        XCTAssertTrue(app.element("goals.empty").waitForExistence(timeout: 10))

        // Add a goal from the add button.
        app.buttons["goals.fab"].tap()
        let name = app.textFields["Goal name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.enterText("UI Trip")
        app.textFields["Target amount"].enterText("100")
        app.buttons["goals.form.submit"].tapSettled()
        XCTAssertTrue(text("Savings goal added").waitForExistence(timeout: 5))
        let addMoney = app.buttons["goals.card.addMoney"]
        XCTAssertTrue(addMoney.waitForExistence(timeout: 5))

        // Add money: "Finish goal" fills the remainder; the goal completes.
        addMoney.tap()
        let finish = app.buttons["goals.allocate.chip.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tapSettled()
        app.buttons["goals.allocate.submit"].tapSettled()
        XCTAssertTrue(waitForTransient(app.element("goals.celebration"), timeout: 2), "celebration shown")
        XCTAssertTrue(addMoney.waitForNonExistence(timeout: 5), "a complete goal has no Add money")

        // Rename it from the actions sheet.
        let more = app.buttons["goals.card.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let edit = app.buttons["goals.actions.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replace(name, with: "UI Trip Renamed")
        let update = app.buttons["goals.form.submit"]
        XCTAssertEqual(update.label, "Update")
        update.tapSettled()
        XCTAssertTrue(text("Savings goal updated").waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "UI Trip Renamed")).firstMatch
                .waitForExistence(timeout: 5))

        // Delete it from the actions sheet.
        more.tap()
        let delete = app.buttons["goals.actions.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["goals.delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.element("goals.empty").waitForExistence(timeout: 5))
    }
}
