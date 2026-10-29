import BudgieCore
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    // MARK: - Data

    enum DataTask: Equatable {
        case exportCSV, importCSV, exportBackup, importBackup

        /// What VoiceOver reads for the running row.
        var busyLabel: String {
            switch self {
            case .exportCSV, .exportBackup: "Exporting"
            case .importCSV: "Importing"
            case .importBackup: "Restoring"
            }
        }
    }

    enum ImportKind {
        case csv, backup

        /// Flutter's `allowedExtensions: ['csv']` / `['json']`, as types.
        var contentTypes: [UTType] {
            switch self {
            case .csv: [.commaSeparatedText]
            case .backup: [.json]
            }
        }
    }

    /// The dialog once a file was read: the CSV rows to import, or the
    /// backup to restore.
    struct Confirmation: Identifiable {
        enum Kind {
            case csv(CSVImport.Summary)
            case restore(RestorePlan)
        }

        let id = UUID()
        let kind: Kind
    }

    /// The DATA rows are enabled again (share sheet closed, picker
    /// cancelled, dialog closed, or a message shown).
    func finishDataTask() {
        dataTask = nil
        importKind = nil
    }

    private func showToast(_ message: CSVImport.Message) {
        let style: Toast.Style =
            switch message.tone {
            case .neutral: .neutral
            case .success: .success
            case .error: .danger
            }
        model.showToast(Toast(message: message.text, style: style))
    }

    /// `_exportTransactions`: the file is built off the main thread (the
    /// row's spinner shows meanwhile), then shared; the spinner stays until
    /// the sheet closes, and the success message shows once an activity
    /// completed.
    func exportCSV() {
        dataTask = .exportCSV
        Task {
            do {
                let url = try await model.exportCSV()
                share(ShareFile(
                    url: url, subject: "Budget Transactions Export",
                    completedToast: Toast(message: "Transactions exported successfully!")))
            } catch {
                finishDataTask()
                model.showToast(Toast.error("Error exporting transactions: \(error.localizedDescription)"))
            }
        }
    }

    /// `_exportBackup`: the file is built off the main thread, then shared;
    /// "Backup exported" once an activity completed.
    func exportBackup() {
        dataTask = .exportBackup
        Task {
            do throws(AppModel.DataTransferError) {
                let url = try await model.exportBackup()
                share(ShareFile(
                    url: url, subject: BackupEnvelope.shareSubject, completedToast: Toast(message: BackupEnvelope.exportedMessage)))
            } catch {
                finishDataTask()
                model.showToast(Toast.error(BackupEnvelope.exportFailedMessage(error.reason)))
            }
        }
    }

    /// The system share sheet for an export. The file is deleted once the
    /// sheet closes, or at once when the page was left while the file was
    /// being built or the sheet could not be shown.
    private func share(_ file: ShareFile) {
        guard isVisible else {
            model.finishExport(file.url)
            finishDataTask()
            return
        }
        let presented = SharePresenter.present(file) { completed in
            model.finishExport(file.url)
            finishDataTask()
            if completed { model.showToast(file.completedToast) }
        }
        if !presented {
            model.finishExport(file.url)
            finishDataTask()
        }
    }

    func pickFile(_ kind: ImportKind) {
        dataTask = kind == .csv ? .importCSV : .importBackup
        importKind = kind
        showsImporter = true
    }

    /// The picked file's bytes, read in place, then the CSV preview or the
    /// backup decode. A file that cannot be read, or is over
    /// `CSVImport.maximumFileBytes`, gets a message (Flutter returns
    /// silently for the first and reads any size).
    func picked(_ result: Result<[URL], any Error>) {
        guard let kind = importKind else { return }
        Task {
            let read: Result<[UInt8], CSVImport.Failure>
            if case .success(let urls) = result, let url = urls.first {
                read = await Self.read(url)
            } else {
                read = .failure(.unreadableFile)
            }
            switch read {
            case .failure(let failure):
                finishDataTask()
                switch kind {
                case .csv: showToast(CSVImport.failureMessage(failure))
                case .backup:
                    model.showToast(Toast.error(BackupEnvelope.importFailedMessage(failure.message)))
                }
            case .success(let bytes):
                switch kind {
                case .csv: await previewCSV(bytes)
                case .backup: await decodeBackup(bytes)
                }
            }
        }
    }

    /// Off the main thread, inside the file's security scope, coordinated
    /// (an iCloud file that is not downloaded yet is fetched first). The
    /// size is checked before anything is read (before the download too
    /// when iCloud reports it), and the file is mapped rather than copied,
    /// so only the returned bytes are held.
    private static func read(_ url: URL) async -> Result<[UInt8], CSVImport.Failure> {
        await Task.detached(priority: .userInitiated) { () -> Result<[UInt8], CSVImport.Failure> in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            func tooLarge(_ url: URL) -> Bool {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
                return (values?.fileSize ?? values?.totalFileSize ?? 0) > CSVImport.maximumFileBytes
            }
            if tooLarge(url) { return .failure(.fileTooLarge) }
            var result: Result<[UInt8], CSVImport.Failure> = .failure(.unreadableFile)
            var error: NSError? = nil
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { readable in
                if tooLarge(readable) {
                    result = .failure(.fileTooLarge)
                } else if let data = try? Data(contentsOf: readable, options: .mappedIfSafe) {
                    result = .success([UInt8](data))
                }
            }
            return result
        }.value
    }

    /// `_importTransactions` up to the dialog: Flutter's message when there
    /// is nothing to import, else the confirmation with the counts.
    private func previewCSV(_ bytes: [UInt8]) async {
        do {
            let summary = try await model.previewCSVImport(bytes)
            if let empty = summary.emptyResultMessage {
                finishDataTask()
                showToast(empty)
            } else {
                confirmation = Confirmation(kind: .csv(summary))
            }
        } catch {
            finishDataTask()
            showToast(CSVImport.failureMessage(error))
        }
    }

    /// `_importBackup` up to the dialog: Flutter's message for a file it
    /// refuses, else "Replace all data?".
    private func decodeBackup(_ bytes: [UInt8]) async {
        do {
            let plan = try await model.decodeBackup(bytes)
            confirmation = Confirmation(kind: .restore(plan))
        } catch {
            finishDataTask()
            model.showToast(Toast.error(BackupEnvelope.importFailedMessage(error.message)))
        }
    }

    @ViewBuilder
    func confirmationDialog(_ confirmation: Confirmation) -> some View {
        switch confirmation.kind {
        case .csv(let summary):
            DataImportDialog(
                title: summary.confirmTitle, message: summary.confirmMessage, confirmTitle: CSVImport.importButtonTitle,
                destructive: false, busyLabel: DataTask.importCSV.busyLabel, identifier: "csvimport.confirm",
                onCancel: closeConfirmation
            ) {
                let saved = await model.importCSV(summary)
                closeConfirmation()
                if saved { showToast(summary.successMessage) } else { model.showToast(.saveFailed) }
            }
        case .restore(let plan):
            DataImportDialog(
                title: RestorePlan.confirmationTitle, message: plan.confirmationMessage,
                confirmTitle: RestorePlan.replaceButtonTitle, destructive: true, busyLabel: DataTask.importBackup.busyLabel,
                identifier: "backup.confirm",
                onCancel: closeConfirmation
            ) {
                let outcome = await model.restoreBackup(plan)
                closeConfirmation()
                model.showToast(outcome.toast)
            }
        }
    }

    /// Cancel, a scrim tap, or the import done: the rows are enabled again.
    /// A cancel writes nothing and shows nothing.
    func closeConfirmation() {
        confirmation = nil
        finishDataTask()
    }
}
