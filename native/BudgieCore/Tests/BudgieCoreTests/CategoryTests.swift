import Foundation
import Testing

@testable import BudgieCore

@Suite("Categories")
struct CategoryTests {
    @Test("the typical store's categories load with Dart defaults; missing section gives the seeds")
    func load() throws {
        let scenario = try Scenario(Fixtures.url("store/typical"))
        let snapshot = StoreFile.decode(scenario.fileSystem.snapshot[StoreFile.primaryName]!)!
        let categories = CategoryCatalog.effective(CategoryCatalog.rows(snapshot.sections[Section.categories]))
        #expect(categories.contains { $0.name == "Pet Food" && $0.type == .expense && $0.iconIdentifier == "paw" })
        #expect(categories.contains { $0.name == "Side Gig ✨" && $0.type == .income })
        #expect(CategoryCatalog.effective(CategoryCatalog.rows(nil)) == CategoryCatalog.builtIn)
        #expect(CategoryCatalog.effective(CategoryCatalog.rows(.array([.object(JSONObject(ordered: [("name", .string("x"))]))])))
            == CategoryCatalog.builtIn)
        let picker = CategoryCatalog.pickerList(categories, type: .expense, usedNames: ["Groceries", "Legacy Only"])
        #expect(picker.first?.name == "General")
        #expect(picker.last?.name == "Legacy Only")
    }

    @Test("picker used names skip like Dart _containsName: lower-case UTF-16, trimmed query, archived included")
    func pickerUsedNames() {
        func def(_ name: String, _ order: Int, archived: Bool = false) -> CategoryInfo {
            CategoryInfo.make(
                id: "expense-\(order)", type: .expense, name: name, iconIdentifier: "cart", colorToken: "accent",
                sortOrder: order, isArchived: archived, isBuiltIn: false)
        }
        let defined = [def("Caf\u{E9}", 0), def("Old", 1, archived: true)]
        let used = [
            "CAF\u{C9}",  // same lower-case code units as "Café": skipped
            "Cafe\u{301}",  // canonically equal, different code units: a separate category in Dart
            "cafe\u{301}",  // now matches the one just added
            "old",  // matches the archived definition: skipped
            " Legacy ",  // trimmed for the check, stored untrimmed
            "Legacy",  // " legacy " != "legacy": added again, as Dart does
            "  legacy",  // trims to "legacy", which the previous one added
        ]
        let picker = CategoryCatalog.pickerList(defined, type: .expense, usedNames: used)
        #expect(picker.map { Array($0.name.utf16) } == ["Caf\u{E9}", "Cafe\u{301}", " Legacy ", "Legacy"].map { Array($0.utf16) })
    }
}
