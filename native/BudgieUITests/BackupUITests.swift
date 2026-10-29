import XCTest

/// Settings > DATA backup rows end to end through the system share sheet
/// and document picker: Export backup opens the share sheet (cancelled: no
/// message), a corrupt file gives Flutter's error, and a backup is
/// restored after its confirmation (Cancel first changes nothing), and a
/// backup that turns App Lock on locks the app.
///
/// Erased simulators only. Restoring replaces the app's data with the
/// fixture's three transactions (dated last month, so a later suite's
/// current month starts empty), and each restore's safety copy pushes an
/// older one out. The app is launched with `BUDGIE_UITEST_DATA_GUARD=1`:
/// the first guarded launch must find nothing entered (an erased
/// simulator, before other suites add data), which marks the install as
/// the tests'; any other data is refused and the tests skip. Never run
/// them on a simulator with real or demo data.
///
/// Needs the picker files: after an erase and boot, run
/// `native/scripts/stage_import_fixtures.sh <UDID>` (they show under
/// Browse > On My iPhone).
@MainActor
final class BackupUITests: XCTestCase {
    let app = XCUIApplication()
    private var screen: SettingsDataScreen!

    override func setUp() async throws {
        continueAfterFailure = false
        screen = SettingsDataScreen(app: app)
        try screen.launchOverTestData()
    }

    /// The share sheet opens with the file (titled with the subject);
    /// cancelling it shows no "Backup exported" and frees the rows.
    func testExportOpensShareSheetAndCancelShowsNothing() {
        screen.openSettings()
        screen.tapRow("settings.exportBackup")
        // The sheet's header shows the subject (share_plus's `subject`).
        let title = app.descendants(matching: .any)["LP.CaptionBar.TopCaption"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "share sheet\n\(app.debugDescription)")
        XCTAssertEqual(title.label, "Budgie Backup")
        screen.closeShareSheet()
        XCTAssertTrue(screen.waitUntil(10) { !title.exists }, "share sheet closed")
        XCTAssertFalse(screen.labelled("Backup exported").waitForExistence(timeout: 3), "no message after a cancel")
        XCTAssertTrue(screen.waitUntil(5) { app.buttons["settings.exportBackup"].exists }, "the row is enabled again")
    }

    /// A file Flutter refuses: its message, nothing restored.
    func testCorruptFileShowsTheError() {
        screen.openSettings()
        let before = screen.transactionCount()
        screen.tapRow("settings.importBackup")
        screen.pick("Budgie UITest Corrupt")
        XCTAssertTrue(
            screen.labelled("Could not import backup: This is not a valid Budgie backup file").waitForExistence(timeout: 15))
        XCTAssertFalse(screen.element("backup.confirm.title").exists)
        XCTAssertEqual(screen.transactionCount(), before)
    }

    /// "Replace all data?" with Flutter's counts; Cancel keeps the data;
    /// Replace restores it ("Backup restored") and Home shows its rows.
    func testRestoreAfterConfirmation() {
        screen.openSettings()
        let before = screen.transactionCount()
        screen.tapRow("settings.importBackup")
        screen.pick("Budgie UITest Backup")
        let title = screen.element("backup.confirm.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Replace all data?")
        XCTAssertEqual(
            screen.element("backup.confirm.message").label,
            "This will import 3 transactions, 0 net worth entries, 1 budgets, 0 goals and 0 recurring templates, "
                + "replacing everything currently in Budgie. This cannot be undone.")
        screen.element("backup.confirm.cancel").tapSettled()
        XCTAssertTrue(screen.waitUntil(5) { !title.exists })
        XCTAssertFalse(screen.labelled("Backup restored").waitForExistence(timeout: 2))
        XCTAssertEqual(screen.transactionCount(), before, "Cancel changes nothing")

        screen.restoreFixtureBackup()
        XCTAssertEqual(screen.transactionCount(), 3)
        app.goToHomeRoot()
        for name in ["UITest Groceries", "UITest Rent", "UITest Paycheck"] {
            XCTAssertTrue(screen.containing(name).waitForExistence(timeout: 10), name)
        }
    }

