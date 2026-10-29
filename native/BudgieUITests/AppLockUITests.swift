import XCTest

/// App Lock's privacy cover and lock screen live in a window above the app's
/// own (`AppLockWindow`), so they cover whatever is presented: a SwiftUI
/// sheet (the Home FAB's form) and the over-full-screen `AddFormHost` a
/// `budgetapp://` route opens. Fresh install, no data needed (sim A).
///
/// The simulator has no passcode, where the real authentication unlocks at
/// once, so the tests use the DEBUG hooks of `AppLockTestHooks`: the lock is
/// on in memory with a timeout, and only the first authentication (the
/// launch unlock) succeeds; later ones fail, so a lock screen stays up.
///
/// Making the app inactive while still querying it: pulling Control Center
/// down from the top right corner resigns the scene's active state (the app
/// stays "running foreground" and its accessibility tree stays queryable),
/// and a swipe up from the bottom edge closes it again. The cover is then
/// detected by its own text ("App preview hidden", in a window above the
/// app's) and by the sheet's buttons no longer being hittable. A relock
/// needs the background (the timeout counts from there), so that one goes
/// through `XCUIDevice.press(.home)` and `app.activate()`.
@MainActor
final class AppLockUITests: XCTestCase {
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(timeout: Int, authSuccesses: Int = 1) {
        app.launchEnvironment["BUDGIE_UITEST_APP_LOCK"] = String(timeout)
        app.launchEnvironment["BUDGIE_UITEST_AUTH_SUCCESSES"] = String(authSuccesses)
        app.budgie()
    }

    private var cover: XCUIElement { app.staticTexts["App preview hidden"] }
    private var lockTitle: XCUIElement { app.staticTexts["Budgie is locked"] }
    private var cancel: XCUIElement { app.buttons["Cancel"].firstMatch }
    private var amount: XCUIElement { app.textFields["Amount"] }

    private func openControlCenter() {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.6)))
    }

    private func closeControlCenter() {
        let bottom = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
        bottom.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
    }

    /// Opens the add form as a SwiftUI sheet from Home's FAB.
    private func openSheet() {
        app.buttons["Add transaction"].tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable)
    }

    /// Opens the add form as the over-full-screen host a route uses.
    private func openRoutedForm() {
        XCUIDevice.shared.system.open(URL(string: "budgetapp://add-expense")!)
        let open = springboard.buttons["Open"]
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForExistence(timeout: 10))
        XCTAssertTrue(cancel.isHittable)
    }

    private func expectCovered(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "no privacy cover over \(what)", file: file, line: line)
        XCTAssertFalse(cancel.isHittable, "\(what) is reachable through the cover", file: file, line: line)
    }

    private func expectUncovered(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(cover.waitForNonExistence(timeout: 10), "the cover stayed up over \(what)", file: file, line: line)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "\(what) is gone", file: file, line: line)
        XCTAssertTrue(cancel.isHittable, "\(what) is not usable again", file: file, line: line)
    }

    /// (a), (c): the cover is above a SwiftUI sheet while the app is
    /// inactive, and going active removes it with the sheet still usable.
    func testPrivacyCoverIsAboveASheet() throws {
        launch(timeout: 3600)
        openSheet()
        XCTAssertFalse(cover.exists)

        openControlCenter()
        expectCovered("the sheet")
        closeControlCenter()
        expectUncovered("the sheet")
        amount.enterText("7")
        XCTAssertEqual(amount.value as? String, "7", "the sheet takes input again")
    }

    /// (b), (c): the same over the over-full-screen `AddFormHost` of a route.
    func testPrivacyCoverIsAboveARoutedForm() throws {
        launch(timeout: 3600)
        openRoutedForm()

        openControlCenter()
        expectCovered("the routed form")
        closeControlCenter()
        expectUncovered("the routed form")
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Add Expense"].waitForNonExistence(timeout: 5))
    }

    /// A focused field's keyboard (and its QuickType bar) sits in a window
    /// above the cover's, so focus is resigned when the cover goes up. The
    /// typed text stays.
    func testCoverDismissesTheKeyboardAndKeepsTheText() throws {
        launch(timeout: 3600)
        openSheet()
        amount.enterText("42")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the field is focused")

        openControlCenter()
        expectCovered("the sheet")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "the keyboard stayed up under the cover")
        closeControlCenter()
        expectUncovered("the sheet")
        XCTAssertEqual(amount.value as? String, "42", "the typed amount was lost")
    }

    /// (d): relocked after the background, the lock screen is above the
    /// sheet and VoiceOver (the accessibility tree) reaches only it.
    func testRelockShowsTheLockScreenAboveASheet() throws {
        launch(timeout: 0)
        openSheet()

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(lockTitle.waitForExistence(timeout: 10), "not relocked")
        XCTAssertTrue(app.buttons["Unlock"].isHittable, "the lock screen is not on top")
        XCTAssertFalse(cover.exists, "the privacy cover stayed up under the lock screen")
        XCTAssertFalse(cancel.exists, "the sheet is still in the accessibility tree while locked")
        XCTAssertFalse(amount.exists, "the sheet's data is reachable while locked")
        XCTAssertFalse(app.tabBars.buttons["Home"].exists, "the tabs are still in the accessibility tree while locked")
    }

    /// (d): the same over a route's over-full-screen host, which leaves the
    /// screens beneath it in the tree (`AddFormHost`).
    func testRelockShowsTheLockScreenAboveARoutedForm() throws {
        launch(timeout: 0)
        openRoutedForm()

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(lockTitle.waitForExistence(timeout: 10), "not relocked")
        XCTAssertTrue(app.buttons["Unlock"].isHittable)
        XCTAssertFalse(cancel.exists, "the routed form is still in the accessibility tree while locked")
        XCTAssertFalse(app.tabBars.buttons["Home"].exists)
    }

    /// A relock that unlocks at once (the second authentication succeeds)
    /// leaves the sheet as it was and brings it back to the accessibility
    /// tree.
    func testUnlockingAfterRelockKeepsTheSheet() throws {
        launch(timeout: 0, authSuccesses: 2)
        openSheet()
        amount.enterText("5")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        XCTAssertTrue(lockTitle.waitForNonExistence(timeout: 10), "the lock screen stayed up")
        expectUncovered("the sheet")
        XCTAssertEqual(amount.value as? String, "5")
    }

    /// Not backgrounded for the timeout: no relock, only the cover.
    func testBriefInterruptionDoesNotRelock() throws {
        launch(timeout: 3600)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        XCTAssertFalse(lockTitle.exists)
        XCTAssertTrue(cover.waitForNonExistence(timeout: 10))
    }
}
