import BudgieCore
import XCTest

@testable import Runner

@MainActor
final class BackupModelTests: XCTestCase {
    private var scratch: Scratch!

    override func setUp() async throws {
        scratch = try Scratch()
    }

    override func tearDown() async throws {
        scratch.remove()
    }

    private var today: DartDateTime { DartCalendar(timeZone: .autoupdatingCurrent).now() }

    /// A current store the restores below replace: a transaction, a custom
    /// category and tag, EUR and hide balances.
    private func seededModel() async throws -> AppModel {
        let model = await scratch.start()
        XCTAssertEqual(model.phase, .ready)
        let added = await model.addTransaction(type: .expense, description: "Old lunch", amount: 9.5, category: "Food", date: today)
        XCTAssertTrue(added)
        let category = await model.addCategory(type: .expense, name: "Hobbies", iconIdentifier: "cart", colorToken: "green")
        XCTAssertEqual(category, .saved)
        let tag = await model.addTag(name: "Work")
        XCTAssertEqual(tag, .saved)
        let currency = await model.setBaseCurrency("EUR")
        XCTAssertTrue(currency)
        let hidden = await model.setHideBalances(true)
        XCTAssertTrue(hidden)
        return model
    }

    private static let schema3 = """
        {
          "schemaVersion": 3,
          "app": "budgie",
          "appVersion": "3.4.0",
          "exportedAt": "2026-09-01T09:00:00.000",
          "data": {
            "transactions": [
              {"id": "b1", "type": "income", "description": "Backup pay", "amount": 2500.0, "category": "Salary",
               "date": "2026-08-01T10:00:00.000", "recurringTemplateId": null, "tagIds": ["bt"],
               "createdAt": "2026-08-01T10:00:00.000", "updatedAt": "2026-08-01T10:00:00.000"},
              {"id": "b2", "type": "expense", "description": "Backup rent", "amount": 1200.0, "category": "Housing",
               "date": "2026-08-02T10:00:00.000", "recurringTemplateId": null, "tagIds": [],
               "createdAt": "2026-08-02T10:00:00.000", "updatedAt": "2026-08-02T10:00:00.000"}
            ],
            "netWorthEntries": [],
            "categoryBudgetLimits": {"Housing": 1500.0, "Dropped": 0},
            "savingsGoals": [],
            "recurringTransactions": [],
            "themeMode": "dark",
            "categories": [
              {"id": "expense-housing", "type": "expense", "name": "Housing", "iconIdentifier": "house", "colorToken": "blue",
               "sortOrder": 0, "isArchived": false, "isBuiltIn": true},
              {"id": "income-salary", "type": "income", "name": "Salary", "iconIdentifier": "briefcase", "colorToken": "green",
               "sortOrder": 0, "isArchived": false, "isBuiltIn": true}
            ],
            "transactionTags": [{"id": "bt", "name": "Backup tag", "colorToken": "accent"}],
            "categorizationRules": [],
            "baseCurrencyCode": "gbp",
            "localeOverride": null,
            "appLockEnabled": false,
            "autoLockTimeoutSeconds": 30,
            "hideBalances": false
          }
        }
        """

    /// Schema 1 (July 2026): only the first six `data` keys.
    private static let schema1 = """
        {"schemaVersion": 1, "app": "budgie", "appVersion": "2.0.0", "exportedAt": "2026-07-20T09:00:00.000",
         "data": {
           "transactions": [
             {"id": "v1", "type": "expense", "description": "Schema one", "amount": 5.0, "category": "Food",
              "date": "2026-07-19T10:00:00.000", "recurringTemplateId": null, "tagIds": [],
              "createdAt": "2026-07-19T10:00:00.000", "updatedAt": "2026-07-19T10:00:00.000"}
           ],
           "netWorthEntries": [], "categoryBudgetLimits": {}, "savingsGoals": [], "recurringTransactions": [],
           "themeMode": "light"}}
        """

    /// Export: the file is named for the clock, holds the envelope, and a
    /// decode of it gives back what was exported.
    func testExportDecodesBack() async throws {
        let model = try await seededModel()
        let url = try await model.exportBackup()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("budgie_backup_"))
        XCTAssertEqual(url.pathExtension, "json")
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertTrue(String(decoding: bytes.prefix(60), as: UTF8.self).hasPrefix("{\n  \"schemaVersion\": 3,\n  \"app\": \"budgie\""))

