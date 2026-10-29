import XCTest

// Typing and tapping that survive the software keyboard coming back.
//
// XCTest types through a virtual hardware keyboard that it attaches for each
// `typeText` and detaches afterwards. While it is attached UIKit minimises the
// software keyboard; about a second after it detaches (longer under load)
// UIKit shows the software keyboard again, and every sheet footer and centred
// dialog above it moves up by the keyboard's height. A plain `tap()` resolves
// its point from a snapshot and delivers the touch later, so a tap resolved
// while the keyboard was minimised and delivered after it came back landed on
// the keyboard (the form's Add became a space after "coffee", or a "9" in the
// amount) or, under a dialog, on its scrim. So every typing step here waits for
// the keyboard to come back and settle, and `tapSettled` waits for the keyboard
// and for its element to be hittable and still.

@MainActor
extension XCUIElement {
    /// Taps this field once it has settled, then types `text` into it.
    func enterText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        tapSettled(file: file, line: line)
        typeSettled(text)
    }

    /// Types `text` into this (focused) field, then waits for the software
    /// keyboard to come back and settle.
    func typeSettled(_ text: String) {
        typeText(text)
        waitForKeyboardToSettle()
    }

    /// Taps once the keyboard has settled and this element exists, is
    /// hittable and has stopped moving (a sheet or dialog entrance, or the
    /// keyboard, moves it).
    func tapSettled(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(exists || waitForExistence(timeout: timeout), "\(self) exists", file: file, line: line)
        waitForKeyboardToSettle()
        let deadline = Date().addingTimeInterval(timeout)
        var last = CGRect.null
        while Date() < deadline {
            let current = frame
            if isHittable && current == last { break }
            last = current
            Thread.sleep(forTimeInterval: 0.2)
        }
        tap()
    }
}

/// Waits until there is no software keyboard, or it is on screen and has
/// stopped moving. A keyboard that exists below the screen is minimised for
/// XCTest's virtual hardware keyboard and about to come back; after
/// `timeout` (a keyboard that stays minimised) the caller goes on.
@MainActor
private func waitForKeyboardToSettle(timeout: TimeInterval = 5) {
    let app = XCUIApplication()
    let keyboard = app.keyboards.firstMatch
    let deadline = Date().addingTimeInterval(timeout)
    var last = CGRect.null
    while Date() < deadline {
        guard keyboard.exists else { return }
        let frame = keyboard.frame
        if frame.minY < app.frame.maxY && frame == last { return }
        last = frame
        Thread.sleep(forTimeInterval: 0.2)
    }
}

// MARK: - Shared screen helpers

@MainActor
extension XCUIApplication {
    /// Launches past the onboarding tour and waits for the Home tab. Launch
    /// environment additions go before this call.
    func budgie(homeTimeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        launchEnvironment["BUDGIE_SKIP_ONBOARDING"] = "1"
        launch()
        XCTAssertTrue(tabBars.buttons["Home"].waitForExistence(timeout: homeTimeout), "Home tab", file: file, line: line)
    }

    /// Opens `link` through the system, accepting its "Open in Budgie?"
    /// prompt when one appears.
    func route(_ link: String, file: StaticString = #filePath, line: UInt = #line) {
        XCUIDevice.shared.system.open(URL(string: link)!)
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(wait(for: .runningForeground, timeout: 10), "app not in front after \(link)", file: file, line: line)
    }

