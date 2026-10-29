import XCTest

/// The Spend and Flow tabs beyond TabsUITests' happy path. Spend: the month
/// sheet, selecting a donut slice by tapping the ring, and the category's
/// drill-in (edit a row, swipe-delete a row). Flow: a bar opening the month
/// detail sheet, the metric strip, Year over year and the trend card, a
/// preview row opening SEE ALL, and SEE ALL's filters (type, category, reset
/// and the "N of M" count; minimum and maximum amount; From, To and the
/// month pill).
///
/// Regression group: sim A (BudgieAppTests + Recurring, Onboarding, MVPFlow,
/// Tabs, Insights, Voice, AppLock + SettingsUITests + this class). It sorts
/// after InsightsUITests, so the rows it adds (every one carries a per-run
/// suffix) cannot reach that class's empty-store assumption; every test
/// deletes its rows again, failed or not (`tearDown` relaunches and deletes
/// by suffix through Flow's SEE ALL search). Everything else on the
/// simulator is tolerated: the assertions are about its own rows.
@MainActor
final class SpendFlowUITests: XCTestCase {
    let app = XCUIApplication()
    private let suffix = String(Int.random(in: 1000...9999))
    private var cleanUp: (() -> Void)?

    override func setUp() async throws {
        continueAfterFailure = false
        app.budgie()
        cleanUp = { self.app.deleteTransactions(containing: self.suffix) }
    }

    override func tearDown() async throws {
        if let cleanUp {
            self.cleanUp = nil
            // From a known state: a failure may have left a sheet open.
            app.terminate()
            app.budgie()
            cleanUp()
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func monthKey(monthsAgo: Int) -> String {
        format(monthsAgo: monthsAgo, "yyyy-MM")
    }

    private func format(monthsAgo: Int, _ pattern: String) -> String {
        let month = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: month)
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    /// The Spend row of a category (`spend.row.<rank>`, label "<name>, ...").
    private func spendRow(_ category: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'spend.row.' AND label BEGINSWITH %@", "\(category), "))
            .firstMatch
    }

    /// Flow's SEE ALL page with its search and filters.
    private func openFlowSeeAll() {
        app.goToTabRoot("Flow", marker: "flow.rangePill")
        let seeAll = app.buttons["See all transactions"].firstMatch
        for _ in 0..<4 where !seeAll.isHittable { app.swipeUp() }
        seeAll.tapSettled()
        XCTAssertTrue(app.textFields["flow.all.search"].waitForExistence(timeout: 10), "Flow SEE ALL")
    }

    private var count: XCUIElement { app.element("flow.all.count") }

    private func expectCount(_ matches: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(count.waitUntil("label BEGINSWITH %@", ["\(matches) of "]), "\(what): \(count.label)", file: file, line: line)
    }

    /// The "N of M" count with both numbers.
    private func countNumbers() -> (matches: Int, total: Int)? {
        let parts = count.label.components(separatedBy: " of ")
        guard parts.count == 2, let matches = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return (matches, total)
    }

    private func resultRow(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'flow.all.row' AND label CONTAINS %@", text)).firstMatch
    }

    /// Picks the 15th of `monthsAgo` months back in the day picker that is
    /// open, then OK; `steps` is how many times to press Previous Month
    /// first (the picker opens on the month of the date already set).
    private func pickDay15(monthsAgo: Int, steps: Int) {
        let ok = app.buttons["datePicker.ok"]
        XCTAssertTrue(ok.waitForExistence(timeout: 10), "the date picker")
        for _ in 0..<steps { app.buttons["DatePicker.PreviousMonth"].tapSettled() }
        app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", \(format(monthsAgo: monthsAgo, "LLLL")) 15")).firstMatch
            .tapSettled()
        ok.tapSettled()
        XCTAssertTrue(ok.waitForNonExistence(timeout: 5), "the date picker closed")
    }

    // MARK: - Spend

