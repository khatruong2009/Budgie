import Foundation
import Testing

@testable import BudgieCore

private func fixture(_ name: String) throws -> J {
    try Fixtures.json("goals/\(name)")
}

private func bits(_ value: J) -> Double? {
    value.string.flatMap { UInt64($0, radix: 16) }.map { Double(bitPattern: $0) }
}

private func hex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}

private func memoryLine(_ g: SavingsGoalRecord) -> String {
    [g.id, g.name, hex(g.targetAmount), hex(g.currentAmount), g.targetDate.toIso8601String(), g.createdAt.toIso8601String(),
     g.completedAt?.toIso8601String() ?? "null"].joined(separator: "|")
}

private func memoryLine(_ g: J) -> String {
    [g["id"].string!, g["name"].string!, g["targetAmount"].string!, g["currentAmount"].string!, g["targetDate"].string!,
     g["createdAt"].string!, g["completedAt"].string ?? "null"].joined(separator: "|")
}

private func memoryLines(_ data: FinancialData) -> [String] { data.savingsGoals.map(memoryLine) }
private func memoryLines(_ memory: J) -> [String] { memory.array.map(memoryLine) }

private func load(_ sections: JSONObject, calendar: DartCalendar, now: DartDateTime) -> FinancialData {
    FinancialData.load(
        FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences([:]), calendar: calendar,
        now: { now }, newID: { UUID().uuidString.lowercased() }
    ).data
}

/// The formatter configurations the generator used, in its order.
private let formatters = [
    MoneyFormatter(currencyCode: "USD"),
    MoneyFormatter(currencyCode: "EUR", locale: "de_DE"),
    MoneyFormatter(currencyCode: "USD", hideBalances: true),
]

