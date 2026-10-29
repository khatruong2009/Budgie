import XCTest

extension AccessibilityAuditUITests {
    // MARK: - Seed and clean up

    /// Rows, a tag, a budget, an account and a goal, through the UI.
    func seed() {
        seeded = true
        app.showDollarAmounts()
        app.addTransaction(amount: "42.50", description: "\(suffix) groceries", category: "Groceries")
        app.addTransaction(income: true, amount: "900", description: "\(suffix) pay")
        app.addTransaction(amount: "18", description: "\(suffix) older", category: "Health", monthsAgo: 1)

        // A tag.
        app.goToHomeRoot()
        app.openSettings()
        app.buttons["settings.tagsRules"].tapSettled()
        app.buttons["tags.add"].tapSettled()
        let name = app.textFields["Tag name"]
        if expect(name, "the tag dialog") {
            name.typeSettled(tag)
            app.buttons["tags.editor.submit"].tapSettled()
            _ = name.waitForNonExistence(timeout: 10)
        }

        // A budget.
        app.goToHomeRoot()
        let add = app.buttons["home.budgets.add"]
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp() }
        add.tapSettled()
        let tile = app.buttons["budgets.picker.Entertainment"]
        if expect(tile, "the Add a budget picker") {
            tile.tapSettled()
            let field = app.textFields["budgets.limit.field"]
            if expect(field, "the limit sheet") {
                field.enterText("75")
                field.typeText("\n")
                _ = field.waitForNonExistence(timeout: 10)
            }
        }

        // An account.
        app.goToTabRoot("Worth", marker: "worth.add")
        let emptyAdd = app.buttons["worth.empty.add"]
        (emptyAdd.waitForExistence(timeout: 2) ? emptyAdd : app.buttons["worth.add"]).tapSettled()
        if expect(app.element("worth.editor"), "the account editor") {
            app.textFields["Account name"].enterText(asset)
            app.textFields["Asset balance"].enterText("1500")
            app.buttons["worth.editor.save"].tapSettled()
            _ = app.element("worth.editor").waitForNonExistence(timeout: 10)
        }

        // A goal.
        app.goToTabRoot("Goals", marker: "goals.fab")
        app.buttons["goals.fab"].tapSettled()
        let goalName = app.textFields["Goal name"]
        if expect(goalName, "the goal form") {
            goalName.enterText(goal)
            app.textFields["Target amount"].enterText("500")
            app.buttons["goals.form.submit"].tapSettled()
            _ = goalName.waitForNonExistence(timeout: 10)
        }
        app.goToHomeRoot()
    }

    /// Removes everything `seed` added; each part only if it is there.
    func cleanUp() {
        // Each part starts from a freshly launched app, so a dialog or page
        // left over from the one before cannot get in its way.
        // Goal.
        app.goToTabRoot("Goals", marker: "goals.fab")
        while app.buttons["goals.card.more"].waitForExistence(timeout: 2) {
            app.buttons["goals.card.more"].firstMatch.tapSettled()
            app.buttons["goals.actions.delete"].tapSettled()
            let confirm = app.buttons["goals.delete.confirm"]
            if !confirm.waitForExistence(timeout: 5) { break }
            confirm.tapSettled()
            _ = confirm.waitForNonExistence(timeout: 5)
        }

        // Account.
        launch()
        app.goToTabRoot("Worth", marker: "worth.add")
        for toggle in ["worth.toggle.assets", "worth.toggle.liabilities"] {
            guard app.buttons[toggle].waitForExistence(timeout: 2) else { continue }
            app.buttons[toggle].tapSettled()
            let row = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'worth.account.' AND identifier CONTAINS %@", suffix)).firstMatch
            while row.waitForExistence(timeout: 2) {
                let tabBar = app.tabBars.firstMatch
                for _ in 0..<3 where row.frame.maxY > tabBar.frame.minY { app.swipeUp() }
                row.press(forDuration: 1.0)
                let delete = app.buttons["Delete Account"]
                guard delete.waitForExistence(timeout: 5) else { break }
                delete.tap()
                let confirm = app.alerts["Delete account?"].buttons["Delete"]
                if confirm.waitForExistence(timeout: 5) {
                    confirm.tap()
                    _ = confirm.waitForNonExistence(timeout: 5)
                }
            }
        }

        // Budget.
        launch()
        app.goToHomeRoot()
        let budgetRow = app.buttons["home.budgets.row.Entertainment"]
        if budgetRow.waitForExistence(timeout: 3) {
            for _ in 0..<6 where !(budgetRow.exists && budgetRow.isHittable) { app.swipeUp() }
            budgetRow.tapSettled()
            let remove = app.buttons["budgets.limit.remove"]
            if remove.waitForExistence(timeout: 10) {
                remove.tapSettled()
                _ = budgetRow.waitForNonExistence(timeout: 10)
            }
        }

        // Rows.
        launch()
        app.deleteTransactions(containing: suffix)

        // Tag.
        launch()
        app.openSettings()
        app.buttons["settings.tagsRules"].tapSettled()
        let deleteTag = app.buttons["Delete \(tag)"]
        if deleteTag.waitForExistence(timeout: 5) {
            for _ in 0..<6 where !deleteTag.isHittable { app.swipeUp() }
            deleteTag.tapSettled()
            app.buttons["tags.delete.confirm"].tapSettled()
            _ = deleteTag.waitForNonExistence(timeout: 10)
        }
        app.goToHomeRoot()
    }
}