    /// The month sheet switches the month, tapping the ring selects a slice
    /// (centre text and row), and the drill-in edits and deletes a row.
    func testSpendMonthSheetDonutSelectionAndDrillIn() throws {
        let description = "\(suffix) spend"
        app.showDollarAmounts()
        app.addTransaction(amount: "11.11", description: description, category: "Health")
        app.addTransaction(amount: "22.22", description: "\(suffix) old", category: "Health", monthsAgo: 1)

        app.goToTabRoot("Spend", marker: "spend.donut")
        let donut = app.element("spend.donut")
        let pill = app.buttons["spend.monthPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertEqual(pill.label, format(monthsAgo: 0, "LLLL"))

        // The month sheet: this month is ticked; last month switches the donut.
        pill.tapSettled()
        XCTAssertTrue(app.element("spend.monthSheet").waitForExistence(timeout: 5), "the month sheet")
        let current = app.buttons["spend.month.\(monthKey(monthsAgo: 0))"]
        let previous = app.buttons["spend.month.\(monthKey(monthsAgo: 1))"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.isSelected, "this month is the selected row")
        previous.tapSettled()
        XCTAssertTrue(previous.waitForNonExistence(timeout: 5), "the sheet closed on a pick")
        XCTAssertTrue(pill.waitForLabel(format(monthsAgo: 1, "LLLL")), "the pill follows: \(pill.label)")
        XCTAssertTrue(spendRow("Health").waitForExistence(timeout: 5), "last month's Health row")
        XCTAssertTrue(value(donut).hasPrefix("Spent "), value(donut))
        pill.tapSettled()
        current.tapSettled()
        XCTAssertTrue(pill.waitForLabel(format(monthsAgo: 0, "LLLL")))

        // Tapping the ring at 12 o'clock selects the first slice.
        XCTAssertTrue(donut.waitForExistence(timeout: 5))
        XCTAssertTrue(value(donut).hasPrefix("Spent "), "nothing selected: \(value(donut))")
        let first = app.buttons["spend.row.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(first.isSelected)
        let ring = donut.coordinate(withNormalizedOffset: CGVector(dx: 0.53, dy: 0.0625))
        ring.tap()
        XCTAssertTrue(donut.waitUntil("NOT (value BEGINSWITH %@)", ["Spent "]), "a slice is selected: \(value(donut))")
        let name = first.label.components(separatedBy: ", ")[0]
        XCTAssertTrue(value(donut).hasPrefix("\(name), "), "\(value(donut)) names \(name)")
        XCTAssertTrue(first.waitUntil("isSelected == true"), "the slice's row is highlighted")
        ring.tap()
        XCTAssertTrue(donut.waitUntil("value BEGINSWITH %@", ["Spent "]), "tapping it again deselects: \(value(donut))")
        XCTAssertTrue(first.waitUntil("isSelected == false"))

        // Drill in on Health: the summary, then edit the row from the list.
        let health = spendRow("Health")
        health.tapSettled()
        let summary = app.element("spend.drillIn.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "the drill-in")
        XCTAssertTrue(summary.label.hasPrefix("Total spent "), summary.label)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'spend.drillIn.row' AND label CONTAINS %@", description)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the row in the drill-in")
        XCTAssertTrue(row.label.contains("$11.11"), row.label)
        row.tapSettled()
        XCTAssertTrue(app.staticTexts["Edit Expense"].waitForExistence(timeout: 5), "the edit form")
        let amount = app.textFields["Amount"]
        XCTAssertEqual(amount.value as? String, "11.11")
        amount.tapSettled()
        amount.clearText()
        amount.typeSettled("13")
        app.buttons["Update"].tapSettled()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 10), "the form closed")
        XCTAssertTrue(row.waitUntil("label CONTAINS %@", ["$13.00"]), "the row shows the edit: \(row.label)")

        // Swipe it away, confirmed.
        row.swipeLeft()
        let confirm = app.alerts["Delete Transaction"].buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.labelled(exactly: "Transaction deleted").waitForExistence(timeout: 5), "the deleted toast")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "the row is gone from the drill-in")
    }

    // MARK: - Flow

    /// A bar opens the month's detail sheet; the metric strip, Year over
    /// year and the trend are there; the range pill changes; a preview row
    /// opens SEE ALL.
    func testFlowBarMonthDetailMetricsAndPreviewRow() throws {
        app.showDollarAmounts()
        app.addTransaction(income: true, amount: "500", description: "\(suffix) pay")
        app.addTransaction(amount: "200", description: "\(suffix) rent")

        app.goToTabRoot("Flow", marker: "flow.rangePill")
        let rangePill = app.buttons["flow.rangePill"]
        XCTAssertEqual(rangePill.value as? String, "6 months")

        // The metric strip: two labelled chips with values.
        let average = app.element("flow.metric.avgSaved")
        let rate = app.element("flow.metric.savingsRate")
        XCTAssertTrue(average.waitForExistence(timeout: 5))
        XCTAssertEqual(average.label, "Average saved per month")
        XCTAssertFalse(value(average).isEmpty)
        XCTAssertEqual(rate.label, "Savings rate")
        XCTAssertTrue(value(rate).hasSuffix("%"), value(rate))

        // A bar: its detail sheet with Income, Expenses and Net cash flow.
        let bar = app.element("flow.bar.\(monthKey(monthsAgo: 0))")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.label.hasPrefix(format(monthsAgo: 0, "LLLL yyyy")), bar.label)
        bar.tapSettled()
        let detail = app.element("flow.monthDetail")
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "the month detail sheet")
        let income = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Income' AND value BEGINSWITH '$'")).firstMatch
        let expenses = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Expenses' AND value BEGINSWITH '$'")).firstMatch
        let net = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Net cash flow' AND value CONTAINS '$'")).firstMatch
        XCTAssertTrue(income.exists && expenses.exists && net.exists, "the three tiles")
        XCTAssertTrue(value(income).hasPrefix("$"), value(income))
        XCTAssertTrue(value(expenses).hasPrefix("$"), value(expenses))
        XCTAssertTrue(value(net).contains("$"), value(net))
        // No close button: drag the sheet down by its grab handle, just
        // above the content.
        let top = app.descendants(matching: .any).matching(identifier: "flow.monthDetail").firstMatch.frame.minY
        let handle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.05, (top - 8) / app.frame.height)))
        handle.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(detail.waitForNonExistence(timeout: 10), "the sheet closed")

        // The range pill: 3 months, then back to 12.
        rangePill.tapSettled()
        let three = app.buttons["flow.range.3"]
        XCTAssertTrue(three.waitForExistence(timeout: 5))
        three.tapSettled()
        XCTAssertTrue(three.waitForNonExistence(timeout: 5))
        XCTAssertEqual(rangePill.value as? String, "3 months")
        XCTAssertTrue(average.exists && rate.exists, "the strip follows the range")

        // Year over year and the trend sit further down.
        let yoy = app.element("flow.yoy")
        let trend = app.element("flow.trend")
        for _ in 0..<4 where !(yoy.exists && trend.exists) { app.swipeUp() }
        XCTAssertTrue(yoy.exists, "Year over year")
        XCTAssertTrue(trend.exists, "the 12-month trend")

        // A preview row opens SEE ALL.
        let preview = app.buttons.matching(NSPredicate(format: "identifier == 'flow.preview.row' AND label CONTAINS %@", suffix)).firstMatch
        for _ in 0..<4 where !(preview.exists && preview.isHittable) { app.swipeUp() }
        XCTAssertTrue(preview.exists, "a preview row for the new rows")
        preview.tapSettled()
        XCTAssertTrue(app.textFields["flow.all.search"].waitForExistence(timeout: 10), "SEE ALL from a preview row")
    }

    /// SEE ALL: the "N of M" count follows the search, the type pills and the
    /// category sheet; RESET clears every filter.
    func testFlowSeeAllTypeCategoryAndReset() throws {
        app.showDollarAmounts()
        app.addTransaction(amount: "11", description: "\(suffix) coffee", category: "Health")
        app.addTransaction(income: true, amount: "300", description: "\(suffix) pay")

        openFlowSeeAll()
        let search = app.textFields["flow.all.search"]
        search.enterText(suffix)
        expectCount(2, "both new rows match the search")
        XCTAssertTrue(resultRow("coffee").exists)
        XCTAssertTrue(resultRow("pay").exists)
        XCTAssertTrue(app.buttons["flow.all.reset"].exists, "RESET shows while a filter is active")

        // Type: Income, Expense, All.
        let type = app.element("flow.all.type")
        XCTAssertTrue(type.exists)
        type.buttons["Income"].tapSettled()
        expectCount(1, "Income only")
        XCTAssertTrue(resultRow("pay").waitForExistence(timeout: 5))
        XCTAssertFalse(resultRow("coffee").exists)
        type.buttons["Expense"].tapSettled()
        expectCount(1, "Expense only")
        XCTAssertTrue(resultRow("coffee").waitForExistence(timeout: 5))
        XCTAssertFalse(resultRow("pay").exists)
        type.buttons["All"].tapSettled()
        expectCount(2, "All again")

        // Category: Health leaves the coffee.
        let category = app.buttons["flow.all.category"]
        XCTAssertEqual(category.value as? String, "All categories")
        category.tapSettled()
        let health = app.buttons.matching(NSPredicate(format: "identifier == 'flow.all.option' AND label == 'Health'")).firstMatch
        XCTAssertTrue(health.waitForExistence(timeout: 5), "the category sheet")
        health.tapSettled()
        XCTAssertTrue(category.waitForValue("Health"), "the category button reads Health")
        expectCount(1, "Health only")
        XCTAssertTrue(resultRow("coffee").exists)
        XCTAssertFalse(resultRow("pay").exists)

        // Category and type that match nothing: the empty card.
        type.buttons["Income"].tapSettled()
        expectCount(0, "Health income")
        XCTAssertTrue(app.element("flow.all.empty").waitForExistence(timeout: 5))

        // RESET: everything cleared, every transaction counted.
        let reset = app.buttons["flow.all.reset"]
        XCTAssertTrue(reset.exists)
        reset.tapSettled()
        XCTAssertTrue(category.waitForValue("All categories"), "the category cleared")
        XCTAssertTrue(reset.waitForNonExistence(timeout: 5), "RESET hides once nothing is filtered")
        XCTAssertFalse(value(search).contains(suffix), "the search cleared")
        XCTAssertTrue(count.waitUntil("label MATCHES %@", [#"^(\d+) of \1$"#]), "all rows shown: \(count.label)")
        if let numbers = countNumbers() { XCTAssertGreaterThanOrEqual(numbers.total, 2) }
    }

    /// SEE ALL: minimum and maximum amount, the From and To dates and the
    /// month pill (which sets both dates).
    func testFlowSeeAllAmountAndDateFilters() throws {
        app.showDollarAmounts()
        app.addTransaction(income: true, amount: "300", description: "\(suffix) pay")
        app.addTransaction(amount: "7", description: "\(suffix) old", monthsAgo: 1)

        openFlowSeeAll()
        let search = app.textFields["flow.all.search"]
        search.enterText(suffix)
        expectCount(2, "both new rows match the search")

        // Minimum 100 keeps the pay; maximum 10 keeps the old row.
        let minimum = app.textFields["flow.all.min"]
        minimum.enterText("100")
        expectCount(1, "at least 100")
        XCTAssertTrue(resultRow("pay").waitForExistence(timeout: 5))
        XCTAssertFalse(resultRow("old").exists)
        minimum.tapSettled()
        minimum.clearText()
        expectCount(2, "no minimum")
        let maximum = app.textFields["flow.all.max"]
        maximum.enterText("10")
        expectCount(1, "at most 10")
        XCTAssertTrue(resultRow("old").waitForExistence(timeout: 5))
        XCTAssertFalse(resultRow("pay").exists)
        maximum.tapSettled()
        maximum.clearText()
        expectCount(2, "no maximum")

        // From and To, both the 15th of last month: the old row only.
        let from = app.buttons["flow.all.from"]
        let to = app.buttons["flow.all.to"]
        XCTAssertEqual(from.value as? String, "Any date")
        from.tapSettled()
        pickDay15(monthsAgo: 1, steps: 1)
        let day = "\(format(monthsAgo: 1, "MMM")) 15"
        XCTAssertTrue(from.waitForValue(day), "From reads \(day): \(value(from))")
        expectCount(2, "from last month on")
        to.tapSettled()
        pickDay15(monthsAgo: 1, steps: 0)
        XCTAssertTrue(to.waitForValue(day), "To reads \(day): \(value(to))")
        expectCount(1, "last month's 15th only")
        XCTAssertTrue(resultRow("old").waitForExistence(timeout: 5))
        XCTAssertFalse(resultRow("pay").exists)

        // The month pill: this month replaces both dates.
        let monthPill = app.buttons["flow.all.month"]
        monthPill.tapSettled()
        let option = app.buttons.matching(
            NSPredicate(format: "identifier == 'flow.all.option' AND label == %@", format(monthsAgo: 0, "LLLL yyyy"))).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "the month sheet")
        option.tapSettled()
        XCTAssertTrue(option.waitForNonExistence(timeout: 5))
        XCTAssertTrue(from.waitForValue("\(format(monthsAgo: 0, "MMM")) 1"), "From is the month's first day: \(value(from))")
        expectCount(1, "this month only")
        XCTAssertTrue(resultRow("pay").waitForExistence(timeout: 5))
        XCTAssertFalse(resultRow("old").exists)

        // RESET clears the dates too.
        app.buttons["flow.all.reset"].tapSettled()
        XCTAssertTrue(from.waitForValue("Any date"), "From cleared: \(value(from))")
        XCTAssertTrue(to.waitForValue("Any date"), "To cleared: \(value(to))")
    }
}
