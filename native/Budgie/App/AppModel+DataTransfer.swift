import BudgieCore
import Foundation
import os
import UIKit

extension AppModel {
    // MARK: - Export files

    /// A new file in the temporary directory for an export. Complete file
    /// protection: it is only needed while the share sheet is up (so the
    /// device is unlocked), and a copy left behind is unreadable while the
    /// device is locked. The store itself is `.completeUntilFirstUserAuthentication`
    /// because the app reads it in the background; an export never is.
    private func beginExport(named name: String) -> URL {
        removeStaleExports()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        activeExport = url
        return url
    }

    nonisolated private static let exportWriteOptions: Data.WritingOptions = [.atomic, .completeFileProtection]

    /// The share sheet is done with `url` (or never showed): the file is
    /// deleted (it holds financial data; Flutter leaves it in `tmp`).
    func finishExport(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if activeExport == url { activeExport = nil }
    }

    /// Deletes export files left in the temporary directory, except the one
    /// a share sheet is using: at launch (a kill while the sheet was open),
    /// when the app goes to the background (an export whose screen was left
    /// before its sheet showed), and before each export.
    func removeStaleExports() {
        let directory = FileManager.default.temporaryDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names
        where (name.hasPrefix("budgie_backup_") && name.hasSuffix(".json")) || (name.hasPrefix("transactions_") && name.hasSuffix(".csv")) {
            let url = directory.appendingPathComponent(name)
            if url.lastPathComponent == activeExport?.lastPathComponent { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - CSV export

    /// `_exportTransactions`: the CSV built and written off the main thread
    /// to a temporary file for the share sheet; the caller passes it to
    /// `finishExport` once the sheet closes.
    func exportCSV() async throws -> URL {
        let data = self.data
        let url = beginExport(named: CSVExport.fileName(now: now))
        let written = await Task.detached(priority: .userInitiated) { () -> Result<Void, any Error> in
            Result {
                let rows = (data?.transactions ?? []).map {
                    CSVExport.Row(
                        date: $0.date, isIncome: $0.type == .income, category: $0.category, description: $0.description,
                        amount: $0.amount)
                }
                try Data(CSVExport.export(rows)).write(to: url, options: Self.exportWriteOptions)
            }
        }.value
        do {
            try written.get()
        } catch {
            finishExport(url)
            throw error
        }
        return url
    }

    // MARK: - CSV import

    /// The first half of "Import from CSV" (`parseTransactionsCsv`):
    /// decode, validate and dedupe against the readable transactions, off
    /// the main thread. Writes nothing.
    func previewCSVImport(_ bytes: [UInt8]) async throws(CSVImport.Failure) -> CSVImport.Summary {
        let existing = data?.transactions ?? []
        let calendar = self.calendar
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws(CSVImport.Failure) in try CSVImport.parse(bytes: bytes, existing: existing, calendar: calendar) }
        }.value
        return try result.get()
    }

    /// The second half (`importTransactions`): the summary's rows appended
    /// in file order, with the new category names they bring, in one
    /// awaited commit. The rows and the sections to write are built off the
    /// main thread, and those sections are written as built (not serialised
    /// again). True when it verified (or there was nothing to import); false
    /// when the rows are only in memory (the unsaved banner). Runs as a
    /// background task, so leaving the app does not stop it part way.
    @discardableResult
    func importCSV(_ summary: CSVImport.Summary) async -> Bool {
        guard !isRestoring, data != nil else { return false }
        let background = BackgroundWork("Import CSV")
        defer { background.end() }
        var result: FinancialData.CSVImportResult
        // Built from a copy: a change made meanwhile (none can be, the card
        // is modal) is never overwritten, the rows are built again over it.
        repeat {
            guard let current = data else { return false }
            let revision = dataRevision
            let now = self.now
            result = await Task.detached(priority: .userInitiated) {
                current.importTransactions(summary, now: now, newID: Self.makeID)
            }.value
            if revision == dataRevision { break }
        } while true
        guard !result.sections.isEmpty else { return true }
        data = result.data
        transactionsChanged()
        return await persist(prepared: result.sections)
    }

    // MARK: - Backup export and restore (D10)

    /// The marketing version (Flutter's `PackageInfo.version`, falling back
    /// to 2.0.0), written into backups and safety copies.
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"

    /// `_exportBackup`: the envelope built and encoded off the main thread
    /// from the current data and theme, written to a temporary file named
    /// for one clock read (the same one as `exportedAt`). The caller shares
    /// it and passes it to `finishExport` once the share sheet closes.
    func exportBackup() async throws(DataTransferError) -> URL {
        guard let data else { throw DataTransferError(reason: "Your data is not loaded yet.") }
        let now = self.now
        let theme = themeMode.rawValue
        let version = Self.appVersion
        let url = beginExport(named: BackupEnvelope.fileName(now: now))
        let written = await Task.detached(priority: .userInitiated) { () -> DataTransferError? in
            do {
                let bytes = try BackupEnvelope.encode(data: data, themeMode: theme, appVersion: version, now: now)
                try Data(bytes).write(to: url, options: Self.exportWriteOptions)
                return nil
            } catch let error as BackupExportError {
                return DataTransferError(reason: error.message)
            } catch {
                return DataTransferError(reason: error.localizedDescription)
            }
        }.value
        if let written {
            finishExport(url)
            throw written
        }
        return url
    }

    /// `decodeBackup`, off the main thread: the restore plan, or Flutter's
    /// message. Writes nothing.
    func decodeBackup(_ bytes: [UInt8]) async throws(BackupError) -> RestorePlan {
        let calendar = self.calendar
        let now = self.now
        let result = await Task.detached(priority: .userInitiated) {
            Result { () throws(BackupError) in
                try BackupEnvelope.decode(bytes: bytes, calendar: calendar, now: now, newID: Self.makeID)
            }
        }.value
        return try result.get()
    }

    /// Replaces the data with `plan` (D10):
    ///
    /// 1. Changes that are only in memory are retried first. If some still
    ///    are not saved, the restore is refused (nothing done; the banner
    ///    and its Retry stay): they would be in neither the restored data
    ///    nor the safety copy, which is taken from disk.
    /// 2. The restored data is built off the main thread.
    /// 3. On the store actor, with no other commit in between: the safety
    ///    copy of the store and preferences (no restore without it), then
    ///    ONE commit of all ten sections (sections the file leaves out are
    ///    rewritten unchanged).
    /// 4. Only once it verified: memory, a fresh tracker (the commit wrote
    ///    every section a flag can name, from the data now in memory), the
    ///    settings' preference mirrors and the theme (its setter's no-op
    ///    guard included). Then the older safety copies are pruned, never
    ///    the one just made.
    ///
    /// A "Match device" locale is the one mirror removed before the commit
    /// (Flutter writes all its mirrors before its commit): both apps fall
    /// back to the mirror when the stored `localeOverride` is null, so a
    /// kill between the commit and the mirrors would otherwise bring the
    /// old locale back. The other settings are never null in the section,
    /// so their mirrors are only fallbacks and follow the commit. A failed
    /// commit puts the locale mirror back. The whole restore runs as a
    /// background task, so leaving the app does not stop it between the
    /// commit and the mirrors and theme.
    ///
    /// The session is not marked unlocked, so App Lock turned on by the file
    /// locks at once, as in Flutter.
    func restoreBackup(_ plan: RestorePlan) async -> RestoreOutcome {
        guard phase == .ready, data != nil, !isRestoring else {
            return .failed(DataTransferError(reason: "Your data is not loaded yet."))
        }
        isRestoring = true
        editedDuringRestore = false
        defer { isRestoring = false }
        let background = BackgroundWork("Restore backup")
        defer { background.end() }

        if hasUnsavedChanges { await retryFlaggedSections() }
        guard !hasUnsavedChanges else { return .failed(.unsavedChanges) }

        guard let current = data else { return .failed(DataTransferError(reason: "Your data is not loaded yet.")) }
        let now = self.now
        let result = await Task.detached(priority: .userInitiated) {
            current.restoring(plan, now: now, newID: Self.makeID)
        }.value

        let calendar = self.calendar
        let safetyCopy = PreRestoreBackup(
            applicationSupport: applicationSupport, store: DirectoryFileSystem(directory: storeDirectory),
            exportPreferences: { [preferences] in try preferences.exportDomain() }, appVersion: Self.appVersion,
            clock: { calendar.now() })
        guard !editedDuringRestore else { return .failed(.changedDuringRestore) }
        let removesLocaleMirror = result.preferenceWrites.contains { $0.key == PreferenceKey.localeOverride && $0.value == nil }
        let localeMirror = preferences.value(forKey: PreferenceKey.localeOverride)

        let copy: URL
        do {
            copy = try await store.updateSections(result.sections, afterSafetyCopy: { [preferences] in
                let folder = try safetyCopy.create()
                // After the copy, which keeps the preferences as they were.
                if removesLocaleMirror { preferences.set(nil, forKey: PreferenceKey.localeOverride) }
                return folder
            })
        } catch {
            switch error {
            case .safetyCopyFailed(let reason):
                Self.dataLog.error("restore aborted: the pre-restore safety copy failed: \(reason, privacy: .public)")
                return .failed(.safetyCopyFailed)
            case .store(let error):
                if removesLocaleMirror { preferences.set(localeMirror, forKey: PreferenceKey.localeOverride) }
                Self.dataLog.error("restore commit failed: \(String(describing: error), privacy: .public)")
                return .failed(DataTransferError(reason: Self.describe(error)))
            }
        }

        // Committed. An edit that reached `persist` while the commit ran
        // (none can) was made on the data just replaced; the restore wins.
        if editedDuringRestore { Self.dataLog.fault("a save arrived during the restore commit; superseded by the restore") }
        data = result.data
        tracker = PersistenceTracker(store: store)
        syncSaveState()
        for write in result.preferenceWrites { preferences.set(write.value, forKey: write.key) }
        if let mode = result.themeMode.flatMap(ThemeMode.init(rawValue:)) { setThemeMode(mode) }
        netWorthRevision &+= 1
        transactionsChanged()
        syncWidget()
        // Memory and disk agree again: edits and routes may run while the
        // older copies are pruned.
        isRestoring = false
        _ = await Task.detached(priority: .utility) {
            try? safetyCopy.prune(keeping: PreRestoreBackup.retained, protecting: copy)
        }.value
        return .restored(generated: result.generatedTransactions)
    }

    /// A store error in words.
    private static func describe(_ error: FinancialStoreError) -> String {
        switch error {
        case .protectedDataUnavailable: "The device is locked."
        case .readFailed(_, let reason), .writeFailed(_, let reason): reason
        case .verificationFailed: "The saved data did not verify."
        case .dataUnreadable: "The stored data could not be read."
        }
    }
}