        let plan = try await model.decodeBackup(bytes)
        XCTAssertEqual(plan.counts.transactions, 1)
        XCTAssertEqual(plan.transactions?.first?.description, "Old lunch")
        XCTAssertEqual(plan.baseCurrencyCode, "EUR")
        XCTAssertEqual(plan.hideBalances, true)
        XCTAssertEqual(plan.themeMode, "system")
        XCTAssertTrue(plan.categories?.contains { $0.name == "Hobbies" } ?? false)
        XCTAssertEqual(plan.tags?.map(\.name), ["Work"])
        XCTAssertTrue(plan.keptItems.isEmpty)
        XCTAssertEqual(plan.confirmationMessage, plan.flutterConfirmationMessage)

        // Restoring its own export changes nothing the user sees.
        let before = model.data?.transactions.map(\.id)
        let outcome = await model.restoreBackup(plan)
        XCTAssertEqual(outcome, .restored(generated: 0))
        XCTAssertEqual(model.data?.transactions.map(\.id), before)
        XCTAssertEqual(model.data?.appSettings.baseCurrencyCode, "EUR")
    }

    /// A schema-3 file replaces everything: memory, the one commit on disk,
    /// the five preference mirrors and the theme; budgets <= 0 are dropped;
    /// the safety copy holds the store as it was.
    func testRestoreSchema3ReplacesEverything() async throws {
        let model = try await seededModel()
        let before = try await scratch.stored()
        let plan = try await model.decodeBackup(Array(Self.schema3.utf8))
        XCTAssertEqual(
            plan.confirmationMessage,
            "This will import 2 transactions, 0 net worth entries, 2 budgets, 0 goals and 0 recurring templates, "
                + "replacing everything currently in Budgie. This cannot be undone.")

        let outcome = await model.restoreBackup(plan)
        XCTAssertEqual(outcome, .restored(generated: 0))
        XCTAssertEqual(outcome.toast.message, "Backup restored")
        XCTAssertEqual(outcome.toast.style, .success)
        XCTAssertFalse(model.isRestoring)
        XCTAssertFalse(model.hasUnsavedChanges)

        let data = try XCTUnwrap(model.data)
        XCTAssertEqual(data.transactions.map(\.description), ["Backup pay", "Backup rent"])
        XCTAssertEqual(data.categories.map(\.name), ["Housing", "Salary"])
        XCTAssertEqual(data.tags.map(\.name), ["Backup tag"])
        XCTAssertEqual(data.budgetLimits.map(\.0), ["Housing"])
        XCTAssertEqual(data.budgetLimits.map(\.1), [1500])
        XCTAssertEqual(data.appSettings.baseCurrencyCode, "GBP")
        XCTAssertEqual(data.appSettings.autoLockTimeoutSeconds, 30)
        XCTAssertFalse(data.appSettings.hideBalances)
        XCTAssertEqual(model.themeMode, .dark)

        let prefs = scratch.preferences
        XCTAssertEqual(prefs.value(forKey: PreferenceKey.baseCurrencyCode), .string("GBP"))
        XCTAssertNil(prefs.value(forKey: PreferenceKey.localeOverride))
        XCTAssertEqual(prefs.value(forKey: PreferenceKey.appLockEnabled), .bool(false))
        XCTAssertEqual(prefs.value(forKey: PreferenceKey.autoLockTimeoutSeconds), .int(30))
        XCTAssertEqual(prefs.value(forKey: PreferenceKey.hideBalances), .bool(false))
        XCTAssertEqual(prefs.value(forKey: PreferenceKey.themeMode), .string("dark"))

        let disk = try await scratch.stored()
        XCTAssertEqual(disk.revision, before.revision + 1, "one commit")
        XCTAssertEqual(disk.sections[Section.transactions]?.arrayValue?.count, 2)
        XCTAssertEqual(disk.sections[Section.appSettings]?.objectValue?["baseCurrencyCode"]?.stringValue, "GBP")
        for section in Section.all { XCTAssertEqual(disk.sections[section], data.serializedSection(section), section) }

        let copies = try scratch.completeSafetyCopies()
        XCTAssertEqual(copies.count, 1)
        let copiedPrimary = copies[0].appendingPathComponent(StoreFile.directoryName).appendingPathComponent(StoreFile.primaryName)
        let copied = try XCTUnwrap(StoreFile.verify([UInt8](try Data(contentsOf: copiedPrimary))))
        XCTAssertEqual(copied.revision, before.revision, "the copy is the store before the restore")
    }

    /// D10: a schema-1 file replaces its six keys and keeps the categories,
    /// tags, rules and settings (and their preferences) it does not carry.
    func testRestoreSchema1KeepsAbsentSections() async throws {
        let model = try await seededModel()
        let categoriesBefore = model.data?.categories
        let plan = try await model.decodeBackup(Array(Self.schema1.utf8))
        XCTAssertEqual(plan.keptItems, ["categories", "tags", "rules", "settings"])
        XCTAssertTrue(plan.confirmationMessage.hasSuffix(" Your categories, tags, rules and settings are kept."))

        let outcome = await model.restoreBackup(plan)
        XCTAssertEqual(outcome, .restored(generated: 0))
        let data = try XCTUnwrap(model.data)
        XCTAssertEqual(data.transactions.map(\.description), ["Schema one"])
        // Kept, plus the launch pass's definition for the restored rows'
        // "Food" (Flutter adds it at its next launch).
        let before = try XCTUnwrap(categoriesBefore)
        XCTAssertEqual(Array(data.categories.prefix(before.count)), before)
        XCTAssertEqual(data.categories.dropFirst(before.count).map(\.name), ["Food"])
        XCTAssertEqual(data.tags.map(\.name), ["Work"])
        XCTAssertEqual(data.appSettings.baseCurrencyCode, "EUR")
        XCTAssertTrue(data.appSettings.hideBalances)
        XCTAssertEqual(scratch.preferences.value(forKey: PreferenceKey.baseCurrencyCode), .string("EUR"))
        XCTAssertEqual(scratch.preferences.value(forKey: PreferenceKey.hideBalances), .bool(true))
        XCTAssertEqual(model.themeMode, .light)
    }

    /// A file Flutter refuses gives its message and changes nothing.
    func testCorruptFileChangesNothing() async throws {
        let model = try await seededModel()
        let before = try await scratch.stored()
        let dataBefore = model.data?.transactions
        for (text, expected) in [
            ("not json", BackupError.notABackup), (#"{"schemaVersion": 4, "data": {}}"#, .newerVersion),
            (#"{"schemaVersion": 3}"#, .missingData), (#"{"schemaVersion": 3, "data": {"transactions": [{"id": 1}]}}"#, .corrupt),
        ] {
            do {
                _ = try await model.decodeBackup(Array(text.utf8))
                XCTFail("\(text) decoded")
            } catch {
                XCTAssertEqual(error, expected, text)
            }
        }
        XCTAssertEqual(
            BackupEnvelope.importFailedMessage(BackupError.notABackup.message),
            "Could not import backup: This is not a valid Budgie backup file")
        XCTAssertEqual(model.data?.transactions, dataBefore)
        let after = try await scratch.stored()
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(try scratch.completeSafetyCopies(), [])
    }

    /// Each restore makes a safety copy, numbered in creation order; only
    /// the newest three are kept.
    func testSafetyCopiesArePrunedToThree() async throws {
        let model = await scratch.start()
        let plan = try await model.decodeBackup(Array(Self.schema3.utf8))
        for _ in 0..<4 {
            let outcome = await model.restoreBackup(plan)
            XCTAssertEqual(outcome, .restored(generated: 0))
        }
        let copies = try scratch.completeSafetyCopies().map(\.lastPathComponent)
        XCTAssertEqual(copies.map { String($0.prefix(8)) }, ["s000002-", "s000003-", "s000004-"])
    }

    /// A failed commit leaves memory, preferences, the theme and the unsaved
    /// flags as they were; the message names the failure.
    func testFailedCommitLeavesEverythingUnchanged() async throws {
        let model = try await seededModel()
        let plan = try await model.decodeBackup(Array(Self.schema3.utf8))
        let dataBefore = model.data
        let unlock = try scratch.lockStoreDirectory()
        defer { unlock() }

        let outcome = await model.restoreBackup(plan)
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(outcome.toast.message.hasPrefix("Could not import backup: "))
        XCTAssertEqual(outcome.toast.style, .danger)
        XCTAssertEqual(model.data?.transactions, dataBefore?.transactions)
        XCTAssertEqual(model.data?.appSettings, dataBefore?.appSettings)
        XCTAssertFalse(model.hasUnsavedChanges, "nothing is flagged")
        XCTAssertFalse(model.isRestoring)
        XCTAssertEqual(model.themeMode, .system)
        XCTAssertEqual(scratch.preferences.value(forKey: PreferenceKey.baseCurrencyCode), .string("EUR"))
        XCTAssertNil(scratch.preferences.value(forKey: PreferenceKey.themeMode))
        unlock()
        let disk = try await scratch.stored()
        XCTAssertEqual(disk.sections[Section.transactions]?.arrayValue?.count, 1)
    }

    /// No safety copy, no restore.
    func testNoRestoreWithoutASafetyCopy() async throws {
        let model = try await seededModel()
        let before = try await scratch.stored()
        let plan = try await model.decodeBackup(Array(Self.schema3.utf8))
        // A file where the copies' folder should be.
        try Data().write(to: scratch.preRestore)

        let outcome = await model.restoreBackup(plan)
        XCTAssertEqual(outcome, .failed(AppModel.DataTransferError(reason: "A safety copy of your current data could not be made.")))
        XCTAssertEqual(model.data?.transactions.map(\.description), ["Old lunch"])
        let after = try await scratch.stored()
        XCTAssertEqual(after.revision, before.revision)
    }

    /// Changes only in memory are saved before a restore, so the safety
    /// copy holds them; afterwards nothing is left to retry.
    func testRestoreSavesUnsavedChangesFirst() async throws {
        let model = try await seededModel()
        let plan = try await model.decodeBackup(Array(Self.schema3.utf8))
        let unlock = try scratch.lockStoreDirectory()
        let added = await model.addTransaction(type: .expense, description: "Unsaved", amount: 1, category: "Food", date: today)
        XCTAssertFalse(added)
        XCTAssertTrue(model.hasUnsavedChanges)
        unlock()

        let outcome = await model.restoreBackup(plan)
        XCTAssertEqual(outcome, .restored(generated: 0))
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.lastSaveError)
        let revision = try await scratch.stored().revision
        await model.retrySaves()
        let afterRetry = try await scratch.stored()
        XCTAssertEqual(afterRetry.revision, revision, "nothing left to retry")
        XCTAssertEqual(model.data?.transactions.map(\.description), ["Backup pay", "Backup rent"])

        let copy = try XCTUnwrap(try scratch.completeSafetyCopies().last)
        let primary = copy.appendingPathComponent(StoreFile.directoryName).appendingPathComponent(StoreFile.primaryName)
        let copied = try XCTUnwrap(StoreFile.decode([UInt8](try Data(contentsOf: primary))))
        let descriptions = copied.sections[Section.transactions]?.arrayValue?.compactMap { $0.objectValue?["description"]?.stringValue }
        XCTAssertEqual(descriptions, ["Old lunch", "Unsaved"], "the safety copy has the change that was unsaved")
    }

    /// Changes that still cannot be saved refuse the restore: nothing is
    /// copied, written or replaced, and they stay in memory behind the banner.
    func testRestoreRefusedWhileChangesCannotBeSaved() async throws {
        let model = try await seededModel()
        let plan = try await model.decodeBackup(Array(Self.schema3.utf8))
        let unlock = try scratch.lockStoreDirectory()
        defer { unlock() }
        let added = await model.addTransaction(type: .expense, description: "Unsaved", amount: 1, category: "Food", date: today)
        XCTAssertFalse(added)

        let outcome = await model.restoreBackup(plan)
        XCTAssertEqual(outcome, .failed(.unsavedChanges))
        XCTAssertEqual(
            outcome.toast.message,
            "Could not import backup: Some changes are not saved yet. Tap Retry at the top of the screen, then import the backup again.")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.isRestoring)
        XCTAssertEqual(model.data?.transactions.map(\.description), ["Old lunch", "Unsaved"])
        XCTAssertEqual(try scratch.completeSafetyCopies(), [])
        unlock()
        await model.retrySaves()
        XCTAssertFalse(model.hasUnsavedChanges)
        let disk = try await scratch.stored()
        XCTAssertEqual(disk.sections[Section.transactions]?.arrayValue?.count, 2)
    }

    /// While a restore runs routes wait, and a save that arrives anyway is
    /// flagged (not written, not dropped); the restore then stops before its
    /// commit, so the edit is kept and a retry saves it. A retry during the
    /// restore writes nothing.
    func testSaveDuringRestoreIsKept() async throws {
        let model = try await seededModel()
        let plan = try await model.decodeBackup(Array(Self.schema3.utf8))
        let before = try await scratch.stored()
        model.pendingAdd = .expense

        let restore = Task { await model.restoreBackup(plan) }
        while !model.isRestoring { await Task.yield() }
        XCTAssertFalse(model.canOpenRoutes, "routes wait for the restore")
        XCTAssertNil(model.takePendingAdd())
        let added = await model.addTransaction(type: .expense, description: "Mid-restore", amount: 2, category: "Food", date: today)
        XCTAssertFalse(added)
        XCTAssertTrue(model.hasUnsavedChanges, "flagged: the banner and Retry take over")
        await model.retrySaves()
        let duringRestore = try await scratch.stored().revision
        XCTAssertEqual(duringRestore, before.revision, "no retry during the restore")

        let outcome = await restore.value
        XCTAssertEqual(outcome, .failed(.changedDuringRestore))
        XCTAssertFalse(model.isRestoring)
        XCTAssertTrue(model.canOpenRoutes)
        XCTAssertEqual(model.takePendingAdd(), .expense, "the queued route opens now")
        XCTAssertEqual(model.data?.transactions.map(\.description), ["Old lunch", "Mid-restore"])
        let afterRestore = try await scratch.stored().revision
        XCTAssertEqual(afterRestore, before.revision, "the restore wrote nothing")

        await model.retrySaves()
        XCTAssertFalse(model.hasUnsavedChanges)
        let disk = try await scratch.stored()
        XCTAssertEqual(disk.sections[Section.transactions]?.arrayValue?.count, 2)
    }

    /// "Match device" in the file removes the locale mirror (both apps fall
    /// back to it when the stored value is null); a failed commit puts the
    /// old mirror back.
    func testMatchDeviceLocaleMirror() async throws {
        let model = try await seededModel()
        let set = await model.setLocaleOverride("de_DE")
        XCTAssertTrue(set)
        XCTAssertEqual(scratch.preferences.value(forKey: PreferenceKey.localeOverride), .string("de_DE"))
        let plan = try await model.decodeBackup(Array(Self.schema3.utf8))

        let unlock = try scratch.lockStoreDirectory()
        let failed = await model.restoreBackup(plan)
        guard case .failed = failed else { return XCTFail("\(failed)") }
        XCTAssertEqual(scratch.preferences.value(forKey: PreferenceKey.localeOverride), .string("de_DE"), "put back")
        XCTAssertEqual(model.data?.appSettings.localeOverride, "de_DE")
        unlock()

        let outcome = await model.restoreBackup(plan)
        XCTAssertEqual(outcome, .restored(generated: 0))
        XCTAssertNil(scratch.preferences.value(forKey: PreferenceKey.localeOverride))
        XCTAssertNil(model.data?.appSettings.localeOverride)
        let disk = try await scratch.stored()
        XCTAssertEqual(disk.sections[Section.appSettings]?.objectValue?["localeOverride"], .null)
        // What a relaunch reads: the null section value, no mirror to fall back on.
        let relaunched = await scratch.start()
        XCTAssertNil(relaunched.data?.appSettings.localeOverride)
    }

    /// Restore never marks the session unlocked: a file that turns App Lock
    /// on locks at once (Flutter's false -> true).
    func testRestoreTurningLockOnLocks() async throws {
        let model = await scratch.start()
        XCTAssertFalse(model.isLocked)
        let text = Self.schema3.replacingOccurrences(of: #""appLockEnabled": false"#, with: #""appLockEnabled": true"#)
        let plan = try await model.decodeBackup(Array(text.utf8))
        let outcome = await model.restoreBackup(plan)
        XCTAssertEqual(outcome, .restored(generated: 0))
        XCTAssertTrue(model.isLocked)
        XCTAssertFalse(model.canOpenRoutes)
    }
}
