import BudgieCore
import XCTest

@testable import Runner

@MainActor
final class CSVImportModelTests: XCTestCase {
    private var scratch: Scratch!

    override func setUp() async throws {
        scratch = try Scratch()
    }

    override func tearDown() async throws {
        scratch.remove()
    }

    private static let header = "Date,Type,Category,Description,Amount"

    private func csv(_ rows: String...) -> [UInt8] { Array(([Self.header] + rows).joined(separator: "\r\n").utf8) }

    /// Import: the rows, a new category defined in the same commit, one
    /// write; a second import of the same file finds only duplicates.
    func testImportThenAllDuplicates() async throws {
        let model = await scratch.start()
        let before = try await scratch.stored()
        let file = csv("2026-09-01,Income,Salary,Pay,\"$1,000.00\"", "2026-09-02,Expense,Board games,Dice,12.50")
        let summary = try await model.previewCSVImport(file)
        XCTAssertEqual(summary.drafts.count, 2)
        XCTAssertEqual(summary.confirmTitle, "Import 2 transactions?")
        XCTAssertNil(summary.confirmMessage)
        XCTAssertNil(summary.emptyResultMessage)

        let saved = await model.importCSV(summary)
        XCTAssertTrue(saved)
        XCTAssertEqual(summary.successMessage.text, "Imported 2 transactions")
        XCTAssertEqual(summary.successMessage.tone, .success)
        XCTAssertEqual(model.data?.transactions.map(\.description), ["Pay", "Dice"])
        XCTAssertTrue(model.categories(for: .expense).contains { $0.name == "Board games" })
        let disk = try await scratch.stored()
        XCTAssertEqual(disk.revision, before.revision + 1, "one commit")
        XCTAssertEqual(disk.sections[Section.transactions]?.arrayValue?.count, 2)
        XCTAssertTrue(disk.sections[Section.categories]?.arrayValue?.contains { $0.objectValue?["name"]?.stringValue == "Board games" } ?? false)

        let again = try await model.previewCSVImport(file)
        XCTAssertEqual(again.drafts.count, 0)
        XCTAssertEqual(again.duplicateCount, 2)
        XCTAssertEqual(again.emptyResultMessage?.text, "All transactions in this file already exist")
        XCTAssertEqual(again.emptyResultMessage?.tone, .neutral)
    }

    /// Existing rows cancel matching file rows; the rest import; unreadable
    /// rows are counted.
    func testDuplicatesSkipped() async throws {
        let model = await scratch.start()
        let date = try XCTUnwrap(model.calendar.tryParse("2026-09-03"))
        let added = await model.addTransaction(type: .expense, description: "Coffee", amount: 4, category: "Food", date: date)
        XCTAssertTrue(added)
        let summary = try await model.previewCSVImport(csv(
            "2026-09-03,Expense,Food,Coffee,4.00", "2026-09-03,Expense,Food,Coffee,4.00", "2026-02-30,Expense,Food,Bad,1"))
        XCTAssertEqual(summary.drafts.count, 1)
        XCTAssertEqual(summary.confirmTitle, "Import 1 transaction?")
        XCTAssertEqual(summary.confirmMessage, "1 duplicate will be skipped\n1 row could not be read")
        let saved = await model.importCSV(summary)
        XCTAssertTrue(saved)
        XCTAssertEqual(summary.successMessage.text, "Imported 1 transaction, 1 duplicate skipped")
        XCTAssertEqual(model.data?.transactions.count, 2)
    }

    /// A file without the header is refused with the bare message.
    func testHeaderFailure() async throws {
        let model = await scratch.start()
        do {
            _ = try await model.previewCSVImport(Array("date;type\n1;2".utf8))
            XCTFail("parsed")
        } catch {
            XCTAssertEqual(error, .notATransactionsCSV)
            XCTAssertEqual(CSVImport.failureMessage(error).text, "Could not import: Not a valid transactions CSV export")
            XCTAssertEqual(CSVImport.failureMessage(error).tone, .error)
        }
        XCTAssertEqual(CSVImport.failureMessage(.unreadableFile).text, "Could not import: The file could not be read")
    }

