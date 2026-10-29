import Foundation

/// Whether the device's protected data (the app container) is readable.
/// On iOS this is `UIApplication.shared.isProtectedDataAvailable`, kept in a
/// thread-safe flag by the app. It must be synchronous so a commit never
/// suspends between its checks and its writes.
public protocol ProtectedDataAvailability: Sendable {
    var isProtectedDataAvailable: Bool { get }
}

/// For tests and platforms without file protection.
public struct AlwaysAvailable: ProtectedDataAvailability {
    public init() {}
    public var isProtectedDataAvailable: Bool { true }
}

public enum FinancialStoreError: Error, Equatable, Sendable {
    /// The device is locked (or prewarmed before first unlock). Nothing was
    /// read or written.
    case protectedDataUnavailable
    /// A file exists but could not be read. Never treated as "no data".
    case readFailed(name: String, reason: String)
    case writeFailed(name: String, reason: String)
    /// The primary read back from disk did not verify at the expected revision.
    case verificationFailed(expected: Int64, found: Int64?)
    /// The store files were unreadable and were set aside as `.corrupt-*`.
    /// Even with legacy preferences present, the Swift app stops and asks
    /// (MIGRATION_SPEC 14.0 Q3). `corruptFiles` are the
    /// set-aside names not yet acknowledged.
    case dataUnreadable(corruptFiles: [String])
}

