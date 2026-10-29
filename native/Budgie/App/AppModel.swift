import BudgieCore
import Foundation
import Observation
import os
import UIKit
import WidgetKit

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

/// The app's single source of truth. Owns the bootstrap (MIGRATION_SPEC
/// sections 6, 9, 10) and every mutation; views only read and call methods.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// Prewarmed or locked launch: nothing has been read.
        case waitingForUnlock
        case starting
        /// Something prevents a safe start; nothing was written.
        case blocked(Blocker)
        case ready
    }

    enum Blocker: Equatable {
        /// The pre-migration copy could not be made (rule 1); the store was
        /// not touched.
        case backupFailed(String)
        /// A store file exists but cannot be read. Never shown as empty data.
        case readFailed(String)
        /// Both store files were unreadable and set aside (approved Q3).
        case dataUnreadable([String])
    }

    private(set) var phase: Phase = .starting
    /// Once the app is ready, every change asks for the insight cards;
    /// only one that touches the engine's inputs (transactions, budget
    /// limits, goals) recomputes them. A path that replaces much of the data
    /// (a restore, a CSV import) should assign `data` once, not per row.
    private(set) var data: FinancialData? {
        didSet {
            dataRevision &+= 1
            if phase == .ready { refreshInsights() }
        }
    }
    /// Bumped by every change of `data`: work built from a copy off the
    /// main thread (a CSV import) checks that nothing changed meanwhile.
    @ObservationIgnored private var dataRevision = 0
    private(set) var loadReport: FinancialStore.LoadReport?
    private(set) var backupOutcome: PreNativeMigrationBackup.Outcome?
    /// A quick action, widget or deep link waiting to open the add form.
    /// Views take it with `takePendingAdd()` once routes may open.
    var pendingAdd: AddRoute?
    /// Whether this session has passed App Lock. Starts false: a launch
    /// with the lock on is locked until the owner authenticates.
    private(set) var sessionUnlocked = false
    /// The message shown by the root toast host.
    private(set) var toast: Toast?
    /// The first-launch tour shows instead of the tabs: the Flutter flag
    /// `flutter.onboarding_completed` is not true. Read in `bootstrap()`
    /// once protected data is available; cleared by `completeOnboarding()`.
    /// Routes stay queued while it is true (`canOpenRoutes`).
    private(set) var showsOnboarding = false
    private(set) var themeMode: ThemeMode = .system
    private(set) var hasUnsavedChanges = false
    private(set) var lastSaveError: String?
    /// Everything derived from the ledger, rebuilt off the main thread once
    /// per change of the transactions. Views read this, never re-scan rows.
    private(set) var ledger = LedgerIndex.empty(calendar: DartCalendar(timeZone: .autoupdatingCurrent))
    /// Bumped whenever `ledger` is replaced; views observe this.
    private(set) var ledgerRevision = 0
    private var ledgerTask: Task<Void, Never>?
    /// The month Home, Flow and Insights show (Flutter
    /// `TransactionModel.selectedMonth`): shared, starts at the current
    /// month, not persisted.
    private(set) var selectedMonth: DartDateTime = {
        let calendar = DartCalendar(timeZone: .autoupdatingCurrent)
        return calendar.month(of: calendar.now())
    }()

    let calendar = DartCalendar(timeZone: .autoupdatingCurrent)
    private let protectedData: ProtectedDataMonitor
    private let preferences: UserDefaultsPreferences
    private let store: FinancialStore
    /// Replaced (all flags cleared) after a restore, whose one commit wrote
    /// every section a flag can name.
    private var tracker: PersistenceTracker
    private let storeDirectory: URL
    private let applicationSupport: URL
    /// False for a scratch directory (tests): the App Group widget values
    /// and timelines belong to the installed app.
    private let syncsWidget: Bool

    /// The app passes nothing. Tests pass a scratch Application Support
    /// directory and a preferences suite, so a full bootstrap runs without
    /// touching the host app's data (widget values included).
    init(applicationSupport: URL? = nil, preferences: UserDefaultsPreferences? = nil) {
        syncsWidget = applicationSupport == nil
        protectedData = ProtectedDataMonitor()
        let preferences = preferences ?? UserDefaultsPreferences(domainName: AppIdentifiers.bundleID)
        let applicationSupport =
            applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.preferences = preferences
        self.applicationSupport = applicationSupport
        storeDirectory = applicationSupport.appendingPathComponent(StoreFile.directoryName, isDirectory: true)
        let calendar = self.calendar
        store = FinancialStore(
            fileSystem: DirectoryFileSystem(directory: storeDirectory), preferences: preferences,
            protectedData: protectedData, clock: { DartDateTime.now(timeZone: calendar.timeZone) })
        tracker = PersistenceTracker(store: store)
    }

    var now: DartDateTime { calendar.now() }

    /// Dart `selectMonth`: normalised to `DateTime(year, month)`.
    func selectMonth(_ month: DartDateTime) {
        selectedMonth = calendar.month(of: month)
        refreshInsights()
    }

    private func newID() -> String { UUID().uuidString.lowercased() }

    // MARK: - Bootstrap

    private var isStarting = false

    func start() async {
        guard !isStarting, phase != .ready else { return }
        isStarting = true
        let interval = Signpost.launch.beginInterval("bootstrap")
        defer {
            isStarting = false
            Signpost.launch.endInterval("bootstrap", interval)
        }
        await bootstrap()
    }

    private func bootstrap() async {
        if !protectedData.isProtectedDataAvailable {
            phase = .waitingForUnlock
            let waitStart = ContinuousClock.now
            let wait = Signpost.launch.beginInterval("protectedDataWait")
            await protectedData.waitUntilAvailable()
            Signpost.launch.endInterval("protectedDataWait", wait)
            LaunchLog.protectedDataAvailable(after: Self.seconds(since: waitStart))
        }
        phase = .starting
        // Exports a kill left behind while their share sheet was open.
        removeStaleExports()

        // Preferences are only trustworthy once protected data is available.
        #if DEBUG
        // UI tests and scripted runs: "1" starts past the onboarding tour
        // (the flag is written for real), "0" removes the flag so the tour
        // shows on a simulator where an earlier run completed it.
        switch ProcessInfo.processInfo.environment["BUDGIE_SKIP_ONBOARDING"] {
        case "1": OnboardingFlag.markCompleted(preferences)
        case "0": OnboardingFlag.reset(preferences)
        default: break
        }
        #endif
        themeMode = ThemeMode(rawValue: preferences.string(PreferenceKey.themeMode) ?? "") ?? .system
        insightPreferences = InsightPreferences.load(from: preferences, timeZone: calendar.timeZone)
        // Flutter's gate reads the flag only once the data loaded; here it is
        // read before, but nothing shows it until `phase` is `.ready`.
        showsOnboarding = !OnboardingFlag.isCompleted(preferences)

        // Rule 1: copy everything before the first read or write.
        do {
            let backup = PreNativeMigrationBackup(
                applicationSupport: applicationSupport,
                sources: .init(
                    storeDirectory: storeDirectory,
                    exportPreferences: { [preferences] in try preferences.exportDomain() },
                    exportAppGroupPreferences: {
                        let domain = UserDefaults(suiteName: AppIdentifiers.appGroup)?
                            .persistentDomain(forName: AppIdentifiers.appGroup) ?? [:]
                        return try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
                    }),
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
            let outcome = try backup.ensure(lastCommittedChecksum: preferences.string(PreferenceKey.lastCommittedChecksum))
            backupOutcome = outcome
            switch outcome {
            case .created: LaunchLog.preNativeSnapshot("created")
            case .alreadyCurrent: LaunchLog.preNativeSnapshot("exists")
            }
        } catch {
            LaunchLog.preNativeSnapshot("failed")
            phase = .blocked(.backupFailed(String(describing: error)))
            return
        }

        let snapshot: FinancialSnapshot
        let read = Signpost.launch.beginInterval("store.read")
        do {
            snapshot = try await store.read()
            Signpost.launch.endInterval("store.read", read)
            LaunchLog.storeLoaded(revision: Int(snapshot.revision))
        } catch .dataUnreadable(let files) {
            Signpost.launch.endInterval("store.read", read)
            LaunchLog.storeLoadFailed("dataUnreadable")
            phase = .blocked(.dataUnreadable(files))
            return
        } catch .protectedDataUnavailable {
            Signpost.launch.endInterval("store.read", read)
            LaunchLog.storeLoadFailed("protectedDataUnavailable")
            // The device locked between the check and the read: wait again.
            phase = .waitingForUnlock
            let waitStart = ContinuousClock.now
            await protectedData.waitUntilAvailable()
            LaunchLog.protectedDataAvailable(after: Self.seconds(since: waitStart))
            phase = .starting
            await bootstrap()
            return
        } catch {
            Signpost.launch.endInterval("store.read", read)
            LaunchLog.storeLoadFailed("readFailed")
            phase = .blocked(.readFailed(String(describing: error)))
            return
        }
        loadReport = await store.lastLoadReport

        let incompatible = FinancialData.incompatibleSectionNames(in: snapshot)
        guard incompatible.isEmpty else {
            LaunchLog.storeLoadFailed("unsupportedSectionShape")
            phase = .blocked(.readFailed("Existing data has unsupported section types: \(incompatible.joined(separator: ", ")). The original files and migration safety copy have been kept."))
            return
        }

        var loaded = Signpost.launch.withIntervalSignpost("FinancialData.load") {
            FinancialData.load(
                snapshot, preferences: preferences, calendar: calendar, now: { [calendar] in calendar.now() }, newID: newID)
        }
        #if DEBUG
        // BackupUITests and CSVImportUITests replace the data (restores
        // over it, and their safety copies push older ones out). With
        // BUDGIE_UITEST_DATA_GUARD=1 the app opens only data UI tests own:
        // a store with nothing anyone entered (an erased simulator: at most
        // the built-in categories a first launch writes) marks the install
        // as theirs, and any other store is refused before anything is
        // written (the tests then skip).
        if ProcessInfo.processInfo.environment["BUDGIE_UITEST_DATA_GUARD"] == "1" {
            let marker = "budgie.uitest.ownsData"
            let d = loaded.data
            let nothingEntered =
                d.transactionRows.isEmpty && d.templateRows.isEmpty && d.netWorthRows.isEmpty && d.goalRows.isEmpty
                && d.tagRows.isEmpty && d.ruleRows.isEmpty && d.budgetLimitsObject.members.isEmpty
                && d.categories.allSatisfy(\.isBuiltIn)
            if nothingEntered { preferences.set(.bool(true), forKey: marker) }
            guard preferences.bool(marker) == true else {
                phase = .blocked(.readFailed("UI test data guard: this data was not made by UI tests (erase the simulator first)."))
                return
            }
        }
        #endif
        data = loaded.data
        netWorthRevision &+= 1
        // Hide balances may have changed where the widget flag was not
        // written (the Flutter build, a failed settings save).
        syncWidgetPrivacy()
        if !loaded.pendingWrites.isEmpty {
            await persist(loaded.pendingWrites.map(\.0))
        }

        // Launch-time generation (Dart `_initializeApp`), rows and cursors in
        // one commit (approved Q2).
        let launchTime = now
        let generation = Signpost.launch.beginInterval("recurringGeneration")
        let result = RecurringGenerator.generateDue(in: &loaded.data, now: launchTime, clock: { [calendar] in calendar.now() }, newID: newID)
        if result.changed {
            data = loaded.data
            await persist([Section.transactions, Section.recurringTransactions])
        } else {
            syncWidget()
        }
        Signpost.launch.endInterval("recurringGeneration", generation)
        // The first index is awaited so the first frame already has totals.
        let transactions = loaded.data.transactions
        let firstIndex = Signpost.launch.beginInterval("ledgerIndex.first")
        ledger = await Task.detached(priority: .userInitiated) { [calendar] in
            Signpost.ledger.withIntervalSignpost("LedgerIndex.build") { LedgerIndex.build(transactions, calendar: calendar) }
        }.value
        ledgerRevision &+= 1
        Signpost.launch.endInterval("ledgerIndex.first", firstIndex)
        // Like the index, the first cards are ready for the first frame.
        let firstInsights = Signpost.launch.beginInterval("insights.first")
        await updateInsights(generation: insightsGeneration)
        Signpost.launch.endInterval("insights.first", firstInsights)
        #if DEBUG
        // In memory only (nothing is written): UI tests turn App Lock on.
        if let seconds = AppLockTestHooks.timeoutSeconds {
            data?.appSettings.appLockEnabled = true
            data?.appSettings.autoLockTimeoutSeconds = seconds
        }
        #endif
        phase = .ready
        Signpost.launch.emitEvent("ready")
        #if DEBUG
        await RehearsalSummary.performScriptedEditsIfRequested(self)
        RehearsalSummary.writeIfRequested(self)
        #endif
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Retry after a blocked start (backup or read failure).
    func retryStart() async {
        guard case .blocked = phase else { return }
        phase = .starting
        await start()
    }

    /// The user chose to start with an empty store after `dataUnreadable`.
    /// The set-aside files stay on disk.
    func startFresh(acknowledging files: [String]) async {
        do {
            try await store.acknowledgeUnreadableData(files)
        } catch {
            return
        }
        phase = .starting
        await start()
    }

    // MARK: - Persistence

    /// The current in-memory value of a section. Every section in
    /// `Section.all` has a typed serializer; any other name is a programming
    /// error. In release it writes the section as loaded rather than null.
    private func serialize(_ section: String) -> JSONValue {
        guard let data else { return .null }
        guard let value = data.serializedSection(section) else {
            assertionFailure("no serializer for section \(section)")
            return data.sections[section] ?? .null
        }
        return value
    }

    /// Writes the named sections (plus anything still unsaved) and waits for
    /// the verified result. The change is already visible in memory. False
    /// means the sections are flagged: the unsaved banner and the retries
    /// take over.
    ///
    /// No edit can start while a restore runs: routes wait
    /// (`canOpenRoutes`), the confirmation card covers Settings, and nothing
    /// else writes. If one reaches this anyway it is not written (the
    /// restore's commit would overwrite it, or it would put old memory back
    /// over the restore): its sections are flagged, and the restore then
    /// stops before its commit, so the edit stays in memory behind the
    /// banner (`restoreBackup`).
    @discardableResult
    private func persist(_ sections: [String]) async -> Bool {
        guard !isRestoring else { return holdDuringRestore(sections) }
        return await persist(prepared: sections.map { ($0, serialize($0)) })
    }

    /// `persist` for sections already serialised (off the main thread).
    private func persist(prepared payload: [(String, JSONValue)]) async -> Bool {
        guard !isRestoring else { return holdDuringRestore(payload.map(\.0)) }
        let saved = await tracker.persist(payload, serialize: serialize)
        hasUnsavedChanges = tracker.hasUnsavedChanges
        lastSaveError = tracker.lastError.map { String(describing: $0) }
        if saved && payload.contains(where: { $0.0 == Section.transactions }) { syncWidget() }
        return saved
    }

    private func holdDuringRestore(_ sections: [String]) -> Bool {
        editedDuringRestore = true
        Self.dataLog.error("a save arrived during a restore; flagged, not written")
        tracker.flag(sections, because: .writeFailed(name: StoreFile.primaryName, reason: "Not saved while a backup was restored."))
        hasUnsavedChanges = tracker.hasUnsavedChanges
        lastSaveError = tracker.lastError.map { String(describing: $0) }
        return false
    }

    /// Writes every flagged section again. A no-op while a restore runs: a
    /// retry serialising the old memory after its commit would undo it
    /// (the restore retries before it starts, see `restoreBackup`).
    func retrySaves() async {
        guard !isRestoring else { return }
        await retryFlaggedSections()
    }

    private func retryFlaggedSections() async {
        _ = await tracker.retry(serialize: serialize)
        hasUnsavedChanges = tracker.hasUnsavedChanges
        lastSaveError = tracker.lastError.map { String(describing: $0) }
        if !hasUnsavedChanges { syncWidget() }
    }

    /// Rebuilds `ledger` off the main thread after the transactions changed
    /// in memory. A newer change supersedes a build still in flight.
    private func transactionsChanged() {
        guard let transactions = data?.transactions else { return }
        let calendar = self.calendar
        ledgerTask?.cancel()
        let rebuild = Signpost.ledger.beginInterval("ledgerRebuild")
        ledgerTask = Task {
            let index = await Task.detached(priority: .userInitiated) {
                Signpost.ledger.withIntervalSignpost("LedgerIndex.build") { LedgerIndex.build(transactions, calendar: calendar) }
            }.value
            guard !Task.isCancelled else {
                Signpost.ledger.endInterval("ledgerRebuild", rebuild, "superseded")
                return
            }
            ledger = index
            ledgerRevision &+= 1
            Signpost.ledger.endInterval("ledgerRebuild", rebuild)
        }
    }

    // MARK: - Widget

    /// App Group key for Hide balances (D12). Swift-only: Flutter's widget
    /// reads just `cashFlow` / `cashFlowMonth` and ignores it.
    private static let widgetHideBalancesKey = "budgieHideBalances"

    /// `_syncWidgetCashFlow`: current month's cash flow into the App Group,
    /// with the Hide balances flag the widget masks it by.
    private func syncWidget() {
        guard syncsWidget, let data, protectedData.isProtectedDataAvailable else { return }
        let value = data.widgetCashFlow(now: now)
        let defaults = UserDefaults(suiteName: AppIdentifiers.appGroup)
        defaults?.set(value.amount, forKey: "cashFlow")
        defaults?.set(value.month, forKey: "cashFlowMonth")
        defaults?.set(data.appSettings.hideBalances, forKey: Self.widgetHideBalancesKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Just the Hide balances flag, reloading the widget only when it
    /// changed (launch, and every Hide balances change, saved or not: the
    /// widget follows what the app shows).
    private func syncWidgetPrivacy() {
        guard syncsWidget, let data, protectedData.isProtectedDataAvailable,
            let defaults = UserDefaults(suiteName: AppIdentifiers.appGroup)
        else { return }
        let hidden = data.appSettings.hideBalances
        guard defaults.object(forKey: Self.widgetHideBalancesKey) as? Bool != hidden else { return }
        defaults.set(hidden, forKey: Self.widgetHideBalancesKey)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Mutations

    /// Applies `body` to the loaded data in place, then runs `after` (side
    /// effects that must precede the write). False, nothing run, without
    /// loaded data or when `body` returns false (a refused edit).
    private func applyMutation(_ body: (inout FinancialData) -> Bool, after: () -> Void = {}) -> Bool {
        guard data != nil, body(&data!) else { return false }
        after()
        return true
    }

    /// `applyMutation`, then the awaited write of `sections`. False for a
    /// refused edit (nothing written) and for a failed write alike.
    private func mutate(
        _ sections: [String], _ body: (inout FinancialData) -> Bool, after: () -> Void = {}
    ) async -> Bool {
        guard applyMutation(body, after: after) else { return false }
        return await persist(sections)
    }

    /// `mutate` for the accounts and the selected Worth month: bumps
    /// `netWorthRevision` (the `worthCache` key) before the write.
    private func mutateNetWorth(_ sections: [String], _ body: (inout FinancialData) -> Bool) async -> Bool {
        await mutate(sections, body, after: { netWorthRevision &+= 1 })
    }

    // MARK: - Transactions

    @discardableResult
    func addTransaction(
        type: TransactionType, description: String, amount: Double, category: String, date: DartDateTime, tagIds: [String] = []
    ) async -> Bool {
        guard amount.isFinite else { return false }
        return await mutate(
            [Section.transactions],
            { data in
                _ = data.addTransaction(
                    type: type, description: description, amount: amount, category: category, date: date, tagIds: tagIds,
                    id: newID(), now: now)
                return true
            },
            after: transactionsChanged)
    }

    /// Whether a readable transaction with this id is in memory (a false
    /// update/delete for a missing row is not a save failure).
    func hasTransaction(id: String) -> Bool {
        data?.transactionRows.contains { $0.record?.id == id } ?? false
    }

    @discardableResult
    func updateTransaction(id: String, _ edit: TransactionRecord.Edit) async -> Bool {
        guard edit.amount.isFinite else { return false }
        return await mutate(
            [Section.transactions], { $0.updateTransaction(id: id, edit, now: now) }, after: transactionsChanged)
    }

    @discardableResult
    func deleteTransaction(id: String) async -> Bool {
        await mutate([Section.transactions], { $0.deleteTransaction(id: id) }, after: transactionsChanged)
    }

    // MARK: - Recurring

    /// Dart generates due occurrences right after a template is added.
    @discardableResult
    func addTemplate(_ edit: RecurringTemplate.Edit) async -> Bool {
        guard edit.amount.isFinite else { return false }
        var generated = false
        return await mutate(
            [Section.recurringTransactions, Section.transactions],
            { data in
                data.addTemplate(.make(
                    id: newID(), type: edit.type, description: edit.description, amount: edit.amount, category: edit.category,
                    pattern: edit.pattern, startDate: edit.startDate, dayOfMonth: edit.dayOfMonth, dayOfWeek: edit.dayOfWeek))
                generated = RecurringGenerator.generateDue(
                    in: &data, now: now, clock: { [calendar] in calendar.now() }, newID: newID).changed
                return true
            },
            after: { if generated { transactionsChanged() } })
    }

    @discardableResult
    func updateTemplate(id: String, _ edit: RecurringTemplate.Edit) async -> Bool {
        guard edit.amount.isFinite else { return false }
        return await mutate([Section.recurringTransactions], { $0.updateTemplate(id: id, edit) })
    }

    @discardableResult
    func setTemplateActive(id: String, _ active: Bool) async -> Bool {
        await mutate([Section.recurringTransactions], { $0.setTemplateActive(id: id, active, now: now) })
    }

    @discardableResult
    func deleteTemplate(id: String) async -> Bool {
        await mutate([Section.recurringTransactions], { $0.deleteTemplate(id: id) })
    }

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

    /// `_generateDueTransactions` (recurring_transactions_page.dart:120-146):
    /// the launch generator, run now for every due template; the rows and
    /// the advanced cursors go to disk in one write.
    @discardableResult
    func generateDueNow() async -> DueGeneration {
        guard data != nil else { return DueGeneration(generated: 0, saved: true) }
        let result = RecurringGenerator.generateDue(in: &data!, now: now, clock: { [calendar] in calendar.now() }, newID: newID)
        guard result.changed else {
            // Nothing due, but an earlier failed write may still be in
            // memory only: retry it, and report success only once it is saved.
            if hasUnsavedChanges { await retrySaves() }
            return DueGeneration(generated: 0, saved: !hasUnsavedChanges)
        }
        if !result.generated.isEmpty { transactionsChanged() }
        let saved = await persist([Section.transactions, Section.recurringTransactions])
        return DueGeneration(generated: result.generated.count, saved: saved)
    }

    /// The latest transaction generated from a template, for the edit
    /// form's preview (`RecurringGenerator.previewOccurrences(editing:...)`).
    /// Read it once when the form opens: it scans the ledger.
    func lastGeneratedDate(forTemplate id: String) -> DartDateTime? {
        data?.lastGeneratedDate(forTemplate: id)
    }

    // MARK: - Onboarding

    /// The tour was completed or skipped: Flutter's `setBool(onboarding_completed,
    /// true)`, then the tabs show and any queued route opens (`canOpenRoutes`).
    func completeOnboarding() {
        OnboardingFlag.markCompleted(preferences)
        showsOnboarding = false
    }

    // MARK: - Budgets

    /// Dart `getCategoryBudgetLimit`: exact name, nil when there is none.
    func budgetLimit(for category: String) -> Double? {
        data?.budgetLimit(for: category)
    }

    /// Dart `setCategoryBudgetLimit` (trimmed; `limit <= 0` removes).
    @discardableResult
    func setBudgetLimit(category: String, limit: Double) async -> Bool {
        await mutate([Section.categoryBudgetLimits], { $0.setBudgetLimit(category: category, limit: limit) })
    }

    /// Dart `removeCategoryBudgetLimit`.
    @discardableResult
    func removeBudgetLimit(category: String) async -> Bool {
        await mutate([Section.categoryBudgetLimits], { $0.removeBudgetLimit(category: category) })
    }

    /// Home's budget rows and the Edit/Add picker lists for `month`, in
    /// one pass over the categories and the ledger month summary.
    func budgetOverview(forMonth month: DartDateTime) -> FinancialData.BudgetOverview {
        data?.budgetOverview(ledger.summary(forMonth: month)) ?? .empty
    }

    // MARK: - Net worth

    /// The month the Worth tab shows (Flutter `selectedNetWorthMonth`):
    /// persisted, loaded as stored even when stale or in the future.
    var selectedNetWorthMonth: DartDateTime { data?.selectedNetWorthMonth ?? calendar.month(of: now) }

    /// Bumped by every change to the accounts or the selected Worth month
    /// (and by the load); keys `worthCache`.
    private(set) var netWorthRevision = 0
    /// The Worth tab's derived values, computed once per revision instead
    /// of on every render (the history walks every snapshot).
    @ObservationIgnored private var worthCache = WorthCache()

    private struct WorthCache {
        var revision = -1
        var history: [NetWorthHistoryPoint]?
        var months: (current: DartDateTime, value: [DartDateTime])?
        var changes: [DartDateTime: Double?] = [:]
    }

    /// The cache for the current revision (emptied when it moved on).
    /// Reading `netWorthRevision` here makes views observe it.
    private func currentWorthCache() -> WorthCache {
        if worthCache.revision != netWorthRevision { worthCache = WorthCache(revision: netWorthRevision) }
        return worthCache
    }

    /// The Worth month strip (`getNetWorthAvailableMonths`), newest first.
    var netWorthAvailableMonths: [DartDateTime] {
        guard let data else { return [] }
        let current = calendar.month(of: now)
        if let months = currentWorthCache().months, months.current == current { return months.value }
        let value = data.netWorthAvailableMonths(now: now)
        worthCache.months = (current, value)
        return value
    }

    /// The growth chart's points (`getNetWorthHistory(limit: 24)`), newest
    /// first.
    var netWorthHistory: [NetWorthHistoryPoint] {
        guard let data else { return [] }
        if let history = currentWorthCache().history { return history }
        let history = data.netWorthHistory(limit: 24)
        worthCache.history = history
        return history
    }

    /// `getNetWorthChange(month)`: nil without a change to show.
    func netWorthChange(forMonth month: DartDateTime) -> Double? {
        guard let data else { return nil }
        if let change = currentWorthCache().changes[month] { return change }
        let change = data.netWorthChange(forMonth: month)
        worthCache.changes[month] = .some(change)
        return change
    }

    /// Whether any readable account exists (the Worth empty state).
    var hasNetWorthEntries: Bool { data?.hasNetWorthEntries ?? false }

    /// The account with this id (the history page follows it live).
    func netWorthEntry(id: String) -> NetWorthEntryRecord? {
        data?.netWorthEntry(id: id)
    }

    /// `getNetWorthEntryHistory`: ascending; empty for an unknown id.
    func netWorthEntryHistory(id: String) -> [NetWorthSnapshotRecord] {
        data?.netWorthEntryHistory(id: id) ?? []
    }

    /// Dart `selectNetWorthMonth`: normalised to the month, then written,
    /// even when it is already selected (as Flutter).
    @discardableResult
    func selectNetWorthMonth(_ month: DartDateTime) async -> Bool {
        await mutateNetWorth([Section.selectedNetWorthMonth]) {
            $0.selectNetWorthMonth(month)
            return true
        }
    }

    /// Dart `addNetWorthEntry`: the snapshot lands on `recordedAt`, else
    /// `now` for the current month or the month's end-of-month sentinel.
    /// False without a write for an empty name or a non-finite amount.
    @discardableResult
    func addNetWorthEntry(
        name: String, type: NetWorthEntryType, amount: Double, month: DartDateTime? = nil, recordedAt: DartDateTime? = nil
    ) async -> Bool {
        guard amount.isFinite else { return false }
        return await mutateNetWorth([Section.netWorthEntries]) {
            $0.addNetWorthEntry(
                name: name, type: type, amount: amount, month: month, recordedAt: recordedAt, id: newID(), now: now) != nil
        }
    }

    /// Dart `updateNetWorthEntry` (also "update balance" for a month): name
    /// and type, plus one added or replaced snapshot.
    @discardableResult
    func updateNetWorthEntry(
        id: String, name: String, type: NetWorthEntryType, amount: Double, month: DartDateTime? = nil,
        recordedAt: DartDateTime? = nil
    ) async -> Bool {
        guard amount.isFinite else { return false }
        return await mutateNetWorth([Section.netWorthEntries]) {
            $0.updateNetWorthEntry(
                id: id, name: name, type: type, amount: amount, month: month, recordedAt: recordedAt, now: now)
        }
    }

    /// Dart `deleteNetWorthEntry`: the account and all its snapshots.
    @discardableResult
    func deleteNetWorthEntry(id: String) async -> Bool {
        await mutateNetWorth([Section.netWorthEntries], { $0.deleteNetWorthEntry(id: id) })
    }

    /// Dart `deleteNetWorthSnapshot`: the snapshot recorded at exactly
    /// `recordedAt`; false without a write when there is none.
    @discardableResult
    func deleteNetWorthSnapshot(entryID: String, recordedAt: DartDateTime) async -> Bool {
        await mutateNetWorth(
            [Section.netWorthEntries], { $0.deleteNetWorthSnapshot(entryID: entryID, recordedAt: recordedAt) })
    }

    // MARK: - Savings goals

    /// Dart's process-wide `SavingsGoal._idCounter`: advanced only by a
    /// goal that is actually added.
    private var savingsGoalIDCounter = 0

    /// The Goals tab's list (`_sortedGoals`): incomplete first, then target
    /// date ascending, stable.
    var savingsGoals: [SavingsGoalRecord] { SavingsGoalRecord.sorted(data?.savingsGoals ?? []) }

    /// The summary card's totals and ring.
    var savingsGoalsSummary: SavingsGoalsSummary { SavingsGoalsSummary(goals: data?.savingsGoals ?? []) }

    /// What a goal mutation did: written and verified, changed in memory
    /// but not written (the unsaved banner and Retry take over), or refused
    /// with nothing changed or written (so no save-failed toast).
    enum SaveOutcome: Equatable {
        case saved, failed, rejected
    }

    private func persistGoals() async -> SaveOutcome {
        await persist([Section.savingsGoals]) ? .saved : .failed
    }

    /// Dart `addSavingsGoal`: the trimmed name, the target date's local
    /// midnight, a Flutter-format id. Rejected (no write) for a blank name
    /// or a target that is not a positive finite number.
    @discardableResult
    func addSavingsGoal(name: String, targetAmount: Double, targetDate: DartDateTime) async -> SaveOutcome {
        let now = self.now
        guard targetAmount.isFinite,
            applyMutation(
                {
                    $0.addSavingsGoal(
                        name: name, targetAmount: targetAmount, targetDate: targetDate,
                        id: SavingsGoalRecord.makeID(now: now, counter: savingsGoalIDCounter), now: now) != nil
                },
                after: { savingsGoalIDCounter += 1 })
        else { return .rejected }
        return await persistGoals()
    }

    /// Dart `updateSavingsGoal` (the edit form): name, target, saved amount
    /// and target date (not normalised); `completedAt` follows the amount.
    @discardableResult
    func updateSavingsGoal(id: String, _ edit: SavingsGoalRecord.Edit) async -> SaveOutcome {
        guard edit.targetAmount.isFinite, edit.currentAmount.isFinite,
            applyMutation({ $0.updateSavingsGoal(id: id, edit, now: now) })
        else { return .rejected }
        return await persistGoals()
    }

    /// Dart `deleteSavingsGoal`: every goal with this id.
    @discardableResult
    func deleteSavingsGoal(id: String) async -> SaveOutcome {
        guard applyMutation({ $0.deleteSavingsGoal(id: id) }) else { return .rejected }
        return await persistGoals()
    }

    /// Dart `allocateToSavingsGoal` (Add money): no transaction is created.
    /// Whether it completes the goal is `willComplete(allocating:)` on the
    /// goal as shown before the dialog, as in Flutter.
    @discardableResult
    func allocateToSavingsGoal(id: String, amount: Double) async -> SaveOutcome {
        guard amount.isFinite, applyMutation({ $0.allocateToSavingsGoal(id: id, amount: amount, now: now) }) else {
            return .rejected
        }
        return await persistGoals()
    }

    // MARK: - Settings (store section + mirrored preference, like Dart)

    private static let settingsLog = Logger(subsystem: AppIdentifiers.bundleID, category: "settings")

    /// Dart `setBaseCurrencyCode`: trimmed and uppercased; a code that is
    /// not 3 characters long, or the current one, writes nothing. Amounts
    /// are not converted.
    @discardableResult
    func setBaseCurrency(_ code: String) async -> Bool {
        await updateSettings("baseCurrencyCode") { $0.setBaseCurrencyCode(code) }
    }

    /// Dart `setLocaleOverride`: nil or blank is "Match device" (the mirror
    /// is removed). Written even when unchanged, as Dart does.
    @discardableResult
    func setLocaleOverride(_ locale: String?) async -> Bool {
        await updateSettings("localeOverride") { $0.setLocaleOverride(locale) }
    }

    /// Dart `setAppLockEnabled`.
    @discardableResult
    func setAppLockEnabled(_ enabled: Bool) async -> Bool {
        await updateSettings("appLockEnabled") { $0.setAppLockEnabled(enabled) }
    }

    /// Dart `setAutoLockTimeoutSeconds`: a negative value writes nothing.
    @discardableResult
    func setAutoLockTimeoutSeconds(_ seconds: Int) async -> Bool {
        await updateSettings("autoLockTimeoutSeconds") { $0.setAutoLockTimeoutSeconds(seconds) }
    }

    /// Dart `setHideBalances`: `moneyFormatter` masks every amount at once,
    /// and the Home Screen widget too (D12; Flutter's widget ignores it).
    @discardableResult
    func setHideBalances(_ hidden: Bool) async -> Bool {
        let saved = await updateSettings("hideBalances") { $0.setHideBalances(hidden) }
        syncWidgetPrivacy()
        return saved
    }

    /// One `AppSettingsProvider` setter: memory, the preference mirror, then
    /// the whole `appSettings` section, awaited. True when the write verified
    /// or the value was already current; false for a rejected value or a
    /// failed write, which stays in memory behind the unsaved banner (Flutter
    /// has no failure handling: its change reverts on relaunch).
    private func updateSettings(_ field: String, _ change: (inout AppSettings) -> SettingsUpdate) async -> Bool {
        guard data != nil else { return false }
        switch change(&data!.appSettings) {
        case .rejected:
            return false
        case .unchanged:
            return true
        case .write(let key, let value):
            preferences.set(value, forKey: key)
            let saved = await persist([Section.appSettings])
            if !saved { Self.settingsLog.error("appSettings.\(field, privacy: .public) not saved; kept in memory") }
            return saved
        }
    }

    /// Dart `ThemeProvider.setThemeMode`: the preference only, no store
    /// section; the current mode writes nothing.
    func setThemeMode(_ mode: ThemeMode) {
        guard mode != themeMode else { return }
        themeMode = mode
        preferences.set(.string(mode.rawValue), forKey: PreferenceKey.themeMode)
    }

    // MARK: - Insights (Flutter `LocalInsightsSection` on the Flow tab)

    /// The dismissed and snoozed ids (`flutter.local_insights_dismissed_v1`,
    /// `flutter.local_insights_snoozed_v1`): preferences, never the store.
    /// Read in `bootstrap()` once protected data is available.
    private(set) var insightPreferences = InsightPreferences()
    /// Flow's insight cards: at most three, in the engine's order. Ids can
    /// repeat (both cards show and go together), so views key by offset.
    private(set) var insights: [LocalInsight] = []
    @ObservationIgnored private var insightsTask: Task<Void, Never>?
    /// Bumped by every recompute; a result computed for an older one is
    /// dropped.
    @ObservationIgnored private var insightsGeneration = 0
    /// What the latest recompute reads. A refresh whose inputs are the same
    /// computes nothing: its result is already shown or on its way.
    @ObservationIgnored private var insightInputs: InsightInputs?

    /// Everything `InsightEngine.generate` depends on. The engine reads
    /// `now` only through its calendar day, and the preferences through the
    /// ids they exclude at `now`. The stored rows are compared, not the
    /// derived lists: an array whose storage an edit did not touch (net
    /// worth, settings, tags, rules) compares in O(1), and one that grew or
    /// shrank by its count.
    private struct InsightInputs: Equatable {
        let transactions: [StoredRow<TransactionRecord>]
        let budgetLimits: JSONObject
        let goals: [StoredRow<SavingsGoalRecord>]
        let selectedMonth: DartDateTime
        let day: DartDateTime.Fields
        let excludedIDs: [String]

        static func == (lhs: InsightInputs, rhs: InsightInputs) -> Bool {
            lhs.transactions == rhs.transactions && lhs.budgetLimits == rhs.budgetLimits && lhs.goals == rhs.goals
                && lhs.selectedMonth == rhs.selectedMonth
                && (lhs.day.year, lhs.day.month, lhs.day.day) == (rhs.day.year, rhs.day.month, rhs.day.day)
                && lhs.excludedIDs.count == rhs.excludedIDs.count
                && zip(lhs.excludedIDs, rhs.excludedIDs).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
        }
    }

    private func currentInsightInputs(_ data: FinancialData, now: DartDateTime) -> InsightInputs {
        InsightInputs(
            transactions: data.transactionRows, budgetLimits: data.budgetLimitsObject, goals: data.goalRows,
            selectedMonth: selectedMonth, day: now.fields, excludedIDs: insightPreferences.excludedIDs(now: now))
    }

    /// Recomputes `insights` off the main thread when an input changed: the
    /// transactions, budget limits or goals, the selected month, the
    /// preferences, or the clock (a snooze ending, a new day moving budget
    /// pace). Called on every data change, month change, dismiss and snooze;
    /// Flow also calls it when it appears and when the scene becomes active.
    /// Several calls in one turn compute once.
    func refreshInsights() {
        guard let data else { return }
        let inputs = currentInsightInputs(data, now: now)
        guard inputs != insightInputs else { return }
        insightInputs = inputs
        insightsGeneration &+= 1
        let generation = insightsGeneration
        insightsTask?.cancel()
        insightsTask = Task {
            guard !Task.isCancelled else { return }
            await updateInsights(generation: generation)
        }
    }

    /// The engine's lists are derived from `data` inside the detached task,
    /// not on the main thread.
    private func updateInsights(generation: Int) async {
        guard let data else { return }
        let now = self.now
        let inputs = currentInsightInputs(data, now: now)
        insightInputs = inputs
        let selectedMonth = inputs.selectedMonth, excluded = inputs.excludedIDs, calendar = self.calendar
        let result = await Task.detached(priority: .userInitiated) {
            Signpost.ledger.withIntervalSignpost("insights.generate") {
                InsightEngine.generate(
                    transactions: data.transactions, budgetLimits: data.budgetLimits, savingsGoals: data.savingsGoals,
                    selectedMonth: selectedMonth, now: now, excludedIDs: excluded, calendar: calendar)
            }
        }.value
        guard generation == insightsGeneration, result != insights else { return }
        insights = result
    }

    /// `_dismiss`: hidden for good; the whole dismissed list is rewritten.
    /// Like Flutter, no confirmation and no undo.
    func dismissInsight(id: String) {
        let write = insightPreferences.dismiss(id)
        preferences.set(write.value, forKey: write.key)
        hideInsight(id)
    }

    /// `_snooze`: hidden for 30 x 24 hours from now; the whole snoozed map
    /// is rewritten.
    func snoozeInsight(id: String) {
        let write = insightPreferences.snooze(id, now: now)
        preferences.set(write.value, forKey: write.key)
        hideInsight(id)
    }

    /// Every card with the id goes at once, as Flutter's rebuild does; the
    /// next candidate fills in when the recomputation lands.
    private func hideInsight(_ id: String) {
        insights.removeAll { $0.id.utf16.elementsEqual(id.utf16) }
        refreshInsights()
    }

    // MARK: - Categories (category management)

    /// What a category edit did: written and verified; changed in memory
    /// but not written (the unsaved banner and Retry take over, the caller
    /// shows `Toast.saveFailed`); nothing to do (a Flutter no-op: unknown
    /// id, unchanged state, a move to the same slot); or refused with
    /// nothing changed, carrying Flutter's copy (`error.message`).
    enum CategoryOutcome: Equatable {
        case saved, failed, unchanged
        case rejected(CategoryEditError)
    }

    /// Dart `categoriesFor(type, includeArchived:)`: the management list.
    func categoryDefinitions(type: TransactionType, includeArchived: Bool) -> [CategoryInfo] {
        data?.categoryDefinitions(type: type, includeArchived: includeArchived) ?? []
    }

    /// The error saving `name` would give (live editor validation);
    /// `excluding` is the edited category's id, nil when adding.
    func validateCategoryName(_ name: String, type: TransactionType, excluding id: String?) -> CategoryEditError? {
        data?.validateCategoryName(name, type: type, excluding: id)
    }

    /// The `moveCategory` offset for Move up (`direction` -1) or Move down
    /// (+1) relative to the rows shown; nil when that move is not offered.
    func categoryMoveOffset(id: String, direction: Int, includeArchived: Bool) -> Int? {
        data?.categoryMoveOffset(id: id, direction: direction, includeArchived: includeArchived)
    }

    /// Dart `addCategory` (the type is the page's selected segment).
    @discardableResult
    func addCategory(type: TransactionType, name: String, iconIdentifier: String, colorToken: String) async -> CategoryOutcome {
        await editCategories { data throws(CategoryEditError) in
            try data.addCategory(type: type, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, newID: newID)
        }
    }

    /// Dart `updateCategory` plus the page's rename cascade (transactions,
    /// the expense budget key, templates, rules of the same type or none),
    /// all in one commit.
    @discardableResult
    func updateCategory(id: String, name: String, iconIdentifier: String, colorToken: String) async -> CategoryOutcome {
        let now = self.now
        return await editCategories { data throws(CategoryEditError) in
            try data.updateCategory(id: id, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, now: now)
        }
    }

    /// Dart `setArchived` (Archive / Restore).
    @discardableResult
    func setCategoryArchived(id: String, _ archived: Bool) async -> CategoryOutcome {
        await editCategories { data throws(CategoryEditError) in try data.setCategoryArchived(id: id, archived) }
    }

    /// Dart `moveCategory`: `offset` in the type's whole list (use
    /// `categoryMoveOffset` for Move up / Move down).
    @discardableResult
    func moveCategory(id: String, offset: Int) async -> CategoryOutcome {
        await editCategories { data in data.moveCategory(id: id, offset: offset) }
    }

    /// Runs one category edit on a copy (a refused edit leaves `data`
    /// untouched), then memory first and one awaited commit of every
    /// changed section. A rename that touched transactions rebuilds the
    /// ledger, which keys totals by category name.
    private func editCategories(
        _ edit: (inout FinancialData) throws(CategoryEditError) -> CategoryEditResult
    ) async -> CategoryOutcome {
        guard var copy = data else { return .unchanged }
        let result: CategoryEditResult
        do {
            result = try edit(&copy)
        } catch {
            return .rejected(error)
        }
        guard !result.changedSections.isEmpty else { return .unchanged }
        data = copy
        if result.changedSections.contains(Section.transactions) { transactionsChanged() }
        return await persist(result.changedSections) ? .saved : .failed
    }

    func categories(for type: TransactionType) -> [CategoryInfo] {
        data?.categoryPicker(for: type) ?? CategoryCatalog.pickerList(CategoryCatalog.builtIn, type: type, usedNames: [])
    }

    // MARK: - Tags and rules

    /// What a tag or rule edit did: written and verified; changed in memory
    /// but not written (the unsaved banner and Retry take over, the caller
    /// shows `Toast.saveFailed`; Flutter is silent); nothing to do (an
    /// unknown id, where Flutter rewrites the unchanged list); or refused
    /// with nothing changed, carrying the copy to show (`error.message`).
    enum TagRuleOutcome: Equatable {
        case saved, failed, unchanged
        case rejected(CategorizationEditError)
    }

    /// Transaction tags (`transactionTags`), in stored order (Flutter's
    /// `tags`: the page, the form chips and the Flow filter chips).
    var tags: [TransactionTagRecord] { data?.tags ?? [] }

    /// Flutter's `rules` getter, priority descending: the order the Tags &
    /// rules page lists them and suggestions try them.
    var rules: [CategorizationRuleRecord] { data?.rulesByPriority ?? [] }

    /// The error adding this tag name would give, else nil.
    func validateTagName(_ name: String) -> CategorizationEditError? {
        data?.validateTagName(name)
    }

    /// Dart `addTag`: the trimmed name, "accent" colour. Writes
    /// `transactionTags`.
    @discardableResult
    func addTag(name: String, colorToken: String = "accent") async -> TagRuleOutcome {
        let id = newID()
        return await editTagsAndRules { data throws(CategorizationEditError) in
            try data.addTag(name: name, colorToken: colorToken, id: id)
            return [Section.transactionTags]
        }
    }

    /// Dart `deleteTag`: the tag goes and every rule drops it; transactions
    /// keep the id (D9). One commit of `transactionTags` and
    /// `categorizationRules` (Flutter makes two).
    @discardableResult
    func deleteTag(id: String) async -> TagRuleOutcome {
        await editTagsAndRules { data in data.deleteTag(id: id) }
    }

    /// Dart `addRule` with a new id. The Flutter dialog's rule sets only
    /// the pattern, match, type, category and tags (`RuleDraft` defaults
    /// for the rest). Writes `categorizationRules`.
    @discardableResult
    func addRule(_ draft: RuleDraft) async -> TagRuleOutcome {
        let id = newID()
        return await editTagsAndRules { data throws(CategorizationEditError) in
            try data.addRule(draft, id: id)
            return [Section.categorizationRules]
        }
    }

    /// Dart `deleteRule`. Writes `categorizationRules`.
    @discardableResult
    func deleteRule(id: String) async -> TagRuleOutcome {
        await editTagsAndRules { data in data.deleteRule(id: id) ? [Section.categorizationRules] : [] }
    }

    /// Swift-only rule edit: in place (id and stored position kept), only
    /// the changed keys patched. Writes `categorizationRules`;
    /// `.unchanged` when the draft matches the rule.
    @discardableResult
    func updateRule(id: String, _ draft: RuleDraft) async -> TagRuleOutcome {
        await editTagsAndRules { data throws(CategorizationEditError) in
            try data.updateRule(id: id, draft) ? [Section.categorizationRules] : []
        }
    }

    /// Swift-only enable switch (`isEnabled`). Writes `categorizationRules`;
    /// `.unchanged` when the rule is unknown or already so.
    @discardableResult
    func setRuleEnabled(id: String, _ enabled: Bool) async -> TagRuleOutcome {
        await editTagsAndRules { data in data.setRuleEnabled(id: id, enabled) ? [Section.categorizationRules] : [] }
    }

    /// Runs one tag or rule edit on a copy (a refused edit leaves `data`
    /// untouched), then memory first and one awaited commit of the sections
    /// it returns.
    private func editTagsAndRules(
        _ edit: (inout FinancialData) throws(CategorizationEditError) -> [String]
    ) async -> TagRuleOutcome {
        guard var copy = data else { return .unchanged }
        let sections: [String]
        do {
            sections = try edit(&copy)
        } catch {
            return .rejected(error)
        }
        guard !sections.isEmpty else { return .unchanged }
        data = copy
        return await persist(sections) ? .saved : .failed
    }

    /// The form's auto-categorisation (`applySuggestion`,
    /// transaction_form.dart:106-121): the amount text parses with Dart's
    /// `double.tryParse(text) ?? 0`. The caller applies the rule only if its
    /// category is in the current picker list.
    func suggestion(type: TransactionType, description: String, amountText: String) -> CategorizationRuleRecord? {
        guard let data else { return nil }
        return CategorizationEngine.suggest(
            rules: data.rules, type: type, description: description, amount: DartDouble.tryParse(amountText) ?? 0)
    }

    /// `applySuggestion` with its gate, for a caller that has no picker
    /// list of its own (the voice prefill, transaction_form.dart:78-88): the
    /// first matching rule, or nil when its category is not an active
    /// category of `type`. Set the category and replace the selected tags
    /// with `tagIds` (a Set in Flutter: duplicates collapse).
    func suggestion(type: TransactionType, description: String, amount: Double) -> CategorizationRuleRecord? {
        guard let data else { return nil }
        return CategorizationEngine.suggestion(
            rules: data.rules, type: type, description: description, amount: amount,
            activeCategoryNames: categories(for: type).map(\.name))
    }

    func categoryInfo(named name: String, type: TransactionType) -> CategoryInfo? {
        data?.categoryInfo(named: name, type: type)
    }

    var moneyFormatter: MoneyFormatter {
        let settings = data?.appSettings
        return MoneyFormatter(
            currencyCode: settings?.baseCurrencyCode ?? "USD", locale: settings?.localeOverride,
            hideBalances: settings?.hideBalances ?? false)
    }

    // MARK: - Export files

    /// The export file whose share sheet is being prepared or is open: the
    /// background sweep leaves it alone. Nil otherwise.
    private var activeExport: URL?

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
                current.importTransactions(summary, now: now, newID: { UUID().uuidString.lowercased() })
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
                try BackupEnvelope.decode(bytes: bytes, calendar: calendar, now: now, newID: { UUID().uuidString.lowercased() })
            }
        }.value
        return try result.get()
    }

    /// A restore is running, from its start until memory, the tracker and
    /// the mirrors were swapped (or it failed): routes wait
    /// (`canOpenRoutes`) and `persist` / `retrySaves` write nothing.
    private(set) var isRestoring = false
    /// A save reached `persist` since the restore started.
    @ObservationIgnored private var editedDuringRestore = false

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
            current.restoring(plan, now: now, newID: { UUID().uuidString.lowercased() })
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
        hasUnsavedChanges = false
        lastSaveError = nil
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

    private static let dataLog = Logger(subsystem: AppIdentifiers.bundleID, category: "data")

    /// A store error in words.
    private static func describe(_ error: FinancialStoreError) -> String {
        switch error {
        case .protectedDataUnavailable: "The device is locked."
        case .readFailed(_, let reason), .writeFailed(_, let reason): reason
        case .verificationFailed: "The saved data did not verify."
        case .dataUnreadable: "The stored data could not be read."
        }
    }

    // MARK: - Toasts

    func showToast(_ toast: Toast) { self.toast = toast }

    /// Dismisses `id` if it is still the one showing.
    func dismissToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
    }

    // MARK: - Routing

    /// Settings' "Turn on App Lock" prompt is up. The prompt makes the scene
    /// inactive, so App Lock holds its privacy cover back until the scene
    /// is active again (it would flash over Settings as the lock turns on).
    private(set) var isEnablingAppLock = false

    func setEnablingAppLock(_ enabling: Bool) { isEnablingAppLock = enabling }

    /// App Lock is on and this session has not authenticated.
    var isLocked: Bool { data?.appSettings.appLockEnabled == true && !sessionUnlocked }

    func markUnlocked() { sessionUnlocked = true }

    /// After the lock timeout in the background.
    func relock() { sessionUnlocked = false }

    /// Routes open only over unlocked, onboarded data: a quick action or
    /// deep link on a locked launch waits for the unlock (it used to open
    /// the form above the lock screen). One arriving during a restore waits
    /// for it to end (the form would edit data the restore is replacing);
    /// `MainView` opens it when this turns true.
    var canOpenRoutes: Bool { phase == .ready && !isLocked && !showsOnboarding && !isRestoring }

    /// The pending add route, cleared, when it may open now; otherwise nil
    /// and the route stays queued.
    func takePendingAdd() -> AddRoute? {
        guard canOpenRoutes, let route = pendingAdd else { return nil }
        pendingAdd = nil
        return route
    }

    func open(_ url: URL) {
        let action = url.host?.isEmpty == false ? url.host! : (url.pathComponents.dropFirst().first ?? "")
        switch action {
        case "add-income", "add_income": pendingAdd = .income
        case "add-expense", "add_expense": pendingAdd = .expense
        case "voice-add", "voice_add": pendingAdd = .voice
        default: break
        }
    }

    func handleShortcut(_ type: String) {
        switch type {
        case "action_add_income": pendingAdd = .income
        case "action_add_expense": pendingAdd = .expense
        case "action_voice_add": pendingAdd = .voice
        default: break
        }
    }

    static func registerShortcuts() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: "action_add_expense", localizedTitle: "Add Expense", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "minus.circle.fill")),
            UIApplicationShortcutItem(
                type: "action_add_income", localizedTitle: "Add Income", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "plus.circle.fill")),
            UIApplicationShortcutItem(
                type: "action_voice_add", localizedTitle: "Add by Voice", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "mic.circle.fill")),
        ]
    }
}

/// Asks iOS for time to finish work the user may leave part way (a
/// restore, an import): until `end()`, or until the system's limit, when
/// it is ended for the app. Without it a restore suspended in the
/// background between its commit and the preference mirrors would leave
/// them stale until it resumed (or for good if the app was then killed).
@MainActor
private final class BackgroundWork {
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
