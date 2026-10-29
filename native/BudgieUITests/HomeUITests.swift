import XCTest

/// Home flows the older classes do not reach: the budgets section (add, edit
/// and remove a monthly limit through the pickers and the limit sheet), the
/// safe-to-spend breakdown sheet, the month pill with its year stepper and
/// wheel, the add button's long press (the quick-expense category sheet) and
/// the SEE ALL list's month strip with a swipe delete. Also the settings
/// gear's 44pt tap area.
///
/// Regression group: sim B (Backup + CSVImport first, then Categories, Goals,
/// this class, RouteOverPresentation, TagsRules, Worth, WorthGoalsDepth). It
/// tolerates the data those leave behind (the restored backup's three rows
/// last month and its Groceries limit) and needs no empty store: it budgets
/// Entertainment, which nothing else does, and its rows carry a per-run
/// suffix. Each test removes what it added, failed or not (`tearDown`
/// relaunches and cleans).
@MainActor
final class HomeUITests: XCTestCase {
    let app = XCUIApplication()
    private let suffix = String(Int.random(in: 1000...9999))
    private var cleanUp: (() -> Void)?

    override func setUp() async throws {
        continueAfterFailure = false
        app.budgie()
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

    /// Scrolls Home up until `element` is on screen.
    private func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) is on screen", file: file, line: line)
    }

    /// Saves the limit with the hardware Return key. After XCTest types, its
    /// virtual hardware keyboard leaves the limit sheet sitting behind the
    /// software keyboard (Save is not hittable, although by hand the sheet
    /// rides up above the keyboard), and the field's `onSubmit` is the other
    /// way to save.
    private func submitLimit(_ field: XCUIElement) {
        field.typeText("\n")
    }

    private var budgetRow: XCUIElement { app.buttons["home.budgets.row.Entertainment"] }

    /// Removes the Entertainment limit when there is one.
    private func removeBudgetIfPresent() {
        app.goToHomeRoot()
        guard budgetRow.waitForExistence(timeout: 3) else { return }
        reveal(budgetRow)
        budgetRow.tapSettled()
        let remove = app.buttons["budgets.limit.remove"]
        if remove.waitForExistence(timeout: 10) {
            remove.tapSettled()
            _ = budgetRow.waitForNonExistence(timeout: 10)
        }
    }

    /// "Added to August" (another month of this year) or "Added to
    /// December 2025", as the toast words it.
    private func addedToast(monthsAgo: Int) -> String {
        let month = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let sameYear = Calendar.current.component(.year, from: month) == Calendar.current.component(.year, from: Date())
        formatter.dateFormat = sameYear ? "LLLL" : "LLLL yyyy"
        return "Added to \(formatter.string(from: month))"
    }

    /// "September 2026": the label of the month pill and of the SEE ALL
    /// month chips.
    private func monthLabel(monthsAgo: Int) -> String {
        let month = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: month)
    }

    // MARK: - Tests

    /// The gear's hit region is at least 44 x 44pt (its glyph stays 36pt).
    func testSettingsGearHasA44ptTarget() throws {
        app.goToHomeRoot()
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(gear.frame.width, 44)
        XCTAssertGreaterThanOrEqual(gear.frame.height, 44)
        // A tap in its outer ring (inside 44pt, outside the old 36pt) opens Settings.
        gear.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(app.switches["settings.hideBalances"].waitForExistence(timeout: 10), "Settings opened from the gear's edge")
    }

    /// Budgets: add a limit for a category through the Add picker and the
    /// limit sheet, edit it through EDIT, then remove it from its row.
    func testBudgetAddEditAndRemove() throws {
        app.showDollarAmounts()
        cleanUp = { self.removeBudgetIfPresent() }
        removeBudgetIfPresent()

        // Add: "Add a budget" > Entertainment > 75 > Save.
        let add = app.buttons["home.budgets.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        reveal(add)
        add.tapSettled()
        let tile = app.buttons["budgets.picker.Entertainment"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the Add a budget picker")
        tile.tapSettled()
        let field = app.textFields["budgets.limit.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the limit sheet")
        XCTAssertFalse(app.buttons["budgets.limit.remove"].exists, "a new limit has nothing to remove")
        XCTAssertFalse(app.buttons["budgets.limit.save"].isEnabled, "Save waits for an amount")
        field.enterText("75")
        XCTAssertTrue(app.buttons["budgets.limit.save"].isEnabled)
        submitLimit(field)
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "the sheet closed after Save")
        XCTAssertTrue(budgetRow.waitForExistence(timeout: 10), "the budget row")
        XCTAssertTrue(budgetRow.label.hasPrefix("Entertainment, "), budgetRow.label)
        XCTAssertTrue(budgetRow.label.contains(" of $75.00, "), budgetRow.label)

        // Edit: EDIT > Entertainment (prefilled) > 120 > Save.
        let edit = app.buttons["Edit, Budgets"]
        reveal(edit)
        edit.tapSettled()
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "the Edit budgets picker")
        XCTAssertTrue(tile.label.contains("$75 limit"), tile.label)
        tile.tapSettled()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "75.00", "the limit sheet opens on the stored limit")
        XCTAssertTrue(app.buttons["budgets.limit.remove"].exists, "an existing limit can be removed")
        field.tapSettled()
        field.clearText()
        field.typeSettled("120")
        submitLimit(field)
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        XCTAssertTrue(budgetRow.waitUntil("label CONTAINS %@", [" of $120, "]), "edited limit: \(budgetRow.label)")

        // Remove: the row opens the sheet; Remove takes the row away.
        reveal(budgetRow)
        budgetRow.tapSettled()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        app.buttons["budgets.limit.remove"].tapSettled()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        XCTAssertTrue(budgetRow.waitForNonExistence(timeout: 10), "the budget row is gone")
        XCTAssertTrue(app.buttons["home.budgets.add"].waitForExistence(timeout: 5))
    }

    /// The safe-to-spend card opens its breakdown sheet, which lists the
    /// six inputs and the total, and closes again.
    func testSafeToSpendSheetOpensAndCloses() throws {
        app.showDollarAmounts()
        app.goToHomeRoot()
        let card = app.buttons["home.safeToSpend"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.hasPrefix("Safe to spend") || card.label.hasPrefix("Projected shortfall"), card.label)
        XCTAssertTrue(card.label.hasSuffix("Double tap for breakdown."))
        card.tapSettled()

        let income = app.labelled(containing: "Income recorded, ")
        XCTAssertTrue(income.waitForExistence(timeout: 10), "the breakdown sheet")
        for row in ["Income still expected", "Expenses recorded", "Upcoming recurring bills", "Flexible budget reserve", "Suggested goal contributions"] {
            XCTAssertTrue(app.labelled(containing: "\(row), ").exists, row)
        }
        XCTAssertTrue(income.label.contains("$"), income.label)

        // No close button: drag the sheet down by one of its rows.
        income.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(income.waitForNonExistence(timeout: 10), "the sheet closed")
        XCTAssertTrue(card.isHittable, "Home is usable again")
    }

    /// The month pill opens the month panel: the year stepper changes the
    /// year (and the pill), the wheel reads the month and follows a drag,
    /// and the pill closes the panel.
    func testMonthPillYearStepperAndWheelChangeTheMonth() throws {
        app.goToHomeRoot()
        let pill = app.buttons["home.monthPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        let start = monthLabel(monthsAgo: 0)
        XCTAssertEqual(pill.label, start)
        let parts = start.split(separator: " ")
        let month = String(parts[0])
        let year = Int(parts[1]) ?? 0

        pill.tapSettled()
        let yearLabel = app.element("home.monthPanel.year")
        XCTAssertTrue(yearLabel.waitForExistence(timeout: 5), "the month panel opened")
        XCTAssertEqual(yearLabel.label, "Year \(year)")
        let wheel = app.element("home.monthWheel")
        XCTAssertEqual(wheel.value as? String, month)

        // The year stepper keeps the month.
        app.buttons["home.monthPanel.prevYear"].tapSettled()
        XCTAssertTrue(pill.waitForLabel("\(month) \(year - 1)"), "previous year: \(pill.label)")
        XCTAssertTrue(yearLabel.waitForLabel("Year \(year - 1)"))
        XCTAssertEqual(wheel.value as? String, month)
        app.buttons["home.monthPanel.nextYear"].tapSettled()
        XCTAssertTrue(pill.waitForLabel(start), "next year: \(pill.label)")

        // The wheel: drag it one row towards the nearer end of the year.
        let english = DateFormatter()
        english.locale = Locale(identifier: "en_US_POSIX")
        let months = english.standaloneMonthSymbols ?? []
        let index = months.firstIndex(of: month) ?? 0
        let forward = index < 11
        let expected = months[forward ? index + 1 : index - 1]
        let from = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: forward ? 0.23 : 0.77))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(wheel.waitForValue(expected), "the wheel moved to \(expected): \(String(describing: wheel.value))")
        XCTAssertTrue(pill.label.hasPrefix(expected), "the pill follows the wheel: \(pill.label)")

        // Close the panel with the pill; it leaves the accessibility tree.
        pill.tapSettled()
        XCTAssertTrue(yearLabel.waitForNonExistence(timeout: 5), "the month panel closed")
    }

    /// Long-pressing the add button opens the quick-expense categories;
    /// choosing Health opens the expense form on Health, which saves.
    func testQuickExpenseFromTheAddButtonLongPress() throws {
        let description = "\(suffix) quick"
        cleanUp = { self.app.deleteTransactions(containing: self.suffix) }
        app.goToHomeRoot()
        let fab = app.buttons["Add transaction"]
        XCTAssertTrue(fab.waitForExistence(timeout: 10))
        fab.press(forDuration: 1.0)

        let choice = app.buttons["Choose Health"]
        XCTAssertTrue(choice.waitForExistence(timeout: 10), "the quick-expense sheet")
        XCTAssertTrue(app.staticTexts["Add expense"].exists)
        choice.tapSettled()

        // The form opens once the sheet has gone, on the chosen category.
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForExistence(timeout: 10), "the expense form")
        XCTAssertFalse(choice.exists, "the category sheet is gone")
        let category = app.formCategory
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertEqual(category.value as? String, "Health")
        let amount = app.textFields["Amount"]
        amount.enterText("4.56")
        app.textFields["Description"].enterText(description)
        app.buttons["Add"].tapSettled()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 10))

        let row = app.labelled(containing: description)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the new row on Home")
        XCTAssertTrue((row.value as? String ?? "").contains("Health"), "\(String(describing: row.value))")
        XCTAssertTrue((row.value as? String ?? "").contains("$4.56"), "\(String(describing: row.value))")
    }

    /// SEE ALL: the month strip lists the months with rows, tapping a chip
    /// switches the list, and a swipe deletes a row with its toast. Also the
    /// "Added to <month>" toast for a row dated outside the month on screen.
    func testSeeAllMonthStripAndSwipeDelete() throws {
        let now = "\(suffix) now"
        let old = "\(suffix) old"
        cleanUp = { self.app.deleteTransactions(containing: self.suffix) }
        app.showDollarAmounts()

        app.addTransaction(amount: "12", description: now)
        app.addTransaction(amount: "33", description: old, monthsAgo: 1)
        XCTAssertTrue(app.labelled(exactly: addedToast(monthsAgo: 1)).waitForExistence(timeout: 5), "the dated-elsewhere toast")

        app.goToHomeRoot()
        app.buttons["See all transactions"].firstMatch.tapSettled()
        let current = app.buttons[monthLabel(monthsAgo: 0)]
        let previous = app.buttons[monthLabel(monthsAgo: 1)]
        XCTAssertTrue(current.waitForExistence(timeout: 10), "a chip for this month")
        XCTAssertTrue(previous.exists, "a chip for last month")
        XCTAssertTrue(current.isSelected, "the newest month is selected first")
        XCTAssertFalse(previous.isSelected)

        let nowRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", now)).firstMatch
        let oldRow = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", old)).firstMatch
        XCTAssertTrue(nowRow.waitForExistence(timeout: 5))
        XCTAssertFalse(oldRow.exists, "last month's row is not in this month's list")
        let summary = app.labelled(containing: "Net cash flow ")
        XCTAssertTrue(summary.label.hasPrefix("Income "), summary.label)

        previous.tapSettled()
        XCTAssertTrue(previous.waitUntil("isSelected == true"), "last month selected")
        XCTAssertFalse(current.isSelected)
        XCTAssertTrue(oldRow.waitForExistence(timeout: 5), "last month's row")
        XCTAssertTrue(oldRow.label.contains("$33.00"), oldRow.label)
        XCTAssertFalse(nowRow.exists)

        current.tapSettled()
        XCTAssertTrue(nowRow.waitForExistence(timeout: 5), "this month's row is back")
        XCTAssertFalse(oldRow.exists)

        // Swipe left, confirm: the row and its toast.
        nowRow.swipeLeft()
        let confirm = app.alerts["Delete Transaction"].buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.labelled(exactly: "Transaction deleted").waitForExistence(timeout: 5), "the deleted toast")
        XCTAssertTrue(nowRow.waitForNonExistence(timeout: 5))
    }
}
