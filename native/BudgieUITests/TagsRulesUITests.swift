import XCTest

/// Settings > Tags & rules end to end: add a tag (and a refused duplicate),
/// add a merchant rule using it (Done and opening a dropdown dismiss the
/// keyboard), see the rule pick the category and tag in the transaction
/// form, find the saved expense through Flow SEE ALL's tag filter, delete
/// the tag through its confirmation while the rule still uses it (the rule
/// keeps its category and loses the tag; the tag is gone from the form),
/// then delete the rule (instant: no more suggestion). A second test
/// covers the Swift-only rule edit, maximum amount, enable switch and Any
/// type. Names carry a per-run suffix so a rerun without an erase starts
/// clean.
///
/// The test leaves the store as it found it, failed or not: `tearDown`
/// relaunches the app and runs `cleanUp` (delete the added expense, then
/// the rule and the tag if they are still there).
@MainActor
final class TagsRulesUITests: XCTestCase {
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

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    private func openTagsAndRules() {
        app.goToHomeRoot()
        app.buttons["home.settings"].tapSettled()
        app.buttons["Tags & rules"].tapSettled()
        XCTAssertTrue(app.element("tagsRules.list").waitForExistence(timeout: 10))
    }

    /// Scrolls the page until the element is on screen.
    private func reveal(_ target: XCUIElement) {
        let list = app.element("tagsRules.list")
        for _ in 0..<10 {
            if target.exists && target.isHittable { return }
            list.swipeUp()
        }
        XCTAssertTrue(target.isHittable, "\(target) on screen")
    }

    /// Opens the add form from Home (switched to Income for an income) and
    /// types an amount and a description.
    private func openExpenseForm(description: String, amount amountText: String = "12", income: Bool = false) {
        app.goToHomeRoot()
        app.buttons["Add transaction"].tapSettled()
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        if income {
            app.buttons["Income"].firstMatch.tapSettled()
            amount.tapSettled()
        }
        amount.typeSettled(amountText)
        guard !description.isEmpty else { return }
        app.textFields["Description"].enterText(description)
    }

    /// The form's selected category (the Category row's value).
    private var wheelValue: String { app.formCategory.value as? String ?? "" }

    /// The form's tag chip with this name (a button; the page is not
    /// behind the sheet on another tab).
    private func formChip(_ name: String) -> XCUIElement { app.buttons[name] }

    /// Flow > SEE ALL, with its filters.
    private func openSeeAll() {
        app.tabBars.buttons["Flow"].tap()
        let seeAll = app.buttons["See all transactions"].firstMatch
        XCTAssertTrue(seeAll.waitForExistence(timeout: 10))
        if !seeAll.isHittable { app.swipeUp() }
        seeAll.tapSettled()
        XCTAssertTrue(app.textFields["flow.all.search"].waitForExistence(timeout: 5))
    }

