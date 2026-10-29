import BudgieCore
import Foundation
import Observation
import os
import UIKit
import WidgetKit

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
    var data: FinancialData? {
        didSet {
            dataRevision &+= 1
            if phase == .ready { refreshInsights() }
        }
    }
    /// Bumped by every change of `data`: work built from a copy off the
    /// main thread (a CSV import) checks that nothing changed meanwhile.
    @ObservationIgnored var dataRevision = 0
    private(set) var loadReport: FinancialStore.LoadReport?
    private(set) var backupOutcome: PreNativeMigrationBackup.Outcome?
    /// A quick action, widget or deep link waiting to open the add form.
    /// Views take it with `takePendingAdd()` once routes may open.
    var pendingAdd: AddRoute?
    /// Whether this session has passed App Lock. Starts false: a launch
    /// with the lock on is locked until the owner authenticates.
    var sessionUnlocked = false
    /// The message shown by the root toast host.
    private(set) var toast: Toast?
    /// The first-launch tour shows instead of the tabs: the Flutter flag
    /// `flutter.onboarding_completed` is not true. Read in `bootstrap()`
    /// once protected data is available; cleared by `completeOnboarding()`.
    /// Routes stay queued while it is true (`canOpenRoutes`).
    private(set) var showsOnboarding = false
    var themeMode: ThemeMode = .system
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
    let preferences: UserDefaultsPreferences
    let store: FinancialStore
    /// Replaced (all flags cleared) after a restore, whose one commit wrote
    /// every section a flag can name.
    var tracker: PersistenceTracker
    let storeDirectory: URL
    let applicationSupport: URL
    /// False for a scratch directory (tests): the App Group widget values
    /// and timelines belong to the installed app.
    private let syncsWidget: Bool

    // Stored state of the features in the `AppModel+*.swift` extensions
    // (an extension cannot hold stored properties). Each comment is the
    // feature's own.

    /// Bumped by every change to the accounts or the selected Worth month
    /// (and by the load); keys `worthCache`.
    var netWorthRevision = 0
    /// The Worth tab's derived values, computed once per revision instead
    /// of on every render (the history walks every snapshot).
    @ObservationIgnored var worthCache = WorthCache()

    /// Dart's process-wide `SavingsGoal._idCounter`: advanced only by a
    /// goal that is actually added.
    var savingsGoalIDCounter = 0

    /// The dismissed and snoozed ids (`flutter.local_insights_dismissed_v1`,
    /// `flutter.local_insights_snoozed_v1`): preferences, never the store.
    /// Read in `bootstrap()` once protected data is available.
    var insightPreferences = InsightPreferences()
    /// Flow's insight cards: at most three, in the engine's order. Ids can
    /// repeat (both cards show and go together), so views key by offset.
    var insights: [LocalInsight] = []
    @ObservationIgnored var insightsTask: Task<Void, Never>?
    /// Bumped by every recompute; a result computed for an older one is
    /// dropped.
    @ObservationIgnored var insightsGeneration = 0
    /// What the latest recompute reads. A refresh whose inputs are the same
    /// computes nothing: its result is already shown or on its way.
    @ObservationIgnored var insightInputs: InsightInputs?

    /// The export file whose share sheet is being prepared or is open: the
    /// background sweep leaves it alone. Nil otherwise.
    var activeExport: URL?

    /// A restore is running, from its start until memory, the tracker and
    /// the mirrors were swapped (or it failed): routes wait
    /// (`canOpenRoutes`) and `persist` / `retrySaves` write nothing.
    var isRestoring = false
    /// A save reached `persist` since the restore started.
    @ObservationIgnored var editedDuringRestore = false

    /// Settings' "Turn on App Lock" prompt is up. The prompt makes the scene
    /// inactive, so App Lock holds its privacy cover back until the scene
    /// is active again (it would flash over Settings as the lock turns on).
    var isEnablingAppLock = false

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

    func newID() -> String { Self.makeID() }

    /// For work off the main actor (CSV import, backup decode, restore).
    nonisolated static func makeID() -> String { UUID().uuidString.lowercased() }

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
        if !protectedData.isProtectedDataAvailable { await waitForUnlock() }
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
            await waitForUnlock()
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

    /// Shows the waiting screen until protected data is available.
    private func waitForUnlock() async {
        phase = .waitingForUnlock
        let waitStart = ContinuousClock.now
        let wait = Signpost.launch.beginInterval("protectedDataWait")
        await protectedData.waitUntilAvailable()
        Signpost.launch.endInterval("protectedDataWait", wait)
        LaunchLog.protectedDataAvailable(after: Self.seconds(since: waitStart))
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
    func persist(_ sections: [String]) async -> Bool {
        guard !isRestoring else { return holdDuringRestore(sections) }
        return await persist(prepared: sections.map { ($0, serialize($0)) })
    }

    /// `persist` for sections already serialised (off the main thread).
    func persist(prepared payload: [(String, JSONValue)]) async -> Bool {
        guard !isRestoring else { return holdDuringRestore(payload.map(\.0)) }
        let saved = await tracker.persist(payload, serialize: serialize)
        syncSaveState()
        if saved && payload.contains(where: { $0.0 == Section.transactions }) { syncWidget() }
        return saved
    }

    private func holdDuringRestore(_ sections: [String]) -> Bool {
        editedDuringRestore = true
        Self.dataLog.error("a save arrived during a restore; flagged, not written")
        tracker.flag(sections, because: .writeFailed(name: StoreFile.primaryName, reason: "Not saved while a backup was restored."))
        syncSaveState()
        return false
    }

    /// Mirrors the tracker's unsaved state into the observable properties.
    func syncSaveState() {
        hasUnsavedChanges = tracker.hasUnsavedChanges
        lastSaveError = tracker.lastError.map { String(describing: $0) }
    }

    /// Writes every flagged section again. A no-op while a restore runs: a
    /// retry serialising the old memory after its commit would undo it
    /// (the restore retries before it starts, see `restoreBackup`).
    func retrySaves() async {
        guard !isRestoring else { return }
        await retryFlaggedSections()
    }

    func retryFlaggedSections() async {
        _ = await tracker.retry(serialize: serialize)
        syncSaveState()
        if !hasUnsavedChanges { syncWidget() }
    }

    /// Rebuilds `ledger` off the main thread after the transactions changed
    /// in memory. A newer change supersedes a build still in flight.
    func transactionsChanged() {
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
    func syncWidget() {
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
    func syncWidgetPrivacy() {
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
    func applyMutation(_ body: (inout FinancialData) -> Bool, after: () -> Void = {}) -> Bool {
        guard data != nil, body(&data!) else { return false }
        after()
        return true
    }

    /// `applyMutation`, then the awaited write of `sections`. False for a
    /// refused edit (nothing written) and for a failed write alike.
    func mutate(
        _ sections: [String], _ body: (inout FinancialData) -> Bool, after: () -> Void = {}
    ) async -> Bool {
        guard applyMutation(body, after: after) else { return false }
        return await persist(sections)
    }

    /// `mutate` for the accounts and the selected Worth month: bumps
    /// `netWorthRevision` (the `worthCache` key) before the write.
    func mutateNetWorth(_ sections: [String], _ body: (inout FinancialData) -> Bool) async -> Bool {
        await mutate(sections, body, after: { netWorthRevision &+= 1 })
    }

    // MARK: - Onboarding

    /// The tour was completed or skipped: Flutter's `setBool(onboarding_completed,
    /// true)`, then the tabs show and any queued route opens (`canOpenRoutes`).
    func completeOnboarding() {
        OnboardingFlag.markCompleted(preferences)
        showsOnboarding = false
    }

    static let dataLog = Logger(subsystem: AppIdentifiers.bundleID, category: "data")

    // MARK: - Toasts

    func showToast(_ toast: Toast) { self.toast = toast }

    /// Dismisses `id` if it is still the one showing.
    func dismissToast(_ id: UUID) {
        if toast?.id == id { toast = nil }
    }
}
