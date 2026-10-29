import XCTest

/// Settings > Import from CSV end to end through the system document
/// picker. Each test first restores the staged backup (three transactions)
/// so the counts are known, then imports: a file with two duplicates of
/// those rows, two new rows and a bad row (Cancel, then Import), a file of
/// only duplicates (the neutral message) and a file without the header
/// (Flutter's error, bare).
///
/// Erased simulators only: like BackupUITests, it replaces the app's data
/// and launches with the data guard (it skips over data UI tests did not
/// make). Needs the picker files: after an erase and boot, run
/// `native/scripts/stage_import_fixtures.sh <UDID>`.
@MainActor
final class CSVImportUITests: XCTestCase {
    let app = XCUIApplication()
    private var screen: SettingsDataScreen!

    override func setUp() async throws {
        continueAfterFailure = false
        screen = SettingsDataScreen(app: app)
        try screen.launchOverTestData()
        screen.openSettings()
        screen.restoreFixtureBackup()
        XCTAssertEqual(screen.transactionCount(), 3)
    }

    /// The confirmation shows the counts only; Cancel imports nothing;
    /// Import adds the two new rows with Flutter's success message.
    func testImportSkipsDuplicates() {
        screen.tapRow("settings.importCSV")
        screen.pick("Budgie UITest Import")
        let title = screen.element("csvimport.confirm.title")
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Import 2 transactions?")
        XCTAssertEqual(screen.element("csvimport.confirm.message").label, "2 duplicates will be skipped\n1 row could not be read")
        screen.element("csvimport.confirm.cancel").tapSettled()
        XCTAssertTrue(screen.waitUntil(5) { !title.exists })
        XCTAssertEqual(screen.transactionCount(), 3, "Cancel imports nothing")

        screen.tapRow("settings.importCSV")
        screen.pick("Budgie UITest Import")
        screen.element("csvimport.confirm.confirm").tapSettled()
        XCTAssertTrue(screen.labelled("Imported 2 transactions, 2 duplicates skipped").waitForExistence(timeout: 15))
        XCTAssertEqual(screen.transactionCount(), 5)
        app.goToHomeRoot()
        for name in ["UITest Refund", "UITest Coffee"] {
            XCTAssertTrue(screen.containing(name).waitForExistence(timeout: 10), name)
        }
    }

    /// Nothing new: the neutral message and no dialog. No header: the bare
    /// error message.
    func testDuplicatesOnlyAndBadHeader() {
        screen.tapRow("settings.importCSV")
        screen.pick("Budgie UITest Duplicates")
        XCTAssertTrue(screen.labelled("All transactions in this file already exist").waitForExistence(timeout: 15))
        XCTAssertFalse(screen.element("csvimport.confirm.title").exists)

        screen.tapRow("settings.importCSV")
        screen.pick("Budgie UITest Bad Header")
        XCTAssertTrue(screen.labelled("Could not import: Not a valid transactions CSV export").waitForExistence(timeout: 15))
        XCTAssertEqual(screen.transactionCount(), 3)
    }
}
