import XCTest

extension AccessibilityAuditUITests {
    func auditHome() {
        step("Home", main: true) {
            app.goToHomeRoot()
            guard expect(app.buttons["home.settings"], "Home") else { return false }
            auditTopAndBottom("Home")
            return true
        }
    }

    func auditHomeSheets() {
        // The month panel.
        step("Home month panel", main: true) {
            app.goToHomeRoot()
            let pill = app.buttons["home.monthPill"]
            guard press(pill, "pill") else { return false }
            guard expect(app.element("home.monthPanel.year"), "the month panel") else { return false }
            runner.audit("Home month panel")
            guard press(pill, "pill") else { return false }
            return app.element("home.monthPanel.year").waitForNonExistence(timeout: 5)
        }

        // Safe to spend.
        step("Safe to spend sheet", main: true) {
            app.goToHomeRoot()
            let card = app.buttons["home.safeToSpend"]
            guard expect(card, "the safe-to-spend card") else { return false }
            guard press(card, "card") else { return false }
            let income = app.labelled(containing: "Income recorded, ")
            guard expect(income, "the breakdown sheet") else { return false }
            runner.audit("Safe to spend sheet")
            dragSheetDown(from: income)
            return income.waitForNonExistence(timeout: 10)
        }

        // The budget pickers and the limit sheet.
        step("Budget pickers and limit sheet") {
            app.goToHomeRoot()
            let edit = app.buttons["Edit, Budgets"]
            for _ in 0..<6 where !(edit.exists && edit.isHittable) { app.swipeUp() }
            guard expect(edit, "Edit, Budgets") else { return false }
            guard press(edit, "edit") else { return false }
            let tile = app.buttons["budgets.picker.Entertainment"]
            guard expect(tile, "the Edit budgets picker") else { return false }
            runner.audit("Budget picker")
            guard press(tile, "tile") else { return false }
            let field = app.textFields["budgets.limit.field"]
            guard expect(field, "the limit sheet") else { return false }
            runner.audit("Budget limit sheet")
            // The field is focused on open: Return saves the unchanged limit.
            field.typeText("\n")
            return field.waitForNonExistence(timeout: 10)
        }

        // The quick-expense sheet.
        step("Quick expense sheet") {
            app.goToHomeRoot()
            app.buttons["Add transaction"].press(forDuration: 1.0)
            let choice = app.buttons["Choose Health"]
            guard expect(choice, "the quick-expense sheet") else { return false }
            runner.audit("Quick expense sheet")
            guard press(choice, "choice") else { return false }
            let cancel = app.buttons["Cancel"].firstMatch
            guard expect(cancel, "the expense form") else { return false }
            guard press(cancel, "cancel") else { return false }
            return app.textFields["Amount"].waitForNonExistence(timeout: 10)
        }

        // Home SEE ALL, the month strip and an edit form.
        step("Home SEE ALL", main: true) {
            app.goToHomeRoot()
            let seeAll = app.buttons["See all transactions"].firstMatch
            for _ in 0..<6 where !(seeAll.exists && seeAll.isHittable) { app.swipeUp() }
            guard expect(seeAll, "SEE ALL") else { return false }
            guard press(seeAll, "seeAll") else { return false }
            let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "\(suffix) groceries")).firstMatch
            guard expect(row, "a SEE ALL row") else { return false }
            runner.audit("Home SEE ALL")
            guard press(row, "row") else { return false }
            guard expect(app.staticTexts["Edit Expense"], "the edit form") else { return false }
            runner.audit("Edit Transaction form")
            // Delete Transaction sits under the bottom fade until the form is
            // scrolled to its end.
            app.element("form.category").swipeUp()
            guard expect(app.buttons["Delete Transaction"], "the delete button") else { return false }
            runner.audit("Edit form scrolled to its end")
            guard press(app.buttons["Cancel"].firstMatch, "app.buttons[\"Cancel\"].firstMatch") else { return false }
            _ = app.textFields["Amount"].waitForNonExistence(timeout: 10)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }
    }

    func auditTransactionForms() {
        step("Add Expense form", main: true) {
            app.goToHomeRoot()
            guard press(app.buttons["Add transaction"], "app.buttons[\"Add transaction\"]") else { return false }
            let amount = app.textFields["Amount"]
            guard expect(amount, "the Add Expense form") else { return false }
            runner.audit("Add Expense form")

            // The date picker.
            let date = app.buttons["Date"]
            if date.exists {
                guard press(date, "date") else { return false }
                if expect(app.buttons["datePicker.ok"], "the date picker") {
                    runner.audit("Date picker")
                    guard press(app.buttons["datePicker.cancel"], "app.buttons[\"datePicker.cancel\"]") else { return false }
                    _ = app.buttons["datePicker.ok"].waitForNonExistence(timeout: 5)
                }
            }

            // "Make this recurring" opens the recurring form.
            let recurring = app.buttons["Make this recurring"]
            if recurring.waitForExistence(timeout: 2) {
                if !recurring.isHittable { app.swipeUp() }
                guard press(recurring, "recurring") else { return false }
                if expect(app.element("recurring.form.title"), "the recurring form") {
                    runner.audit("Recurring form (from the transaction form)")
                    guard press(app.buttons["Cancel"].firstMatch, "app.buttons[\"Cancel\"].firstMatch") else { return false }
                    _ = app.element("recurring.form.title").waitForNonExistence(timeout: 5)
                }
            }
            // The recurring form's Cancel may close the whole sheet.
            if amount.exists, app.buttons["Cancel"].firstMatch.exists { app.buttons["Cancel"].firstMatch.tapSettled() }
            return amount.waitForNonExistence(timeout: 10)
        }

        step("Add Income form") {
            app.goToHomeRoot()
            guard press(app.buttons["Add transaction"], "app.buttons[\"Add transaction\"]") else { return false }
            let amount = app.textFields["Amount"]
            guard expect(amount, "the add form") else { return false }
            guard press(app.buttons["Income"].firstMatch, "app.buttons[\"Income\"].firstMatch") else { return false }
            runner.audit("Add Income form")
            guard press(app.buttons["Cancel"].firstMatch, "app.buttons[\"Cancel\"].firstMatch") else { return false }
            return amount.waitForNonExistence(timeout: 10)
        }
    }

    func auditWorth() {
        step("Worth", main: true) {
            app.goToTabRoot("Worth", marker: "worth.add")
            guard expect(app.element("worth.add"), "Worth") else { return false }
            auditTopAndBottom("Worth")
            return true
        }

        step("Worth account editor", main: true) {
            app.goToTabRoot("Worth", marker: "worth.add")
            guard press(app.buttons["worth.add"], "app.buttons[\"worth.add\"]") else { return false }
            let editor = app.element("worth.editor")
            guard expect(editor, "the account editor") else { return false }
            runner.audit("Worth account editor")
            guard press(app.buttons["worth.editor.month"], "app.buttons[\"worth.editor.month\"]") else { return false }
            let cell = editor.buttons[monthName("LLLL yyyy")]
            guard expect(cell, "the editor's month grid") else { return false }
            runner.audit("Worth editor month grid")
            guard press(cell, "cell") else { return false }
            _ = cell.waitForNonExistence(timeout: 5)
            guard press(app.buttons["worth.editor.cancel"], "app.buttons[\"worth.editor.cancel\"]") else { return false }
            return editor.waitForNonExistence(timeout: 5)
        }

        step("Worth account history") {
            app.goToTabRoot("Worth", marker: "worth.add")
            let row = app.element("worth.account.\(asset)")
            guard expect(row, "the seeded account") else { return false }
            let tabBar = app.tabBars.firstMatch
            for _ in 0..<3 where row.frame.maxY > tabBar.frame.minY { app.swipeUp() }
            row.press(forDuration: 1.0)
            let history = app.buttons["View History"]
            guard expect(history, "View History in the context menu") else { return false }
            history.tap()
            guard expect(app.element("worth.history.hero"), "the account history") else { return false }
            auditTopAndBottom("Worth account history")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }
    }

    func auditGoals() {
        step("Goals", main: true) {
            app.goToTabRoot("Goals", marker: "goals.fab")
            guard expect(app.element("goals.card"), "the goal card") else { return false }
            auditTopAndBottom("Goals")
            return true
        }

        step("Goal form", main: true) {
            app.goToTabRoot("Goals", marker: "goals.fab")
            guard press(app.buttons["goals.fab"], "app.buttons[\"goals.fab\"]") else { return false }
            let name = app.textFields["Goal name"]
            guard expect(name, "the goal form") else { return false }
            runner.audit("Goal form")
            guard press(app.buttons["goals.form.cancel"], "app.buttons[\"goals.form.cancel\"]") else { return false }
            return name.waitForNonExistence(timeout: 5)
        }

        step("Goal allocation dialog") {
            app.goToTabRoot("Goals", marker: "goals.fab")
            guard press(app.buttons["goals.card.addMoney"].firstMatch, "app.buttons[\"goals.card.addMoney\"].firstMatch") else { return false }
            let amount = app.textFields["Allocation amount"]
            guard expect(amount, "the Add money dialog") else { return false }
            runner.audit("Goal allocation dialog")
            guard press(app.buttons["goals.allocate.cancel"], "app.buttons[\"goals.allocate.cancel\"]") else { return false }
            return amount.waitForNonExistence(timeout: 5)
        }

        step("Goal actions sheet and delete dialog") {
            app.goToTabRoot("Goals", marker: "goals.fab")
            guard press(app.buttons["goals.card.more"].firstMatch, "app.buttons[\"goals.card.more\"].firstMatch") else { return false }
            let delete = app.buttons["goals.actions.delete"]
            guard expect(delete, "the goal actions sheet") else { return false }
            runner.audit("Goal actions sheet")
            guard press(delete, "delete") else { return false }
            let cancel = app.buttons["goals.delete.cancel"]
            guard expect(cancel, "the delete dialog") else { return false }
            runner.audit("Goal delete dialog")
            guard press(cancel, "cancel") else { return false }
            return cancel.waitForNonExistence(timeout: 5)
        }
    }

    func auditSpend() {
        step("Spend", main: true) {
            app.goToTabRoot("Spend", marker: "spend.donut")
            guard expect(app.element("spend.donut"), "the donut") else { return false }
            auditTopAndBottom("Spend")
            return true
        }

        step("Spend month sheet", main: true) {
            app.goToTabRoot("Spend", marker: "spend.donut")
            guard press(app.buttons["spend.monthPill"], "app.buttons[\"spend.monthPill\"]") else { return false }
            guard expect(app.element("spend.monthSheet"), "the month sheet") else { return false }
            runner.audit("Spend month sheet")
            let current = app.buttons["spend.month.\(monthName("yyyy-MM"))"]
            guard press(current, "current") else { return false }
            return current.waitForNonExistence(timeout: 5)
        }

        step("Spend drill-in") {
            app.goToTabRoot("Spend", marker: "spend.donut")
            let row = app.buttons["spend.row.0"]
            guard expect(row, "a category row") else { return false }
            guard press(row, "row") else { return false }
            guard expect(app.element("spend.drillIn.summary"), "the drill-in") else { return false }
            auditTopAndBottom("Spend drill-in")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }
    }

    func auditFlow() {
        step("Flow", main: true) {
            app.goToTabRoot("Flow", marker: "flow.rangePill")
            guard expect(app.buttons["flow.rangePill"], "Flow") else { return false }
            auditTopAndBottom("Flow")
            return true
        }

        step("Flow range sheet") {
            app.goToTabRoot("Flow", marker: "flow.rangePill")
            guard press(app.buttons["flow.rangePill"], "app.buttons[\"flow.rangePill\"]") else { return false }
            let six = app.buttons["flow.range.6"]
            guard expect(six, "the range sheet") else { return false }
            runner.audit("Flow range sheet")
            guard press(six, "six") else { return false }
            return six.waitForNonExistence(timeout: 5)
        }

        step("Flow month detail", main: true) {
            app.goToTabRoot("Flow", marker: "flow.rangePill")
            let bar = app.element("flow.bar.\(monthName("yyyy-MM"))")
            guard expect(bar, "this month's bar") else { return false }
            guard press(bar, "bar") else { return false }
            let detail = app.element("flow.monthDetail")
            guard expect(detail, "the month detail sheet") else { return false }
            runner.audit("Flow month detail")
            let top = detail.frame.minY
            let handle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: max(0.05, (top - 8) / app.frame.height)))
            handle.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
            return detail.waitForNonExistence(timeout: 10)
        }

        step("Flow SEE ALL", main: true) {
            app.goToTabRoot("Flow", marker: "flow.rangePill")
            let seeAll = app.buttons["See all transactions"].firstMatch
            for _ in 0..<6 where !(seeAll.exists && seeAll.isHittable) { app.swipeUp() }
            guard expect(seeAll, "SEE ALL") else { return false }
            guard press(seeAll, "seeAll") else { return false }
            let search = app.textFields["flow.all.search"]
            guard expect(search, "Flow SEE ALL") else { return false }
            runner.audit("Flow SEE ALL")

            // Tag chips and the month and category pickers.
            let category = app.buttons["flow.all.category"]
            guard press(category, "category") else { return false }
            let option = app.buttons.matching(identifier: "flow.all.option").firstMatch
            if expect(option, "the category sheet") {
                runner.audit("Flow SEE ALL category sheet")
                guard press(option, "option") else { return false }
                _ = option.waitForNonExistence(timeout: 5)
            }
            let month = app.buttons["flow.all.month"]
            guard press(month, "month") else { return false }
            let monthOption = app.buttons.matching(identifier: "flow.all.option").firstMatch
            if expect(monthOption, "the month sheet") {
                runner.audit("Flow SEE ALL month sheet")
                guard press(monthOption, "monthOption") else { return false }
                _ = monthOption.waitForNonExistence(timeout: 5)
            }

            // Filters in use: RESET shows.
            search.enterText(suffix)
            guard expect(app.buttons["flow.all.reset"], "RESET") else { return false }
            runner.audit("Flow SEE ALL filtered")
            guard press(app.buttons["flow.all.reset"], "app.buttons[\"flow.all.reset\"]") else { return false }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }
    }

    func auditSettings() {
        step("Settings", main: true) {
            app.openSettings()
            guard expect(app.element("settings.theme"), "Settings") else { return false }
            auditTopAndBottom("Settings")
            return true
        }

        step("Settings currency and number format sheets") {
            app.openSettings()
            let currency = app.buttons["settings.currency"]
            guard press(currency, "currency") else { return false }
            let dollar = app.buttons["US Dollar"]
            guard expect(dollar, "the currency sheet") else { return false }
            runner.audit("Currency sheet")
            guard press(dollar, "dollar") else { return false }
            _ = dollar.waitForNonExistence(timeout: 5)
            let format = app.buttons["settings.numberFormat"]
            guard press(format, "format") else { return false }
            let choice = app.buttons["Match device"]
            guard expect(choice, "the number format sheet") else { return false }
            runner.audit("Number format sheet")
            guard press(choice, "choice") else { return false }
            _ = choice.waitForNonExistence(timeout: 5)
            return true
        }

        step("Categories") {
            guard openSettingsPage("settings.categories", marker: app.element("categories.list")) else { return false }
            auditTopAndBottom("Categories")
            guard press(app.buttons["categories.add"], "app.buttons[\"categories.add\"]") else { return false }
            let name = app.buttons["categories.editor.cancel"]
            if expect(name, "the category editor") {
                runner.audit("Category editor")
                guard press(app.buttons["categories.editor.cancel"], "app.buttons[\"categories.editor.cancel\"]") else { return false }
                _ = name.waitForNonExistence(timeout: 5)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }

        step("Tags & rules") {
            guard openSettingsPage("settings.tagsRules", marker: app.element("tagsRules.list")) else { return false }
            auditTopAndBottom("Tags & rules")
            guard press(app.buttons["tags.add"], "app.buttons[\"tags.add\"]") else { return false }
            let name = app.textFields["Tag name"]
            if expect(name, "the tag dialog") {
                runner.audit("Tag dialog")
                guard press(app.buttons["tags.editor.cancel"], "app.buttons[\"tags.editor.cancel\"]") else { return false }
                _ = name.waitForNonExistence(timeout: 5)
            }
            guard press(app.buttons["rules.add"], "app.buttons[\"rules.add\"]") else { return false }
            let pattern = app.textFields["Merchant text"]
            if expect(pattern, "the rule editor") {
                runner.audit("Rule editor")
                guard press(app.buttons["rules.editor.cancel"], "app.buttons[\"rules.editor.cancel\"]") else { return false }
                _ = pattern.waitForNonExistence(timeout: 5)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }

        step("Recurring") {
            guard openSettingsPage("settings.recurring", marker: app.staticTexts["Recurring Transactions"]) else { return false }
            runner.audit("Recurring")
            let add = app.buttons["recurring.add"]
            let emptyAdd = app.buttons["recurring.empty.add"]
            guard press(add.exists ? add : emptyAdd, "the add button") else { return false }
            if expect(app.element("recurring.form.title"), "the recurring form") {
                runner.audit("Recurring form")
                guard press(app.buttons["Cancel"].firstMatch, "app.buttons[\"Cancel\"].firstMatch") else { return false }
                _ = app.element("recurring.form.title").waitForNonExistence(timeout: 5)
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }

        step("Data diagnostics") {
            guard openSettingsPage("settings.diagnostics", marker: app.staticTexts["Unreadable rows kept"]) else { return false }
            runner.audit("Data diagnostics")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }

        step("Licences") {
            guard openSettingsPage("settings.licences", marker: app.navigationBars["Licences"]) else { return false }
            auditTopAndBottom("Licences")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            return true
        }
    }

    /// Opens Settings (from wherever) and taps a row, scrolling to it.
    private func openSettingsPage(_ row: String, marker: XCUIElement) -> Bool {
        app.openSettings()
        let button = app.buttons[row]
        for _ in 0..<6 where !(button.exists && button.isHittable) { app.swipeUp() }
        guard expect(button, "the \(row) row") else { return false }
        guard press(button, "button") else { return false }
        return expect(marker, "the page of \(row)")
    }
}