    /// A failed write keeps the rows in memory behind the unsaved banner and
    /// reports false (the caller shows the save-failed toast).
    func testFailedWrite() async throws {
        let model = await scratch.start()
        let summary = try await model.previewCSVImport(csv("2026-09-01,Expense,Food,Lunch,8"))
        let unlock = try scratch.lockStoreDirectory()
        defer { unlock() }
        let saved = await model.importCSV(summary)
        XCTAssertFalse(saved)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(model.data?.transactions.map(\.description), ["Lunch"])
    }

    /// A failed write of rows that bring a new category flags both sections:
    /// one retry writes the rows and the definition together.
    func testFailedWriteWithNewCategoryFlagsBoth() async throws {
        let model = await scratch.start()
        let summary = try await model.previewCSVImport(csv("2026-09-01,Expense,Board games,Dice,12.50"))
        let unlock = try scratch.lockStoreDirectory()
        let saved = await model.importCSV(summary)
        XCTAssertFalse(saved)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.categories(for: .expense).contains { $0.name == "Board games" }, "in memory")
        unlock()

        await model.retrySaves()
        XCTAssertFalse(model.hasUnsavedChanges)
        let disk = try await scratch.stored()
        XCTAssertEqual(disk.sections[Section.transactions]?.arrayValue?.count, 1)
        XCTAssertTrue(
            disk.sections[Section.categories]?.arrayValue?.contains { $0.objectValue?["name"]?.stringValue == "Board games" } ?? false)
    }

    /// 10,000 rows imported onto a 10,000-row ledger: the rows and the
    /// sections are built off the main thread, which never stalls for long
    /// (the confirmation's spinner keeps turning).
    func testLargeImportKeepsTheMainThreadFree() async throws {
        let model = await scratch.start()
        func rows(_ prefix: String) -> [UInt8] {
            let lines = (0..<10_000).map { "2026-0\(1 + $0 % 9)-1\($0 % 10),Expense,Food,\(prefix) \($0),\($0 % 97).25" }
            return Array(([Self.header] + lines).joined(separator: "\r\n").utf8)
        }
        let first = try await model.previewCSVImport(rows("Seed"))
        let seeded = await model.importCSV(first)
        XCTAssertTrue(seeded)
        let summary = try await model.previewCSVImport(rows("Second"))
        XCTAssertEqual(summary.drafts.count, 10_000)

        // A main-actor ticker: the longest gap between its ticks is the
        // longest time the main thread was busy with something else.
        final class Stall: @unchecked Sendable {
            var longest: TimeInterval = 0
            var ticks = 0
            var running = true
        }
        let stall = Stall()
        let ticker = Task { @MainActor in
            var last = Date()
            while stall.running {
                try? await Task.sleep(for: .milliseconds(5))
                let now = Date()
                stall.longest = max(stall.longest, now.timeIntervalSince(last))
                stall.ticks += 1
                last = now
            }
        }
        let tickDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while stall.ticks < 2 {
            if ContinuousClock.now >= tickDeadline {
                stall.running = false
                XCTFail("timed out: the ticker never ticked")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        stall.longest = 0
        let started = Date()
        let saved = await model.importCSV(summary)
        let elapsed = Date().timeIntervalSince(started)
        stall.running = false
        await ticker.value
        XCTAssertTrue(saved)
        XCTAssertEqual(model.data?.transactions.count, 20_000)
        print("large import: \(elapsed)s, longest main-thread stall \(stall.longest)s")
        XCTAssertLessThan(stall.longest, 0.25, "longest main-thread stall during the import")
    }

    /// Nothing to import writes nothing.
    func testEmptySummaryWritesNothing() async throws {
        let model = await scratch.start()
        let before = try await scratch.stored()
        let summary = try await model.previewCSVImport(csv())
        XCTAssertEqual(summary.emptyResultMessage?.text, "No transactions found in this file")
        XCTAssertEqual(summary.emptyResultMessage?.tone, .neutral)
        let saved = await model.importCSV(summary)
        XCTAssertTrue(saved)
        let after = try await scratch.stored()
        XCTAssertEqual(after.revision, before.revision)
    }
}
