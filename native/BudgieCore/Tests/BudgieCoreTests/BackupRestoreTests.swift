import Foundation
import Testing

@testable import BudgieCore

/// A store directory whose files cannot be read (device lock, I/O error).
private struct UnreadableStore: StoreFileSystem {
    struct Failure: Error {}
    func read(_ name: String) throws -> [UInt8]? { throw Failure() }
    func writeStaged(_ name: String, _ bytes: [UInt8]) throws { throw Failure() }
    func commitStaged(_ name: String) throws { throw Failure() }
    func rename(_ name: String, to newName: String) throws { throw Failure() }
    func list() throws -> [String] { [StoreFile.primaryName] }
}

@Suite("Pre-restore safety copy")
struct PreRestoreBackupTests {
    func support() -> URL {
        TestDirectory.make("budgie-restore")
    }

    func backup(_ support: URL, store: StoreFileSystem, at micros: Int64 = 1_790_000_000_000_000) -> PreRestoreBackup {
        let prefs = try! PropertyListSerialization.data(fromPropertyList: ["flutter.themeMode": "dark"], format: .binary, options: 0)
        return PreRestoreBackup(
            applicationSupport: support, store: store, exportPreferences: { prefs }, appVersion: "test",
            clock: { DartDateTime(microsecondsSinceEpoch: micros, timeZone: testZone) })
    }