    private func leaveSeeAll() {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Deletes every SEE ALL row whose label contains `text` (swipe, then
    /// the Delete Transaction alert).
    private func deleteTransactions(containing text: String) {
        app.goToHomeRoot()
        app.buttons["See all transactions"].firstMatch.tapSettled()
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        var deleted = 0
        while row.waitForExistence(timeout: 3) && deleted < 5 {
            row.swipeLeft()
            app.alerts["Delete Transaction"].buttons["Delete"].tapSettled()
            XCTAssertTrue(app.alerts["Delete Transaction"].waitForNonExistence(timeout: 10))
            deleted += 1
        }
        XCTAssertFalse(row.exists, "transactions with \(text) deleted")
    }

    // MARK: - Test

    func testTagsAndRules() throws {
        let suffix = String(Int.random(in: 1000...9999))
        let tag = "UI Work \(suffix)"
        let merchant = "UIMart \(suffix)"
        let description = "uimart \(suffix) market"
        cleanUp = {
            self.deleteTransactions(containing: description)
            self.openTagsAndRules()
            let deleteRule = self.app.buttons["Delete rule \(merchant)"]
            if deleteRule.exists {
                self.reveal(deleteRule)
                deleteRule.tapSettled()
                XCTAssertTrue(deleteRule.waitForNonExistence(timeout: 5), "rule deleted")
            }
            let deleteTag = self.app.buttons["Delete \(tag)"]
            if deleteTag.exists {
                self.reveal(deleteTag)
                deleteTag.tapSettled()
                self.app.buttons["tags.delete.confirm"].tapSettled()
                XCTAssertTrue(deleteTag.waitForNonExistence(timeout: 10), "tag deleted")
            }
        }

        openTagsAndRules()
        let startedEmpty = app.element("tags.empty").exists && app.element("rules.empty").exists

        // Add the tag: its row and delete button appear.
        app.buttons["tags.add"].tapSettled()
        let name = app.textFields["Tag name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeSettled(tag)
        app.buttons["tags.editor.submit"].tapSettled()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10), "tag dialog closed")
        XCTAssertTrue(app.labelled(exactly: tag).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete \(tag)"].exists)
        XCTAssertFalse(app.element("tags.empty").exists)

        // A duplicate in another case is refused inline; the dialog stays.
        app.buttons["tags.add"].tapSettled()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeSettled(tag.uppercased())
        app.buttons["tags.editor.submit"].tapSettled()
        XCTAssertTrue(app.labelled(exactly: "A tag with this name already exists").waitForExistence(timeout: 5))
        XCTAssertTrue(name.exists, "dialog still open")
        app.buttons["tags.editor.cancel"].tapSettled()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10))

        // Add a rule: Groceries, with the tag; Add is off until there is text.
        app.buttons["rules.add"].tapSettled()
        let pattern = app.textFields["Merchant text"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 5))
        let add = app.buttons["rules.editor.submit"]
        XCTAssertFalse(add.isEnabled, "Add is disabled while the text is empty")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "autofocused")
        pattern.typeSettled(merchant)
        // Done dismisses the keyboard.
        pattern.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Done dismissed the keyboard")
        XCTAssertEqual(app.element("rules.editor.type").value as? String, "Expense")
        XCTAssertEqual(app.element("rules.editor.match").value as? String, "Contains")
        // Opening a dropdown with the keyboard up dismisses it first.
        pattern.tapSettled()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.element("rules.editor.category").tapSettled()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "the dropdown dismissed the keyboard")
        app.buttons["Groceries"].firstMatch.tapSettled()
        XCTAssertTrue(app.element("rules.editor.category").waitForValue("Groceries"))
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'rules.editor.tag.' AND label == %@", tag)).firstMatch
        chip.tapSettled()
        XCTAssertTrue(chip.waitUntil("isSelected == true"), "tag selected")
        add.tapSettled()
        XCTAssertTrue(pattern.waitForNonExistence(timeout: 10), "rule dialog closed")
        let rule = app.labelled(exactly: merchant)
        reveal(rule)
        XCTAssertEqual(rule.value as? String, "contains \u{00B7} Groceries \u{00B7} 1 tags")

        // The form: the description picks Groceries and selects the tag.
        openExpenseForm(description: description)
        XCTAssertTrue(waitUntil { self.wheelValue.contains("Groceries") }, "rule set the category, wheel shows \(wheelValue)")
        XCTAssertTrue(formChip(tag).waitForExistence(timeout: 5))
        XCTAssertTrue(formChip(tag).isSelected, "rule selected the tag")
        app.buttons["Add"].tapSettled()
        XCTAssertTrue(app.textFields["Amount"].waitForNonExistence(timeout: 10), "form closed")

        // Flow SEE ALL lists the new tag; filtering by it finds the expense.
        openSeeAll()
        let filterChip = app.buttons[tag]
        XCTAssertTrue(filterChip.waitForExistence(timeout: 5), "SEE ALL lists the tag")
        if !filterChip.isHittable { app.swipeUp() }
        filterChip.tapSettled()
        let rows = app.buttons.matching(identifier: "flow.all.row")
        XCTAssertTrue(waitUntil { rows.count == 1 }, "one tagged row, got \(rows.count)")
        XCTAssertTrue(rows.firstMatch.label.contains(description))
        leaveSeeAll()

        // Delete the tag while the rule uses it: Cancel keeps it; Delete
        // removes it, and the rule keeps its category without the tag.
        openTagsAndRules()
        let deleteTag = app.buttons["Delete \(tag)"]
        reveal(deleteTag)
        deleteTag.tapSettled()
        XCTAssertTrue(app.buttons["tags.delete.confirm"].waitForExistence(timeout: 5))
        app.buttons["tags.delete.cancel"].tapSettled()
        XCTAssertTrue(app.buttons["tags.delete.confirm"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.labelled(exactly: tag).exists, "cancel kept the tag")
        deleteTag.tapSettled()
        app.buttons["tags.delete.confirm"].tapSettled()
        XCTAssertTrue(app.labelled(exactly: tag).waitForNonExistence(timeout: 10), "tag deleted")
        reveal(rule)
        XCTAssertEqual(rule.value as? String, "contains \u{00B7} Groceries", "the rule lost the tag")

        // The rule still picks Groceries; the tag chip is gone from the form.
        openExpenseForm(description: description + " again")
        XCTAssertTrue(waitUntil { self.wheelValue.contains("Groceries") }, "rule still sets the category, wheel shows \(wheelValue)")
        XCTAssertFalse(formChip(tag).waitForExistence(timeout: 2), "tag chip gone from the form")
        app.buttons["Cancel"].tapSettled()
        XCTAssertTrue(app.textFields["Amount"].waitForNonExistence(timeout: 10))

        // Delete the rule: instant, and the form no longer suggests.
        openTagsAndRules()
        let deleteRule = app.buttons["Delete rule \(merchant)"]
        reveal(deleteRule)
        deleteRule.tapSettled()
        XCTAssertTrue(rule.waitForNonExistence(timeout: 5), "rule deleted without a confirmation")
        if startedEmpty {
            XCTAssertTrue(app.element("tags.empty").waitForExistence(timeout: 5))
            XCTAssertTrue(app.element("rules.empty").exists)
        }
        openExpenseForm(description: description + " again")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(wheelValue.contains("Groceries"), "no suggestion, wheel shows \(wheelValue)")
        app.buttons["Cancel"].tapSettled()
        XCTAssertTrue(app.textFields["Amount"].waitForNonExistence(timeout: 10))

        // Gone from SEE ALL's filter.
        openSeeAll()
        XCTAssertFalse(app.buttons[tag].waitForExistence(timeout: 2), "tag chip gone from SEE ALL")
        leaveSeeAll()
    }

    // MARK: - Swift-only: edit, bounds, enable switch, any type

    /// The rule row's enable switch.
    private func ruleSwitch(_ pattern: String) -> XCUIElement {
        app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'rules.row.enabled.' AND label == %@", "Enable rule \(pattern)"))
            .firstMatch
    }

    /// Picks `option` from one of the editor's dropdowns.
    private func pick(_ option: String, in identifier: String) {
        app.element(identifier).tapSettled()
        app.buttons[option].firstMatch.tapSettled()
        XCTAssertTrue(app.element(identifier).waitForValue(option), "\(identifier) is \(option)")
    }

    /// Opens a form, checks the wheel, and cancels it.
    private func expectSuggestion(
        _ expected: Bool, category: String, description: String, amount: String, income: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        openExpenseForm(description: description, amount: amount, income: income)
        if expected {
            XCTAssertTrue(
                waitUntil { self.wheelValue.contains(category) }, "suggested \(category), wheel shows \(wheelValue)", file: file,
                line: line)
        } else {
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertFalse(wheelValue.contains(category), "no suggestion, wheel shows \(wheelValue)", file: file, line: line)
        }
        app.buttons["Cancel"].tapSettled()
        XCTAssertTrue(app.textFields["Amount"].waitForNonExistence(timeout: 10))
    }

    /// Edit a rule in place (pattern, category, a maximum), see the form
    /// suggest only under the maximum, switch the rule off (no suggestion)
    /// and on again, then make it Any type with a category both types have
    /// and see the income form take it too. Nothing is saved but the rule,
    /// which `tearDown` deletes.
    func testEditBoundsEnableAndAnyType() throws {
        let suffix = String(Int.random(in: 1000...9999))
        let merchant = "UIEdit \(suffix)"
        let edited = "UIEdited \(suffix)"
        let description = "uiedited \(suffix) cafe"
        cleanUp = {
            self.openTagsAndRules()
            for name in [merchant, edited] {
                let delete = self.app.buttons["Delete rule \(name)"]
                if delete.exists {
                    self.reveal(delete)
                    delete.tapSettled()
                    XCTAssertTrue(delete.waitForNonExistence(timeout: 5), "rule \(name) deleted")
                }
            }
        }

        // A plain rule (Expense, Contains, the first category).
        openTagsAndRules()
        app.buttons["rules.add"].tapSettled()
        let pattern = app.textFields["Merchant text"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 5))
        pattern.typeSettled(merchant)
        app.buttons["rules.editor.submit"].tapSettled()
        XCTAssertTrue(pattern.waitForNonExistence(timeout: 10), "rule dialog closed")
        let row = app.labelled(exactly: merchant)
        reveal(row)

        // Edit it: prefilled, Save, in place under the new text.
        row.tapSettled()
        XCTAssertTrue(app.labelled(exactly: "Edit merchant rule").waitForExistence(timeout: 5))
        XCTAssertEqual(pattern.value as? String, merchant)
        XCTAssertEqual(app.buttons["rules.editor.submit"].label, "Save")
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 1), "an edit does not autofocus")
        pattern.tapSettled()
        pattern.typeSettled(String(repeating: XCUIKeyboardKey.delete.rawValue, count: merchant.count) + edited + "\n")
        pick("Eating Out", in: "rules.editor.category")
        let maximum = app.textFields["Maximum amount"]
        maximum.tapSettled()
        maximum.typeSettled("20")
        app.buttons["rules.editor.submit"].tapSettled()
        XCTAssertTrue(pattern.waitForNonExistence(timeout: 10), "editor closed")
        let editedRow = app.labelled(exactly: edited)
        reveal(editedRow)
        let subtitle = editedRow.value as? String ?? ""
        XCTAssertTrue(subtitle.hasPrefix("contains \u{00B7} Eating Out \u{00B7} up to "), subtitle)
        XCTAssertFalse(app.labelled(exactly: merchant).exists, "edited in place, no second row")

        // Only amounts up to the maximum (inclusive) get the suggestion.
        expectSuggestion(false, category: "Eating Out", description: description, amount: "25")
        expectSuggestion(true, category: "Eating Out", description: description, amount: "20")

        // Switched off: dimmed "off", no suggestion.
        openTagsAndRules()
        let toggle = ruleSwitch(edited)
        reveal(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tapSettled()
        XCTAssertTrue(toggle.waitForValue("0"), "switched off")
        XCTAssertTrue(editedRow.waitUntil("value ENDSWITH %@", ["\u{00B7} off"]), "subtitle says off")
        expectSuggestion(false, category: "Eating Out", description: description, amount: "12")

        // On again, then Any type with Gift (both types have it).
        openTagsAndRules()
        reveal(toggle)
        toggle.tapSettled()
        XCTAssertTrue(toggle.waitForValue("1"), "switched on")
        reveal(editedRow)
        editedRow.tapSettled()
        XCTAssertTrue(app.labelled(exactly: "Edit merchant rule").waitForExistence(timeout: 5))
        XCTAssertEqual(maximum.value as? String, "20.00", "the maximum prefilled")
        pick("Any type", in: "rules.editor.type")
        XCTAssertEqual(app.element("rules.editor.category").value as? String, "Eating Out", "kept: the Any list has it")
        XCTAssertTrue(app.element("rules.editor.anyTypeNote").exists, "Eating Out is expense-only")
        pick("Gift", in: "rules.editor.category")
        XCTAssertFalse(app.element("rules.editor.anyTypeNote").exists, "Gift is in both lists")
        app.buttons["rules.editor.submit"].tapSettled()
        XCTAssertTrue(pattern.waitForNonExistence(timeout: 10), "editor closed")
        reveal(editedRow)
        XCTAssertTrue(
            editedRow.waitUntil("value BEGINSWITH %@", ["contains \u{00B7} Gift \u{00B7} any type \u{00B7} up to "]),
            editedRow.value as? String ?? "")
        expectSuggestion(true, category: "Gift", description: description, amount: "12", income: true)
        expectSuggestion(true, category: "Gift", description: description, amount: "12")
    }
}
