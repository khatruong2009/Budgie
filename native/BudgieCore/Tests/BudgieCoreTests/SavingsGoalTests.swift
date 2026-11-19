import Foundation
import Testing

@testable import BudgieCore

/// Port of the goal test in budget_app/test/transaction_model_budget_reports_test.dart
/// ("savings goals persist and track allocation progress"), plus the
/// Swift-only persistence rules (raw patching, unreadable rows, non-finite
/// input) and status edge cases. The clock is pinned to 2026-03-10 09:15
/// New York (Dart's test uses the real clock).
@Suite("Savings goals (transaction_model_budget_reports_test.dart and more)")
struct SavingsGoalTests {
    let calendar = DartCalendar(timeZone: newYorkZone)
    var now: DartDateTime { calendar.date(2026, 3, 10, 9, 15) }

    func load(_ goals: String? = nil) -> FinancialData {
        var sections = JSONObject()
        if let goals { sections[Section.savingsGoals] = try! JSONParser.parse(goals) }
        return loadFinancialData(sections, calendar: calendar, now: now, newID: { "new-id" }).data
    }

    func reload(_ data: FinancialData) -> FinancialData {
        load(DartJSON.encodeString(data.savingsGoalsSection()))
    }

    func section(_ data: FinancialData) -> String { DartJSON.encodeString(data.savingsGoalsSection()) }

    // MARK: - Dart test

    @Test("savings goals persist and track allocation progress")
    func persistAndTrack() {
        var data = load()
        data.addSavingsGoal(name: "Vacation", targetAmount: 5000, targetDate: calendar.date(2026, 12, 1), id: "g1", now: now)
        let goal = data.savingsGoals.first!
        let r1 = data.allocateToSavingsGoal(id: goal.id, amount: 1250, now: now)
        #expect(r1)
        #expect(data.savingsGoals.first!.currentAmount == 1250)
        #expect(data.savingsGoals.first!.progress == 0.25)
        #expect(!data.savingsGoals.first!.isCompleted)

        let r2 = data.allocateToSavingsGoal(id: goal.id, amount: 3750, now: now)
        #expect(r2)
        #expect(data.savingsGoals.first!.isCompleted)
        #expect(data.savingsGoals.first!.completedAt != nil)

        let restored = reload(data)
        #expect(restored.savingsGoals.count == 1)
        #expect(restored.savingsGoals.first!.name == "Vacation")
        #expect(restored.savingsGoals.first!.currentAmount == 5000)
        #expect(restored.savingsGoals.first!.isCompleted)
    }

    // MARK: - Finish goal

