import BudgieCore
import Foundation
import UIKit

enum AppIdentifiers {
    static let bundleID = "com.khatruong.budgetbuddy"
    static let appGroup = "group.com.khatruong.budgetbuddy"
}

/// What the Add sheet should open with (quick actions, deep links, widget).
/// `.voice` opens the recording sheet, which continues into the add form
/// with what was said (`VoiceDraft`).
enum AddRoute: Equatable, Sendable {
    case expense, income, voice
}

enum ThemeMode: String, CaseIterable, Sendable {
    case light, dark, system
}

extension AppModel {
    /// What the Recurring page's "Generate Due Transactions" did.
    struct DueGeneration: Equatable, Sendable {
        /// Rows written from due templates (Flutter shows no count).
        var generated: Int
        /// Everything is on disk: the rows and advanced cursors were written
        /// and verified, or nothing was due and no earlier change is still
        /// unsaved (a retry ran first). False: changes are in memory only
        /// (unsaved banner).
        var saved: Bool

        /// Flutter's message, also when nothing was due; the save-failed
        /// toast when the write failed.
        var toast: Toast { saved ? .dueGenerated : .saveFailed }
    }

    /// What a category, tag or rule edit did: written and verified; changed
    /// in memory but not written (the unsaved banner and Retry take over,
    /// the caller shows `Toast.saveFailed`); nothing to do (a Flutter no-op:
    /// unknown id, unchanged state, a move to the same slot); or refused
    /// with nothing changed, carrying the copy to show (`error.message`).
    enum EditOutcome<E: Error> {
        case saved, failed, unchanged
        case rejected(E)
    }

    /// What a goal mutation did: written and verified, changed in memory
    /// but not written (the unsaved banner and Retry take over), or refused
    /// with nothing changed or written (so no save-failed toast).
    enum SaveOutcome: Equatable {
        case saved, failed, rejected
    }

    /// Something `exportBackup` or `restoreBackup` could not do, in words
    /// for "Could not export backup: …" / "Could not import backup: …".
    struct DataTransferError: Error, Equatable {
        let reason: String

        /// Refused before anything was done: some changes are only in memory.
        static let unsavedChanges = DataTransferError(
            reason: "Some changes are not saved yet. Tap Retry at the top of the screen, then import the backup again.")
        /// An edit arrived while the restore ran (none can: see `persist`).
        static let changedDuringRestore = DataTransferError(
            reason: "Your data changed while the backup was being restored. Nothing was replaced; try again.")
        static let safetyCopyFailed = DataTransferError(reason: "A safety copy of your current data could not be made.")
    }

    enum RestoreOutcome: Equatable {
        /// Committed and verified; memory swapped. `generated`: rows the
        /// recurring generator added.
        case restored(generated: Int)
        /// Nothing changed, in memory or on disk.
        case failed(DataTransferError)

        /// "Backup restored", or "Could not import backup: <reason>".
        var toast: Toast {
            switch self {
            case .restored: Toast(message: BackupEnvelope.restoredMessage)
            case .failed(let error): Toast(message: BackupEnvelope.importFailedMessage(error.reason), style: .danger)
            }
        }
    }
}

extension AppModel.EditOutcome: Equatable where E: Equatable {}

/// Asks iOS for time to finish work the user may leave part way (a
/// restore, an import): until `end()`, or until the system's limit, when
/// it is ended for the app. Without it a restore suspended in the
/// background between its commit and the preference mirrors would leave
/// them stale until it resumed (or for good if the app was then killed).
@MainActor
final class BackgroundWork {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
