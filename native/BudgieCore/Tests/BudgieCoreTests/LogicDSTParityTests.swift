import Foundation
import Testing

@testable import BudgieCore

/// The logic fixtures (logic_fixtures_test.dart) in the zones whose DST
/// change happens at midnight. America/Santiago is in `fixtureZones`, so
/// DomainParityTests runs the generator, safe-to-spend and random files in
/// it; Asia/Beirut is not, so the same three files are checked here with the
/// same assertions. Fixtures/logic/tz/<zone>/generator_dst.json and
/// safe_to_spend_dst.json (templates, rows and clocks on, just before and
/// just after each gap and fold, carrying epoch microseconds because a
/// fold-hour wall time names two instants) are checked in every logic zone.
private func logicFixture(_ zone: String, _ file: String) throws -> J {
    try Fixtures.json(zoneDirectory(zone) + "/" + file)
}

private func instant(_ value: J, _ zone: TimeZone) -> DartDateTime {
    DartDateTime(microsecondsSinceEpoch: Int64(value["us"].int!), timeZone: zone)
}

/// `RecurringGenerator.generateDue` on one generator case. The clock is the
/// exact instant Dart used; dates also compare as epoch microseconds when
/// the case records them.
private func checkGeneratorCases(zone: String, file: String) throws {
    let tz = TimeZone(identifier: zone)!
    let calendar = DartCalendar(timeZone: tz)
    let fixture = try logicFixture(zone, file)
    #expect(fixture["tz"].string == zone)
    #expect(!fixture["cases"].array.isEmpty)
    for c in fixture["cases"].array {
        let template = RecurringTemplate.parse(c["template"].value!, calendar: calendar, newID: { "x" })!
        var data = FinancialData.load(
            FinancialSnapshot(revision: 0, sections: JSONObject(ordered: [(Section.recurringTransactions, .array([.object(template.raw)]))])),
            preferences: InMemoryPreferences(), calendar: calendar, now: { calendar.date(2026, 1, 1, 12) }, newID: { "id" }
        ).data
        let now = instant(c["now"], tz)
        #expect(now.toIso8601String() == c["now"]["iso"].string, "\(zone) now")
        _ = RecurringGenerator.generateDue(in: &data, now: now, clock: { now }, newID: { UUID().uuidString })
        let label = "\(zone) \(c["label"].string!) @ \(c["now"]["iso"].string!) (\(c["now"]["us"].int!))"
        let want = c["generated"].array
        #expect(data.transactions.map { $0.date.toIso8601String() } == want.compactMap { $0["date"].string }, "\(label) dates")
        if want.allSatisfy({ !$0["dateUs"].isNull }) {
            #expect(data.transactions.map { Int($0.date.microsecondsSinceEpoch) } == want.map { $0["dateUs"].int! }, "\(label) date instants")
        }
        #expect(data.transactions.allSatisfy { $0.recurringTemplateId == template.id && $0.amount == 10.0 }, "\(label) rows")
        #expect(data.templates[0].nextOccurrence.toIso8601String() == c["nextOccurrence"].string, "\(label) cursor")
        if !c["nextOccurrenceUs"].isNull {
            #expect(Int(data.templates[0].nextOccurrence.microsecondsSinceEpoch) == c["nextOccurrenceUs"].int!, "\(label) cursor instant")
        }
    }
}

private func checkBreakdown(_ b: SafeToSpendBreakdown, _ w: J, _ label: String, into failures: inout [String]) {
    let pairs: [(String, Double?, Double?)] = [
        ("actualIncome", b.actualIncome, w["actualIncome"].double),
        ("expectedIncome", b.expectedIncome, w["expectedIncome"].double),
        ("actualExpenses", b.actualExpenses, w["actualExpenses"].double),
        ("upcoming", b.upcomingRecurringExpenses, w["upcomingRecurringExpenses"].double),
        ("reserve", b.flexibleBudgetReserve, w["flexibleBudgetReserve"].double),
        ("goals", b.plannedGoalContributions, w["plannedGoalContributions"].double),
        ("safeToSpend", b.safeToSpend, w["safeToSpend"].double),
        ("daily", b.dailyAllowance, w["dailyAllowance"].double),
        ("days", Double(b.daysRemaining), w["daysRemaining"].double),
        ("overCommitment", b.overCommitment, w["overCommitment"].double),
    ]
    for (name, swift, dart) in pairs where swift != dart {
        failures.append("\(label) \(name): swift \(String(describing: swift)) dart \(String(describing: dart))")
    }
    if b.isOverCommitted != w["isOverCommitted"].bool {
        failures.append("\(label) isOverCommitted")
    }
    if b.asOf.toIso8601String() != w["asOf"].string || b.month.toIso8601String() != w["month"].string {
        failures.append("\(label) dates: swift \(b.asOf.toIso8601String()) / \(b.month.toIso8601String()) dart \(w["asOf"].string ?? "") / \(w["month"].string ?? "")")
    }
}

@Suite("Logic in zones with a midnight DST change (Fixtures/logic)")
struct LogicDSTParityTests {
    @Test("Beirut: recurring generator cases", arguments: beirutZones)
    func beirutGenerator(zone: String) throws {
        try checkGeneratorCases(zone: zone, file: "generator.json")
    }

