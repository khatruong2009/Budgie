import BudgieCore
import XCTest

@testable import Runner

/// A full `AppModel` bootstrap against a scratch Application Support
/// directory and a scratch preferences suite (never the host app's data).
@MainActor
private final class ScratchApp {
    let directory: URL
    private let scratchPreferences: ScratchPreferences
    var suite: String { scratchPreferences.suite }
    var defaults: UserDefaults { scratchPreferences.defaults }
    var preferences: UserDefaultsPreferences { scratchPreferences.preferences }

    init() throws {
        directory = TestDirectory.make("budgie-model")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchPreferences = ScratchPreferences("model", onboardingCompleted: false)
    }

    func makeModel() -> AppModel { AppModel(applicationSupport: directory, preferences: preferences) }

    var storeDirectory: URL { directory.appendingPathComponent(StoreFile.directoryName, isDirectory: true) }

    func store() -> FinancialStore {
        scratchStore(storeDirectory: storeDirectory, preferences: preferences)
    }

    /// Writes `sections` as an existing store (before the model starts).
    func seed(_ sections: JSONObject) async throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        _ = try await store().replace(sections: sections)
    }

    /// What is on disk now, read by a fresh store.
    func stored() async throws -> FinancialSnapshot { try await scratchStored(storeDirectory: storeDirectory, preferences: preferences) }

    func remove() {
        scratchPreferences.remove()
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class OnboardingModelTests: XCTestCase {
    private var scratch: ScratchApp!

    override func setUp() async throws {
        scratch = try ScratchApp()
    }

    override func tearDown() async throws {
        unsetenv("BUDGIE_SKIP_ONBOARDING")
        scratch.remove()
    }

    /// A first launch shows the tour and holds routes; completing it writes
    /// Flutter's CFBoolean, opens the queued route, and later launches skip
    /// the tour.
    func testTourShowsUntilCompletedThenNeverAgain() async throws {
        let model = scratch.makeModel()
        XCTAssertFalse(model.showsOnboarding, "nothing is read before the bootstrap")
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.showsOnboarding)
        XCTAssertFalse(model.canOpenRoutes)
        model.open(URL(string: "budgetapp://add-income")!)
        XCTAssertNil(model.takePendingAdd(), "a route waits for the tour")
        XCTAssertEqual(model.pendingAdd, .income)

        model.completeOnboarding()
        XCTAssertFalse(model.showsOnboarding)
        XCTAssertTrue(model.canOpenRoutes)
        XCTAssertEqual(model.takePendingAdd(), .income)
        let raw = try XCTUnwrap(scratch.defaults.persistentDomain(forName: scratch.suite)?[PreferenceKey.onboardingCompleted] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(raw), CFBooleanGetTypeID())
        XCTAssertTrue(raw.boolValue)

        let relaunched = scratch.makeModel()
        await relaunched.start()
        XCTAssertEqual(relaunched.phase, .ready)
        XCTAssertFalse(relaunched.showsOnboarding)
        XCTAssertTrue(relaunched.canOpenRoutes)
    }

    /// Flutter's `getBool` throws on another type and its gate shows the
    /// tour; so does a stored false.
    func testWrongTypeOrFalseShowsTheTour() async {
        for value: PreferenceValue in [.string("true"), .int(1), .bool(false)] {
            scratch.preferences.set(value, forKey: PreferenceKey.onboardingCompleted)
            let model = scratch.makeModel()
            await model.start()
            XCTAssertTrue(model.showsOnboarding, "\(value)")
            scratch.preferences.set(nil, forKey: PreferenceKey.onboardingCompleted)
        }
    }

    /// The UI-test hook: "1" writes the flag before it is read, "0" removes it.
    func testSkipHook() async {
        setenv("BUDGIE_SKIP_ONBOARDING", "1", 1)
        let skipped = scratch.makeModel()
        await skipped.start()
        XCTAssertFalse(skipped.showsOnboarding)
        XCTAssertEqual(scratch.preferences.value(forKey: PreferenceKey.onboardingCompleted), .bool(true))

        setenv("BUDGIE_SKIP_ONBOARDING", "0", 1)
        let reset = scratch.makeModel()
        await reset.start()
        XCTAssertTrue(reset.showsOnboarding)
        XCTAssertNil(scratch.preferences.value(forKey: PreferenceKey.onboardingCompleted))
    }
}

@MainActor
final class RecurringModelTests: XCTestCase {
    private var scratch: ScratchApp!

