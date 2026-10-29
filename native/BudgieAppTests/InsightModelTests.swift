import BudgieCore
import Observation
import XCTest

@testable import Runner

/// The Insights wiring in `AppModel`: the two `flutter.local_insights_*`
/// preferences round-trip through a full bootstrap against a scratch
/// Application Support directory and preferences suite, dismiss and snooze
/// hide cards at once and for later launches, data or month changes
/// recompute the cards, a superseded result is dropped, and a refresh (Flow
/// appearing, the scene becoming active) brings back a card whose snooze
/// ended.
@MainActor
final class InsightModelTests: XCTestCase {
    private var directory: URL!
    private var scratchPreferences: ScratchPreferences!
    private var preferences: UserDefaultsPreferences { scratchPreferences.preferences }

    override func setUp() async throws {
        directory = TestDirectory.make("budgie-insights")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchPreferences = ScratchPreferences("insights", onboardingCompleted: true)
    }

    override func tearDown() async throws {
        scratchPreferences.remove()
        try? FileManager.default.removeItem(at: directory)
    }

    private let calendar = DartCalendar(timeZone: .autoupdatingCurrent)

    private func makeModel() -> AppModel { AppModel(applicationSupport: directory, preferences: preferences) }

    /// Noon today: in the current month whatever the clock says.
    private var today: DartDateTime {
        let now = calendar.now()
        return calendar.date(now.year, now.month, now.day, 12)
    }

    private var yearMonth: String {
        let now = calendar.now()
        return "\(now.year)-\(now.month)"
    }

    private func row(
        _ id: String, _ description: String, _ amount: Double, _ category: String, date: DartDateTime? = nil
    ) -> JSONValue {
        .object(TransactionRecord.make(
            id: id, type: .expense, description: description, amount: amount, category: category, date: date ?? today,
            now: calendar.now()).raw)
    }

    /// Two identical coffees today (a `duplicate:` card, warning) and 150 of
    /// a 100 Groceries budget (a `budget-pace:` card, urgent), whatever the
    /// day of the month. Optionally: a pair of identical rows in the
    /// previous month (its own `duplicate:` card), `filler` rows in 2020
    /// that give no card but make every computation slow, and goals.
    private func seed(
        duplicates: Int = 2, previousMonthDuplicates: Bool = false, filler: Int = 0, goals: [JSONValue] = []
    ) async throws {
        let storeDirectory = directory.appendingPathComponent(StoreFile.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = FinancialStore(
            fileSystem: DirectoryFileSystem(directory: storeDirectory), preferences: preferences, protectedData: AlwaysAvailable())
        var rows = (0..<duplicates).map { row("c\($0)", "Corner Cafe", 4.5, "Eating Out") }
        rows.append(row("g", "Market", 150, "Groceries"))
        if previousMonthDuplicates {
            rows += (0..<2).map { row("p\($0)", "Old Cafe", 3, "Eating Out", date: previousMonthDay) }
        }
        rows += (0..<filler).map {
            row("f\($0)", "Filler \($0)", Double($0 % 500) + 1, "Filler", date: calendar.date(2020, 1, 1 + $0 % 28, 12))
        }
        _ = try await store.replace(sections: JSONObject(ordered: [
            (Section.transactions, .array(rows)),
            (Section.categoryBudgetLimits, .object(JSONObject(ordered: [("Groceries", .double(100))]))),
            (Section.savingsGoals, .array(goals)),
        ]))
    }

    /// The 10th of the previous month, noon.
    private var previousMonthDay: DartDateTime { calendar.date(today.year, today.month - 1, 10, 12) }

    private var previousDuplicateID: String {
        let day = previousMonthDay
        return "duplicate:expense:old-cafe:3.00:\(calendar.date(day.year, day.month, day.day).toIso8601String())"
    }

    private var paceID: String { "budget-pace:groceries:\(yearMonth)" }

    private var duplicateID: String {
        "duplicate:expense:corner-cafe:4.50:\(calendar.date(today.year, today.month, today.day).toIso8601String())"
    }

    /// Waits for an asynchronous recomputation.
    private func waitUntil(
        _ condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out: \(message)", file: file, line: line)
    }

    func testTheFirstCardsAreReadyWithTheData() async throws {
        try await seed()
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.insights.map(\.id), [paceID, duplicateID], "urgent first, then warning")
        XCTAssertEqual(model.insights.first?.headline, "Groceries is ahead of budget pace")
        XCTAssertEqual(model.insights.last?.explanation, "Corner Cafe appears more than once with the same amount and date.")
    }