    @Test("Beirut: safe-to-spend cases", arguments: beirutZones)
    func beirutSafeToSpend(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let fixture = try logicFixture(zone, "safe_to_spend.json")
        let transactions = fixture["transactions"].array.map { TransactionRecord.parse($0.value!, calendar: calendar, newID: { "x" })! }
        let templates = fixture["recurring"].array.map { RecurringTemplate.parse($0.value!, calendar: calendar, newID: { "x" })! }
        let limits = fixture["limits"].keys.map { ($0, fixture["limits"][$0].double!) }
        let results = fixture["results"].array
        #expect(results.count == LogicParityTests.asOfInputs.count)
        var failures: [String] = []
        for (index, result) in results.enumerated() {
            let original = LogicParityTests.asOfInputs[index]
            let asOf = try calendar.parse(original)
            let month = try calendar.parse(result["month"].string!)
            let goals = fixture["goals"].array.map { SavingsGoalRecord.parse($0.value!, calendar: calendar, now: asOf, newID: { "g" })! }
            let b = SafeToSpend.calculate(
                transactions: transactions, templates: templates, budgetLimits: limits, savingsGoals: goals,
                month: month, asOf: asOf, wallClock: asOf, calendar: calendar)
            checkBreakdown(b, result, "\(zone) \(original)", into: &failures)
        }
        #expect(failures.isEmpty, "\(failures.prefix(10))")
    }

    @Test("Beirut: 400 random safe-to-spend scenarios", arguments: beirutZones)
    func beirutRandom(zone: String) throws {
        let calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
        let fixture = try logicFixture(zone, "safe_to_spend_random.json")
        let cases = fixture["cases"].array
        #expect(cases.count == 400)
        var failures: [String] = []
        for (index, c) in cases.enumerated() {
            let asOf = try calendar.parse(c["asOf"].string!)
            let month = try calendar.parse(c["month"].string!)
            let transactions = c["transactions"].array.map { TransactionRecord.parse($0.value!, calendar: calendar, newID: { "x" })! }
            let templates = c["recurring"].array.map { RecurringTemplate.parse($0.value!, calendar: calendar, newID: { "x" })! }
            let limits = c["limits"].keys.map { ($0, c["limits"][$0].double!) }
            let goals = c["goals"].array.map { SavingsGoalRecord.parse($0.value!, calendar: calendar, now: asOf, newID: { "g" })! }
            let b = SafeToSpend.calculate(
                transactions: transactions, templates: templates, budgetLimits: limits, savingsGoals: goals,
                month: month, asOf: asOf, wallClock: asOf, calendar: calendar)
            checkBreakdown(b, c["result"], "#\(index)", into: &failures)
        }
        #expect(failures.isEmpty, "\(zone): \(failures.count) mismatches, first: \(failures.prefix(10))")
    }

    @Test("generator: templates stepping across the gap and fold days", arguments: logicZones)
    func generatorDST(zone: String) throws {
        try checkGeneratorCases(zone: zone, file: "generator_dst.json")
    }

    @Test("safe-to-spend: clocks and rows on, before and after each gap and fold", arguments: logicZones)
    func safeToSpendDST(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let fixture = try logicFixture(zone, "safe_to_spend_dst.json")
        #expect(fixture["tz"].string == zone)
        let transactions = fixture["transactions"].array.map { TransactionRecord.parse($0.value!, calendar: calendar, newID: { "x" })! }
        let templates = fixture["recurring"].array.map { RecurringTemplate.parse($0.value!, calendar: calendar, newID: { "x" })! }
        let limits = fixture["limits"].keys.map { ($0, fixture["limits"][$0].double!) }
        var failures: [String] = []
        let results = fixture["results"].array
        #expect(results.count >= 25)
        for result in results {
            let asOf = instant(result["asOf"], tz)
            let month = instant(result["month"], tz)
            let goals = fixture["goals"].array.map { SavingsGoalRecord.parse($0.value!, calendar: calendar, now: asOf, newID: { "g" })! }
            let b = SafeToSpend.calculate(
                transactions: transactions, templates: templates, budgetLimits: limits, savingsGoals: goals,
                month: month, asOf: asOf, wallClock: asOf, calendar: calendar)
            checkBreakdown(b, result["result"], "\(zone) \(result["month"]["iso"].string!) @ \(result["asOf"]["iso"].string!) (\(result["asOf"]["us"].int!))", into: &failures)
        }
        #expect(failures.isEmpty, "\(zone): \(failures.count) mismatches, first: \(failures.prefix(10))")
    }

    @Test("safe-to-spend: random cases on the transition days", arguments: logicZones)
    func randomDST(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let fixture = try logicFixture(zone, "safe_to_spend_dst.json")
        let cases = fixture["randomCases"].array
        #expect(cases.count == 120)
        var failures: [String] = []
        for (index, c) in cases.enumerated() {
            let asOf = instant(c["asOf"], tz)
            let month = instant(c["month"], tz)
            let transactions = c["transactions"].array.map { TransactionRecord.parse($0.value!, calendar: calendar, newID: { "x" })! }
            let templates = c["recurring"].array.map { RecurringTemplate.parse($0.value!, calendar: calendar, newID: { "x" })! }
            let limits = c["limits"].keys.map { ($0, c["limits"][$0].double!) }
            let goals = c["goals"].array.map { SavingsGoalRecord.parse($0.value!, calendar: calendar, now: asOf, newID: { "g" })! }
            let b = SafeToSpend.calculate(
                transactions: transactions, templates: templates, budgetLimits: limits, savingsGoals: goals,
                month: month, asOf: asOf, wallClock: asOf, calendar: calendar)
            checkBreakdown(b, c["result"], "\(zone) #\(index) @ \(c["asOf"]["iso"].string!)", into: &failures)
        }
        #expect(failures.isEmpty, "\(zone): \(failures.count) mismatches, first: \(failures.prefix(10))")
    }
}
