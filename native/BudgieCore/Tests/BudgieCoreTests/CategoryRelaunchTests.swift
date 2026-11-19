import Foundation
import Testing

@testable import BudgieCore

@Suite("Categories: a padded legacy name is defined once, not at every launch")
struct CategoryRelaunchTests {
    /// Flutter's `_containsName` compares the trimmed candidate with the
    /// stored, untrimmed names, so a padded name ("  Padded Cat ") never
    /// matches the definition it created and each launch adds another.
    /// Swift adds the same first definition (the launch parity fixtures) and
    /// then finds it.
    @Test("typical, launched repeatedly with the store kept between launches: 20 categories every time")
    func typicalRelaunches() async throws {
        let scenario = try Scenario(Fixtures.url("store/typical"))
        var counts: [Int] = []
        var sections: [String] = []
        var padded: [Int] = []
        for _ in 0..<5 {
            let launched = try #require(try await launchWithSnapshot(scenario, matchesPaddedCategoryNames: true))
            counts.append(launched.data.categories.count)
            padded.append(launched.data.categories.filter { DartString.trim($0.name) == "Padded Cat" }.count)
            sections.append(DartJSON.encodeString(try #require(launched.snapshot.sections[Section.categories])))
        }
        #expect(counts == [20, 20, 20, 20, 20])
        #expect(padded == [1, 1, 1, 1, 1])
        // Nothing is rewritten after the first launch.
        #expect(Set(sections).count == 1)
    }

    @Test("the first launch writes what Flutter's writes: one new definition, padding kept")
    func firstLaunchAddsOne() async throws {
        let scenario = try Scenario(Fixtures.url("store/typical"))
        let before = try await scenario.makeStore().read()
        let storedCount = before.sections[Section.categories]?.arrayValue?.count ?? 0
        let launched = try #require(try await launchWithSnapshot(scenario, matchesPaddedCategoryNames: true))
        let added = launched.data.categories.dropFirst(storedCount)
        #expect(added.count == 1)
        #expect(added.first?.name == "  Padded Cat ")
        #expect(added.first?.type == .expense)
        #expect(added.first?.isBuiltIn == false && added.first?.iconIdentifier == "square_grid_2x2" && added.first?.colorToken == "accent")
    }

    private static let builtInJSON = DartJSON.encodeString(.array(CategoryCatalog.builtIn.map { .object($0.raw) }))

    private func load(_ sections: JSONObject) -> FinancialData.LoadResult {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        return loadFinancialData(sections, calendar: calendar, now: calendar.date(2026, 9, 28), newID: sequentialIDs("id"))
    }

    private func transaction(_ id: String, _ type: String, _ category: String) -> String {
        #"{"id":"\#(id)","type":"\#(type)","description":"d","amount":1.0,"category":"\#(category)","date":"2026-09-01T00:00:00.000"}"#
    }

    /// Launches `json`, applies the pending writes, and launches again.
    private func relaunch(_ json: String, times: Int) -> [FinancialData.LoadResult] {
        var sections = try! JSONParser.parse(json).objectValue!
        var results: [FinancialData.LoadResult] = []
        for _ in 0..<times {
            let result = load(sections)
            results.append(result)
            for (name, value) in result.pendingWrites { sections[name] = value }
        }
        return results
    }

    @Test("transaction, template and budget-key names are each defined once, per type")
    func everySource() {
        let json = #"""
        {"categories":\#(Self.builtInJSON),
         "transactions":[\#(transaction("t1", "expense", "  Padded Tx ")), \#(transaction("t2", "income", " Padded Income "))],
         "recurringTransactions":[{"id":"r","type":"expense","description":"x","amount":5.0,"category":"Padded Tpl  ","pattern":"monthly","startDate":"2026-01-01T00:00:00.000","nextOccurrence":"2026-10-01T00:00:00.000"}],
         "categoryBudgetLimits":{" Padded Key":50}}
        """#
        let runs = relaunch(json, times: 4)
        let want = CategoryCatalog.builtIn.count + 4
        #expect(runs.map { $0.data.categories.count } == [want, want, want, want])
        #expect(runs[0].pendingWrites.map(\.0).contains(Section.categories))
        for later in runs.dropFirst() { #expect(!later.pendingWrites.map(\.0).contains(Section.categories), "a later launch writes no categories") }
        #expect(Set(runs[3].data.categories.map(\.name)).isSuperset(of: ["  Padded Tx ", " Padded Income ", "Padded Tpl  ", " Padded Key"]))
    }

    @Test("a name matching a padded definition stored before the launch adds nothing; the type still counts")
    func storedPadding() {
        let seeds = CategoryCatalog.builtIn + [
            CategoryInfo.make(id: "expense-old", type: .expense, name: "  Old Pad ", iconIdentifier: "cart", colorToken: "red", sortOrder: 13, isBuiltIn: false)
        ]
        let json = #"""
        {"categories":\#(DartJSON.encodeString(.array(seeds.map { .object($0.raw) }))),
         "transactions":[\#(transaction("t1", "expense", "Old Pad")), \#(transaction("t2", "expense", " old pad ")),
                         \#(transaction("t3", "income", "Old Pad"))]}
        """#
        let added = load(try! JSONParser.parse(json).objectValue!).data.categories.dropFirst(seeds.count)
        #expect(added.map(\.name) == ["Old Pad"] && added.first?.type == .income)
    }

    @Test("inside one first launch Dart's rule stands: two rows with the same padded name add two definitions, once")
    func samePassIsDartsRule() {
        let json = #"""
        {"categories":\#(Self.builtInJSON),
         "transactions":[\#(transaction("t1", "expense", " Twice ")), \#(transaction("t2", "expense", " Twice "))]}
        """#
        let runs = relaunch(json, times: 3)
        let want = CategoryCatalog.builtIn.count + 2
        #expect(runs.map { $0.data.categories.count } == [want, want, want])
        #expect(!runs[1].pendingWrites.map(\.0).contains(Section.categories) && !runs[2].pendingWrites.map(\.0).contains(Section.categories))
    }

    @Test("a padded name that matches a built-in definition adds nothing and writes no categories")
    func paddedBuiltIn() {
        let json = #"{"categories":\#(Self.builtInJSON),"transactions":[\#(transaction("t1", "expense", " groceries "))]}"#
        let result = load(try! JSONParser.parse(json).objectValue!)
        #expect(result.data.categories.count == CategoryCatalog.builtIn.count)
        #expect(!result.pendingWrites.map(\.0).contains(Section.categories))
    }
}