    /// `target - current` can fall one ulp short once added back:
    /// 14133.23 + (60422.9 - 14133.23) is 60422.899999999994. "Finish goal"
    /// submits `finishAmount`, which completes the goal in the model too.
    @Test("Finish goal's amount completes the goal even where target - current rounds short")
    func finishAmount() {
        var data = load(#"[{"id":"g","name":"Car","targetAmount":60422.9,"currentAmount":14133.23,"targetDate":"2027-01-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null}]"#)
        let goal = data.savingsGoals[0]
        #expect(goal.currentAmount + goal.remainingAmount < goal.targetAmount, "the rounding case itself")
        let finish = goal.finishAmount
        #expect(finish >= goal.remainingAmount)
        #expect(finish == goal.remainingAmount.nextUp)
        #expect(goal.willComplete(allocating: finish))
        let allocated = data.allocateToSavingsGoal(id: "g", amount: finish, now: now)
        #expect(allocated)
        #expect(data.savingsGoals[0].isCompleted)
        #expect(data.savingsGoals[0].completedAt == now)

        // Where the remainder adds back exactly it is the remainder itself.
        let exact = load(#"[{"id":"e","name":"Trip","targetAmount":1000.0,"currentAmount":250.0,"targetDate":"2027-01-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null}]"#)
        #expect(exact.savingsGoals[0].finishAmount == 750)
        // Nothing remains: 0 (the chip is hidden).
        let done = load(#"[{"id":"d","name":"Done","targetAmount":100.0,"currentAmount":120.0,"targetDate":"2027-01-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null}]"#)
        #expect(done.savingsGoals[0].finishAmount == 0)
    }

    // MARK: - New rows

    @Test("a new goal: Dart toJson key order, double lexemes, midnight target, Flutter id format")
    func make() {
        var data = load()
        let id = SavingsGoalRecord.makeID(now: now, counter: 37)
        #expect(id == "savings_goal_\(String(now.microsecondsSinceEpoch, radix: 36))_11")
        #expect(SavingsGoalRecord.makeID(now: DartDateTime(microsecondsSinceEpoch: 0, timeZone: calendar.timeZone), counter: 0)
            == "savings_goal_0_0")
        let added = data.addSavingsGoal(
            name: " Trip \u{FEFF}", targetAmount: 1200, targetDate: calendar.date(2026, 12, 1, 18, 30, 5), id: id, now: now)
        #expect(added?.name == "Trip")
        #expect(section(data) == """
            [{"id":"\(id)","name":"Trip","targetAmount":1200.0,"currentAmount":0.0,\
            "targetDate":"2026-12-01T00:00:00.000","createdAt":"2026-03-10T09:15:00.000","completedAt":null}]
            """)
    }

    @Test("add guards: blank name (Dart trim, U+FEFF included), target <= 0, non-finite target")
    func addGuards() {
        var data = load()
        for (name, target) in [("  ", 10.0), ("\u{FEFF}", 10), ("A", 0), ("A", -1), ("A", .nan), ("A", .infinity)] {
            let r3 = data.addSavingsGoal(name: name, targetAmount: target, targetDate: now, id: "x", now: now)
            #expect(r3 == nil)
        }
        #expect(data.goalRows.isEmpty)
    }

    // MARK: - Patching

    @Test("edits patch only what changed; unknown keys, id, createdAt and key order survive")
    func unknownKeysSurvive() {
        var data = load(#"[{"extra":[1,2.50],"id":"g","name":"Trip","targetAmount":1200.00,"currentAmount":0.0,"targetDate":"2026-12-01","createdAt":"2026-01-05T10:00:00Z","completedAt":null,"z":true}]"#)
        let r4 = data.allocateToSavingsGoal(id: "g", amount: 100, now: now)
        #expect(r4)
        // The date-only target and the UTC createdAt parse to the stored
        // values, so their lexemes stay; 1200.00 is already that double.
        #expect(section(data) == #"[{"extra":[1,2.50],"id":"g","name":"Trip","targetAmount":1200.00,"currentAmount":100.0,"targetDate":"2026-12-01","createdAt":"2026-01-05T10:00:00Z","completedAt":null,"z":true}]"#)

        let target = calendar.date(2027, 1, 2, 9, 30)
        let r5 = data.updateSavingsGoal(id: "g", .init(name: " Trip 2 ", targetAmount: 1200, currentAmount: 1200, targetDate: target), now: now)
        #expect(r5)
        // The edited date is kept with its time (Dart does not normalise on update).
        #expect(section(data) == #"[{"extra":[1,2.50],"id":"g","name":"Trip 2","targetAmount":1200.00,"currentAmount":1200.0,"targetDate":"2027-01-02T09:30:00.000","createdAt":"2026-01-05T10:00:00Z","completedAt":"2026-03-10T09:15:00.000","z":true}]"#)
    }

    @Test("an edited row is written with Dart's types: int and string amounts, fallback dates, missing completedAt")
    func dartTypesOnEdit() {
        var data = load(#"[{"id":"g","name":"  ","targetAmount":1200,"currentAmount":"25.5","targetDate":"garbage"}]"#)
        let goal = data.savingsGoals[0]
        #expect(goal.name == "Savings Goal" && goal.currentAmount == 25.5)
        #expect(goal.targetDate == now && goal.createdAt == now)
        let r6 = data.allocateToSavingsGoal(id: "g", amount: 1, now: now)
        #expect(r6)
        #expect(section(data) == #"[{"id":"g","name":"Savings Goal","targetAmount":1200.0,"currentAmount":26.5,"targetDate":"2026-03-10T09:15:00.000","createdAt":"2026-03-10T09:15:00.000","completedAt":null}]"#)
    }

    @Test("unreadable rows are kept verbatim through every mutation, and hidden")
    func unreadableRows() {
        var data = load(#"[7,{"id":1,"name":"Bad id"},{"id":"g","name":"Ok","targetAmount":10.0,"currentAmount":0.0,"targetDate":"2026-12-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null},{"id":"h","name":["x"]}]"#)
        #expect(data.savingsGoals.map(\.id) == ["g"])
        data.allocateToSavingsGoal(id: "g", amount: 5, now: now)
        data.addSavingsGoal(name: "New", targetAmount: 3, targetDate: calendar.date(2026, 5, 1), id: "n", now: now)
        data.deleteSavingsGoal(id: "g")
        #expect(section(data) == #"[7,{"id":1,"name":"Bad id"},{"id":"h","name":["x"]},{"id":"n","name":"New","targetAmount":3.0,"currentAmount":0.0,"targetDate":"2026-05-01T00:00:00.000","createdAt":"2026-03-10T09:15:00.000","completedAt":null}]"#)
        let r7 = data.deleteSavingsGoal(id: "1")
        #expect(!r7)
    }

    @Test("duplicate ids: allocate and delete touch every copy; update patches each with its own createdAt and stamp")
    func duplicateIDs() {
        let rows = #"[{"id":"d","name":"A","targetAmount":100.0,"currentAmount":10.0,"targetDate":"2026-08-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null},{"id":"d","name":"B","targetAmount":200.0,"currentAmount":200.0,"targetDate":"2026-09-01T00:00:00.000","createdAt":"2026-01-02T00:00:00.000","completedAt":"2026-02-02T00:00:00.000"}]"#
        var data = load(rows)
        let r8 = data.allocateToSavingsGoal(id: "d", amount: 5, now: now)
        #expect(r8)
        #expect(data.savingsGoals.map(\.currentAmount) == [15, 205])
        let r9 = data.updateSavingsGoal(id: "d", .init(name: "C", targetAmount: 50, currentAmount: 60, targetDate: calendar.date(2026, 7, 1)), now: now)
        #expect(r9)
        #expect(data.savingsGoals.map(\.name) == ["C", "C"])
        #expect(data.savingsGoals.map { $0.createdAt.toIso8601String() } == ["2026-01-01T00:00:00.000", "2026-01-02T00:00:00.000"])
        #expect(data.savingsGoals.map { $0.completedAt?.toIso8601String() } == ["2026-03-10T09:15:00.000", "2026-02-02T00:00:00.000"])
        let r10 = data.deleteSavingsGoal(id: "d")
        #expect(r10)
        #expect(data.goalRows.isEmpty)
    }

    // MARK: - Completion stamp

    @Test("completedAt: stamped on reaching the target, kept while complete, cleared below it, re-stamped")
    func completionStamp() {
        var data = load()
        data.addSavingsGoal(name: "G", targetAmount: 100, targetDate: calendar.date(2026, 12, 1), id: "g", now: now)
        let later = calendar.date(2026, 3, 11), latest = calendar.date(2026, 3, 12)
        #expect(data.savingsGoals[0].willComplete(allocating: 100))
        data.allocateToSavingsGoal(id: "g", amount: 100, now: now)
        #expect(data.savingsGoals[0].completedAt == now)
        #expect(!data.savingsGoals[0].willComplete(allocating: 100))
        data.allocateToSavingsGoal(id: "g", amount: 50, now: later)
        #expect(data.savingsGoals[0].completedAt == now && data.savingsGoals[0].currentAmount == 150)
        // A withdrawal (negative allocation) below the target clears it; the
        // amount floors at 0.
        data.allocateToSavingsGoal(id: "g", amount: -120, now: later)
        #expect(data.savingsGoals[0].completedAt == nil)
        data.allocateToSavingsGoal(id: "g", amount: -1000, now: later)
        #expect(data.savingsGoals[0].currentAmount == 0)
        data.updateSavingsGoal(id: "g", .init(name: "G", targetAmount: 100, currentAmount: 100, targetDate: data.savingsGoals[0].targetDate), now: latest)
        #expect(data.savingsGoals[0].completedAt == latest)
        // -0.0 clamps to 0.0 (Dart `clamp` orders -0.0 below 0.0).
        data.updateSavingsGoal(id: "g", .init(name: "G", targetAmount: 100, currentAmount: -0.0, targetDate: data.savingsGoals[0].targetDate), now: latest)
        #expect(data.savingsGoals[0].currentAmount.sign == .plus && data.savingsGoals[0].completedAt == nil)
        #expect(section(data).contains(#""currentAmount":0.0,"#))
    }

    @Test("a zero target is stamped by an allocation but never completed (as Dart)")
    func zeroTarget() {
        var data = load(#"[{"id":"z","name":"Z","targetAmount":-10,"currentAmount":0.0,"targetDate":"2026-12-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null}]"#)
        data.allocateToSavingsGoal(id: "z", amount: 5, now: now)
        let goal = data.savingsGoals[0]
        #expect(goal.targetAmount == 0 && !goal.isCompleted && goal.completedAt == now && goal.progress == 0)
        #expect(section(data).contains(#""targetAmount":0.0,"#))
    }

    // MARK: - Non-finite input (D6)

    @Test("non-finite amounts are refused before memory changes")
    func nonFinite() {
        let rows = #"[{"id":"g","name":"G","targetAmount":100.0,"currentAmount":0.0,"targetDate":"2026-12-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null},{"id":"n","name":"N","targetAmount":100.0,"currentAmount":"NaN","targetDate":"2026-12-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null},{"id":"i","name":"I","targetAmount":"Infinity","currentAmount":1.0,"targetDate":"2026-12-01T00:00:00.000","createdAt":"2026-01-01T00:00:00.000","completedAt":null}]"#
        var data = load(rows)
        let before = section(data)
        let date = calendar.date(2026, 12, 1)
        let r11 = data.allocateToSavingsGoal(id: "g", amount: .nan, now: now)
        #expect(!r11)
        let r12 = data.allocateToSavingsGoal(id: "g", amount: .infinity, now: now)
        #expect(!r12)
        let r13 = data.updateSavingsGoal(id: "g", .init(name: "G", targetAmount: .infinity, currentAmount: 1, targetDate: date), now: now)
        #expect(!r13)
        let r14 = data.updateSavingsGoal(id: "g", .init(name: "G", targetAmount: 10, currentAmount: .nan, targetDate: date), now: now)
        #expect(!r14)
        // Stored non-finite values (hand-edited strings) cannot be written.
        let r15 = data.allocateToSavingsGoal(id: "n", amount: 5, now: now)
        #expect(!r15)
        let r16 = data.allocateToSavingsGoal(id: "i", amount: 5, now: now)
        #expect(!r16)
        // Overflow of a finite sum.
        let r17 = data.allocateToSavingsGoal(id: "g", amount: 1.7e308, now: now)
        #expect(r17)
        let r18 = data.allocateToSavingsGoal(id: "g", amount: 1.7e308, now: now)
        #expect(!r18)
        #expect(data.savingsGoals[0].currentAmount == 1.7e308)
        #expect(section(data) != before)
        // A NaN progress does not crash the percent (Dart throws there).
        #expect(data.savingsGoals[1].progress.isNaN && data.savingsGoals[1].progressPercent == 0)
        // An edit replaces both amounts, so a stored NaN row can be repaired.
        let r19 = data.updateSavingsGoal(id: "n", .init(name: "N", targetAmount: 100, currentAmount: 5, targetDate: date), now: now)
        #expect(r19)
    }

    // MARK: - Status, sort, summary

    @Test("status: target day behind unless funded; created today for today; overdue; complete; on pace")
    func status() {
        func goal(_ target: Double, _ current: Double, due: DartDateTime, created: DartDateTime) -> SavingsGoalRecord {
            var g = SavingsGoalRecord.make(id: "g", name: "G", targetAmount: target, targetDate: due, now: created)
            g = g.allocating(current, now: created) ?? g
            return g
        }
        let day = calendar.date(2026, 3, 15)
        let onDay = calendar.date(2026, 3, 15, 12)
        #expect(goal(100, 99.99, due: day, created: calendar.date(2026, 3, 1)).status(now: onDay, calendar: calendar) == .behind)
        #expect(!goal(100, 99.99, due: day, created: calendar.date(2026, 3, 1)).isOverdue(now: onDay, calendar: calendar))
        #expect(goal(100, 100, due: day, created: calendar.date(2026, 3, 1)).status(now: onDay, calendar: calendar) == .complete)
        #expect(goal(50, 0, due: day, created: calendar.date(2026, 3, 15, 10)).status(now: onDay, calendar: calendar) == .behind)
        let overdue = goal(100, 90, due: calendar.date(2026, 3, 14), created: calendar.date(2026, 1, 1))
        #expect(overdue.isOverdue(now: onDay, calendar: calendar) && overdue.status(now: onDay, calendar: calendar) == .behind)
        #expect(SavingsGoalText.pace(overdue, now: onDay, calendar: calendar, formatter: MoneyFormatter())
            == "Mar 14 \u{00B7} bump to $10/mo to catch up")
        let half = goal(100, 50, due: calendar.date(2026, 1, 11), created: calendar.date(2026, 1, 1))
        #expect(half.status(now: calendar.date(2026, 1, 6), calendar: calendar) == .onTrack)
        #expect(half.status(now: calendar.date(2026, 1, 6, 0, 0, 0, 1), calendar: calendar) == .behind)
        #expect(SavingsGoalText.pace(half, now: calendar.date(2026, 1, 6), calendar: calendar, formatter: MoneyFormatter())
            == "Jan 11 \u{00B7} $50/mo keeps you on pace")
    }

    @Test("sort: incomplete first, then target date; stable at any length (Dart only up to 32)")
    func sortStable() {
        let due = calendar.date(2026, 6, 1)
        var goals: [SavingsGoalRecord] = []
        for i in 0..<40 {
            var g = SavingsGoalRecord.make(id: "g\(i)", name: "G", targetAmount: 10, targetDate: i % 5 == 0 ? calendar.date(2026, 5, 1) : due, now: now)
            if i % 7 == 0 { g = g.allocating(10, now: now)! }
            goals.append(g)
        }
        let sorted = SavingsGoalRecord.sorted(goals)
        let incomplete = goals.filter { !$0.isCompleted }, complete = goals.filter(\.isCompleted)
        func byDate(_ list: [SavingsGoalRecord]) -> [String] {
            list.filter { $0.targetDate == calendar.date(2026, 5, 1) }.map(\.id) + list.filter { $0.targetDate == due }.map(\.id)
        }
        #expect(sorted.map(\.id) == byDate(incomplete) + byDate(complete))
    }

    @Test("summary: totals include over-funding; ring clamps; empty list")
    func summary() {
        var data = load()
        data.addSavingsGoal(name: "A", targetAmount: 100, targetDate: calendar.date(2026, 6, 1), id: "a", now: now)
        data.addSavingsGoal(name: "B", targetAmount: 300, targetDate: calendar.date(2026, 5, 1), id: "b", now: now)
        data.allocateToSavingsGoal(id: "a", amount: 250, now: now)
        let summary = SavingsGoalsSummary(goals: data.savingsGoals)
        #expect(summary.totalSaved == 250 && summary.totalTarget == 400 && summary.completedCount == 1 && summary.count == 2)
        #expect(summary.progress == 0.625 && SavingsGoalText.summaryPercent(summary) == "63%")
        #expect(SavingsGoalText.summaryCaption(summary, formatter: MoneyFormatter()) == "of $400 \u{00B7} 1 of 2 complete")
        data.allocateToSavingsGoal(id: "a", amount: 1000, now: now)
        #expect(SavingsGoalsSummary(goals: data.savingsGoals).progress == 1)
        let empty = SavingsGoalsSummary(goals: [])
        #expect(empty.progress == 0 && empty.percent == 0 && empty.count == 0)
    }
}
