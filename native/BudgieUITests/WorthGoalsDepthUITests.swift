import XCTest

/// The Worth and Goals tabs past their lifecycle tests. Worth: the Assets /
/// Liabilities toggle and the add button opening the active side's editor, a
/// balance saved in a past month through the editor's month grid, the month
/// chip strip, the account history (stat cards, the timeline count, deleting
/// one balance update behind its confirmation) and the growth range pills.
/// Goals: validation errors, cancelling the form, the allocation dialog and
/// the delete dialog, and a partial allocation moving the progress.
///
/// Regression group: sim B (Backup + CSVImport first, then Categories,
/// Goals, Home, RouteOverPresentation, TagsRules, Worth, this class). Like
/// WorthUITests and GoalsUITests it needs no accounts and no goals at the
/// start, and leaves none: every account and goal carries a per-run suffix
/// and `tearDown` relaunches and deletes whatever the test left. Ledger rows
/// on the simulator do not matter.
@MainActor
final class WorthGoalsDepthUITests: XCTestCase {
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
            // From a known state: a failure may have left a dialog open.
            app.terminate()
            app.budgie()
            cleanUp()
        }
        try await super.tearDown()
    }

    // MARK: - Worth helpers

    private func openWorth() {
        app.goToTabRoot("Worth", marker: "worth.add")
    }

    private func account(_ name: String) -> XCUIElement { app.element("worth.account.\(name)") }

    /// Scrolls until `element` is wholly above the floating tab bar (a long
    /// press behind it never raises the context menu).
    private func revealAboveTabBar(_ element: XCUIElement) {
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<3 where element.frame.maxY > tabBar.frame.minY {
            app.swipeUp()
        }
        XCTAssertLessThanOrEqual(element.frame.maxY, tabBar.frame.minY, "\(element) is behind the tab bar")
    }

    /// Opens a row's context menu and picks `item` ("View History",
    /// "Delete Account").
    private func choose(_ item: String, on row: XCUIElement) {
        revealAboveTabBar(row)
        row.press(forDuration: 1.0)
        let action = app.buttons[item]
        XCTAssertTrue(action.waitForExistence(timeout: 5), "\(item) in the context menu")
        action.tap()
    }

    /// The editor, opened by the empty state's add button or the FAB.
    private func fillAccount(name: String, balanceLabel: String, balance: String) {
        let editor = app.element("worth.editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "the account editor")
        app.textFields["Account name"].enterText(name)
        app.textFields[balanceLabel].enterText(balance)
    }

    /// Picks `monthsAgo` months back in the editor's month grid.
    private func pickEditorMonth(monthsAgo: Int) {
        let editor = app.element("worth.editor")
        app.buttons["worth.editor.month"].tapSettled()
        let month = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
        if Calendar.current.component(.year, from: month) != Calendar.current.component(.year, from: Date()) {
            editor.buttons["Previous year"].tapSettled()
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"
        let cell = editor.buttons[formatter.string(from: month)]
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "the month grid offers \(formatter.string(from: month))")
        cell.tapSettled()
        XCTAssertTrue(cell.waitForNonExistence(timeout: 5), "the grid closed after a pick")
    }

    private func monthLabel(monthsAgo: Int, _ pattern: String = "LLLL yyyy") -> String {
        let month = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: month)
    }

    /// Deletes this run's accounts from both tabs, through the context menu.
    private func deleteAccounts() {
        openWorth()
        for toggle in ["worth.toggle.assets", "worth.toggle.liabilities"] {
            guard app.buttons[toggle].waitForExistence(timeout: 2) else { return }
            app.buttons[toggle].tapSettled()
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'worth.account.' AND identifier CONTAINS %@", suffix)).firstMatch
            while row.waitForExistence(timeout: 2) {
                choose("Delete Account", on: row)
                let confirm = app.alerts["Delete account?"].buttons["Delete"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                confirm.tap()
                XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
            }
        }
    }

    // MARK: - Worth tests

    /// The Assets / Liabilities toggle, the add button opening the editor on
    /// the active side, the editor's type pills, and the totals.
    func testLiabilitiesToggleAndTheEditorFollowsIt() throws {
        let asset = "WGD Asset \(suffix)"
        let loan = "WGD Loan \(suffix)"
        app.showDollarAmounts()
        openWorth()
        cleanUp = { self.deleteAccounts() }
        XCTAssertTrue(app.staticTexts["No net worth accounts yet"].waitForExistence(timeout: 10), "no accounts to start from")

        // An asset from the empty state.
        app.buttons["worth.empty.add"].tapSettled()
        fillAccount(name: asset, balanceLabel: "Asset balance", balance: "1000")
        app.buttons["worth.editor.save"].tapSettled()
        XCTAssertTrue(account(asset).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["worth.toggle.assets"].isSelected, "Assets is the first tab")
        XCTAssertFalse(app.buttons["worth.toggle.liabilities"].isSelected)

        // Liabilities: none yet; the add button opens the editor on Liability.
        app.buttons["worth.toggle.liabilities"].tapSettled()
        XCTAssertTrue(app.buttons["worth.toggle.liabilities"].waitUntil("isSelected == true"))
        XCTAssertTrue(app.element("worth.accounts.empty").waitForExistence(timeout: 5), "no liabilities yet")
        XCTAssertFalse(account(asset).exists, "the asset is not on the Liabilities tab")
        app.buttons["worth.add"].tapSettled()
        XCTAssertTrue(app.element("worth.editor").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["worth.editor.liability"].isSelected, "the editor opens on Liability")
        XCTAssertFalse(app.buttons["worth.editor.asset"].isSelected)
        XCTAssertTrue(app.textFields["Liability balance"].exists)
        fillAccount(name: loan, balanceLabel: "Liability balance", balance: "250")
        app.buttons["worth.editor.save"].tapSettled()
        XCTAssertTrue(account(loan).waitForExistence(timeout: 10), "the liability row")
        XCTAssertEqual(account(loan).label, "\(loan), $250")
        XCTAssertFalse(app.element("worth.accounts.empty").exists)

        // Totals: assets minus liabilities.
        XCTAssertEqual(app.element("worth.split").label, "Assets $1,000, liabilities $250")
        XCTAssertEqual(app.element("worth.hero").label, "Net worth $750.00")

        // Back on Assets, the add button opens on Asset, and the pills switch.
        app.buttons["worth.toggle.assets"].tapSettled()
        XCTAssertTrue(account(asset).waitForExistence(timeout: 5))
        XCTAssertFalse(account(loan).exists)
        app.buttons["worth.add"].tapSettled()
        XCTAssertTrue(app.element("worth.editor").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["worth.editor.asset"].isSelected, "the editor opens on Asset")
        app.buttons["worth.editor.liability"].tapSettled()
        XCTAssertTrue(app.buttons["worth.editor.liability"].waitUntil("isSelected == true"))
        XCTAssertTrue(app.textFields["Liability balance"].waitForExistence(timeout: 5), "the balance field follows the type")
        app.buttons["worth.editor.cancel"].tapSettled()
        XCTAssertTrue(app.element("worth.editor").waitForNonExistence(timeout: 5))
    }

    /// A balance saved in a past month through the month grid, the month
    /// chip strip, a second balance in another month, the history page's
    /// stat cards and timeline, deleting one update, the growth range pills,
    /// and deleting the account from its history page.
    func testPastMonthBalanceMonthStripHistoryAndGrowthRange() throws {
        let name = "WGD Fund \(suffix)"
        app.showDollarAmounts()
        openWorth()
        cleanUp = { self.deleteAccounts() }
        XCTAssertTrue(app.staticTexts["No net worth accounts yet"].waitForExistence(timeout: 10), "no accounts to start from")

        // 500 in a month three months back, chosen in the editor's grid.
        app.buttons["worth.empty.add"].tapSettled()
        fillAccount(name: name, balanceLabel: "Asset balance", balance: "500")
        pickEditorMonth(monthsAgo: 3)
        XCTAssertTrue(app.staticTexts[monthLabel(monthsAgo: 3)].exists, "the editor banner names the month")
        app.buttons["worth.editor.save"].tapSettled()
        XCTAssertTrue(account(name).waitForExistence(timeout: 10))
        XCTAssertEqual(account(name).label, "\(name), $500", "the balance carries forward to this month")

        // The month strip has this month and that month; this month is selected.
        let now = app.buttons[monthLabel(monthsAgo: 0)]
        let past = app.buttons[monthLabel(monthsAgo: 3)]
        XCTAssertTrue(now.waitForExistence(timeout: 5), "a chip for this month")
        XCTAssertTrue(past.exists, "a chip for the past month")
        XCTAssertTrue(now.isSelected)
        past.tapSettled()
        XCTAssertTrue(past.waitUntil("isSelected == true"), "the past month is selected")
        XCTAssertFalse(now.isSelected)
        XCTAssertTrue(
            app.staticTexts["TOTAL \u{00B7} \(monthLabel(monthsAgo: 3).uppercased())"].waitForExistence(timeout: 5),
            "the hero names the month")
        XCTAssertEqual(app.element("worth.hero").label, "Net worth $500.00")

        // A second balance, in this month: edit the row from this month's chip.
        now.tapSettled()
        XCTAssertTrue(now.waitUntil("isSelected == true"))
        revealAboveTabBar(account(name))
        account(name).tapSettled()
        XCTAssertTrue(app.element("worth.editor").waitForExistence(timeout: 5))
        let balance = app.textFields["Asset balance"]
        XCTAssertEqual(balance.value as? String, "500")
        balance.tapSettled()
        balance.clearText()
        balance.typeSettled("800")
        app.buttons["worth.editor.save"].tapSettled()
        XCTAssertTrue(app.element("worth.editor").waitForNonExistence(timeout: 10))
        XCTAssertTrue(account(name).waitForLabel("\(name), $800"), "this month's balance: \(account(name).label)")
        past.tapSettled()
        XCTAssertTrue(account(name).waitForLabel("\(name), $500"), "the past month still reads 500: \(account(name).label)")
        now.tapSettled()
        XCTAssertTrue(account(name).waitForLabel("\(name), $800"))

        // The growth range pills: 1Y is the default.
        let oneYear = app.buttons["1Y"]
        let all = app.buttons["ALL"]
        let sixMonths = app.buttons["6M"]
        for _ in 0..<4 where !(oneYear.exists && oneYear.isHittable) { app.swipeUp() }
        XCTAssertTrue(app.element("worth.growth.range").exists, "the growth range pills")
        XCTAssertTrue(oneYear.isSelected, "1Y is the default range")
        all.tapSettled()
        XCTAssertTrue(all.waitUntil("isSelected == true"))
        XCTAssertFalse(oneYear.isSelected)
        sixMonths.tapSettled()
        XCTAssertTrue(sixMonths.waitUntil("isSelected == true"))
        XCTAssertFalse(all.isSelected)

        // History: two entries, current / peak / low.
        for _ in 0..<4 where !account(name).isHittable { app.swipeDown() }
        choose("View History", on: account(name))
        XCTAssertTrue(app.element("worth.history.hero").waitForExistence(timeout: 10))
        let count = app.element("worth.history.timeline.count")
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "2 entries")
        XCTAssertTrue(app.element("worth.history.stat.current").label.contains("800"), app.element("worth.history.stat.current").label)
        XCTAssertTrue(app.element("worth.history.stat.peak").label.contains("800"), app.element("worth.history.stat.peak").label)
        XCTAssertTrue(app.element("worth.history.stat.low").label.contains("500"), app.element("worth.history.stat.low").label)

        // Delete one update: Cancel keeps both, Delete removes the newest.
        let deletes = app.buttons.matching(identifier: "worth.history.timeline.delete")
        for _ in 0..<4 where !deletes.firstMatch.isHittable { app.swipeUp() }
        XCTAssertEqual(deletes.count, 2)
        deletes.element(boundBy: 0).tapSettled()
        let alert = app.alerts["Delete balance update?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        XCTAssertEqual(count.label, "2 entries")
        deletes.element(boundBy: 0).tapSettled()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(count.waitForLabel("1 entry"), "one update left: \(count.label)")
        XCTAssertTrue(app.element("worth.history.stat.current").label.contains("500"), app.element("worth.history.stat.current").label)
        XCTAssertEqual(deletes.count, 1)
        XCTAssertEqual(deletes.firstMatch.label, "Keep at least one balance update", "the last update cannot be deleted")
        XCTAssertFalse(deletes.firstMatch.isEnabled)

        // Delete the account from its history page: it pops to the empty state.
        app.buttons["worth.history.deleteAccount"].tapSettled()
        let confirm = app.alerts["Delete account?"].buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No net worth accounts yet"].waitForExistence(timeout: 10), "back on the empty Worth tab")
    }

    // MARK: - Goals helpers

    private func openGoals() {
        app.goToTabRoot("Goals", marker: "goals.fab")
    }

    private var card: XCUIElement { app.element("goals.card") }

    /// Deletes every goal through the actions sheet.
    private func deleteGoals() {
        openGoals()
        while app.buttons["goals.card.more"].waitForExistence(timeout: 2) {
            app.buttons["goals.card.more"].firstMatch.tapSettled()
            app.buttons["goals.actions.delete"].tapSettled()
            confirmGoalDelete()
        }
    }

    /// Taps the delete dialog's Delete. The accessibility frame of
    /// `goals.delete.confirm` spans the whole dialog, so a tap at its centre
    /// lands on the message; its label text sits on the pill.
    private func confirmGoalDelete() {
        let confirm = app.buttons["goals.delete.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the delete dialog")
        confirm.staticTexts["Delete"].tapSettled()
        _ = confirm.waitForNonExistence(timeout: 5)
    }

    private func addGoal(name: String, target: String) {
        app.buttons["goals.fab"].tapSettled()
        let field = app.textFields["Goal name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the goal form")
        field.enterText(name)
        app.textFields["Target amount"].enterText(target)
        app.buttons["goals.form.submit"].tapSettled()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the goal card")
    }

    // MARK: - Goals tests

    /// The goal form's validation errors show together and clear as the
    /// fields are fixed; Cancel adds nothing.
    func testGoalFormValidationAndCancel() throws {
        openGoals()
        cleanUp = { self.deleteGoals() }
        XCTAssertTrue(app.element("goals.empty").waitForExistence(timeout: 10), "no goals to start from")

        app.buttons["goals.empty.add"].tapSettled()
        let name = app.textFields["Goal name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Add savings goal"].exists)

        // Submit empty: both errors at once.
        app.buttons["goals.form.submit"].tapSettled()
        XCTAssertTrue(app.staticTexts["Name is required"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Enter a target greater than 0"].exists)

        // A name and a zero target: only the target's error remains.
        name.enterText("WGD Trip \(suffix)")
        app.textFields["Target amount"].enterText("0")
        app.buttons["goals.form.submit"].tapSettled()
        XCTAssertTrue(app.staticTexts["Enter a target greater than 0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Name is required"].waitForNonExistence(timeout: 5), "the name error cleared")
        XCTAssertTrue(app.element("goals.form.submit").exists, "the form stays open")

        // Cancel closes it and adds nothing.
        app.buttons["goals.form.cancel"].tapSettled()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5), "the form closed")
        XCTAssertTrue(app.element("goals.empty").waitForExistence(timeout: 5), "still no goals")
    }

    /// A partial allocation moves the progress; the dialog's own errors and
    /// Cancel leave it alone; the delete dialog's Cancel keeps the goal.
    func testPartialAllocationAndCancelPaths() throws {
        let goal = "WGD Trip \(suffix)"
        openGoals()
        cleanUp = { self.deleteGoals() }
        XCTAssertTrue(app.element("goals.empty").waitForExistence(timeout: 10), "no goals to start from")
        app.showDollarAmounts()
        openGoals()

        addGoal(name: goal, target: "100")
        XCTAssertTrue(card.label.hasPrefix(goal), card.label)
        XCTAssertTrue((card.value as? String ?? "").hasPrefix("0 percent, $0 of $100"), "\(String(describing: card.value))")
        let addMoney = app.buttons["goals.card.addMoney"]

        // The dialog's error, then Cancel: nothing moves.
        addMoney.tapSettled()
        let amount = app.textFields["Allocation amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5), "the Add money dialog")
        app.buttons["goals.allocate.submit"].tapSettled()
        XCTAssertTrue(app.staticTexts["Enter an amount greater than 0"].waitForExistence(timeout: 5))
        app.buttons["goals.allocate.cancel"].tapSettled()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5), "the dialog closed")
        XCTAssertTrue((card.value as? String ?? "").hasPrefix("0 percent"), "\(String(describing: card.value))")

        // The 25 chip fills the field; Add money moves it to 25 percent.
        addMoney.tapSettled()
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        app.buttons["goals.allocate.chip.25"].tapSettled()
        XCTAssertTrue(amount.waitForValue("25.00"), "the chip fills the field: \(String(describing: amount.value))")
        app.buttons["goals.allocate.submit"].tapSettled()
        XCTAssertTrue(app.labelled(exactly: "Allocation added").waitForExistence(timeout: 5), "the toast")
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.waitUntil("value BEGINSWITH %@", ["25 percent, $25 of $100"]), "\(String(describing: card.value))")
        let summary = app.element("goals.summary")
        XCTAssertTrue(
            (summary.value as? String ?? "").hasPrefix("$25 of $100, 0 of 1 complete, 25 percent"), "\(String(describing: summary.value))")

        // A typed amount adds to it, and the goal is still open.
        addMoney.tapSettled()
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.enterText("10")
        app.buttons["goals.allocate.submit"].tapSettled()
        XCTAssertTrue(card.waitUntil("value BEGINSWITH %@", ["35 percent, $35 of $100"]), "\(String(describing: card.value))")
        XCTAssertTrue(addMoney.exists, "a partly funded goal can take more")

        // Delete, cancelled: the goal stays; then confirmed.
        app.buttons["goals.card.more"].tapSettled()
        app.buttons["goals.actions.delete"].tapSettled()
        let cancel = app.buttons["goals.delete.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "the delete dialog")
        cancel.tapSettled()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertTrue(card.exists, "Cancel keeps the goal")
        app.buttons["goals.card.more"].tapSettled()
        app.buttons["goals.actions.delete"].tapSettled()
        confirmGoalDelete()
        XCTAssertTrue(app.element("goals.empty").waitForExistence(timeout: 10), "the goal is gone")
    }
}
