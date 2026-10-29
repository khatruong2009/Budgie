import XCTest

/// Settings > Categories end to end: add a category and pick it in the
/// transaction form's wheel, the editor's inline errors, move up / down,
/// archive and restore behind "Show archived", then a rename that reaches
/// an existing transaction's row on Home; and the last active category of
/// a type refusing to be archived. Names carry a per-run suffix so a rerun
/// without an erase starts clean.
///
/// Each test leaves the store as it found it, failed or not: `tearDown`
/// relaunches the app and runs the test's `cleanUp` (delete the added
/// expense and archive the added category, which Flutter cannot delete;
/// restore the archived built-in income categories).
@MainActor
final class CategoriesUITests: XCTestCase {
    let app = XCUIApplication()
    private var cleanUp: (() -> Void)?

    override func setUp() async throws {
        continueAfterFailure = false
        app.budgie()
    }

    override func tearDown() async throws {
        if let cleanUp {
            self.cleanUp = nil
            // From a known state: the failure may have left a dialog, a
            // menu or the form open.
            app.terminate()
            app.budgie()
            cleanUp()
        }
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tapSettled()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeSettled(text)
    }

    private func openCategories() {
        app.goToHomeRoot()
        app.buttons["home.settings"].tapSettled()
        app.buttons["settings.categories"].tapSettled()
        XCTAssertTrue(app.element("categories.list").waitForExistence(timeout: 10))
    }

    /// Scrolls the list until the row is on screen; `required` fails the
    /// test when it never shows up.
    @discardableResult
    private func reveal(_ row: XCUIElement, required: Bool = true) -> Bool {
        let list = app.element("categories.list")
        for _ in 0..<10 {
            if row.exists && row.isHittable { return true }
            list.swipeUp()
        }
        if required { XCTAssertTrue(row.isHittable, "\(row) on screen") }
        return row.isHittable
    }

    private func value(of element: XCUIElement) -> String { element.value as? String ?? "" }

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private func menu(_ id: String) -> XCUIElement { app.buttons["categories.row.menu.\(id)"] }
    private func row(_ id: String) -> XCUIElement { app.element("categories.row.\(id)") }

    /// Opens the row's menu and picks `item`.
    private func choose(_ item: String, forRow id: String) {
        reveal(menu(id))
        menu(id).tapSettled()
        app.buttons[item].firstMatch.tapSettled()
    }

    // MARK: - Tests

    func testAddMoveArchiveRenameAndCascade() throws {
        let suffix = String(Int.random(in: 1000...9999))
        let name = "UI Coffee \(suffix)"
        let renamed = "UI Brew \(suffix)"
        let id = "expense-ui-coffee-\(suffix)"
        let description = "UI latte \(suffix)"
        cleanUp = {
            // The expense, if it was added (SEE ALL's swipe to delete).
            self.app.goToHomeRoot()
            self.app.buttons["See all transactions"].firstMatch.tapSettled()
            let expense = self.app.buttons.containing(NSPredicate(format: "label CONTAINS %@", description)).firstMatch
            if expense.waitForExistence(timeout: 5) {
                expense.swipeLeft()
                self.app.alerts["Delete Transaction"].buttons["Delete"].tapSettled()
                XCTAssertTrue(expense.waitForNonExistence(timeout: 10), "expense deleted")
            }
            // The category, if it was added and is active.
            self.openCategories()
            if self.reveal(self.row(id), required: false), self.value(of: self.row(id)) == "" {
                self.choose("Archive", forRow: id)
                XCTAssertTrue(self.row(id).waitForNonExistence(timeout: 5), "category archived")
            }
        }

        openCategories()

        // Add: the name, an icon and a colour; it lands last, no subtitle.
        app.buttons["categories.add"].tapSettled()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeSettled(name)
        app.buttons["categories.editor.icon.cart"].tapSettled()
        XCTAssertTrue(app.buttons["categories.editor.icon.cart"].isSelected)
        app.buttons["categories.editor.color.green"].tapSettled()
        XCTAssertTrue(app.buttons["categories.editor.color.green"].isSelected)
        app.buttons["categories.editor.submit"].tapSettled()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "editor closed")
        reveal(row(id))
        XCTAssertEqual(row(id).label, name)
        XCTAssertEqual(value(of: row(id)), "")