    override func setUp() async throws {
        scratch = try ScratchApp()
        // Past the tour, like every other launch in these tests.
        OnboardingFlag.markCompleted(scratch.preferences)
    }

    override func tearDown() async throws {
        scratch.remove()
    }

    private var calendar: DartCalendar { DartCalendar(timeZone: .autoupdatingCurrent) }

    func testToastCopy() {
        XCTAssertEqual(Toast.dueGenerated.message, "Due transactions generated and next occurrences updated")
        XCTAssertEqual(Toast.dueGenerated.style, .success)
        XCTAssertEqual(Toast.recurringDeleted.message, "Recurring transaction deleted")
        XCTAssertEqual(Toast.recurringDeleted.style, .success)
        XCTAssertNotEqual(Toast.dueGenerated.id, Toast.dueGenerated.id)
        XCTAssertEqual(AppModel.DueGeneration(generated: 0, saved: true).toast.message, Toast.dueGenerated.message)
        XCTAssertEqual(AppModel.DueGeneration(generated: 3, saved: false).toast.message, Toast.saveFailed.message)
    }

    /// Before the store is loaded there is nothing to generate or read.
    func testBeforeLoad() async {
        let model = AppModel()
        let result = await model.generateDueNow()
        XCTAssertEqual(result, AppModel.DueGeneration(generated: 0, saved: true))
        XCTAssertNil(model.lastGeneratedDate(forTemplate: "t"))
    }

    /// A weekly template the launch skipped while paused, two weeks behind
    /// (its cursor is its start, today's time of day 14 days ago).
    private func seedPausedWeekly() async throws -> DartDateTime {
        let start = calendar.now().adding(days: -14)
        let template = RecurringTemplate.make(
            id: "tpl", type: .expense, description: "Gym", amount: 12.5, category: "Health", pattern: .weekly,
            startDate: start, dayOfMonth: nil, dayOfWeek: start.weekday, isActive: false)
        try await scratch.seed(JSONObject(ordered: [(Section.recurringTransactions, .array([.object(template.raw)]))]))
        return start
    }

    /// Resume skips the two occurrences missed while paused (the cursor is
    /// saved at today's); "Generate Due Transactions" then writes today's
    /// row and the advanced cursor in the one call; a second call finds
    /// nothing due and writes nothing.
    func testResumeSkipsPausedOccurrencesThenGenerateDueWritesToday() async throws {
        let start = try await seedPausedWeekly()
        let today = start.adding(days: 14)

        let model = scratch.makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.data?.transactions.count, 0, "the launch skips a paused template")
        XCTAssertNil(model.lastGeneratedDate(forTemplate: "tpl"))
        let resumed = await model.setTemplateActive(id: "tpl", true)
        XCTAssertTrue(resumed)
        XCTAssertEqual(model.data?.templates.first?.nextOccurrence, today, "the cursor skips to today's occurrence")
        let afterResume = try await scratch.stored()
        let resumedTemplate = afterResume.sections[Section.recurringTransactions]?.arrayValue?.first?.objectValue
        XCTAssertEqual(resumedTemplate?["nextOccurrence"]?.stringValue, today.toIso8601String())
        XCTAssertEqual(resumedTemplate?["isActive"]?.boolValue, true)

        let result = await model.generateDueNow()
        XCTAssertEqual(result, AppModel.DueGeneration(generated: 1, saved: true))
        XCTAssertEqual(model.data?.transactions.map(\.date), [today])
        XCTAssertEqual(model.data?.templates.first?.nextOccurrence, start.adding(days: 21))
        XCTAssertEqual(model.lastGeneratedDate(forTemplate: "tpl"), today)
        XCTAssertFalse(model.hasUnsavedChanges)