@Suite("Goals: savings goal mutations, derived values and copy match the Flutter code (Fixtures/goals)")
struct GoalsParityTests {
    /// Real `TransactionModel` calls (edits through the page's edit path)
    /// through a real store, replayed on `FinancialData`: after every call
    /// the two agree on whether a write is due and on the model's memory;
    /// for data Dart wrote itself the stored `savingsGoals` bytes are
    /// identical. Whatever Swift wrote loads back to the same memory. New
    /// ids follow Dart's format and counter.
    @Test("mutation scenarios", arguments: dstFixtureZones)
    func mutations(zone: String) throws {
        let f = try Fixtures.json("\(Fixtures.zonePath("goals", zone))/mutations.json")
        #expect(f["tz"].string == zone)
        let calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
        let scenarios = f["scenarios"].array
        #expect(scenarios.count == 3)
        // Dart's id counter is process-wide: it runs on across scenarios.
        var lastCounter: Int?
        for s in scenarios {
            let label = "\(zone) \(s["name"].string!)"
            let byteComparable = s["byteComparable"].bool!
            var now = try calendar.parse(s["launch"].string!)
            let initial = try s["initial"].string.map { try JSONParser.parse($0).objectValue! } ?? JSONObject()
            var data = load(initial, calendar: calendar, now: now)
            #expect(memoryLines(data) == memoryLines(s["loaded"]), "\(label) load")

            for (index, step) in s["steps"].array.enumerated() {
                let at = "\(label) step \(index) \(step["op"].string!)"
                if step["op"].string == "clock" {
                    now = try calendar.parse(step["now"].string!)
                    continue
                }
                #expect(step["now"].string == now.toIso8601String(), "\(at) clock")
                let swiftWrote: Bool
                switch step["op"].string! {
                case "add":
                    let newID = step["newId"].string
                    let added = data.addSavingsGoal(
                        name: step["name"].string!, targetAmount: bits(step["targetAmount"])!,
                        targetDate: try calendar.parse(step["targetDate"].string!), id: newID ?? "unused", now: now)
                    swiftWrote = added != nil
                    if let newID {
                        let counter = Int(newID.split(separator: "_").last!, radix: 36)!
                        #expect(SavingsGoalRecord.makeID(now: now, counter: counter) == newID, "\(at) id")
                        if let lastCounter { #expect(counter == lastCounter + 1, "\(at) counter") }
                        lastCounter = counter
                    }
                case "edit":
                    swiftWrote = data.updateSavingsGoal(
                        id: step["id"].string!,
                        .init(name: step["name"].string!, targetAmount: bits(step["targetAmount"])!,
                              currentAmount: bits(step["currentAmount"])!, targetDate: try calendar.parse(step["targetDate"].string!)),
                        now: now)
                case "delete":
                    swiftWrote = data.deleteSavingsGoal(id: step["id"].string!)
                case "allocate":
                    let id = step["id"].string!, amount = bits(step["amount"])!
                    #expect(data.savingsGoal(id: id)?.willComplete(allocating: amount) == step["willComplete"].bool, "\(at) willComplete")
                    swiftWrote = data.allocateToSavingsGoal(id: id, amount: amount, now: now)
                default:
                    Issue.record("unknown op in \(at)")
                    continue
                }
                #expect(swiftWrote == step["wrote"].bool, "\(at) wrote")
                #expect(step["hasUnsavedChanges"].bool == false, "\(at) Dart save failed")
                #expect(memoryLines(data) == memoryLines(step["memory"]), "\(at) memory")
                let swiftSection = DartJSON.encodeString(data.savingsGoalsSection())
                if byteComparable {
                    let dartSection = step["section"].string ?? "[]"
                    #expect(Array(swiftSection.utf16) == Array(dartSection.utf16), "\(at) section:\n\(swiftSection)\n\(dartSection)")
                }
                // What Swift would write loads back as the same memory.
                var written = JSONObject()
                written[Section.savingsGoals] = data.savingsGoalsSection()
                #expect(memoryLines(load(written, calendar: calendar, now: now)) == memoryLines(data), "\(at) reload")
            }
        }
    }

    /// Per goal and pinned "now": progress, percent, overdue, status (the
    /// page's `_statusFor`), suggested contribution and pace copy under
    /// three formatter configurations; per goal the completion copy and the
    /// allocation dialog's `willComplete`; the page's sort and summary.
    @Test("derived values", arguments: dstFixtureZones)
    func derived(zone: String) throws {
        let f = try Fixtures.json("\(Fixtures.zonePath("goals", zone))/derived.json")
        #expect(f["tz"].string == zone)
        let calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
        let unused = calendar.date(2020)
        var goals: [SavingsGoalRecord] = []
        for g in f["goals"].array {
            let goal = try #require(SavingsGoalRecord.parse(
                try JSONParser.parse(g["row"].string!), calendar: calendar, now: unused, newID: { "unused" }))
            goals.append(goal)
            let at = "\(zone) \(goal.id)"
            #expect(memoryLine(goal) == memoryLine(g["memory"]), "\(at) memory")
            #expect(hex(goal.progress) == g["progress"].string, "\(at) progress")
            #expect(goal.progressPercent == g["progressPercent"].int, "\(at) percent")
            #expect(SavingsGoalText.percent(goal) == g["percentLabel"].string, "\(at) percent label")
            #expect(hex(goal.remainingAmount) == g["remaining"].string, "\(at) remaining")
            #expect(goal.isCompleted == g["isCompleted"].bool, "\(at) completed")
            #expect(SavingsGoalText.fullyFunded(goal) == g["fullyFunded"].string, "\(at) fully funded")
            for pair in g["willComplete"].array {
                #expect(goal.willComplete(allocating: bits(pair[0])!) == pair[1].bool, "\(at) willComplete \(pair[0].string!)")
            }
            for n in g["atNows"].array {
                let now = try calendar.parse(n["now"].string!)
                let atNow = "\(at) at \(n["now"].string!)"
                #expect(goal.isOverdue(now: now, calendar: calendar) == n["isOverdue"].bool, "\(atNow) overdue")
                #expect(goal.status(now: now, calendar: calendar).rawValue == n["status"].string, "\(atNow) status")
                #expect(hex(goal.suggestedMonthlyContribution(now: now)) == n["suggested"].string, "\(atNow) suggested")
                #expect(formatters.map { SavingsGoalText.pace(goal, now: now, calendar: calendar, formatter: $0) }
                    == n["paces"].array.map { $0.string! }, "\(atNow) pace")
            }
        }

        let lists = f["lists"].array
        #expect(lists.count == 6)
        for list in lists {
            let ids = list["ids"].array.map { $0.string! }
            let members = ids.map { id in goals.first { $0.id == id }! }
            let expected = list["summary"]
            let at = "\(zone) list \(ids.joined(separator: ","))"
            #expect(SavingsGoalRecord.sorted(members).map(\.id) == expected["order"].array.map { $0.string! }, "\(at) order")
            let summary = SavingsGoalsSummary(goals: members)
            #expect(hex(summary.totalSaved) == expected["totalSaved"].string, "\(at) saved")
            #expect(hex(summary.totalTarget) == expected["totalTarget"].string, "\(at) target")
            #expect(summary.completedCount == expected["completedCount"].int, "\(at) completed")
            #expect(summary.count == expected["count"].int, "\(at) count")
            #expect(hex(summary.progress) == expected["progress"].string, "\(at) progress")
            #expect(SavingsGoalText.summaryPercent(summary) == expected["percent"].string, "\(at) percent")
            #expect(formatters.map { SavingsGoalText.summaryCaption(summary, formatter: $0) } == expected["captions"].array.map { $0.string! },
                    "\(at) captions")
        }
    }
}
