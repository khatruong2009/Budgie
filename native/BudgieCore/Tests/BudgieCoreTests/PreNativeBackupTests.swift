import Foundation
import Testing

@testable import BudgieCore

@Suite("Pre-native migration backup (rule 1)")
struct PreNativeBackupTests {
    func makeEnvironment() throws -> (support: URL, store: URL) {
        let support = TestDirectory.make("budgie-support")
        let store = support.appendingPathComponent(StoreFile.directoryName)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        for (name, bytes) in try typicalFiles() {
            try Data(bytes).write(to: store.appendingPathComponent(name))
        }
        try Data("garbage".utf8).write(to: store.appendingPathComponent(StoreFile.primaryName + ".tmp"))
        return (support, store)
    }

    func backup(_ support: URL, _ store: URL) -> PreNativeMigrationBackup {
        let prefs = try! PropertyListSerialization.data(
            fromPropertyList: ["flutter.themeMode": "dark", "flutter.financial_store_v1": "{}"], format: .binary, options: 0)
        let group = try! PropertyListSerialization.data(fromPropertyList: ["cashFlow": 12.5], format: .binary, options: 0)
        return PreNativeMigrationBackup(
            applicationSupport: support,
            sources: .init(storeDirectory: store, exportPreferences: { prefs }, exportAppGroupPreferences: { group }),
            appVersion: "test")
    }

    @Test("copies every store file and both preference domains, byte for byte, marked complete")
    func createsCompleteCopy() throws {
        let (support, store) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: support) }
        guard case .created(let folder) = try backup(support, store).ensure(lastCommittedChecksum: nil) else {
            Issue.record("expected a new snapshot")
            return
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: store.path) {
            let original = try Data(contentsOf: store.appendingPathComponent(name))
            let copy = try Data(contentsOf: folder.appendingPathComponent(StoreFile.directoryName).appendingPathComponent(name))
            #expect(original == copy, "\(name)")
        }
        let prefs = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: folder.appendingPathComponent("preferences.plist")), format: nil) as! [String: Any]
        #expect(prefs["flutter.financial_store_v1"] as? String == "{}")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("app-group.plist").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PreNativeMigrationBackup.completeMarker).path))
    }

    @Test("not repeated while the store is unchanged or last written by this app; repeated after an outside write")
    func snapshotPolicy() async throws {
        let (support, store) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: support) }
        let backup = backup(support, store)
        guard case .created = try backup.ensure(lastCommittedChecksum: nil) else { Issue.record(); return }
        guard case .alreadyCurrent = try backup.ensure(lastCommittedChecksum: nil) else { Issue.record(); return }

        // The Swift app commits; its own write does not trigger a new copy.
        let prefs = InMemoryPreferences()
        let swiftStore = FinancialStore(
            fileSystem: DirectoryFileSystem(directory: store), preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        try await swiftStore.updateSections([("probe", .int(1))])
        let last = prefs.string(PreferenceKey.lastCommittedChecksum)
        guard case .alreadyCurrent = try backup.ensure(lastCommittedChecksum: last) else { Issue.record(); return }

        // Someone else (a reinstalled Flutter build) writes: a new copy.
        let other = FinancialStore(
            fileSystem: DirectoryFileSystem(directory: store), preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        try await other.updateSections([("probe", .int(2))])
        guard case .created = try backup.ensure(lastCommittedChecksum: last) else { Issue.record(); return }
        #expect(try backup.completeSnapshots().count == 2)
    }

    @Test("an incomplete snapshot (no COMPLETE marker) does not count")
    func incompleteIgnored() throws {
        let (support, store) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: support) }
        let partial = support.appendingPathComponent(PreNativeMigrationBackup.folderName).appendingPathComponent("00000000-partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        guard case .created = try backup(support, store).ensure(lastCommittedChecksum: nil) else { Issue.record(); return }
    }

    @Test("a failing copy throws (the app must not proceed)")
    func failureThrows() throws {
        let (support, store) = try makeEnvironment()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
            try? FileManager.default.removeItem(at: support)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: support.path)
        #expect(throws: (any Error).self) { try backup(support, store).ensure(lastCommittedChecksum: nil) }
    }
}
