import BudgieCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings (Flutter's "More" tab, `settings_page.dart:579-911`), pushed
/// from the Home gear (D2): the title sits in the navigation bar beside the
/// back button, then the brand card and the APPEARANCE, PERSONALIZATION,
/// PRIVACY, DATA and ABOUT cards.
///
/// Differences from Flutter (PARITY_GAPS): turning App lock on asks for
/// Face ID / the passcode first (Flutter locks at once); ABOUT also lists
/// Data diagnostics and Licences.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @State private var destination: Destination?
    @State private var choice: Choice?
    @State private var notice: String?
    /// The DATA row whose work is running (Flutter's `_isExporting`,
    /// `_isImporting`, `_isBackingUp`, `_isRestoring`): from the tap until
    /// its toast, through the share sheet, picker and confirmation.
    @State private var dataTask: DataTask?
    /// Whether the page is on screen: an export that finishes after it was
    /// left is not shared (its file is deleted).
    @State private var isVisible = false
    /// What the document picker is choosing a file for. One `.fileImporter`
    /// serves both imports (a second one on the same view is ignored).
    @State private var importKind: ImportKind?
    @State private var showsImporter = false
    @State private var confirmation: Confirmation?

    var body: some View {
        ScrollView {
            if let data = model.data {
                content(data)
            }
        }
        .background(BudgieColor.background)
        // The system title names the screen (VoiceOver, the back button of
        // pushed pages) but is not drawn: the 26pt title sits at the
        // leading edge instead.
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(BudgieColor.background, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
            SettingsBarTitle {
                // Capped so the largest text sizes cannot push it past the
                // bar or into the back button.
                Text("Settings")
                    .textStyle(.pageTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .fixedSize()
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .navigationDestination(item: $destination) { $0.view }
        .sheet(item: $choice) { choiceSheet($0) }
        .fileImporter(
            isPresented: $showsImporter, allowedContentTypes: (importKind ?? .backup).contentTypes, allowsMultipleSelection: false,
            onCompletion: picked, onCancellation: finishDataTask
        )
        // A scrim tap closes it like Cancel.
        .budgieDialog(item: Binding(get: { confirmation }, set: { if $0 == nil { closeConfirmation() } })) {
            confirmationDialog($0)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .alert("App lock", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Page

    private func content(_ data: FinancialData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsBrandCard()
                .padding(EdgeInsets(top: 20, leading: Metrics.pageHorizontal, bottom: 0, trailing: Metrics.pageHorizontal))
            section("Appearance", rows: [AnyView(SettingsThemeRow(selection: themeSelection))])
            section("Personalization", rows: personalizationRows(data))
            section("Privacy", rows: privacyRows(data.appSettings))
            section("Data", rows: dataRows(data))
            section("About", rows: aboutRows)
        }
        .padding(.bottom, Metrics.spacingL)
        .frame(maxWidth: Metrics.maxContentWidth)
        .frame(maxWidth: .infinity)
    }

    private func personalizationRows(_ data: FinancialData) -> [AnyView] {
        let settings = data.appSettings
        let activeCategories = data.categories.filter { !$0.isArchived }.count
        return [
            AnyView(SettingsRow(
                symbol: "square.on.circle", color: BudgieColor.accent, title: "Categories",
                subtitle: "\(activeCategories) active · custom names, icons, and order",
                action: { destination = .categories }
            ).accessibilityIdentifier("settings.categories")),
            AnyView(SettingsRow(
                symbol: "sparkles", color: BudgieColor.info, title: "Tags & rules",
                subtitle: "\(data.tags.count) tags · \(data.rules.count) rules",
                action: { destination = .tagsAndRules }
            ).accessibilityIdentifier("settings.tagsRules")),
            AnyView(SettingsRow(
                symbol: "banknote", color: BudgieColor.income, title: "Currency",
                subtitle: SettingsOptions.currencyLabel(settings.baseCurrencyCode),
                action: { choice = .currency }
            ).accessibilityIdentifier("settings.currency")),
            AnyView(SettingsRow(
                symbol: "globe", color: BudgieColor.info, iconSize: SettingsGlyph.full, title: "Number format",
                subtitle: SettingsOptions.localeLabel(settings.localeOverride),
                action: { choice = .locale }
            ).accessibilityIdentifier("settings.numberFormat")),
        ]
    }

    private func privacyRows(_ settings: AppSettings) -> [AnyView] {
        let delay = SettingsOptions.lockTimeoutLabel(settings.autoLockTimeoutSeconds)
        var rows: [AnyView] = [
            AnyView(SettingsToggleRow(
                symbol: "lock", color: BudgieColor.accent, iconSize: SettingsGlyph.full, title: "App lock",
                subtitle: settings.appLockEnabled ? "Lock after \(delay)" : "Require device authentication",
                isOn: lockBinding, identifier: "settings.appLock"))
        ]
        // Inserted and removed without animation, as in Flutter.
        if settings.appLockEnabled {
            rows.append(AnyView(SettingsRow(
                symbol: "timer", color: BudgieColor.info, iconSize: SettingsGlyph.full, title: "Lock delay", subtitle: delay,
                action: { choice = .lockDelay }
            ).accessibilityIdentifier("settings.lockDelay")))
        }
        rows.append(AnyView(SettingsToggleRow(
            symbol: "eye.slash", color: BudgieColor.warning, title: "Hide balances",
            subtitle: "Mask amounts throughout the app", isOn: hideBinding, identifier: "settings.hideBalances")))
        return rows
    }

    /// Recurring is never disabled; the other four are while any of them
    /// runs (Flutter's `_dataBusy`), the running one with its spinner.
    private func dataRows(_ data: FinancialData) -> [AnyView] {
        // What the export writes (Flutter `transactions.length`), current
        // as soon as a row is added (the ledger index rebuilds later).
        let transactionCount = data.readableTransactionCount
        func unlessBusy(_ action: @escaping () -> Void) -> (() -> Void)? { dataTask == nil ? action : nil }
        return [
            AnyView(SettingsRow(
                symbol: "repeat", color: BudgieColor.accent, title: "Recurring transactions",
                subtitle: recurringSubtitle(data.templates.filter(\.isActive)),
                action: { destination = .recurring }
            ).accessibilityIdentifier("settings.recurring")),
            AnyView(SettingsRow(
                symbol: "arrow.down.to.line", color: BudgieColor.income, iconSize: SettingsGlyph.small,
                title: "Export as CSV", subtitle: "All \(transactionCount) transactions",
                busy: dataTask == .exportCSV, busyLabel: DataTask.exportCSV.busyLabel,
                action: unlessBusy(exportCSV)
            ).accessibilityIdentifier("settings.exportCSV")),
            AnyView(SettingsRow(
                symbol: "arrow.up.to.line", color: BudgieColor.info, iconSize: SettingsGlyph.small,
                title: "Import from CSV", subtitle: "Add transactions from a file",
                busy: dataTask == .importCSV, busyLabel: DataTask.importCSV.busyLabel,
                action: unlessBusy { pickFile(.csv) }
            ).accessibilityIdentifier("settings.importCSV")),
            AnyView(SettingsRow(
                symbol: "icloud.and.arrow.up", color: BudgieColor.income,
                title: "Export backup", subtitle: "Everything, as a JSON file",
                busy: dataTask == .exportBackup, busyLabel: DataTask.exportBackup.busyLabel,
                action: unlessBusy(exportBackup)
            ).accessibilityIdentifier("settings.exportBackup")),
            AnyView(SettingsRow(
                symbol: "arrow.counterclockwise.circle", color: BudgieColor.danger,
                title: "Import backup", subtitle: "Restore everything (replaces current data)",
                busy: dataTask == .importBackup, busyLabel: DataTask.importBackup.busyLabel,
                action: unlessBusy { pickFile(.backup) }
            ).accessibilityIdentifier("settings.importBackup")),
        ]
    }

    /// Version (no action), then the Swift-only pages: what was loaded,
    /// the fonts' licences, and the debug design gallery.
    private var aboutRows: [AnyView] {
        var rows: [AnyView] = [
            AnyView(SettingsRow(
                symbol: "info.circle", color: BudgieColor.versionIcon, tile: BudgieColor.versionTile,
                iconSize: SettingsGlyph.full, title: "Version",
                subtitle: "Budgie \(Self.version)", action: nil, trailing: { EmptyView() })),
            AnyView(SettingsRow(
                symbol: "list.bullet.rectangle", color: BudgieColor.versionIcon, tile: BudgieColor.versionTile,
                title: "Data diagnostics", subtitle: "What this device loaded",
                action: { destination = .diagnostics }
            ).accessibilityIdentifier("settings.diagnostics")),
            AnyView(SettingsRow(
                symbol: "doc.text", color: BudgieColor.versionIcon, tile: BudgieColor.versionTile,
                title: "Licences", subtitle: "Fonts (SIL Open Font License)",
                action: { destination = .licences }
            ).accessibilityIdentifier("settings.licences")),
        ]
        #if DEBUG
        rows.append(AnyView(SettingsRow(
            symbol: "paintpalette", color: BudgieColor.versionIcon, tile: BudgieColor.versionTile,
            title: "Design gallery", subtitle: "Debug builds only",
            action: { destination = .designGallery })))
        #endif
        return rows
    }

    /// An eyebrow and its card (inset 20, 8 below the eyebrow): the rows
    /// 16 from the card's sides, a hairline between rows.
    private func section(_ title: String, rows: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsEyebrow(title: title)
            GlowCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        if index > 0 { Hairline() }
                        rows[index]
                    }
                }
                .padding(.horizontal, Metrics.spacingM)
                .padding(.vertical, Metrics.spacingXXS)
            }
            .padding(EdgeInsets(top: Metrics.spacingS, leading: Metrics.pageHorizontal, bottom: 0, trailing: Metrics.pageHorizontal))
        }
    }

    /// `_recurringSubtitle` (sp:913-917): the count and the first three
    /// active descriptions, in list order.
    private func recurringSubtitle(_ active: [RecurringTemplate]) -> String {
        if active.isEmpty { return "No active recurring transactions" }
        return "\(active.count) active · \(active.prefix(3).map(\.description).joined(separator: ", "))"
    }

    /// The marketing version only (Flutter's `PackageInfo.version`, falling
    /// back to 2.0.0).
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"

    // MARK: - Controls

    /// Light | Dark | Auto, in Flutter's order.
    private static let themeModes: [ThemeMode] = [.light, .dark, .system]

    private var themeSelection: Binding<Int> {
        Binding(
            get: { Self.themeModes.firstIndex(of: model.themeMode) ?? 2 },
            set: { model.setThemeMode(Self.themeModes[$0]) })
    }

    /// Turning the lock on authenticates first and keeps this session
    /// unlocked; turning it off needs nothing. The switch stays on while the
    /// prompt is up and goes back off only if it fails.
    private var lockBinding: Binding<Bool> {
        Binding(
            get: { model.appLockEnabled || model.isEnablingAppLock },
            set: { enable in
                guard enable else {
                    Task { await model.setAppLockEnabled(false) }
                    return
                }
                guard !model.isEnablingAppLock else { return }
                model.setEnablingAppLock(true)
                Task {
                    switch await DeviceAuth.authenticate(reason: "Turn on App Lock") {
                    case .success:
                        model.markUnlocked()
                        await model.setAppLockEnabled(true)
                    case .failed: break
                    case .unavailable: notice = "Set a passcode in the Settings app to use App Lock."
                    }
                    model.setEnablingAppLock(false)
                }
            })
    }

    private var hideBinding: Binding<Bool> {
        Binding(
            get: { model.data?.appSettings.hideBalances == true },
            set: { hidden in Task { await model.setHideBalances(hidden) } })
    }

    // MARK: - Sheets

    private enum Choice: String, Identifiable {
        case currency, locale, lockDelay
        var id: String { rawValue }
    }

    @ViewBuilder
    private func choiceSheet(_ choice: Choice) -> some View {
        let settings = model.data?.appSettings
        switch choice {
        case .currency:
            SettingsChoiceSheet(
                title: "Base currency", choices: SettingsOptions.currencies, current: settings?.baseCurrencyCode ?? "USD"
            ) { await model.setBaseCurrency($0) }
        case .locale:
            SettingsChoiceSheet(title: "Number format", choices: SettingsOptions.locales, current: settings?.localeOverride) {
                await model.setLocaleOverride($0)
            }
        case .lockDelay:
            SettingsChoiceSheet(
                title: "Lock delay", choices: SettingsOptions.lockDelays, current: settings?.autoLockTimeoutSeconds ?? 60
            ) { await model.setAutoLockTimeoutSeconds($0) }
        }
    }

    // MARK: - Data

    private enum DataTask: Equatable {
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

    private enum ImportKind {
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
    private struct Confirmation: Identifiable {
        enum Kind {
            case csv(CSVImport.Summary)
            case restore(RestorePlan)
        }

        let id = UUID()
        let kind: Kind
    }

    /// The DATA rows are enabled again (share sheet closed, picker
    /// cancelled, dialog closed, or a message shown).
    private func finishDataTask() {
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
    private func exportCSV() {
        dataTask = .exportCSV
        Task {
            do {
                let url = try await model.exportCSV()
                share(ShareFile(
                    url: url, subject: "Budget Transactions Export",
                    completedToast: Toast(message: "Transactions exported successfully!")))
            } catch {
                finishDataTask()
                model.showToast(Toast(message: "Error exporting transactions: \(error.localizedDescription)", style: .danger))
            }
        }
    }

    /// `_exportBackup`: the file is built off the main thread, then shared;
    /// "Backup exported" once an activity completed.
    private func exportBackup() {
        dataTask = .exportBackup
        Task {
            do throws(AppModel.DataTransferError) {
                let url = try await model.exportBackup()
                share(ShareFile(
                    url: url, subject: BackupEnvelope.shareSubject, completedToast: Toast(message: BackupEnvelope.exportedMessage)))
            } catch {
                finishDataTask()
                model.showToast(Toast(message: BackupEnvelope.exportFailedMessage(error.reason), style: .danger))
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

    private func pickFile(_ kind: ImportKind) {
        dataTask = kind == .csv ? .importCSV : .importBackup
        importKind = kind
        showsImporter = true
    }

    /// The picked file's bytes, read in place, then the CSV preview or the
    /// backup decode. A file that cannot be read, or is over
    /// `CSVImport.maximumFileBytes`, gets a message (Flutter returns
    /// silently for the first and reads any size).
    private func picked(_ result: Result<[URL], any Error>) {
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
                    model.showToast(Toast(message: BackupEnvelope.importFailedMessage(failure.message), style: .danger))
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
            model.showToast(Toast(message: BackupEnvelope.importFailedMessage(error.message), style: .danger))
        }
    }

    @ViewBuilder
    private func confirmationDialog(_ confirmation: Confirmation) -> some View {
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
    private func closeConfirmation() {
        confirmation = nil
        finishDataTask()
    }

    // MARK: - Destinations

    private enum Destination: Hashable {
        case categories, tagsAndRules, recurring, diagnostics, licences
        #if DEBUG
        case designGallery
        #endif

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .categories: CategoriesView()
            case .tagsAndRules: TagsRulesView()
            case .recurring: RecurringView()
            case .diagnostics: DiagnosticsView()
            case .licences: LicencesView()
            #if DEBUG
            case .designGallery: DesignGalleryView()
            #endif
            }
        }
    }
}

/// The page title as a leading navigation bar item, without the bar's own
/// glass capsule around it (iOS 26).
private struct SettingsBarTitle<Content: View>: ToolbarContent {
    @ViewBuilder var content: () -> Content

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading, content: content)
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading, content: content)
        }
    }
}