/// The single owner of `financial_store_v2.json` and its backup.
///
/// A port of `AtomicFinancialStore` (MIGRATION_SPEC sections 4, 6, 8):
/// same file format, load precedence, commit protocol and legacy migration,
/// so the Flutter build can be reinstalled over the Swift app at any time.
/// Commits are serialized by the actor; no method suspends between reading
/// the current state and finishing its writes.
public actor FinancialStore {
    public struct LoadReport: Sendable, Equatable {
        public var restoredFromBackup = false
        public var setAside: [String] = []
        public var migratedFrom: LegacyMigration.Source?
        public var removedPreferenceKeys: [String] = []
    }

    private let fileSystem: StoreFileSystem
    private let preferences: PreferencesStore
    private let protectedData: ProtectedDataAvailability
    /// Dart `DateTime.now()`; used for `writtenAt` and `.corrupt-<ms>` stamps.
    private let clock: @Sendable () -> DartDateTime

    private var snapshot: FinancialSnapshot?
    public private(set) var lastLoadReport = LoadReport()

    public init(
        fileSystem: StoreFileSystem,
        preferences: PreferencesStore,
        protectedData: ProtectedDataAvailability,
        clock: @escaping @Sendable () -> DartDateTime = { DartDateTime.now(timeZone: .current) }
    ) {
        self.fileSystem = fileSystem
        self.preferences = preferences
        self.protectedData = protectedData
        self.clock = clock
    }

    /// The current snapshot, loading it on first use. A fresh install yields
    /// `FinancialSnapshot.empty` and writes nothing.
    public func read() throws(FinancialStoreError) -> FinancialSnapshot {
        if let snapshot { return snapshot }
        let loaded = try load()
        snapshot = loaded
        return loaded
    }

    /// Dart `updateSections`: merge, bump the revision, commit, verify.
    @discardableResult
    public func updateSections(_ updates: [(String, JSONValue)]) throws(FinancialStoreError) -> FinancialSnapshot {
        let current = try read()
        let next = current.applying(updates)
        try commit(next)
        snapshot = next
        return next
    }

    /// Why a `commit(_:afterSafetyCopy:)` wrote nothing.
    public enum SafetyCopiedCommitError: Error, Equatable, Sendable {
        /// The copy could not be made (its error, in words).
        case safetyCopyFailed(String)
        case store(FinancialStoreError)
    }

    /// A restore's commit (D10): `safetyCopy` (the pre-restore copy of the
    /// store files) runs on the actor, then `updateSections`, with no other
    /// commit before, between or during them. The copy therefore holds
    /// exactly the files this commit replaces, never half of a commit in
    /// flight. Nothing is written when the copy throws. Returns the copy's
    /// folder (for the prune, which must never remove it).
    public func updateSections(
        _ updates: [(String, JSONValue)], afterSafetyCopy safetyCopy: @Sendable () throws -> URL
    ) throws(SafetyCopiedCommitError) -> URL {
        let copy: URL
        do {
            copy = try safetyCopy()
        } catch {
            throw .safetyCopyFailed(String(describing: error))
        }
        do {
            try updateSections(updates)
        } catch {
            throw .store(error)
        }
        return copy
    }

    /// Dart `replace`: all sections replaced, revision = current + 1.
    @discardableResult
    public func replace(sections: JSONObject) throws(FinancialStoreError) -> FinancialSnapshot {
        let current = try read()
        let next = FinancialSnapshot(schemaVersion: StoreFile.schemaVersion, revision: current.revision + 1, sections: sections)
        try commit(next)
        snapshot = next
        return next
    }

    /// After `dataUnreadable`, the user chose to start with an empty store.
    /// The `.corrupt-*` files stay on disk.
    public func acknowledgeUnreadableData(_ corruptFiles: [String]) throws(FinancialStoreError) {
        let known = Set(acknowledgedCorruptFiles())
        let all = (known.union(corruptFiles)).sorted()
        preferences.set(.stringList(all), forKey: PreferenceKey.acknowledgedCorruptFiles)
        // This is the explicit start-fresh path. Without it, a missing store
        // after a prior save must remain a recovery error, not a new install.
        preferences.set(nil, forKey: PreferenceKey.lastCommittedChecksum)
        snapshot = nil
    }

    /// Forgets the in-memory snapshot (as a relaunch would).
    // Test-only: simulates a relaunch in the store-safety and backup-restore tests
    public func resetInMemoryState() {
        snapshot = nil
    }

    // MARK: - Loading (Dart `_load`)

    private func load() throws(FinancialStoreError) -> FinancialSnapshot {
        try requireProtectedData()
        var report = LoadReport()
        defer { lastLoadReport = report }

        let primaryBytes = try readIfPresent(StoreFile.primaryName)
        let backupBytes = try readIfPresent(StoreFile.backupName)
        let primary = primaryBytes.flatMap(StoreFile.decode)
        let backup = backupBytes.flatMap(StoreFile.decode)

        if primary != nil || backup != nil {
            if let primary, backup == nil || primary.revision >= backup!.revision {
                return primary
            }
            // Primary missing, unreadable or older: restore it from the
            // backup (same revision, fresh header); the backup is untouched.
            let restored = backup!
            let encoded = StoreFile.encode(restored, writtenAt: now())
            try writeAtomically(StoreFile.primaryName, encoded)
            try verifyOnDisk(restored.revision, expectedBytes: encoded)
            report.restoredFromBackup = true
            return restored
        }

        if primaryBytes != nil || backupBytes != nil {
            // Both exist (or the only one exists) and neither decodes: keep
            // them for recovery. An explicit acknowledgment is required
            // before considering the legacy sources below.
            let stamp = millisecondsSinceEpoch()
            var existingNames: Set<String>
            do { existingNames = Set(try fileSystem.list()) }
            catch { throw .readFailed(name: StoreFile.directoryName, reason: "\(error)") }
            for (name, bytes) in [(StoreFile.primaryName, primaryBytes), (StoreFile.backupName, backupBytes)]
            where bytes != nil {
                let baseName = "\(name).corrupt-\(stamp)"
                var newName = baseName
                var suffix = 0
                // POSIX rename replaces its destination. A repeated or reset
                // clock must never replace an earlier recovery original.
                while existingNames.contains(newName) {
                    suffix += 1
                    newName = "\(baseName)-\(suffix)"
                }
                do {
                    try fileSystem.rename(name, to: newName)
                } catch {
                    throw .writeFailed(name: name, reason: "\(error)")
                }
                report.setAside.append(newName)
                existingNames.insert(newName)
            }
        }

        // Settings and stale legacy keys cannot prove recovery of damaged
        // financial files. Block before considering any preference fallback,
        // including on a relaunch after the files were set aside.
        let unacknowledged = try unacknowledgedCorruptFiles()
        if !unacknowledged.isEmpty {
            throw .dataUnreadable(corruptFiles: unacknowledged)
        }
        if preferences.contains(PreferenceKey.lastCommittedChecksum) {
            throw .readFailed(name: StoreFile.directoryName,
                              reason: "Previously saved financial files are missing. Recovery is required before starting an empty store.")
        }
        let migrated = LegacyMigration.migrate(preferences)
        if let key = LegacyMigration.unrecoverableKeys(preferences, result: migrated).first {
            throw .readFailed(name: key, reason: "Existing legacy data could not be migrated. The original preferences have been kept.")
        }
        guard let migrated else { return .empty }
        try commit(migrated.snapshot)
        report.migratedFrom = migrated.source
        report.removedPreferenceKeys = PreferenceKey.migratedKeys.filter { preferences.contains($0) }
        LegacyMigration.removeMigratedKeys(preferences)
        return migrated.snapshot
    }

    private func unacknowledgedCorruptFiles() throws(FinancialStoreError) -> [String] {
        let names: [String]
        do {
            names = try fileSystem.list()
        } catch {
            throw .readFailed(name: StoreFile.directoryName, reason: "\(error)")
        }
        let acknowledged = Set(acknowledgedCorruptFiles())
        return names.filter { name in
            (name.hasPrefix(StoreFile.primaryName + ".corrupt-") || name.hasPrefix(StoreFile.backupName + ".corrupt-"))
                && !acknowledged.contains(name)
        }
    }

    private func acknowledgedCorruptFiles() -> [String] {
        if case .stringList(let names)? = preferences.value(forKey: PreferenceKey.acknowledgedCorruptFiles) {
            return names
        }
        return []
    }

    // MARK: - Committing (Dart `_commit`)

    private func commit(_ next: FinancialSnapshot) throws(FinancialStoreError) {
        try requireProtectedData()
        let encoded = StoreFile.encode(next, writtenAt: now())

        // Preserve the intact current primary as the backup, byte for byte.
        if let current = try readIfPresent(StoreFile.primaryName), StoreFile.decode(current) != nil {
            try writeAtomically(StoreFile.backupName, current)
        }
        try writeAtomically(StoreFile.primaryName, encoded)
        try verifyOnDisk(next.revision, expectedBytes: encoded)

        if let header = StoreFile.verify(encoded) {
            preferences.set(.string(header.payloadChecksum), forKey: PreferenceKey.lastCommittedChecksum)
        }
    }

    private func verifyOnDisk(_ expectedRevision: Int64, expectedBytes: [UInt8]) throws(FinancialStoreError) {
        let written = try readIfPresent(StoreFile.primaryName)
        let header = written.flatMap(StoreFile.verify)
        guard let header, header.revision == expectedRevision, written == expectedBytes else {
            throw .verificationFailed(expected: expectedRevision, found: header?.revision)
        }
    }

    // MARK: - Primitives

    private func requireProtectedData() throws(FinancialStoreError) {
        guard protectedData.isProtectedDataAvailable else { throw .protectedDataUnavailable }
    }

    private func readIfPresent(_ name: String) throws(FinancialStoreError) -> [UInt8]? {
        do {
            return try fileSystem.read(name)
        } catch {
            throw .readFailed(name: name, reason: "\(error)")
        }
    }

    private func writeAtomically(_ name: String, _ bytes: [UInt8]) throws(FinancialStoreError) {
        // Re-checked per write: the device can lock mid-commit.
        try requireProtectedData()
        do {
            try fileSystem.writeStaged(name, bytes)
        } catch {
            throw .writeFailed(name: name, reason: "\(error)")
        }
        try requireProtectedData()
        do { try fileSystem.commitStaged(name) }
        catch { throw .writeFailed(name: name, reason: "\(error)") }
    }

    private func now() -> DartDateTime {
        clock()
    }

    private func millisecondsSinceEpoch() -> Int64 {
        DartDateTime.flooredDivision(now().microsecondsSinceEpoch, 1_000)
    }
}
