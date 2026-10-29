import XCTest

/// Home screen integration driven through SpringBoard
/// (native/scripts/system_flow.sh prepares the simulator: the Flutter build
/// installed and launched once, so its dynamic quick actions exist, then this
/// target installs the Swift build over it and revokes its microphone, so
/// voice entry deterministically shows its "Microphone access is off" error
/// instead of a system prompt or a real recording: these launches come from
/// SpringBoard, so no launch environment hook applies). Tests run in name
/// order.
@MainActor
final class SystemIntegrationUITests: XCTestCase {
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The app icon on the home screen, paging right until it is visible.
    private func appIcon() -> XCUIElement {
        XCUIDevice.shared.press(.home)
        let icon = springboard.icons["Budgie"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10), "Budgie icon not on the home screen")
        var pages = 0
        while !icon.isHittable && pages < 5 {
            springboard.swipeLeft()
            pages += 1
        }
        return icon
    }

    private func quickActionTitles() -> [String] {
        let icon = appIcon()
        icon.press(forDuration: 1.5)
        _ = springboard.buttons["Add Expense"].waitForExistence(timeout: 5)
        let titles = ["Add Expense", "Add Income", "Add by Voice"].filter { springboard.buttons[$0].exists }
        snapshot("quick actions \(titles)")
        return titles
    }

    private func expectForm(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "app did not open", file: file, line: line)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 20), "\(title) form not shown", file: file, line: line)
        snapshot(title)
        app.buttons["Cancel"].tap()
    }

    /// Waits for the voice sheet, which with the microphone revoked
    /// (system_flow.sh) shows the denied message, then cancels it.
    private func expectVoiceSheet(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "app did not open", file: file, line: line)
        let message = app.staticTexts["voice.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 20), "voice sheet not shown", file: file, line: line)
        XCTAssertEqual(message.label, "Microphone access is off. Enable it in Settings > Budgie.", file: file, line: line)
        snapshot("voice sheet")
        app.buttons["voice.cancel"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 5), "voice sheet did not close", file: file, line: line)
    }

    /// The Flutter build registered three dynamic items, including voice.
    /// Before the Swift app's first launch they are still offered; tapping
    /// "Add by Voice" opens the voice sheet.
    func test1_leftoverFlutterVoiceQuickAction() {
        let titles = quickActionTitles()
        XCTAssertEqual(titles, ["Add Expense", "Add Income", "Add by Voice"], "expected the Flutter build's items")
        springboard.buttons["Add by Voice"].tap()
        expectVoiceSheet()
    }

    /// After a launch the Swift app has registered its own three.
    func test2_swiftQuickActions() {
        XCUIDevice.shared.press(.home)
        let titles = quickActionTitles()
        XCTAssertEqual(titles, ["Add Expense", "Add Income", "Add by Voice"])
        springboard.buttons["Add Income"].tap()
        expectForm("Add Income")
        XCUIDevice.shared.press(.home)
        _ = quickActionTitles()
        springboard.buttons["Add by Voice"].tap()
        expectVoiceSheet()
    }

    /// `budgetapp://` links through the system's "Open in Budgie?" prompt.
    func test3_deepLinks() {
        for (link, title) in [
            ("budgetapp://add-income", "Add Income"), ("budgetapp://add-expense", "Add Expense"),
            ("budgetapp://voice-add", nil), ("budgetapp://add_income", "Add Income"),
            ("budgetapp://voice_add", nil),
        ] as [(String, String?)] {
            XCUIDevice.shared.press(.home)
            XCUIDevice.shared.system.open(URL(string: link)!)
            let open = springboard.buttons["Open"]
            if open.waitForExistence(timeout: 5) { open.tap() }
            if let title { expectForm(title) } else { expectVoiceSheet() }
        }
    }

    /// Places the Quick Add widget, checks it shows the month's cash flow the
    /// app wrote to the App Group, and follows its Expense link.
    func test4_widget() {
        // Give the widget a value: one expense this month.
        app.launchEnvironment["BUDGIE_SKIP_ONBOARDING"] = "1"
        app.launch()
        app.buttons["Add transaction"].tap()
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        amount.enterText("12")
        app.buttons["Add"].tapSettled()

        XCUIDevice.shared.press(.home)
        // Edit mode: long-press an empty spot on the home screen.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).press(forDuration: 2.0)
        let edit = springboard.buttons["Edit"]
        if edit.waitForExistence(timeout: 5) {
            edit.tap()
            let add = springboard.buttons["Add Widget"]
            XCTAssertTrue(add.waitForExistence(timeout: 5), "no Add Widget in the edit menu")
            add.tap()
        } else {
            let plus = springboard.buttons["Add Widget"]
            XCTAssertTrue(plus.waitForExistence(timeout: 5), "home screen edit mode not reached")
            plus.tap()
        }
        snapshot("widget gallery")
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "widget gallery search not found")
        search.tap()
        search.typeText("Budgie")
        // The result row, not the search field's own text.
        func searchResult() -> XCUIElement? {
            springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Budgie'")).allElementsBoundByIndex
                .filter { $0.elementType != .searchField && $0.frame.minY > search.frame.maxY + 4 && $0.isHittable }
                .first
        }
        let resultDeadline = Date().addingTimeInterval(10)
        var found = searchResult()
        while found == nil && Date() < resultDeadline {
            Thread.sleep(forTimeInterval: 0.25)
            found = searchResult()
        }
        snapshot("widget search")
        guard let result = found else { return XCTFail("Budgie not in widget search results") }
        result.tapSettled()
        // The detail sheet lists the extension's widgets; the first is
        // "Budget Quick Add". Its button label carries a leading symbol.
        XCTAssertTrue(springboard.staticTexts["Budget Quick Add"].waitForExistence(timeout: 10), "widget detail sheet not shown")
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label ENDSWITH 'Add Widget'")).allElementsBoundByIndex
            .max { $0.frame.minY < $1.frame.minY }
        snapshot("widget detail")
        guard let addWidget else { return XCTFail("no Add Widget button in the detail sheet") }
        addWidget.tap()
        let done = springboard.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        sleep(3)
        snapshot("widget placed")

        // Widget contents are not in the accessibility tree; on a fresh home
        // screen the small widget lands in the top-left slot, so its two
        // links are tapped by position (the script checks the displayed
        // value against the App Group and keeps the screenshot).
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.185)).tap()
        expectForm("Add Income")
        XCUIDevice.shared.press(.home)
        sleep(2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.26, dy: 0.24)).tap()
        expectForm("Add Expense")
    }
}