    @Test("copies every store file byte for byte, the preferences and a manifest, COMPLETE last")
    func copies() throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        var files = try typicalFiles()
        files[StoreFile.primaryName + ".tmp"] = Array("garbage".utf8)
        let store = InMemoryFileSystem(files: files)
        let folder = try backup(support, store: store).create()
        #expect(folder.deletingLastPathComponent().lastPathComponent == PreRestoreBackup.folderName)
        #expect(folder.deletingLastPathComponent().deletingLastPathComponent().path == support.path)
        #expect(folder.lastPathComponent.hasPrefix("s000001-20260921-141320-000000-"))
        for (name, bytes) in files {
            let copy = try Data(contentsOf: folder.appendingPathComponent(StoreFile.directoryName).appendingPathComponent(name))
            #expect([UInt8](copy) == bytes, "\(name)")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(StoreFile.directoryName).path)
        #expect(Set(names) == Set(files.keys))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PreRestoreBackup.preferencesName).path))
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(PreRestoreBackup.manifestName))) as! [String: Any]
        #expect(manifest["reason"] as? String == "restore")
        #expect((manifest["files"] as? [[String: Any]])?.count == files.count)
        #expect(manifest["primaryChecksum"] as? String == StoreFile.verify(files[StoreFile.primaryName]!)?.payloadChecksum)
        #expect(try backup(support, store: store).completeSnapshots().map(\.lastPathComponent) == [folder.lastPathComponent])
    }

    @Test("an empty store still gets a complete copy (preferences only)")
    func emptyStore() throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        let folder = try backup(support, store: InMemoryFileSystem()).create()
        #expect(try backup(support, store: InMemoryFileSystem()).completeSnapshots().map(\.lastPathComponent) == [folder.lastPathComponent])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(StoreFile.directoryName).path).isEmpty)
    }

    @Test("a store that cannot be read, or a folder that cannot be written, fails and leaves nothing")
    func failures() throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(throws: (any Error).self) { try backup(support, store: UnreadableStore()).create() }
        #expect(try backup(support, store: UnreadableStore()).completeSnapshots().isEmpty)
        let root = support.appendingPathComponent(PreRestoreBackup.folderName)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty ?? true)

        // `pre-restore` is a file: nothing can be created under it.
        try? FileManager.default.removeItem(at: root)
        try Data("x".utf8).write(to: root)
        #expect(throws: (any Error).self) {
            try backup(support, store: InMemoryFileSystem(files: try typicalFiles())).create()
        }
    }

    @Test("prune keeps the newest three complete copies and drops incomplete ones; other folders untouched")
    func prune() throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = InMemoryFileSystem(files: try typicalFiles())
        var created: [URL] = []
        for second in 0..<5 {
            created.append(try backup(support, store: store, at: 1_790_000_000_000_000 + Int64(second) * 1_000_000).create())
        }
        let incomplete = support.appendingPathComponent(PreRestoreBackup.folderName).appendingPathComponent("20260922-000000-000000-dead")
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        let sibling = support.appendingPathComponent(PreNativeMigrationBackup.folderName).appendingPathComponent("x")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let removed = try backup(support, store: store).prune()
        #expect(Set(removed.map(\.lastPathComponent)) == Set((created.prefix(2) + [incomplete]).map(\.lastPathComponent)))
        #expect(try backup(support, store: store).completeSnapshots().map(\.lastPathComponent) == created.suffix(3).map(\.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
    }

    @Test("a clock set back still numbers the new copy last: prune never removes it")
    func backwardsClock() throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = InMemoryFileSystem(files: try typicalFiles())
        // Three copies made with the right date, then the clock goes back a
        // year: the new copy's stamp sorts first but its sequence is last.
        var created: [URL] = []
        for second in 0..<3 {
            created.append(try backup(support, store: store, at: 1_790_000_000_000_000 + Int64(second) * 1_000_000).create())
        }
        let yearEarlier: Int64 = 1_790_000_000_000_000 - 365 * 86_400 * 1_000_000
        let newest = try backup(support, store: store, at: yearEarlier).create()
        #expect(newest.lastPathComponent.hasPrefix("s000004-2025"))
        #expect(newest.lastPathComponent.dropFirst(8) < created[0].lastPathComponent.dropFirst(8), "its stamp alone would sort first")
        #expect(try backup(support, store: store).completeSnapshots().last?.lastPathComponent == newest.lastPathComponent)

        let removed = try backup(support, store: store, at: yearEarlier).prune(protecting: newest)
        #expect(removed.map(\.lastPathComponent) == [created[0].lastPathComponent])
        #expect(
            try backup(support, store: store).completeSnapshots().map(\.lastPathComponent)
                == (created.suffix(2) + [newest]).map(\.lastPathComponent))
    }

    @Test("the protected copy survives any prune; unnumbered folders count as oldest")
    func protectedAndLegacy() throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = InMemoryFileSystem(files: try typicalFiles())
        // A complete copy from before the sequence, stamped far in the future.
        let legacy = support.appendingPathComponent(PreRestoreBackup.folderName).appendingPathComponent("20991231-235959-000000-beef")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("ok\n".utf8).write(to: legacy.appendingPathComponent(PreRestoreBackup.completeMarker))
        let first = try backup(support, store: store).create()
        #expect(first.lastPathComponent.hasPrefix("s000001-"))
        let second = try backup(support, store: store).create()
        #expect(second.lastPathComponent.hasPrefix("s000002-"))
        #expect(
            try backup(support, store: store).completeSnapshots().map(\.lastPathComponent)
                == [legacy, first, second].map(\.lastPathComponent))

        let removed = try backup(support, store: store).prune(keeping: 0, protecting: second)
        #expect(Set(removed.map(\.lastPathComponent)) == Set([legacy, first].map(\.lastPathComponent)))
        #expect(try backup(support, store: store).completeSnapshots().map(\.lastPathComponent) == [second.lastPathComponent])
    }

    @Test("the restore commit copies first on the store actor; no copy, no commit")
    func commitAfterSafetyCopy() async throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        let files = InMemoryFileSystem(files: try typicalFiles())
        let store = FinancialStore(fileSystem: files, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        let before = try await store.read()
        let copier = backup(support, store: files)

        struct CopyFailed: Error {}
        do {
            _ = try await store.updateSections([(Section.transactions, .array([]))], afterSafetyCopy: { throw CopyFailed() })
            Issue.record("committed without a copy")
        } catch {
            guard case .safetyCopyFailed = error else { Issue.record("\(error)"); return }
        }
        #expect(try await store.read().revision == before.revision, "nothing written")

        let folder = try await store.updateSections([(Section.transactions, .array([]))], afterSafetyCopy: { try copier.create() })
        #expect(try await store.read().revision == before.revision + 1)
        let copied = try Data(contentsOf: folder.appendingPathComponent(StoreFile.directoryName).appendingPathComponent(StoreFile.primaryName))
        #expect(StoreFile.verify([UInt8](copied))?.revision == before.revision, "the copy is the store the commit replaced")
    }
}

@Suite("Backup restore: one commit, D10 keeps what the file leaves out")
struct BackupRestoreTests {
    let calendar = DartCalendar(timeZone: testZone)