    /// Any element with the identifier: cards, bars and rows are custom
    /// elements, not buttons.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier]
    }

    /// The first element whose label contains `text` (Home's rows are
    /// combined accessibility elements, not buttons).
    func labelled(containing text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The first element whose label is exactly `text`.
    func labelled(exactly text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    /// Home's root page, popping anything pushed on the Home tab.
    func goToHomeRoot() {
        tabBars.buttons["Home"].tap()
        var pops = 0
        while !buttons["home.settings"].waitForExistence(timeout: 1) && pops < 4 {
            navigationBars.buttons.element(boundBy: 0).tap()
            pops += 1
        }
    }

    /// A tab's root page: selects the tab, then pops pushed pages until
    /// `marker` (an identifier that only the root has) shows.
    func goToTabRoot(_ tab: String, marker: String) {
        tabBars.buttons[tab].tap()
        var pops = 0
        while !element(marker).waitForExistence(timeout: 1) && pops < 4 {
            navigationBars.buttons.element(boundBy: 0).tap()
            pops += 1
        }
    }

    /// Deletes every transaction whose description contains `text` through
    /// Flow's SEE ALL (search, swipe left, confirm). The search keyboard
    /// stays up, and a row under it cannot be swiped (the swipe types into
    /// the field), so the list is first dragged up above the keyboard.
    func deleteTransactions(containing text: String, file: StaticString = #filePath, line: UInt = #line) {
        goToTabRoot("Flow", marker: "flow.rangePill")
        let seeAll = buttons["See all transactions"].firstMatch
        if !seeAll.isHittable { swipeUp() }
        seeAll.tapSettled(file: file, line: line)
        let search = textFields["flow.all.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10), "Flow SEE ALL", file: file, line: line)
        search.enterText(text)
        let rows = buttons.matching(identifier: "flow.all.row")
        while rows.firstMatch.waitForExistence(timeout: 3) {
            let row = rows.firstMatch
            if !row.isHittable {
                let window = windows.firstMatch
                window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
                    .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
            }
            let confirm = alerts["Delete Transaction"].buttons["Delete"]
            // A swipe that lands while the keyboard is still settling can be
            // lost: try again.
            for _ in 0..<3 {
                row.swipeLeft()
                if confirm.waitForExistence(timeout: 4) { break }
            }
            XCTAssertTrue(confirm.exists, "delete confirmation", file: file, line: line)
            confirm.tap()
            XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), file: file, line: line)
        }
        XCTAssertTrue(element("flow.all.empty").waitForExistence(timeout: 5), "no rows left for \(text)", file: file, line: line)
    }

    /// Settings, pushed from the Home gear.
    func openSettings() {
        goToHomeRoot()
        buttons["home.settings"].tapSettled()
        _ = switches["settings.hideBalances"].waitForExistence(timeout: 10)
    }

    /// Adds a transaction from Home: the FAB's form, switched to Income for
    /// an income. `category` picks that name in the form's Category menu;
    /// `monthsAgo` > 0 dates it on the 15th of that many months back through
    /// the form's date picker (Previous Month, then the day).
    func addTransaction(
        income: Bool = false, amount: String, description: String, category: String? = nil, monthsAgo: Int = 0,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        goToHomeRoot()
        buttons["Add transaction"].tapSettled(file: file, line: line)
        let amountField = textFields["Amount"]
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "the add form", file: file, line: line)
        if income { buttons["Income"].firstMatch.tapSettled(file: file, line: line) }
        amountField.enterText(amount)
        textFields["Description"].enterText(description)
        if let category { chooseCategory(category, file: file, line: line) }
        if monthsAgo > 0 {
            buttons["Date"].tapSettled(file: file, line: line)
            let ok = buttons["datePicker.ok"]
            XCTAssertTrue(ok.waitForExistence(timeout: 5), "the date picker", file: file, line: line)
            for _ in 0..<monthsAgo { buttons["DatePicker.PreviousMonth"].tapSettled(file: file, line: line) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "LLLL"
            let month = Calendar.current.date(byAdding: .month, value: -monthsAgo, to: Date()) ?? Date()
            let day = buttons.matching(NSPredicate(format: "label ENDSWITH %@", ", \(formatter.string(from: month)) 15")).firstMatch
            day.tapSettled(file: file, line: line)
            ok.tapSettled(file: file, line: line)
            XCTAssertTrue(ok.waitForNonExistence(timeout: 5), "the date picker closed", file: file, line: line)
        }
        buttons["Add"].tapSettled(file: file, line: line)
        XCTAssertTrue(amountField.waitForNonExistence(timeout: 10), "the form closed after Add", file: file, line: line)
    }

    /// The add / edit form's Category row (`form.category`, a button whose
    /// value is the selected category).
    var formCategory: XCUIElement { element("form.category").firstMatch }

    /// Picks `name` in the open add / edit form's Category menu: taps the
    /// row, then the name's button in the menu. The topmost hittable match
    /// is the menu's (a row behind the sheet can share the name); one
    /// scrolled out of the menu's view is tapped as the last match, which
    /// XCTest scrolls into view.
    func chooseCategory(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = formCategory
        row.tapSettled(file: file, line: line)
        let matches = buttons.matching(NSPredicate(format: "label == %@", name))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), "\(name) in the category menu", file: file, line: line)
        let all = matches.allElementsBoundByIndex
        guard let item = all.last(where: { $0.isHittable }) ?? all.last else { return }
        item.tap()
        XCTAssertTrue(row.waitForValue(name), "the form shows \(name), not \(String(describing: row.value))", file: file, line: line)
    }

    /// Shows amounts in US dollars, unmasked, which the money assertions
    /// expect. The simulator keeps settings between runs, and MVPFlowUITests
    /// ends with Euro and Hide balances on. Leaves Settings popped.
    func showDollarAmounts() {
        openSettings()
        let currency = buttons["settings.currency"]
        XCTAssertTrue(currency.waitForExistence(timeout: 10))
        if currency.value as? String != "US Dollar (USD)" {
            currency.tapSettled()
            let dollar = buttons["US Dollar"]
            dollar.tapSettled()
            XCTAssertTrue(dollar.waitForNonExistence(timeout: 5), "currency sheet closed")
            XCTAssertTrue(currency.waitForValue("US Dollar (USD)"))
        }
        let hide = switches["settings.hideBalances"]
        if hide.value as? String == "1" {
            hide.tapSettled()
            XCTAssertTrue(hide.waitForValue("0"), "Hide balances off")
        }
        navigationBars.buttons.element(boundBy: 0).tap()
    }
}

@MainActor
extension XCUIElement {
    /// Waits until `predicate` (evaluated against this element: `label`,
    /// `value`, `isSelected`, `exists`, ...) holds, without a fixed sleep.
    func waitUntil(_ predicate: String, _ arguments: [Any] = [], timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: predicate, argumentArray: arguments), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for `value` to read `expected`.
    func waitForValue(_ expected: String, timeout: TimeInterval = 5) -> Bool {
        waitUntil("value == %@", [expected], timeout: timeout)
    }

    /// Waits for `label` to read `expected`.
    func waitForLabel(_ expected: String, timeout: TimeInterval = 5) -> Bool {
        waitUntil("label == %@", [expected], timeout: timeout)
    }

    /// Empties this (focused) field one delete at a time. A burst of deletes
    /// races a field that regroups its text as it is edited, and the edit
    /// menu's Select All is late under load.
    func clearText() {
        for _ in 0..<24 {
            guard let value = value as? String, !value.isEmpty, value != placeholderValue else { return }
            typeText(XCUIKeyboardKey.delete.rawValue)
        }
    }
}