        // Inline errors: a duplicate (any case) and an empty name keep the
        // editor open with Flutter's copy.
        app.buttons["categories.add"].tapSettled()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeSettled(name.lowercased())
        app.buttons["categories.editor.submit"].tapSettled()
        XCTAssertTrue(app.labelled(exactly: "A category with this name already exists").waitForExistence(timeout: 5))
        XCTAssertTrue(field.exists, "editor still open")
        replaceText(in: field, with: "")
        XCTAssertTrue(app.labelled(exactly: "Enter a category name").waitForExistence(timeout: 5), "the error follows the text")
        app.buttons["categories.editor.submit"].tapSettled()
        XCTAssertTrue(app.labelled(exactly: "Enter a category name").exists)
        app.buttons["categories.editor.cancel"].tapSettled()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))

        // Move up past Loan Payment, then back down.
        let loan = row("expense-loan-payment")
        reveal(row(id))
        XCTAssertGreaterThan(row(id).frame.minY, loan.frame.minY)
        choose("Move up", forRow: id)
        XCTAssertTrue(waitUntil { self.row(id).frame.minY < loan.frame.minY }, "moved up")
        choose("Move down", forRow: id)
        XCTAssertTrue(waitUntil { self.row(id).frame.minY > loan.frame.minY }, "moved down")

        // Archive hides it; Show archived shows it with only Edit / Restore.
        choose("Archive", forRow: id)
        XCTAssertTrue(row(id).waitForNonExistence(timeout: 5), "archived row hidden")
        let showArchived = app.switches["categories.showArchived"]
        showArchived.tapSettled()
        reveal(row(id))
        XCTAssertEqual(value(of: row(id)), "Archived")
        menu(id).tapSettled()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Edit"].exists)
        XCTAssertFalse(app.buttons["Move up"].exists)
        XCTAssertFalse(app.buttons["Move down"].exists)
        app.buttons["Restore"].tapSettled()
        XCTAssertTrue(waitUntil { self.value(of: self.row(id)) == "" }, "restored")
        showArchived.tapSettled()

        // The transaction form's category menu offers it; add an expense with it.
        app.goToHomeRoot()
        app.buttons["Add transaction"].tapSettled()
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.typeSettled("4.5")
        app.textFields["Description"].enterText(description)
        app.chooseCategory(name)
        app.buttons["Add"].tapSettled()
        let transaction = app.labelled(exactly: description)
        XCTAssertTrue(transaction.waitForExistence(timeout: 10))
        XCTAssertTrue(value(of: transaction).contains(name), "row shows \(name)")

        // Rename it: the transaction's row follows (one commit, ledger rebuilt).
        openCategories()
        choose("Edit", forRow: id)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, name)
        replaceText(in: field, with: renamed)
        let save = app.buttons["categories.editor.submit"]
        XCTAssertEqual(save.label, "Save")
        save.tapSettled()
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        reveal(row(id))
        XCTAssertEqual(row(id).label, renamed)
        app.goToHomeRoot()
        XCTAssertTrue(transaction.waitForExistence(timeout: 10))
        XCTAssertTrue(transaction.waitUntil("value CONTAINS %@", [renamed], timeout: 10), "the transaction shows the new name")
    }

    func testLastActiveCategoryCannotBeArchived() throws {
        let others = ["income-salary", "income-investment", "income-gift"]
        cleanUp = {
            // Every built-in income category the test archived.
            self.openCategories()
            self.app.element("categories.type").buttons["Income"].tapSettled()
            self.app.switches["categories.showArchived"].tapSettled()
            for id in others where self.reveal(self.row(id), required: false) {
                guard self.value(of: self.row(id)).contains("Archived") else { continue }
                self.choose("Restore", forRow: id)
                XCTAssertTrue(self.row(id).waitForValue("Built in"), "\(id) restored")
            }
        }

        openCategories()
        let income = app.element("categories.type").buttons["Income"]
        income.tapSettled()
        XCTAssertTrue(row("income-salary").waitForExistence(timeout: 5))

        for id in others {
            choose("Archive", forRow: id)
            XCTAssertTrue(row(id).waitForNonExistence(timeout: 5), "\(id) archived")
        }
        choose("Archive", forRow: "income-other")
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", "At least one category must remain active")).firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertTrue(row("income-other").exists, "still active")

        // Restore the others from the page (tearDown's cleanUp then finds
        // nothing left to restore).
        app.switches["categories.showArchived"].tapSettled()
        for id in others {
            choose("Restore", forRow: id)
            XCTAssertTrue(row(id).waitForValue("Built in"), "\(id) restored")
        }
    }
}
