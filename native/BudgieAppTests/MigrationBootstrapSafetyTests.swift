import BudgieCore
import XCTest

@testable import Runner

@MainActor
final class MigrationBootstrapSafetyTests: XCTestCase {
    func testUnreadableRowsSurviveBootstrapEditAndRelaunch() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(at: scratch.storeDirectory, withIntermediateDirectories: true)
        let lists = [Section.transactions, Section.netWorthEntries, Section.savingsGoals, Section.recurringTransactions,
                     Section.categories, Section.transactionTags, Section.categorizationRules]
        let rawRows: JSONValue = .array([.string("valuable unreadable row"), .object(JSONObject(ordered: [("future", .int(42))]))])
        var sections = JSONObject(ordered: lists.map { ($0, rawRows) })
        sections[Section.categoryBudgetLimits] = .object(JSONObject(ordered: [("future budget", .string("keep this"))]))
        sections[Section.appSettings] = .object(JSONObject(ordered: [("future setting", .string("keep this too"))]))
        sections["futureFeature"] = .array([.int(123)])
        let original = StoreFile.encode(FinancialSnapshot(revision: 11, sections: sections), writtenAt: DartDateTime.now(timeZone: .current))
        try Data(original).write(to: scratch.storeDirectory.appendingPathComponent(StoreFile.primaryName))
        let model = await scratch.start()
        XCTAssertEqual(model.phase, .ready)
        let saved = await model.addTransaction(type: .expense, description: "Synthetic new entry", amount: 12.5, category: "Food",
                                               date: DartDateTime.now(timeZone: .current))
        XCTAssertTrue(saved)
        for _ in 0..<2 {
            let relaunched = await scratch.start()
            XCTAssertEqual(relaunched.phase, .ready)
            let stored = try await scratch.stored()
            for section in lists {
                XCTAssertEqual(Array(stored.sections[section]!.arrayValue!.prefix(2)), rawRows.arrayValue!, section)
            }
            for section in [Section.categoryBudgetLimits, Section.appSettings, "futureFeature"] {
                XCTAssertEqual(stored.sections[section], sections[section], section)
            }
            XCTAssertEqual(stored.sections[Section.transactions]!.arrayValue!.count, 3)
        }
    }

    func testMalformedKnownSectionsBlockBeforeLaunchWrites() async throws {
        for section in Section.all {
            let scratch = try Scratch()
            defer { scratch.remove() }
            try FileManager.default.createDirectory(at: scratch.storeDirectory, withIntermediateDirectories: true)
            let malformed: JSONValue = section == Section.appSettings || section == Section.categoryBudgetLimits
                ? .array([.string("valuable original")]) : .object(JSONObject(ordered: [("keep", .string("valuable original"))]))
            let bytes = StoreFile.encode(FinancialSnapshot(revision: 17, sections: JSONObject(ordered: [(section, malformed)])),
                                         writtenAt: DartDateTime.now(timeZone: .current))
            let primary = scratch.storeDirectory.appendingPathComponent(StoreFile.primaryName)
            try Data(bytes).write(to: primary)
            let model = await scratch.start()
            guard case .blocked(.readFailed) = model.phase else {
                XCTFail("Malformed \(section) must block before launching an empty view")
                continue
            }
            XCTAssertEqual(try Data(contentsOf: primary), Data(bytes), section)
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.storeDirectory.appendingPathComponent(StoreFile.backupName).path), section)
            let snapshots = try PreNativeMigrationBackup(
                applicationSupport: scratch.directory,
                sources: .init(storeDirectory: scratch.storeDirectory, exportPreferences: { Data() }, exportAppGroupPreferences: { Data() }),
                appVersion: "audit").completeSnapshots()
            XCTAssertEqual(snapshots.count, 1, section)
            XCTAssertEqual(try Data(contentsOf: snapshots[0].appendingPathComponent(StoreFile.directoryName).appendingPathComponent(StoreFile.primaryName)), Data(bytes), section)
        }
    }
}
