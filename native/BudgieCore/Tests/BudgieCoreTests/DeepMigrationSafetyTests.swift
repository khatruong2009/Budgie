import Foundation
import Testing

@testable import BudgieCore

@Suite("Deep migration audit: interrupted recovery and missing storage")
struct DeepMigrationSafetyTests {
    @Test("repeated corruption at the same clock time preserves every original")
    func repeatedCorruption() async throws {
        let files = InMemoryFileSystem()
        let prefs = InMemoryPreferences()
        for episode in 0..<3 {
            files.set(StoreFile.primaryName, Array("primary-\(episode)".utf8))
            files.set(StoreFile.backupName, Array("backup-\(episode)".utf8))
            let store = FinancialStore(fileSystem: files, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
            do {
                _ = try await store.read()
                Issue.record("Corruption must block")
            } catch .dataUnreadable(let names) {
                #expect(names.count == (episode + 1) * 2)
            }
            for prior in 0...episode {
                #expect(files.snapshot.values.contains(Array("primary-\(prior)".utf8)))
                #expect(files.snapshot.values.contains(Array("backup-\(prior)".utf8)))
            }
        }
    }

    @Test("a checksummed but undecodable primary cannot overwrite a usable backup")
    func undecodablePrimaryDuringCommit() async throws {
        let files = InMemoryFileSystem(files: try typicalFiles())
        let store = FinancialStore(fileSystem: files, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        _ = try await store.read()
        let backup = files.snapshot[StoreFile.backupName]!
        let payload = Array("[42]".utf8)
        let header = JSONObject(ordered: [
            ("format", .string(StoreFile.formatTag)), ("schemaVersion", .int(2)), ("revision", .int(999)),
            ("payloadLength", .int(payload.count)), ("payloadChecksum", .string(StoreFile.checksum(payload))),
        ])
        let bad = DartJSON.encode(.object(header)) + [0x0A] + payload
        #expect(StoreFile.verify(bad) != nil && StoreFile.decode(bad) == nil)
        files.set(StoreFile.primaryName, bad)
        try await store.updateSections([("probe", .int(1))])
        #expect(files.snapshot[StoreFile.backupName] == backup)
        #expect(StoreFile.decode(files.snapshot[StoreFile.backupName]!) != nil)
    }

    @Test("missing files after a verified save block stale settings fallback")
    func missingPreviouslySavedFiles() async throws {
        let files = InMemoryFileSystem()
        let prefs = InMemoryPreferences([PreferenceKey.baseCurrencyCode: .string("GBP")])
        let store = FinancialStore(fileSystem: files, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        try await store.updateSections([("valuable", .int(42))])
        files.set(StoreFile.primaryName, nil)
        files.set(StoreFile.backupName, nil)
        let original = prefs.all
        let relaunched = FinancialStore(fileSystem: files, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        await #expect(throws: FinancialStoreError.self) { try await relaunched.read() }
        #expect(files.snapshot.isEmpty)
        #expect(prefs.all == original)
    }

    @Test("explicitly acknowledged corruption can start fresh after a prior save")
    func acknowledgedAfterPriorSave() async throws {
        let files = InMemoryFileSystem()
        let prefs = InMemoryPreferences()
        let store = FinancialStore(fileSystem: files, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        try await store.updateSections([("valuable", .int(42))])
        files.set(StoreFile.primaryName, Array("damaged".utf8))
        await store.resetInMemoryState()
        do {
            _ = try await store.read()
            Issue.record("Expected blocked corruption")
        } catch .dataUnreadable(let names) {
            try await store.acknowledgeUnreadableData(names)
            #expect(try await store.read() == .empty)
            #expect(files.snapshot.values.contains(Array("damaged".utf8)))
        }
    }

    @Test("protection becoming unavailable after staging prevents either rename")
    func lockAfterStaging() async throws {
        for stagedName in [StoreFile.backupName, StoreFile.primaryName] {
            let gate = Switch(true)
            let base = InMemoryFileSystem(files: try typicalFiles())
            let files = LockAfterStage(base: base, gate: gate, stagedName: stagedName)
            let prefs = InMemoryPreferences()
            let store = FinancialStore(fileSystem: files, preferences: prefs, protectedData: gate, clock: fixedNow)
            let before = try await store.read()
            let originalPrimary = base.snapshot[StoreFile.primaryName]
            await #expect(throws: FinancialStoreError.protectedDataUnavailable) {
                try await store.updateSections([("probe", .int(1))])
            }
            #expect(base.snapshot[StoreFile.primaryName] == originalPrimary)
            #expect(prefs.string(PreferenceKey.lastCommittedChecksum) == nil)
            gate.set(true)
            #expect(try await FinancialStore(fileSystem: base, preferences: prefs, protectedData: gate, clock: fixedNow).read() == before)
        }
    }

    @Test("a regular file in place of the store directory is never an empty install")
    func invalidParentDirectory() async throws {
        let parent = TestDirectory.make("budgie-deep")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let dir = parent.appendingPathComponent(StoreFile.directoryName)
        let original = Data("preserve this file".utf8)
        try original.write(to: dir)
        let store = FinancialStore(fileSystem: DirectoryFileSystem(directory: dir), preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        #expect(throws: StoreFileSystemError.self) { try DirectoryFileSystem(directory: dir).read(StoreFile.primaryName) }
        await #expect(throws: FinancialStoreError.self) { try await store.read() }
        #expect(try Data(contentsOf: dir) == original)
    }

    @Test("initial legacy migration interrupted at each write keeps preferences and recovers on retry")
    func interruptedLegacyMigration() async throws {
        for fault in [FaultyFileSystem.Fault.crashBefore, .crashTornWrite, .diskFull] {
            for operation in 0..<2 {
                let prefs = InMemoryPreferences([
                    PreferenceKey.transactions: .string("[{\"amount\":42,\"description\":\"keep me\"}]"),
                    PreferenceKey.baseCurrencyCode: .string("GBP"),
                ])
                let original = prefs.all
                let expected = LegacyMigration.migrate(prefs)!.snapshot
                let files = InMemoryFileSystem()
                let store = FinancialStore(fileSystem: FaultyFileSystem(base: files, failAt: operation, fault: fault), preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
                await #expect(throws: FinancialStoreError.self) { try await store.read() }
                #expect(prefs.all == original)
                let retry = FinancialStore(fileSystem: files, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
                #expect(try await retry.read() == expected)
                #expect(!prefs.contains(PreferenceKey.transactions))
            }
        }
    }

    @Test("backup recovery interrupted at each write retains the original recovery file")
    func interruptedBackupRecovery() async throws {
        for fault in [FaultyFileSystem.Fault.crashBefore, .crashTornWrite, .diskFull] {
            for operation in 0..<2 {
                let original = try typicalFiles()[StoreFile.primaryName]!
                let files = InMemoryFileSystem(files: [StoreFile.primaryName: Array("broken".utf8), StoreFile.backupName: original])
                let store = FinancialStore(fileSystem: FaultyFileSystem(base: files, failAt: operation, fault: fault), preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
                await #expect(throws: FinancialStoreError.self) { try await store.read() }
                #expect(files.snapshot[StoreFile.backupName] == original)
                let retry = FinancialStore(fileSystem: files, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
                #expect(try await retry.read() == StoreFile.decode(original))
            }
        }
    }

    @Test("large on-disk ledger retains every record, original lexeme and unknown section")
    func largeRealDiskRoundTrip() async throws {
        let dir = TestDirectory.make("budgie-large")
        defer { try? FileManager.default.removeItem(at: dir) }
        var snapshot = try #require(StoreFile.decode(typicalFiles()[StoreFile.primaryName]!))
        let exemplar = try #require(snapshot.sections[Section.transactions]?.arrayValue?.first?.objectValue)
        let rows: [JSONValue] = (0..<20_000).map { index in
            var row = exemplar
            row["id"] = .string("stress-\(index)")
            row["description"] = .string("旅費 😀 café \(index)")
            row["amount"] = try! JSONParser.parse("\(index).125000")
            row["futureField"] = .object(JSONObject(ordered: [("preserve", .string("\(index)"))]))
            return .object(row)
        }
        snapshot.sections[Section.transactions] = .array(rows)
        snapshot.sections["futureFeature"] = .object(JSONObject(ordered: [("valuable", .string("keep me"))]))
        let original = StoreFile.encode(snapshot, writtenAt: fixedNow())
        let fs = DirectoryFileSystem(directory: dir)
        try fs.writeStaged(StoreFile.primaryName, original)
        try fs.commitStaged(StoreFile.primaryName)
        let prefs = InMemoryPreferences()
        let store = FinancialStore(fileSystem: fs, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        let loaded = FinancialData.load(try await store.read(), preferences: prefs, calendar: DartCalendar(timeZone: testZone), now: fixedNow, newID: { UUID().uuidString })
        #expect(loaded.data.transactions.count == rows.count)
        #expect(DartJSON.encode(loaded.data.transactionsSection()) == DartJSON.encode(.array(rows)))
        try await store.updateSections([(Section.transactions, loaded.data.transactionsSection())])
        let reloaded = try await FinancialStore(fileSystem: fs, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow).read()
        #expect(DartJSON.encode(.object(reloaded.sections)) == DartJSON.encode(.object(snapshot.sections)))
        #expect(try fs.read(StoreFile.backupName) == original)
    }
}

private final class LockAfterStage: StoreFileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    let gate: Switch
    let stagedName: String
    init(base: InMemoryFileSystem, gate: Switch, stagedName: String) {
        self.base = base; self.gate = gate; self.stagedName = stagedName
    }
    func read(_ name: String) throws -> [UInt8]? { try base.read(name) }
    func writeStaged(_ name: String, _ bytes: [UInt8]) throws {
        try base.writeStaged(name, bytes)
        if name == stagedName { gate.set(false) }
    }
    func commitStaged(_ name: String) throws { try base.commitStaged(name) }
    func rename(_ name: String, to newName: String) throws { try base.rename(name, to: newName) }
    func list() throws -> [String] { try base.list() }
}
