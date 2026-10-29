import Foundation
import Testing

@testable import BudgieCore

private nonisolated(unsafe) let uuidTail = #/^(expense|income)-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/#

@Suite("Categories: legacy names are materialised at launch like the Flutter app")
struct CategoryMaterializationTests {
    /// The categories Dart holds after `_initializeApp` (sectionsAfterInit)
    /// equal the Swift ones after load, field by field and in order. Ids
    /// that Dart drew from a UUID are compared by shape only. Not covered by
    /// `assertDartSummary` (DomainParityTests), which never looks at category
    /// definitions, so this stays a separate test.
    @Test("same definitions as Dart after launch, for every fixture", arguments: DomainParityTests.cases)
    func parity(_ path: String) async throws {
        let url = Fixtures.url(path)
        let scenario = try Scenario(url)
        let expected = try loadExpected(url)
        guard let text = expected["sectionsAfterInit"]["json"].string else {
            // Dart wrote no sections after init: it could not launch (primary_is_directory) or
            // the 10k-row dataset has no category expectations.
            if !["store/primary_is_directory", "store/large_10k"].contains(path) {
                Issue.record("\(path): no sectionsAfterInit in expected.json")
            }
            return
        }
        let dart = J(try JSONParser.parse(text))["categories"].array
        #expect(!dart.isEmpty, "\(path): Dart holds no categories after init")
        // Swift refuses to launch the blocked legacy scenarios Dart migrates partially.
        guard let data = try await launch(scenario) else { return }
        let swift = data.categoryRows.compactMap(\.record)
        #expect(swift.count == dart.count, "\(path) count")
        for (s, d) in zip(swift, dart) {
            let dartID = d["id"].string ?? ""
            if dartID.wholeMatch(of: uuidTail) != nil {
                #expect(s.id.wholeMatch(of: uuidTail) != nil && s.id.hasPrefix(s.type.rawValue), "\(path) \(dartID)")
            } else {
                #expect(s.id == dartID, "\(path) id")
            }
            #expect(s.type.rawValue == d["type"].string && s.name == d["name"].string, "\(path) \(dartID)")
            #expect(s.iconIdentifier == d["iconIdentifier"].string && s.colorToken == d["colorToken"].string, "\(path) \(dartID)")
            #expect(s.sortOrder == d["sortOrder"].int && s.isArchived == d["isArchived"].bool && s.isBuiltIn == d["isBuiltIn"].bool,
                    "\(path) \(dartID) flags")
        }
    }

    private func load(_ json: String, newIDs: [String] = []) -> FinancialData.LoadResult {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let now = calendar.date(2026, 9, 28)
        var ids = newIDs
        let sections = try! JSONParser.parse(json).objectValue!
        return FinancialData.load(
            FinancialSnapshot(schemaVersion: 2, revision: 1, sections: sections), preferences: InMemoryPreferences([:]),
            calendar: calendar, now: { now }, newID: { ids.isEmpty ? "id" : ids.removeFirst() })
    }

    @Test("sources, trimming, case, slugs, budget keys > 0, and no write when nothing changes")
    func rules() throws {
        let seeds = DartJSON.encodeString(.array(CategoryCatalog.builtIn.map { .object($0.raw) }))
        let result = load(#"""
        {"categories":\#(seeds),
         "transactions":[
          {"id":"t1","type":"expense","description":"a","amount":1.0,"category":"  groceries ","date":"2026-09-01T00:00:00.000"},
          {"id":"t2","type":"expense","description":"b","amount":1.0,"category":"Café Crème","date":"2026-09-01T00:00:00.000"},
          {"id":"t3","type":"income","description":"c","amount":1.0,"category":"Groceries","date":"2026-09-01T00:00:00.000"},
          {"id":"t4","type":"expense","description":"d","amount":1.0,"category":"!!!","date":"2026-09-01T00:00:00.000"},
          {"id":"t5","type":"expense","description":"e","amount":1.0,"category":"CAFÉ CRÈME","date":"2026-09-01T00:00:00.000"}],
         "recurringTransactions":[{"id":"r","type":"expense","description":"x","amount":5.0,"category":"Gift","pattern":"monthly","startDate":"2026-01-01T00:00:00.000","nextOccurrence":"2026-10-01T00:00:00.000"},
          {"id":"r2","type":"income","description":"x","amount":5.0,"category":"Café Crème","pattern":"monthly","startDate":"2026-01-01T00:00:00.000","nextOccurrence":"2026-10-01T00:00:00.000"}],
         "categoryBudgetLimits":{"Budget Only":50,"Zero":0,"groceries":10}}
        """#, newIDs: ["uuid-1"])
        let added = result.data.categoryRows.compactMap(\.record).filter { !$0.isBuiltIn }
        // "  groceries " matches the seed Groceries (trimmed, case-insensitive);
        // income Groceries is new; "CAFÉ CRÈME" matches "Café Crème".
        #expect(added.map(\.id) == ["expense-caf-cr-me", "income-groceries", "expense-category", "income-caf-cr-me", "expense-budget-only"])
        #expect(added.map(\.name) == ["Café Crème", "Groceries", "!!!", "Café Crème", "Budget Only"])
        #expect(added.map(\.sortOrder) == [13, 4, 14, 5, 15])
        #expect(added.allSatisfy { $0.iconIdentifier == "square_grid_2x2" && $0.colorToken == "accent" && !$0.isArchived })
        #expect(result.pendingWrites.map(\.0).contains(Section.categories))

        // Canonical seeds and nothing in use: no write.
        #expect(load(#"{"categories":\#(seeds)}"#).pendingWrites.isEmpty)
        // Missing section: the seeds are written.
        let fresh = load("{}")
        #expect(fresh.pendingWrites.map(\.0) == [Section.categories])
        #expect(fresh.data.categoryRows.compactMap(\.record) == CategoryCatalog.builtIn)
        // A taken slug falls back to type-uuid.
        let taken = load(#"""
        {"categories":[{"id":"expense-rent","type":"expense","name":"Housing costs"}],
         "transactions":[{"id":"t","type":"expense","description":"a","amount":1.0,"category":"Rent","date":"2026-09-01T00:00:00.000"}]}
        """#, newIDs: ["0f"])
        #expect(taken.data.categoryRows.compactMap(\.record).map(\.id) == ["expense-rent", "expense-0f"])
    }

    @Test("sort orders renumber per type, stable, archived included; only changed rows are patched")
    func normalize() {
        let result = load(#"""
        {"categories":[
          {"id":"a","type":"expense","name":"A","sortOrder":5,"extra":1},
          {"id":"b","type":"expense","name":"B","sortOrder":1,"isArchived":true},
          {"id":"c","type":"income","name":"C","sortOrder":0},
          {"id":"d","type":"expense","name":"D","sortOrder":1}]}
        """#)
        let rows = result.data.categoryRows.compactMap(\.record)
        #expect(rows.map(\.sortOrder) == [2, 0, 0, 1])
        #expect(DartJSON.encodeString(result.data.categoriesSection())
            == #"[{"id":"a","type":"expense","name":"A","sortOrder":2,"extra":1},{"id":"b","type":"expense","name":"B","sortOrder":0,"isArchived":true},{"id":"c","type":"income","name":"C","sortOrder":0},{"id":"d","type":"expense","name":"D","sortOrder":1}]"#)
    }
    @Test("categoryInfo matches case-insensitively as UTF-16: NFC and NFD spellings stay apart")
    func infoLookup() {
        let data = load(#"""
        {"categories":[
          {"id":"n","type":"expense","name":"Caf\u00e9","iconIdentifier":"cart","colorToken":"accent","sortOrder":0},
          {"id":"d","type":"expense","name":"Cafe\u0301","iconIdentifier":"gift","colorToken":"accent","sortOrder":1}]}
        """#).data
        #expect(data.categoryInfo(named: "CAF\u{E9}", type: .expense)?.id == "n")
        #expect(data.categoryInfo(named: "cafe\u{301}", type: .expense)?.id == "d")
        #expect(data.categoryInfo(named: "Caf\u{E9}", type: .income) == nil)
        #expect(data.categoryPicker(for: .expense).map(\.id).prefix(2) == ["n", "d"])
    }
}