    /// Dismiss: the card goes at once, the sorted list is written as a
    /// string list (never the store), and later launches keep it hidden.
    func testDismissHidesTheCardForGood() async throws {
        try await seed()
        let model = makeModel()
        await model.start()
        let revision = try await storeRevision()

        model.dismissInsight(id: duplicateID)
        XCTAssertEqual(model.insights.map(\.id), [paceID], "hidden before the recomputation lands")
        XCTAssertEqual(preferences.value(forKey: PreferenceKey.localInsightsDismissed), .stringList([duplicateID]))
        XCTAssertNil(preferences.value(forKey: PreferenceKey.localInsightsSnoozed), "a dismiss leaves the snoozes alone")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.insights.map(\.id), [paceID])
        let after = try await storeRevision()
        XCTAssertEqual(after, revision, "preferences only, no store write")

        let relaunched = makeModel()
        await relaunched.start()
        XCTAssertEqual(relaunched.insights.map(\.id), [paceID])
        XCTAssertEqual(relaunched.insightPreferences.dismissed, [duplicateID])
    }

    /// Snooze: hidden now and after a relaunch, written as Dart's
    /// `jsonEncode` of id -> local ISO time 30 x 24h ahead; it shows again
    /// once that time is no longer after `now`.
    func testSnoozeHidesForThirtyDays() async throws {
        try await seed()
        let model = makeModel()
        await model.start()
        let before = calendar.now()
        model.snoozeInsight(id: paceID)
        let after = calendar.now()
        XCTAssertEqual(model.insights.map(\.id), [duplicateID])
        XCTAssertNil(preferences.value(forKey: PreferenceKey.localInsightsDismissed))

        guard case .string(let json)? = preferences.value(forKey: PreferenceKey.localInsightsSnoozed) else {
            return XCTFail("snoozed preference is not a string")
        }
        let loaded = InsightPreferences.load(from: preferences, timeZone: calendar.timeZone)
        let until = try XCTUnwrap(loaded.snoozed.first?.until)
        XCTAssertEqual(loaded.snoozed.map(\.id), [paceID])
        XCTAssertEqual(json, "{\"\(paceID)\":\"\(until.toIso8601String())\"}")
        XCTAssertTrue(!until.isBefore(before.adding(days: 30)) && !until.isAfter(after.adding(days: 30)))
        XCTAssertTrue(loaded.excludedIDs(now: until.adding(days: -1)).contains(paceID))
        XCTAssertFalse(loaded.excludedIDs(now: until).contains(paceID), "back once the time is not after now")

        let relaunched = makeModel()
        await relaunched.start()
        XCTAssertEqual(relaunched.insights.map(\.id), [duplicateID])
    }

    /// A snooze stored by either app whose time has passed no longer hides
    /// its card; one still running does.
    func testAnEndedSnoozeShowsTheCardAgain() async throws {
        try await seed()
        let now = calendar.now()
        preferences.set(
            .string("{\"\(paceID)\":\"\(now.adding(days: -1).toIso8601String())\",\"\(duplicateID)\":\"\(now.adding(days: 29).toIso8601String())\"}"),
            forKey: PreferenceKey.localInsightsSnoozed)
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.insights.map(\.id), [paceID])
    }

    /// Three identical rows give two cards with one id (Flutter shows both);
    /// one dismissal hides both.
    func testRepeatedIDsShowTwiceAndGoTogether() async throws {
        try await seed(duplicates: 3)
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.insights.map(\.id), [paceID, duplicateID, duplicateID])
        model.dismissInsight(id: duplicateID)
        XCTAssertEqual(model.insights.map(\.id), [paceID])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.insights.map(\.id), [paceID])
    }

    /// Adding rows, a budget and moving the selected month recompute the
    /// cards; a dismissed card is replaced by the next candidate.
    func testDataAndMonthChangesRecompute() async throws {
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.insights, [])

        for _ in 0..<2 {
            await model.addTransaction(type: .expense, description: "Corner Cafe", amount: 4.5, category: "Eating Out", date: today)
        }
        try await waitUntil({ model.insights.map(\.id) == [duplicateID] }, "the duplicate card after two adds")

        await model.addTransaction(type: .expense, description: "Market", amount: 150, category: "Groceries", date: today)
        await model.setBudgetLimit(category: "Groceries", limit: 100)
        try await waitUntil({ model.insights.map(\.id) == [paceID, duplicateID] }, "the pace card after the budget")

        let current = model.selectedMonth
        model.selectMonth(calendar.date(current.year, current.month - 1))
        try await waitUntil({ model.insights.isEmpty }, "nothing for the previous month")
        model.selectMonth(current)
        try await waitUntil({ model.insights.map(\.id) == [paceID, duplicateID] }, "back on the current month")

        model.dismissInsight(id: paceID)
        XCTAssertEqual(model.insights.map(\.id), [duplicateID])
    }

    /// Every value `insights` takes from now on (read just after each change).
    private final class Recorder: @unchecked Sendable {
        var values: [[String]] = []
    }

    private static func record(_ model: AppModel, into recorder: Recorder) {
        withObservationTracking {
            _ = model.insights
        } onChange: {
            Task { @MainActor in
                recorder.values.append(model.insights.map(\.id))
                InsightModelTests.record(model, into: recorder)
            }
        }
    }

    /// A computation still running when a newer refresh starts is thrown
    /// away when it lands. The filler rows make each computation take far
    /// longer than the 20ms the first one gets to start: it computes the
    /// previous month (its own duplicate card) while the month goes back
    /// and a dismissal follows. Without the generation check that card
    /// would show until the newest result replaced it.
    func testAResultForSupersededInputsIsDropped() async throws {
        try await seed(previousMonthDuplicates: true, filler: 20_000)
        let model = makeModel()
        let clock = ContinuousClock()
        let launch = await clock.measure { await model.start() }
        XCTAssertEqual(model.insights.map(\.id), [paceID, duplicateID])
        let recorder = Recorder()
        Self.record(model, into: recorder)

        let current = model.selectedMonth
        model.selectMonth(calendar.date(current.year, current.month - 1))
        try await Task.sleep(for: .milliseconds(20))
        model.selectMonth(current)
        model.dismissInsight(id: duplicateID)
        XCTAssertEqual(model.insights.map(\.id), [paceID], "hidden at once")

        // Long enough for both computations (each is a small part of the
        // launch, which also reads and parses the store).
        try await Task.sleep(for: max(launch, .seconds(1)))
        XCTAssertEqual(model.insights.map(\.id), [paceID])
        XCTAssertFalse(recorder.values.contains([previousDuplicateID]), "stale result shown: \(recorder.values)")
        XCTAssertEqual(recorder.values, [[paceID]], "only the dismissal changed the cards")
    }

    /// A goal-only change and a budget removal recompute the cards.
    func testGoalAndBudgetRemovalRecompute() async throws {
        let goal = SavingsGoalRecord.make(
            id: "trip", name: "Trip", targetAmount: 1000, targetDate: today.adding(days: 60), now: today.adding(days: -60))
        try await seed(goals: [.object(goal.raw)])
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.insights.map(\.id), [paceID, duplicateID, "goal-behind:trip"])

        let outcome = await model.allocateToSavingsGoal(id: "trip", amount: 600)
        XCTAssertEqual(outcome, .saved)
        try await waitUntil({ model.insights.map(\.id) == [paceID, duplicateID] }, "the goal card gone once on pace")

        await model.removeBudgetLimit(category: "Groceries")
        try await waitUntil({ model.insights.map(\.id) == [duplicateID] }, "the pace card gone with its budget")
    }

    /// A snooze that ends while the app runs: nothing changes on its own,
    /// the next refresh (Flow appearing, the scene becoming active) brings
    /// the card back.
    func testASnoozeEndingWhileAwayShowsOnTheNextRefresh() async throws {
        try await seed()
        let until = calendar.now().adding(microseconds: 1_500_000)
        preferences.set(.string("{\"\(paceID)\":\"\(until.toIso8601String())\"}"), forKey: PreferenceKey.localInsightsSnoozed)
        let model = makeModel()
        await model.start()
        XCTAssertEqual(model.insights.map(\.id), [duplicateID])

        while !calendar.now().isAfter(until) { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.insights.map(\.id), [duplicateID], "no refresh without a trigger")
        model.refreshInsights()
        try await waitUntil({ model.insights.map(\.id) == [paceID, duplicateID] }, "the card back after the refresh")
    }

    private func storeRevision() async throws -> Int64 {
        let storeDirectory = directory.appendingPathComponent(StoreFile.directoryName, isDirectory: true)
        let store = FinancialStore(
            fileSystem: DirectoryFileSystem(directory: storeDirectory), preferences: preferences, protectedData: AlwaysAvailable())
        return try await store.read().revision
    }
}