    /// Restoring a backup that turns App Lock on locks this session at
    /// once: a restore is not an authentication (only the Settings toggle,
    /// which authenticates first, keeps the session open). With every
    /// authentication refused (DEBUG hook) the lock screen stays up.
    func testRestoreThatTurnsAppLockOnLocksTheApp() throws {
        app.terminate()
        app.launchEnvironment["BUDGIE_UITEST_AUTH_SUCCESSES"] = "0"
        try screen.launchOverTestData()
        screen.openSettings()
        screen.tapRow("settings.importBackup")
        screen.pick("Budgie UITest Locked Backup")
        screen.element("backup.confirm.confirm").tapSettled()
        let lock = screen.element("applock.lock")
        XCTAssertTrue(lock.waitForExistence(timeout: 15), "the lock screen after the restore")
        XCTAssertFalse(screen.waitUntil(3) { !lock.exists }, "nothing unlocks it without authenticating")

        // Put the unlocked fixture back for the suites that follow: the
        // relaunch's lock screen unlocks with one authentication the hook
        // lets succeed.
        app.terminate()
        app.launchEnvironment["BUDGIE_UITEST_AUTH_SUCCESSES"] = "1"
        try screen.launchOverTestData()
        screen.openSettings()
        screen.restoreFixtureBackup()
    }
}

/// Driving Settings > DATA, the document picker and the share sheet (shared
/// with CSVImportUITests).
@MainActor
struct SettingsDataScreen {
    let app: XCUIApplication

    /// Launches past onboarding with the data guard on (see
    /// `BackupUITests`); skips when the app refused the store.
    func launchOverTestData(file: StaticString = #filePath, line: UInt = #line) throws {
        app.launchEnvironment["BUDGIE_SKIP_ONBOARDING"] = "1"
        app.launchEnvironment["BUDGIE_UITEST_DATA_GUARD"] = "1"
        app.launch()
        let home = app.tabBars.buttons["Home"]
        let refused = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "UI test data guard")).firstMatch
        _ = waitUntil(20) { home.exists || refused.exists }
        if refused.exists {
            throw XCTSkip("The app's data was not made by UI tests: erase the simulator, stage the fixtures, then run again.")
        }
        XCTAssertTrue(home.exists, "Home", file: file, line: line)
    }

    func containing(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Polls `condition` until it holds or `timeout` passes.
    func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    func openSettings() {
        app.goToHomeRoot()
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.element("settings.recurring").waitForExistence(timeout: 10))
    }

    /// Scrolls the DATA row into view and taps it.
    func tapRow(_ identifier: String) {
        let row = app.element(identifier)
        XCTAssertTrue(row.waitForExistence(timeout: 10), identifier)
        for _ in 0..<6 where !row.isHittable || row.frame.maxY > app.frame.maxY - 140 {
            app.swipeUp(velocity: .slow)
        }
        row.tapSettled()
    }

    /// The N in the Export as CSV row's "All N transactions".
    func transactionCount() -> Int? {
        let row = app.element("settings.exportCSV")
        guard row.waitForExistence(timeout: 10), let value = row.value as? String else { return nil }
        return Int(value.replacingOccurrences(of: "All ", with: "").replacingOccurrences(of: " transactions", with: ""))
    }

    /// Picks a staged file in the document picker: Browse (on a fresh
    /// simulator it opens on Recents), On My iPhone, then the file.
    func pick(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        if !item.waitForExistence(timeout: 8) {
            let browse = app.buttons["Browse"]
            if browse.waitForExistence(timeout: 5) { browse.tap() }
            if !item.waitForExistence(timeout: 6) {
                let location = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "On My iPhone")).firstMatch
                if location.waitForExistence(timeout: 5) { location.tap() }
            }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 15), "\(name) in the picker\n\(app.debugDescription)", file: file, line: line)
        item.tapSettled(file: file, line: line)
    }

    /// Closes the share sheet without sharing: the system's compact sheet
    /// has no close button, so it is dragged down by its header once it
    /// has settled.
    func closeShareSheet(file: StaticString = #filePath, line: UInt = #line) {
        let header = app.element("LP.CaptionBar.TopCaption")
        XCTAssertTrue(header.waitForExistence(timeout: 10), "share sheet header", file: file, line: line)
        var last = CGRect.null
        _ = waitUntil(10) {
            defer { last = header.frame }
            return header.isHittable && header.frame == last
        }
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0)))
    }

    /// Settings > Import backup > "Budgie UITest Backup" > Replace, then
    /// "Backup restored": the known three-transaction ledger.
    func restoreFixtureBackup() {
        tapRow("settings.importBackup")
        pick("Budgie UITest Backup")
        app.element("backup.confirm.confirm").tapSettled()
        XCTAssertTrue(app.labelled(exactly: "Backup restored").waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(10) { !app.element("backup.confirm.title").exists })
    }
}