        let disk = try await scratch.stored()
        let rows = disk.sections[Section.transactions]?.arrayValue ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows.allSatisfy { $0.objectValue?["recurringTemplateId"]?.stringValue == "tpl" })
        let storedTemplate = disk.sections[Section.recurringTransactions]?.arrayValue?.first?.objectValue
        XCTAssertEqual(storedTemplate?["nextOccurrence"]?.stringValue, start.adding(days: 21).toIso8601String())

        let again = await model.generateDueNow()
        XCTAssertEqual(again, AppModel.DueGeneration(generated: 0, saved: true))
        let unchanged = try await scratch.stored()
        XCTAssertEqual(unchanged.revision, disk.revision, "nothing due, nothing written")
    }

    /// A failed write stays unsaved: a later "Generate Due Transactions"
    /// with nothing due retries it and reports success only once it is on
    /// disk (it used to show the success toast under the unsaved banner).
    func testGenerateDueWithNothingDueRetriesAnUnsavedWrite() async throws {
        _ = try await seedPausedWeekly()
        let model = scratch.makeModel()
        await model.start()
        let resumed = await model.setTemplateActive(id: "tpl", true)
        XCTAssertTrue(resumed)

        // The store directory refuses new files: every write fails.
        let directory = scratch.storeDirectory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        var restored = false
        defer { if !restored { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory) } }

        let failed = await model.generateDueNow()
        XCTAssertEqual(failed, AppModel.DueGeneration(generated: 1, saved: false))
        XCTAssertEqual(failed.toast.message, Toast.saveFailed.message)
        XCTAssertTrue(model.hasUnsavedChanges)

        let stillFailing = await model.generateDueNow()
        XCTAssertEqual(stillFailing, AppModel.DueGeneration(generated: 0, saved: false), "nothing due, the retry failed too")
        XCTAssertEqual(stillFailing.toast.message, Toast.saveFailed.message)
        XCTAssertTrue(model.hasUnsavedChanges)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        restored = true
        let healed = await model.generateDueNow()
        XCTAssertEqual(healed, AppModel.DueGeneration(generated: 0, saved: true))
        XCTAssertEqual(healed.toast.message, Toast.dueGenerated.message)
        XCTAssertFalse(model.hasUnsavedChanges)
        let disk = try await scratch.stored()
        XCTAssertEqual(disk.sections[Section.transactions]?.arrayValue?.count, 1, "the retried row is on disk")
    }

    /// A scratch model never writes the installed app's widget values.
    func testScratchModelLeavesTheWidgetValuesAlone() async throws {
        // The host app's own model writes the real values as it starts;
        // wait for it, so only the scratch model could touch them below.
        for _ in 0..<100 where AppDelegate.model.phase != .ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        let group = try XCTUnwrap(UserDefaults(suiteName: "group.com.khatruong.budgetbuddy"))
        let keys = ["cashFlow", "cashFlowMonth", "budgieHideBalances"]
        let original = keys.map { group.object(forKey: $0) }
        defer { for (key, value) in zip(keys, original) { group.set(value, forKey: key) } }
        group.set(-12_345.5, forKey: "cashFlow")
        group.set("sentinel", forKey: "cashFlowMonth")
        group.set("sentinel", forKey: "budgieHideBalances")

        let model = scratch.makeModel()
        await model.start()
        let added = await model.addTransaction(
            type: .income, description: "Pay", amount: 100, category: "Salary", date: model.now)
        XCTAssertTrue(added)
        XCTAssertEqual(group.double(forKey: "cashFlow"), -12_345.5)
        XCTAssertEqual(group.string(forKey: "cashFlowMonth"), "sentinel")
        XCTAssertEqual(group.string(forKey: "budgieHideBalances"), "sentinel")
    }

    /// The form's add path: a template whose start is the moment the form
    /// opened logs today's occurrence right away (Flutter runs the
    /// generator after the add).
    func testAddFromNowLogsTodayAndKeepsTheTimeOfDay() async throws {
        let model = scratch.makeModel()
        await model.start()
        let opened = model.now
        let start = RecurringForm.resolvedStart(picked: nil, stored: nil, openedAt: opened, calendar: model.calendar)
        let added = await model.addTemplate(RecurringForm.edit(
            type: .income, description: "Pay", amount: 800, category: "Salary", pattern: .monthly, start: start,
            dayOfMonth: opened.day))
        XCTAssertTrue(added)
        let template = try XCTUnwrap(model.data?.templates.first)
        XCTAssertEqual(template.startDate, opened, "time of day and microseconds kept")
        XCTAssertEqual(template.dayOfMonth, opened.day)
        XCTAssertNil(template.dayOfWeek)
        XCTAssertEqual(model.data?.transactions.map(\.date), [opened])
        XCTAssertEqual(
            template.nextOccurrence,
            RecurringGenerator.nextOccurrence(pattern: .monthly, dayOfMonth: opened.day, after: opened, calendar: model.calendar))
        XCTAssertEqual(model.lastGeneratedDate(forTemplate: template.id), opened)
    }
}
