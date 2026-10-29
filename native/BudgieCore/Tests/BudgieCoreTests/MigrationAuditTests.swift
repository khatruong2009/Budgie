import Foundation
import Testing

@testable import BudgieCore

@Suite("Migration audit: never mistake damaged user data for a fresh install")
struct MigrationAuditTests {
    @Test("damaged files still block when settings or stale legacy data exist")
    func corruptionWithPreferences() async throws {
        for prefs in [
            [PreferenceKey.baseCurrencyCode: PreferenceValue.string("GBP")],
            [PreferenceKey.transactions: PreferenceValue.string("[]")],
        ] {
            let files = InMemoryFileSystem(files: [
                StoreFile.primaryName: Array("damaged primary".utf8),
                StoreFile.backupName: Array("damaged backup".utf8),
            ])
            let preferences = InMemoryPreferences(prefs)
            for _ in 0..<2 {
                let store = FinancialStore(fileSystem: files, preferences: preferences, protectedData: AlwaysAvailable(), clock: fixedNow)
                do {
                    _ = try await store.read()
                    Issue.record("Damaged files must block, including on relaunch")
                } catch .dataUnreadable(let names) {
                    #expect(names.count == 2)
                }
                #expect(files.snapshot[StoreFile.primaryName] == nil)
                #expect(files.snapshot[StoreFile.backupName] == nil)
                #expect(preferences.all == prefs)
            }
            #expect(files.snapshot.values.contains(Array("damaged primary".utf8)))
            #expect(files.snapshot.values.contains(Array("damaged backup".utf8)))
        }
    }

    @Test("malformed legacy ledger cannot be erased by a settings-only migration")
    func malformedLegacyLedger() async throws {
        for raw in ["not JSON", "", "null", "{}"] {
            let preferences = InMemoryPreferences([
                PreferenceKey.transactions: .string(raw),
                PreferenceKey.baseCurrencyCode: .string("GBP"),
            ])
            let original = preferences.all
            let files = InMemoryFileSystem()
            let store = FinancialStore(fileSystem: files, preferences: preferences, protectedData: AlwaysAvailable(), clock: fixedNow)
            do {
                _ = try await store.read()
                Issue.record("An existing unreadable ledger must block before committing")
            } catch .readFailed {
            }
            #expect(files.snapshot.isEmpty)
            #expect(preferences.all == original)
        }
    }

    @Test("a legacy-only Flutter update receives a new safety copy even without a primary")
    func legacyBackupRefresh() throws {
        let support = TestDirectory.make("budgie-audit")
        defer { try? FileManager.default.removeItem(at: support) }
        let store = support.appendingPathComponent(StoreFile.directoryName)
        func backup(_ ledger: String) -> PreNativeMigrationBackup {
            let prefs = try! PropertyListSerialization.data(
                fromPropertyList: [PreferenceKey.transactions: ledger], format: .binary, options: 0)
            return PreNativeMigrationBackup(applicationSupport: support,
                sources: .init(storeDirectory: store, exportPreferences: { prefs }, exportAppGroupPreferences: { Data() }),
                appVersion: "audit")
        }
        guard case .created = try backup("[]").ensure(lastCommittedChecksum: nil) else { Issue.record(); return }
        guard case .created(let folder) = try backup("[{\"amount\":42.0}]").ensure(lastCommittedChecksum: nil) else {
            Issue.record("Changed legacy data must be copied before migration removes its keys")
            return
        }
        let saved = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: folder.appendingPathComponent("preferences.plist")), format: nil) as! [String: Any]
        #expect(saved[PreferenceKey.transactions] as? String == "[{\"amount\":42.0}]")
    }

    @Test("an unreadable v1 envelope blocks even when unrelated settings are valid")
    func damagedEnvelope() async throws {
        let prefs = InMemoryPreferences([
            PreferenceKey.legacyEnvelope: .string("truncated"),
            PreferenceKey.baseCurrencyCode: .string("GBP"),
        ])
        let original = prefs.all
        let files = InMemoryFileSystem()
        let store = FinancialStore(fileSystem: files, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        await #expect(throws: FinancialStoreError.self) { try await store.read() }
        #expect(files.snapshot.isEmpty)
        #expect(prefs.all == original)
    }

    @Test("a changed recovery backup receives a safety copy even when the primary is unchanged")
    func recoveryBackupRefresh() throws {
        let helper = PreNativeBackupTests()
        let (support, store) = try helper.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: support) }
        let backup = helper.backup(support, store)
        guard case .created = try backup.ensure(lastCommittedChecksum: nil) else { Issue.record(); return }
        let newBytes = StoreFile.encode(FinancialSnapshot(revision: 999, sections: JSONObject(ordered: [("recovered", .int(42))])), writtenAt: fixedNow())
        try Data(newBytes).write(to: store.appendingPathComponent(StoreFile.backupName))
        guard case .created(let folder) = try backup.ensure(lastCommittedChecksum: nil) else {
            Issue.record("The changed recovery file must be copied before restoring it")
            return
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent(StoreFile.directoryName).appendingPathComponent(StoreFile.backupName)) == Data(newBytes))
    }

    @Test("a COMPLETE marker cannot make a damaged safety copy reusable")
    func damagedSafetyCopy() throws {
        let helper = PreNativeBackupTests()
        let (support, store) = try helper.makeEnvironment()
        defer { try? FileManager.default.removeItem(at: support) }
        let backup = helper.backup(support, store)
        guard case .created(let folder) = try backup.ensure(lastCommittedChecksum: nil) else { Issue.record(); return }
        let primary = folder.appendingPathComponent(StoreFile.directoryName).appendingPathComponent(StoreFile.primaryName)
        try Data("broken safety copy".utf8).write(to: primary)
        guard case .created = try backup.ensure(lastCommittedChecksum: nil) else {
            Issue.record("A safety copy must pass its manifest hashes before reuse")
            return
        }
    }

    @Test("a valid but different payload at the same revision is a failed save")
    func verifyEntirePayload() async throws {
        let base = InMemoryFileSystem(files: try typicalFiles())
        let prefs = InMemoryPreferences()
        let files = SubstitutingFileSystem(base: base)
        let store = FinancialStore(fileSystem: files, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        let before = try await store.read()
        await #expect(throws: FinancialStoreError.verificationFailed(expected: before.revision + 1, found: before.revision + 1)) {
            try await store.updateSections([("probe", .string("intended value"))])
        }
        #expect(try await store.read() == before)
        #expect(prefs.string(PreferenceKey.lastCommittedChecksum) == nil)
        #expect(StoreFile.decode(base.snapshot[StoreFile.backupName]!) == before)
    }
}

private final class SubstitutingFileSystem: ForwardingStoreFileSystem, @unchecked Sendable {
    override func commitStaged(_ name: String) throws {
        try super.commitStaged(name)
        if name == StoreFile.primaryName, var snapshot = StoreFile.decode(base.snapshot[name]!) {
            snapshot.sections["probe"] = .string("different value")
            base.set(name, StoreFile.encode(snapshot, writtenAt: fixedNow()))
        }
    }
}
