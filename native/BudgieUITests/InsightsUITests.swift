import XCTest

/// Flow's Insights section end to end: three expenses each added twice
/// today give three "Possible duplicate transaction" cards. A is snoozed and
/// B dismissed from their "Insight options" menus; both stay hidden after a
/// relaunch while C still shows. The rows are deleted at the end.
///
/// The store may already hold data (BackupUITests and CSVImportUITests
/// leave fixture rows and a budget that bring cards of their own), so the
/// test only counts and acts on cards for this run's rows.
///
/// The snooze and the dismissal stay in the app's preferences (there is no
/// way to undo either in the app). The descriptions carry a per-run suffix,
/// so each run's card ids are new and a second run on the same simulator,
/// even the same day, is not hidden by the first one's.
@MainActor
final class InsightsUITests: XCTestCase {
    let app = XCUIApplication()

    /// Digits: the keyboard never autocorrects them.
    private let run = String(Int.random(in: 100_000...999_999))
    private var descriptions: [String] { ["A", "B", "C"].map { "Insight UI \($0) \(run)" } }

    override func setUp() async throws {
        continueAfterFailure = false
        app.launchEnvironment["BUDGIE_SKIP_ONBOARDING"] = "1"
        app.launch()
    }

    private func tab(_ name: String) {
        app.tabBars.buttons[name].tap()
    }

    /// The duplicate card whose explanation names `description`.
    private func card(_ description: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'flow.insight.card' AND label CONTAINS %@", "\(description) appears more than once")).firstMatch
    }

    /// The cards for this run's rows.
    private var cards: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == 'flow.insight.card' AND label CONTAINS %@", run))
    }

    private func addExpense(_ description: String) {
        app.buttons["Add transaction"].tap()
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.enterText("7")
        app.textFields["Description"].enterText(description)
        app.buttons["Add"].tapSettled()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 10), "form closed")
    }

    /// Opens the menu of the card for `description` and picks `item`. The
    /// menu is the card's sibling and its value is only the headline, which
    /// every duplicate card shares, so it is found by sitting level with the
    /// card.
    private func pick(_ item: String, onCardFor description: String) {
        let card = card(description)
        XCTAssertTrue(card.waitForExistence(timeout: 5), description)
        let menus = app.buttons.matching(identifier: "flow.insight.menu").allElementsBoundByIndex
        let menu = menus.first { $0.frame.midY > card.frame.minY && $0.frame.midY < card.frame.maxY }
        XCTAssertNotNil(menu, "menu for \(description)")
        menu?.tap()
        let button = app.buttons[item]
        XCTAssertTrue(button.waitForExistence(timeout: 5), item)
        button.tap()
    }

    func testSnoozeAndDismissPersist() throws {
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        tab("Flow")
        XCTAssertFalse(cards.firstMatch.waitForExistence(timeout: 2), "no cards for this run's rows yet")

        tab("Home")
        for description in descriptions {
            addExpense(description)
            addExpense(description)
        }

        tab("Flow")
        XCTAssertTrue(app.descendants(matching: .any)["flow.insights"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Insights"].exists)
        XCTAssertTrue(app.staticTexts["Calculated privately on this device \u{B7} Not financial advice"].exists)
        for description in descriptions {
            XCTAssertTrue(card(description).waitForExistence(timeout: 5), description)
        }
        XCTAssertEqual(cards.count, 3)

        pick("Snooze for 30 days", onCardFor: descriptions[0])
        XCTAssertTrue(card(descriptions[0]).waitForNonExistence(timeout: 5), "snoozed card gone")
        pick("Dismiss", onCardFor: descriptions[1])
        XCTAssertTrue(card(descriptions[1]).waitForNonExistence(timeout: 5), "dismissed card gone")
        XCTAssertTrue(card(descriptions[2]).exists)
        XCTAssertEqual(cards.count, 1)

        // Both stay hidden after a relaunch.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Flow"].waitForExistence(timeout: 20))
        tab("Flow")
        XCTAssertTrue(card(descriptions[2]).waitForExistence(timeout: 10))
        XCTAssertFalse(card(descriptions[0]).exists)
        XCTAssertFalse(card(descriptions[1]).exists)
        XCTAssertEqual(cards.count, 1)

        // Clean up: delete the six rows from Home's SEE ALL list.
        let thisRun = NSPredicate(format: "label CONTAINS 'Insight UI' AND label CONTAINS %@", run)
        tab("Home")
        app.buttons["See all transactions"].firstMatch.tap()
        for _ in 0..<6 {
            let row = app.buttons.containing(thisRun).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.swipeLeft()
            let confirm = app.alerts["Delete Transaction"].buttons["Delete"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        }
        XCTAssertFalse(app.buttons.containing(thisRun).firstMatch.waitForExistence(timeout: 2))
        tab("Flow")
        XCTAssertFalse(cards.firstMatch.waitForExistence(timeout: 2), "no cards for this run's rows once they are gone")
    }
}