    func typical() async throws -> (FinancialData, InMemoryFileSystem, FinancialStore) {
        let files = InMemoryFileSystem(files: try typicalFiles())
        let store = FinancialStore(fileSystem: files, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        let snapshot = try await store.read()
        let data = FinancialData.load(snapshot, preferences: InMemoryPreferences(), calendar: calendar, now: fixedNow, newID: { "load-id" }).data
        return (data, files, store)
    }

    func decode(_ text: String) throws -> RestorePlan {
        var n = 0
        return try BackupEnvelope.decode(bytes: Array(text.utf8), calendar: calendar, now: fixedNow(), newID: {
            n += 1
            return "decoded-\(n)"
        })
    }

    @Test("a schema-1 file keeps categories, tags, rules and settings; the rest is replaced")
    func schemaOne() async throws {
        let (current, _, _) = try await typical()
        let plan = try decode(#"""
            {"schemaVersion":1,"data":{
             "transactions":[{"id":"a","type":"expense","description":"d","amount":1,"category":"Brand New","date":"2026-01-01"},
                             {"id":"a","type":"income","description":"dup","amount":2.5,"category":"Salary","date":"2026-01-02"}],
             "netWorthEntries":[],"categoryBudgetLimits":{"Zero":0,"Keep":12},"savingsGoals":[],"recurringTransactions":[],"themeMode":"dark"}}
            """#)
        var ids = 0
        let result = current.restoring(plan, now: fixedNow(), newID: {
            ids += 1
            return "fresh-\(ids)"
        })
        let data = result.data
        #expect(data.transactions.map(\.id) == ["a", "fresh-1"])
        #expect(data.transactions[1].raw["id"]?.stringValue == "fresh-1")
        #expect(data.budgetLimits.map(\.0) == ["Keep"])
        #expect(data.netWorthEntries.isEmpty && data.savingsGoals.isEmpty && data.templates.isEmpty)
        // Kept: rows (byte for byte), settings, the selected month.
        for section in [Section.transactionTags, Section.categorizationRules, Section.appSettings, Section.selectedNetWorthMonth] {
            #expect(DartJSON.encode(data.serializedSection(section)!) == DartJSON.encode(current.serializedSection(section)!), "\(section)")
        }
        #expect(data.appSettings == current.appSettings)
        // Categories kept, plus the legacy name the restored rows use.
        let before = current.categories.map(\.id)
        #expect(Array(data.categories.map(\.id).prefix(before.count)) == before)
        #expect(Array(data.categories.map(\.name).suffix(2)) == ["Brand New", "Keep"])
        #expect(result.preferenceWrites.isEmpty)
        #expect(plan.keptSections == [
            Section.selectedNetWorthMonth, Section.categories, Section.transactionTags, Section.categorizationRules,
            Section.appSettings,
        ])
        #expect(plan.replacedSections == [
            Section.transactions, Section.netWorthEntries, Section.categoryBudgetLimits, Section.savingsGoals,
            Section.recurringTransactions,
        ])
        #expect(result.themeMode == "dark")
        #expect(result.sections.map(\.0) == Section.all)
        // Pure: the current data is untouched.
        #expect(current.transactions.count > 2)
    }

    @Test("settings: provided ones are applied and mirrored in Flutter's order; locale trimmed, blank is Match device")
    func settings() async throws {
        let (current, _, _) = try await typical()
        let plan = try decode(#"{"schemaVersion":3,"data":{"baseCurrencyCode":" gbp ","localeOverride":"   ","appLockEnabled":true,"autoLockTimeoutSeconds":29.9,"hideBalances":false}}"#)
        let result = current.restoring(plan, now: fixedNow(), newID: { "x" })
        #expect(result.data.appSettings == AppSettings(
            baseCurrencyCode: "GBP", localeOverride: nil, appLockEnabled: true, autoLockTimeoutSeconds: 29, hideBalances: false))
        #expect(result.preferenceWrites.map(\.key) == [
            PreferenceKey.baseCurrencyCode, PreferenceKey.localeOverride, PreferenceKey.appLockEnabled,
            PreferenceKey.autoLockTimeoutSeconds, PreferenceKey.hideBalances,
        ])
        #expect(result.preferenceWrites.map(\.value) == [.string("GBP"), nil, .bool(true), .int(29), .bool(false)])
        let padded = try decode(#"{"schemaVersion":3,"data":{"localeOverride":" de_DE "}}"#)
        let second = current.restoring(padded, now: fixedNow(), newID: { "x" })
        #expect(second.data.appSettings.localeOverride == "de_DE")
        #expect(second.preferenceWrites.map(\.value) == [.string("de_DE")])
        #expect(second.data.appSettings.baseCurrencyCode == current.appSettings.baseCurrencyCode)
    }

    @Test("an empty categories list restores the built-ins; unreadable rows of a replaced section are gone")
    func categoriesAndUnreadable() async throws {
        let calendar = self.calendar
        let sections = try JSONParser.parse(#"""
            {"transactions":[{"id":"ok","type":"expense","description":"d","amount":1.0,"category":"General","date":"2026-01-01T00:00:00.000"},{"id":"bad"}],
             "transactionTags":[{"id":"t","name":"Keep"},{"id":5}]}
            """#).objectValue!
        let current = FinancialData.load(
            FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences(), calendar: calendar,
            now: fixedNow, newID: { "id" }
        ).data
        #expect(current.transactionRows.count == 2 && current.tagRows.count == 2)
        let plan = try decode(#"{"schemaVersion":3,"data":{"transactions":[],"categories":[]}}"#)
        let result = current.restoring(plan, now: fixedNow(), newID: { "x" })
        #expect(result.data.transactionRows.isEmpty)
        // Tags were not in the file: kept, the unreadable row too.
        #expect(DartJSON.encode(result.data.tagsSection()) == DartJSON.encode(current.tagsSection()))
        #expect(result.data.categories.map(\.id) == CategoryCatalog.builtIn.map(\.id))
    }

    @Test("the one commit: a verified write whose backup file is the pre-restore primary; the store reloads as restored")
    func commit() async throws {
        // Typical's first launch defines its padded category name (Flutter
        // does so at every launch), and its templates are due: use a store
        // that a launch leaves as it is.
        let files = InMemoryFileSystem()
        let store = FinancialStore(fileSystem: files, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        let seed = try JSONParser.parse(#"""
            {"transactions":[{"id":"t1","type":"expense","description":"Café \"x\"","amount":12,"category":"Groceries","date":"2026-09-01","tagIds":["g"]},
                             {"id":"t2","type":"income","description":"Pay","amount":100.5,"category":"Side Gig","date":"2026-09-02T09:00:00.000Z"}],
             "transactionTags":[{"id":"g","name":" Work "}],
             "categorizationRules":[{"id":"r1","merchantPattern":"a","priority":0},{"id":"r2","merchantPattern":"b","priority":5,"tagIds":["g"]}],
             "categoryBudgetLimits":{"Groceries":250,"Nope":0},
             "recurringTransactions":[{"id":"rt","type":"expense","description":"Rent","amount":1500.0,"category":"Housing","pattern":"monthly","startDate":"2026-01-31","nextOccurrence":"2026-10-31T00:00:00.000","dayOfMonth":31}],
             "appSettings":{"baseCurrencyCode":"EUR","localeOverride":null,"appLockEnabled":false,"autoLockTimeoutSeconds":60,"hideBalances":false}}
            """#).objectValue!
        try await store.updateSections(seed.members.map { ($0.key.value, $0.value) })
        let launched = FinancialData.load(
            try await store.read(), preferences: InMemoryPreferences(), calendar: calendar, now: fixedNow, newID: { "launch" })
        try await store.updateSections(launched.pendingWrites)
        let current = launched.data
        let primaryBefore = files.snapshot[StoreFile.primaryName]!
        let backupBytes = try BackupEnvelope.encode(data: current, themeMode: "system", appVersion: "4.0.0", now: fixedNow())
        let plan = try BackupEnvelope.decode(bytes: backupBytes, calendar: calendar, now: fixedNow(), newID: { "x" })
        #expect(plan.keptItems.isEmpty)
        let result = current.restoring(plan, now: fixedNow(), newID: { UUID().uuidString.lowercased() })
        let before = try await store.read()
        let after = try await store.updateSections(result.sections)
        #expect(after.revision == before.revision + 1)
        #expect(files.snapshot[StoreFile.backupName] == primaryBefore)

        await store.resetInMemoryState()
        let reloaded = FinancialData.load(
            try await store.read(), preferences: InMemoryPreferences(), calendar: calendar, now: fixedNow, newID: { "reload" })
        #expect(reloaded.pendingWrites.isEmpty)
        for section in Section.all {
            #expect(DartJSON.encode(reloaded.data.serializedSection(section)!) == DartJSON.encode(result.data.serializedSection(section)!),
                    "\(section)")
        }
        #expect(result.generatedTransactions == 0)
        // Export after restore is the file restored.
        let reexport = try BackupEnvelope.encode(data: reloaded.data, themeMode: "system", appVersion: "4.0.0", now: fixedNow())
        #expect(reexport == backupBytes)
    }
}
