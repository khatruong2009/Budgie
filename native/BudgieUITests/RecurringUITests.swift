import XCTest

/// Settings > Recurring transactions end to end: the empty state and
/// "Generate Due Transactions", the form's validation and "Next 3
/// Occurrences" preview for a monthly expense and a weekly income, the
/// recurrence glyph on the generated rows (Home Recent activity, Home SEE
/// ALL, Flow SEE ALL), pause / resume, an edit that keeps the next
/// occurrence, "Make this recurring" from the transaction form (a deep
/// link's and the FAB's), and delete behind Flutter's alert. Names carry a
/// per-run suffix; the templates and their generated rows are deleted at
/// the end.
@MainActor
final class RecurringUITests: XCTestCase {
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private let suffix = String(Int.random(in: 1000...9999))
    private var rent: String { "UI rent \(suffix)" }
    private var salary: String { "UI weekly \(suffix)" }
    private var madeRecurring: String { "UI made recurring \(suffix)" }

    override func setUp() async throws {
        continueAfterFailure = false
        app.budgie(homeTimeout: 30)
    }

    // MARK: - Helpers

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tapSettled()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeSettled(text)
    }

    private func openRecurring() {
        app.goToHomeRoot()
        app.buttons["home.settings"].tapSettled()
        app.buttons["settings.recurring"].tapSettled()
        XCTAssertTrue(app.buttons["recurring.add"].waitForExistence(timeout: 10))
    }

    /// The card whose summary mentions `text`.
    private func card(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "recurring.card")
            .containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func summary(_ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'recurring.summary' AND label CONTAINS %@", text)).firstMatch
    }

    private func wheel(_ identifier: String, index: Int) -> XCUIElement {
        let byID = app.pickerWheels[identifier]
        return byID.exists ? byID : app.pickerWheels.element(boundBy: index)
    }

    // MARK: Dates (Flutter's arithmetic on the device clock)

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// `DateTime(y, m + months, min(day, daysInMonth))`.
    private static func monthly(from date: Date, months: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let first = calendar.date(byAdding: .month, value: months, to: calendar.date(from: calendar.dateComponents([.year, .month], from: date))!)!
        let days = calendar.range(of: .day, in: .month, for: first)!.count
        var parts = calendar.dateComponents([.year, .month], from: first)
        parts.day = min(day, days)
        return calendar.date(from: parts)!
    }

    // MARK: - Test

    func testRecurringFlow() throws {
        let now = Date()
        let today = Calendar.current.component(.day, from: now)
        let monthlyDates = [now, Self.monthly(from: now, months: 1, day: today), Self.monthly(from: now, months: 2, day: today)]
        let weeklyDates = [now, now.addingTimeInterval(7 * 86_400), now.addingTimeInterval(14 * 86_400)]

        openRecurring()

        // Empty state (a fresh install; a rerun may already have cards).
        if app.element("recurring.empty").exists {
            XCTAssertTrue(app.staticTexts["No Recurring Transactions"].exists)
            XCTAssertTrue(app.labelled(containing: "Create recurring transactions to automatically").exists)
        }

        // Generate Due Transactions: Flutter's toast even with nothing due.
        app.buttons["recurring.generate"].tapSettled()
        XCTAssertTrue(app.labelled(containing: "Due transactions generated and next occurrences updated").waitForExistence(timeout: 10))

        // Add a monthly expense: validation first.
        app.buttons["recurring.add"].tapSettled()
        XCTAssertTrue(app.staticTexts["Add Recurring Expense"].waitForExistence(timeout: 10))
        app.buttons["recurring.form.save"].tapSettled()
        XCTAssertTrue(app.staticTexts["Amount is required"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Description is required"].exists)
        let amount = app.textFields["Amount"]
        replaceText(in: amount, with: "0")
        XCTAssertFalse(app.staticTexts["Amount is required"].exists, "typing clears the amount error")
        app.buttons["recurring.form.save"].tapSettled()
        XCTAssertTrue(app.staticTexts["Amount must be greater than 0"].waitForExistence(timeout: 5))
        replaceText(in: amount, with: "900")
        replaceText(in: app.textFields["Description"], with: rent)
        XCTAssertFalse(app.staticTexts["Description is required"].exists, "typing clears the description error")
        XCTAssertTrue(app.element("recurring.form.day").exists, "monthly shows the Day of Month wheel")
        let preview = app.element("recurring.form.preview")
        XCTAssertTrue(preview.exists)
        for date in monthlyDates {
            let line = Self.format(date, "EEEE, MMM dd, yyyy")
            XCTAssertTrue(preview.label.contains(line), "monthly preview has \(line): \(preview.label)")
        }
        app.buttons["recurring.form.save"].tapSettled()
        // Today's occurrence is generated at once; the cursor moves a month.
        let rentNext = Self.format(monthlyDates[1], "MMM dd, yyyy")
        XCTAssertTrue(summary(rent).waitForExistence(timeout: 10))
        XCTAssertTrue(summary(rent).label.contains("Monthly"), summary(rent).label)
        XCTAssertTrue(summary(rent).label.contains("next occurrence \(rentNext)"), summary(rent).label)

        // Add a weekly income: the type toggle, the pattern wheel, its preview.
        app.buttons["recurring.add"].tapSettled()
        XCTAssertTrue(app.staticTexts["Add Recurring Expense"].waitForExistence(timeout: 10))
        app.buttons["Income"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Recurring Income"].waitForExistence(timeout: 5))
        replaceText(in: app.textFields["Amount"], with: "50")
        replaceText(in: app.textFields["Description"], with: salary)
        // The pattern wheel is the form's first (the category is a menu row).
        wheel("recurring.form.pattern", index: 0).adjust(toPickerWheelValue: "Weekly")
        XCTAssertTrue(app.element("recurring.form.day").waitForNonExistence(timeout: 5), "no Day of Month for weekly")
        for date in weeklyDates {
            let line = Self.format(date, "EEEE, MMM dd, yyyy")
            XCTAssertTrue(preview.label.contains(line), "weekly preview has \(line): \(preview.label)")
        }
        app.buttons["recurring.form.save"].tapSettled()
        let salaryNext = Self.format(weeklyDates[1], "MMM dd, yyyy")
        XCTAssertTrue(summary(salary).waitForExistence(timeout: 10))
        XCTAssertTrue(summary(salary).label.contains("Weekly"), summary(salary).label)
        XCTAssertTrue(summary(salary).label.contains("income"), summary(salary).label)
        XCTAssertTrue(summary(salary).label.contains("next occurrence \(salaryNext)"), summary(salary).label)

        // Pause, then resume.
        card(rent).buttons["recurring.pause"].tapSettled()
        XCTAssertTrue(summary("\(rent)").waitForExistence(timeout: 5))
        let paused = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'recurring.summary' AND label CONTAINS %@ AND label CONTAINS 'paused'", rent)
        ).firstMatch
        XCTAssertTrue(paused.waitForExistence(timeout: 5), "paused")
        XCTAssertEqual(card(rent).buttons["recurring.pause"].label, "Resume")
        card(rent).buttons["recurring.pause"].tapSettled()
        XCTAssertTrue(paused.waitForNonExistence(timeout: 5), "resumed")

        // Edit: Flutter's title and prefill; the next occurrence is kept.
        card(rent).buttons["recurring.edit"].tapSettled()
        XCTAssertTrue(app.staticTexts["Edit Recurring Expense"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["recurring.form.save"].label, "Update")
        XCTAssertEqual(app.textFields["Amount"].value as? String, "900.00")
        XCTAssertFalse(app.buttons["Income"].exists, "no type toggle when editing")
        XCTAssertTrue(preview.label.contains(Self.format(monthlyDates[1], "EEEE, MMM dd, yyyy")), "edit previews from the cursor")
        let edited = "UI rent edited \(suffix)"
        replaceText(in: app.textFields["Description"], with: edited)
        app.buttons["recurring.form.save"].tapSettled()
        XCTAssertTrue(summary(edited).waitForExistence(timeout: 10))
        XCTAssertTrue(summary(edited).label.contains("next occurrence \(rentNext)"), summary(edited).label)

        // "Make this recurring" turns the transaction form into the recurring
        // form for the form's type, in the same sheet: Cancel closes all of
        // it, also for a deep link's form (AddFormHost); Save adds the
        // template and closes it.
        app.goToHomeRoot()
        XCUIDevice.shared.system.open(URL(string: "budgetapp://add-income")!)
        let openPrompt = springboard.buttons["Open"]
        if openPrompt.waitForExistence(timeout: 3) { openPrompt.tap() }
        XCTAssertTrue(app.staticTexts["Add Income"].waitForExistence(timeout: 10))
        app.buttons["Make this recurring"].tapSettled()
        XCTAssertTrue(app.staticTexts["Add Recurring Income"].waitForExistence(timeout: 10))
        app.buttons["Cancel"].firstMatch.tapSettled()
        XCTAssertTrue(app.staticTexts["Add Recurring Income"].waitForNonExistence(timeout: 10), "the deep link's sheet closed")
        XCTAssertFalse(app.staticTexts["Add Income"].exists)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))

        app.buttons["Add transaction"].tapSettled()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForExistence(timeout: 10))
        app.buttons["Make this recurring"].tapSettled()
        XCTAssertTrue(app.staticTexts["Add Recurring Expense"].waitForExistence(timeout: 10))
        replaceText(in: app.textFields["Amount"], with: "15")
        replaceText(in: app.textFields["Description"], with: madeRecurring)
        app.buttons["recurring.form.save"].tapSettled()
        XCTAssertTrue(app.staticTexts["Add Recurring Expense"].waitForNonExistence(timeout: 10), "the sheet closed after Save")
        XCTAssertFalse(app.staticTexts["Add Expense"].exists)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))
        openRecurring()
        XCTAssertTrue(summary(madeRecurring).waitForExistence(timeout: 10))
        XCTAssertTrue(summary(madeRecurring).label.contains("Monthly"), summary(madeRecurring).label)

        // The generated rows carry the glyph: Home Recent activity and SEE ALL.
        app.goToHomeRoot()
        let recent = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND value CONTAINS 'recurring'", salary)).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "Home recent row marked recurring")
        app.buttons["See all transactions"].firstMatch.tapSettled()
        let seeAllRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS 'recurring'", rent)).firstMatch
        XCTAssertTrue(seeAllRow.waitForExistence(timeout: 10), "Home SEE ALL row marked recurring")

        // Delete both templates behind Flutter's alert.
        openRecurring()
        for name in [edited, salary, madeRecurring] {
            card(name).buttons["recurring.delete"].tapSettled()
            let alert = app.alerts["Delete Recurring Transaction?"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            let message =
                "This will stop generating future transactions for \"\(name)\". Previously generated transactions will not be affected."
            // By predicate: an identifier query is limited to 128 characters.
            XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label == %@", message)).firstMatch.exists, "alert message")
            alert.buttons["Delete"].tap()
            XCTAssertTrue(app.labelled(containing: "Recurring transaction deleted").waitForExistence(timeout: 10))
            XCTAssertTrue(summary(name).waitForNonExistence(timeout: 5))
        }

        // Flow SEE ALL: the rows (kept after the delete) are marked; then
        // delete them so a rerun starts clean.
        app.tabBars.buttons["Flow"].tap()
        let seeAll = app.buttons["See all transactions"].firstMatch
        XCTAssertTrue(seeAll.waitForExistence(timeout: 10))
        if !seeAll.isHittable { app.swipeUp() }
        seeAll.tap()
        let search = app.textFields["flow.all.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.enterText(suffix)
        let rows = app.buttons.matching(identifier: "flow.all.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 3)
        for index in 0..<rows.count {
            XCTAssertTrue(rows.element(boundBy: index).label.hasSuffix(", recurring"), rows.element(boundBy: index).label)
        }
        for _ in 0..<3 {
            let row = rows.firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            // The row starts under the search keyboard (a swipe there
            // swipe-types): drag the list up above it first.
            if !row.isHittable {
                let window = app.windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
            }
            XCTAssertTrue(row.isHittable, "the row is above the keyboard")
            row.swipeLeft()
            let alert = app.alerts["Delete Transaction"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            alert.buttons["Delete"].tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
        }
        XCTAssertTrue(app.element("flow.all.empty").waitForExistence(timeout: 10))
    }
}
