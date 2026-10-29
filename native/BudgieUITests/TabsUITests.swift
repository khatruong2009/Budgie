import XCTest

/// The Spend and Flow tabs end to end on a fresh install: one expense added
/// from Home shows up in the Spend donut and drill-in and in Flow's bars,
/// then is found and deleted from Flow's filterable list.
@MainActor
final class TabsUITests: XCTestCase {
    let app = XCUIApplication()

    private static let description = "UI tabs coffee"

    override func setUp() async throws {
        continueAfterFailure = false
        app.launchEnvironment["BUDGIE_SKIP_ONBOARDING"] = "1"
        app.launch()
    }

    private func tab(_ name: String) {
        app.tabBars.buttons[name].tap()
    }

    /// The current month as the app keys its bars ("2026-09").
    private var currentMonthKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    func testSpendAndFlow() throws {
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))

        // Add an expense from the Home FAB.
        app.buttons["Add transaction"].tap()
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.enterText("12.34")
        app.textFields["Description"].enterText(Self.description)
        app.buttons["Add"].tapSettled()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", Self.description)).firstMatch
                .waitForExistence(timeout: 5))

        // Spend: the donut and the one category row, its drill-in and back.
        tab("Spend")
        XCTAssertTrue(app.element("spend.donut").waitForExistence(timeout: 5))
        let row = app.buttons["spend.row.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.element("spend.drillIn.summary").waitForExistence(timeout: 5))
        XCTAssertTrue(app.element("spend.drillIn.row").exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.element("spend.donut").waitForExistence(timeout: 5))

        // Flow: the net cash flow card with this month's bar.
        tab("Flow")
        XCTAssertTrue(app.element("flow.netCashFlow").waitForExistence(timeout: 5))
        XCTAssertTrue(app.element("flow.bar.\(currentMonthKey)").exists, "bar for \(currentMonthKey)")

        // The range sheet: pick 12 months.
        let rangePill = app.buttons["flow.rangePill"]
        rangePill.tap()
        let twelve = app.buttons["flow.range.12"]
        XCTAssertTrue(twelve.waitForExistence(timeout: 5))
        twelve.tap()
        XCTAssertTrue(twelve.waitForNonExistence(timeout: 5))
        XCTAssertEqual(rangePill.value as? String, "12 months")

        // SEE ALL: search filters the rows.
        let seeAll = app.buttons["See all transactions"].firstMatch
        if !seeAll.isHittable { app.swipeUp() }
        seeAll.tap()
        let search = app.textFields["flow.all.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let rows = app.buttons.matching(identifier: "flow.all.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        search.enterText("zzz")
        XCTAssertTrue(app.element("flow.all.empty").waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 0)
        app.buttons["Clear search"].tapSettled()
        search.enterText("tabs coffee")
        let match = rows.firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(match.label.contains(Self.description))

        // Swipe to delete with the search keyboard still up, confirmed in
        // the alert. The row starts under the keyboard (a swipe there
        // swipe-types into the field), so first scroll it into view with an
        // upward drag above the keyboard, which leaves the keyboard up.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists, "the search keyboard is up")
        if !match.isHittable {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        XCTAssertTrue(match.isHittable, "the row is above the keyboard")
        XCTAssertTrue(keyboard.exists, "scrolling up kept the keyboard up")
        match.swipeLeft()
        let alert = app.alerts["Delete Transaction"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(app.element("flow.all.empty").waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 0)
    }
}
