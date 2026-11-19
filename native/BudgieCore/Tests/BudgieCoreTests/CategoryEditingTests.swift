import Foundation
import Testing

@testable import BudgieCore

private let calendar = DartCalendar(timeZone: newYorkZone)
private let now = calendar.date(2026, 9, 28, 9, 15, 30, 250, 125)

/// Loads sections given as JSON text, with the app's launch pass.
private func data(_ json: String) throws -> FinancialData {
    try loadFinancialData(JSONParser.parse(json).objectValue!, calendar: calendar, now: now, newID: { "new-id" }).data
}

private func category(_ id: String, _ type: String, _ name: String, _ sortOrder: Int, archived: Bool = false) -> String {
    #"{"id":"\#(id)","type":"\#(type)","name":"\#(name)","iconIdentifier":"cart","colorToken":"green","sortOrder":\#(sortOrder),"isArchived":\#(archived),"isBuiltIn":false}"#
}

private func transaction(_ id: String, _ type: String, _ category: String, updatedAt: String = "2026-09-01T10:00:00.000") -> String {
    #"{"id":"\#(id)","type":"\#(type)","description":"d","amount":1.0,"category":"\#(category)","date":"2026-09-01T00:00:00.000","recurringTemplateId":null,"tagIds":[],"createdAt":"2026-09-01T10:00:00.000","updatedAt":"\#(updatedAt)"}"#
}

private func rule(_ id: String, _ type: String?, _ category: String) -> String {
    let typeJSON = type.map { "\"\($0)\"" } ?? "null"
    return #"{"id":"\#(id)","merchantPattern":"p","matchType":"contains","transactionType":\#(typeJSON),"minimumAmount":null,"maximumAmount":null,"category":"\#(category)","tagIds":[],"priority":0,"isEnabled":true}"#
}

@Suite("Category editing: validation, ids, order, archive, the rename cascade")
struct CategoryEditingTests {
    @Test("errors carry Flutter's copy; empty is checked before duplicates; archived names count")
    func validation() throws {
        var d = try data("{}")
        #expect(CategoryEditError.nameRequired.message == "Category name is required")
        #expect(CategoryEditError.duplicateName.message == "A category with this name already exists")
        #expect(CategoryEditError.lastActive.message == "At least one category must remain active")
        #expect(CategoryEditError.duplicateName.localizedDescription == "A category with this name already exists")

        #expect(d.validateCategoryName(" \u{FEFF}\t", type: .expense, excluding: nil) == .nameRequired)
        #expect(d.validateCategoryName(" groceries ", type: .expense, excluding: nil) == .duplicateName)
        #expect(d.validateCategoryName("groceries", type: .income, excluding: nil) == nil)
        // A case-only rename of itself is allowed; of another row it is not.
        #expect(d.validateCategoryName("GROCERIES", type: .expense, excluding: "expense-groceries") == nil)
        #expect(d.validateCategoryName("gift", type: .expense, excluding: "expense-groceries") == .duplicateName)
        // Dart lowercases U+0130 to plain "i", and compares UTF-16 (NFC and NFD differ).
        _ = try d.addCategory(type: .expense, name: "İstanbul", iconIdentifier: "cart", colorToken: "green", newID: { "x" })
        #expect(d.validateCategoryName("istanbul", type: .expense, excluding: nil) == .duplicateName)
        _ = try d.addCategory(type: .expense, name: "Café", iconIdentifier: "cart", colorToken: "green", newID: { "x" })
        #expect(d.validateCategoryName("Cafe\u{301}", type: .expense, excluding: nil) == nil)
        // Archived definitions still block the name.
        try d.setCategoryArchived(id: "expense-travel", true)
        #expect(throws: CategoryEditError.duplicateName) {
            try d.addCategory(type: .expense, name: "travel", iconIdentifier: "cart", colorToken: "green", newID: { "x" })
        }
        // Update: an unknown id changes nothing, before any validation.
        let before = text(d.categoriesSection())
        let missing = try d.updateCategory(id: "missing", name: "", iconIdentifier: "", colorToken: "", now: now)
        #expect(missing == .unchanged)
        #expect(throws: CategoryEditError.nameRequired) {
            try d.updateCategory(id: "expense-general", name: "  ", iconIdentifier: "cart", colorToken: "green", now: now)
        }
        #expect(text(d.categoriesSection()) == before)
    }

    @Test("add: trimmed name, slug or uuid id, registered icon, colour verbatim, sortOrder counts archived rows")
    func add() throws {
        var d = try data("{}")
        try d.setCategoryArchived(id: "expense-loan-payment", true)
        let coffee = try d.addCategory(type: .expense, name: " \tCoffee ☕️\u{FEFF}", iconIdentifier: "nope", colorToken: "teal", newID: { "u" })
        #expect(coffee.changedSections == [Section.categories])
        #expect(text(.object(coffee.category!.raw))
            == #"{"id":"expense-coffee","type":"expense","name":"Coffee ☕️","iconIdentifier":"square_grid_2x2","colorToken":"teal","sortOrder":13,"isArchived":false,"isBuiltIn":false}"#)
        let clash = try d.addCategory(type: .expense, name: "Gift!", iconIdentifier: "gift", colorToken: "", newID: { "0f0e" })
        #expect(clash.category?.id == "expense-0f0e")
        #expect(clash.category?.colorToken == "")
    }

    @Test("archive: last active per type refused, restore unchecked, same state is a no-op")
    func archive() throws {
        var d = try data("{}")
        for id in ["income-salary", "income-investment", "income-gift"] { try d.setCategoryArchived(id: id, true) }
        #expect(throws: CategoryEditError.lastActive) { try d.setCategoryArchived(id: "income-other", true) }
        let again = try d.setCategoryArchived(id: "income-salary", true)
        #expect(again == .unchanged)
        let restored = try d.setCategoryArchived(id: "income-salary", false)
        #expect(restored.changedSections == [Section.categories])
        let archived = try d.setCategoryArchived(id: "income-other", true)
        #expect(archived.category?.isArchived == true)
    }

    @Test("move: whole list with archived rows, clamped, renumbered; visible-row offsets hop hidden rows")
    func move() throws {
        let rows = [
            category("a", "expense", "A", 0), category("b", "expense", "B", 1, archived: true), category("c", "expense", "C", 2),
            category("d", "expense", "D", 3, archived: true), category("e", "expense", "E", 4), category("i", "income", "I", 0),
        ]
        var d = try data(#"{"categories":[\#(rows.joined(separator: ","))]}"#)
        func order() -> [String] { d.categoryDefinitions(type: .expense, includeArchived: true).map(\.id) }

        // Offsets relative to the rows the page shows.
        #expect(d.categoryMoveOffset(id: "c", direction: -1, includeArchived: false) == -2)
        #expect(d.categoryMoveOffset(id: "c", direction: 1, includeArchived: false) == 2)
        #expect(d.categoryMoveOffset(id: "c", direction: -1, includeArchived: true) == -1)
        #expect(d.categoryMoveOffset(id: "a", direction: -1, includeArchived: false) == nil)
        #expect(d.categoryMoveOffset(id: "e", direction: 1, includeArchived: true) == nil)
        #expect(d.categoryMoveOffset(id: "b", direction: 1, includeArchived: true) == nil, "archived rows have no moves")
        #expect(d.categoryMoveOffset(id: "i", direction: 1, includeArchived: false) == nil)
        #expect(d.categoryMoveOffset(id: "missing", direction: 1, includeArchived: false) == nil)

        // Flutter's move by one in the full list lands between hidden rows.
        d.moveCategory(id: "c", offset: -1)
        #expect(order() == ["a", "c", "b", "d", "e"])
        d.moveCategory(id: "c", offset: d.categoryMoveOffset(id: "c", direction: 1, includeArchived: false)!)
        #expect(order() == ["a", "b", "d", "e", "c"])
        #expect(d.categoryDefinitions(type: .expense, includeArchived: true).map(\.sortOrder) == [0, 1, 2, 3, 4])
        let last = d.moveCategory(id: "c", offset: 1)
        #expect(last == .unchanged, "already last")
        let zero = d.moveCategory(id: "c", offset: 0)
        #expect(zero == .unchanged)
        let unknown = d.moveCategory(id: "missing", offset: 1)
        #expect(unknown == .unchanged)
        d.moveCategory(id: "c", offset: -100)
        #expect(order() == ["c", "a", "b", "d", "e"])
        #expect(d.categoryDefinitions(type: .income, includeArchived: true).map(\.sortOrder) == [0])
    }

    @Test("rename cascade: exact UTF-16 names and type; rules of the other type keep the name (D6); nil-typed rules follow")
    func cascade() throws {
        let json = #"""
        {"categories":[\#(category("expense-gift", "expense", "Gift", 0)),\#(category("income-gift", "income", "Gift", 0)),\#(category("expense-cafe", "expense", "Café", 1))],
         "transactions":[\#(transaction("t1", "expense", "Gift", updatedAt: "2030-01-01T00:00:00.000")),\#(transaction("t2", "income", "Gift")),\#(transaction("t3", "expense", "gift")),\#(transaction("t4", "expense", "Café")),\#(transaction("t5", "expense", "Café"))],
         "categorizationRules":[\#(rule("r1", "expense", "Gift")),\#(rule("r2", "income", "Gift")),\#(rule("r3", nil, "Gift")),\#(rule("r4", "expense", "gift"))],
         "categoryBudgetLimits":{"Gift":25.0,"Presents":0,"Café":10}}
        """#
        var d = try data(json)
        let untouched = d.transactions[1].raw
        let result = try d.updateCategory(id: "expense-gift", name: " Presents ", iconIdentifier: "gift", colorToken: "purple", now: now)
        #expect(result.changedSections == [Section.categories, Section.transactions, Section.categoryBudgetLimits, Section.categorizationRules])
        #expect(result.rename == CategoryRename(type: .expense, oldName: "Gift", newName: "Presents", transactions: 1, templates: 0, rules: 2, budgetLimit: .moved))
        same(d.transactions.map(\.category), ["Presents", "Gift", "gift", "Cafe\u{301}", "Caf\u{E9}"], "after the NFC rename")
        // Plain now, even though the stored updatedAt was later.
        #expect(d.transactions[0].raw["updatedAt"]?.stringValue == now.toIso8601String())
        #expect(d.transactions[1].raw == untouched)
        #expect(d.rules.map(\.category) == ["Presents", "Gift", "Presents", "gift"])
        // The old key goes; the stale "Presents":0 member is replaced by the
        // moved limit at the end, as a Dart double.
        #expect(text(d.budgetLimitsSection()) == #"{"Café":10,"Presents":25.0}"#)

        // NFC rename leaves the NFD spelling alone.
        let cafe = try d.updateCategory(id: "expense-cafe", name: "Coffee", iconIdentifier: "cart", colorToken: "green", now: now)
        #expect(cafe.rename?.transactions == 1)
        same(d.transactions.map(\.category), ["Presents", "Gift", "gift", "Cafe\u{301}", "Coffee"], "after the second rename")
        #expect(text(d.budgetLimitsSection()) == #"{"Presents":25.0,"Coffee":10.0}"#)

        // Case-only rename cascades; a budget collision keeps the new key's limit.
        var e = try data(#"{"transactions":[\#(transaction("t1", "expense", "Housing"))],"categoryBudgetLimits":{"Housing":1500.0,"housing":70.0}}"#)
        let housing = try e.updateCategory(id: "expense-housing", name: "housing", iconIdentifier: "house", colorToken: "blue", now: now)
        #expect(housing.rename?.budgetLimit == .dropped)
        #expect(text(e.budgetLimitsSection()) == #"{"housing":70.0}"#)
        #expect(e.transactions[0].category == "housing")

        // Icon-only and padded-same-name edits write the definition only.
        let icon = try e.updateCategory(id: "expense-housing", name: " housing ", iconIdentifier: "car", colorToken: "blue", now: now)
        #expect(icon.changedSections == [Section.categories])
        #expect(icon.rename == nil)

        // The Tags stream's entry point.
        var f = try data(#"{"categorizationRules":[\#(rule("r1", "expense", "A")),\#(rule("r2", "income", "A")),\#(rule("r3", nil, "A"))]}"#)
        let renamed = f.renameRuleCategory(from: "A", to: "B", restrictedTo: .income)
        #expect(renamed > 0)
        #expect(f.rules.map(\.category) == ["A", "B", "B"])
        let none = f.renameRuleCategory(from: "Z", to: "B", restrictedTo: .income)
        #expect(none == 0)
        // Flutter's pass (parity tests only) renames every type.
        let flutterCount = f.renameRuleCategory(from: "A", to: "C", restrictedTo: nil)
        #expect(flutterCount == 1)
    }

    @Test("edits patch rows in place: unknown keys and unreadable rows survive, lexemes of untouched keys too")
    func preservesForeignData() throws {
        let json = #"""
        {"categories":[{"id":"expense-food","name":"Food","sortOrder":0.0,"future":{"x":[1,2.50]}},{"id":7},{"id":"income-pay","type":"income","name":"Pay","sortOrder":0}],
         "transactions":[{"id":"t1","type":"expense","description":"d","amount":12,"category":"Food","date":"2026-09-01","createdAt":"2026-09-01T10:00:00.000Z","updatedAt":"2026-09-01T10:00:00.000Z","merchant":{"name":"ACME"}},{"id":"broken","type":"expense"}],
         "recurringTransactions":[{"id":"r1","type":"expense","description":"box","amount":30.0,"category":"Food","pattern":"monthly","startDate":"2026-01-10T00:00:00.000","nextOccurrence":"2026-02-10T00:00:00.000","dayOfMonth":10,"extra":[1]},{"id":"bad"}],
         "categorizationRules":[{"id":"rule-1","merchantPattern":"  market ","matchType":"weird","category":"Food","priority":2.0,"future":true},"not a rule"]}
        """#
        var d = try data(json)
        try d.updateCategory(id: "expense-food", name: "Groceries", iconIdentifier: "cart", colorToken: "green", now: now)
        #expect(text(d.categoriesSection()) == #"[{"id":"expense-food","name":"Groceries","sortOrder":0.0,"future":{"x":[1,2.50]},"iconIdentifier":"cart","colorToken":"green"},{"id":7},{"id":"income-pay","type":"income","name":"Pay","sortOrder":0}]"#)
        #expect(text(d.transactionsSection())
            == #"[{"id":"t1","type":"expense","description":"d","amount":12,"category":"Groceries","date":"2026-09-01","createdAt":"2026-09-01T10:00:00.000Z","updatedAt":"\#(now.toIso8601String())","merchant":{"name":"ACME"}},{"id":"broken","type":"expense"}]"#)
        #expect(text(d.templatesSection())
            == #"[{"id":"r1","type":"expense","description":"box","amount":30.0,"category":"Groceries","pattern":"monthly","startDate":"2026-01-10T00:00:00.000","nextOccurrence":"2026-02-10T00:00:00.000","dayOfMonth":10,"extra":[1]},{"id":"bad"}]"#)
        #expect(text(d.rulesSection())
            == #"[{"id":"rule-1","merchantPattern":"  market ","matchType":"weird","category":"Groceries","priority":2.0,"future":true},"not a rule"]"#)
    }

    /// AppModel's flow: memory first, then all changed sections in one
    /// verified commit; a failed write keeps the change in memory, flags
    /// every section of the commit, and the next save writes them all.
    @Test("a rename is one commit; a failed write is flagged and healed by the next save")
    @MainActor
    func oneCommitAndFailure() async throws {
        let scenario = try Scenario(Fixtures.url("store/typical"))
        let fs = FlakyFileSystem()
        for (name, bytes) in scenario.fileSystem.snapshot { fs.base.set(name, bytes) }
        let store = testStore(fs, preferences: scenario.preferences)
        let tracker = PersistenceTracker(store: store)
        let snapshot = try await store.read()
        var d = FinancialData.load(
            snapshot, preferences: scenario.preferences, calendar: calendar, now: { now }, newID: { UUID().uuidString.lowercased() }
        ).data
        let serialize: (String) -> JSONValue = { d.serializedSection($0)! }

        let rename = try d.updateCategory(id: "expense-groceries", name: "Food", iconIdentifier: "cart", colorToken: "green", now: now)
        #expect(rename.changedSections == [Section.categories, Section.transactions, Section.categoryBudgetLimits])
        #expect(await tracker.persist(rename.changedSections.map { ($0, serialize($0)) }, serialize: serialize))
        let written = try await store.read()
        #expect(written.revision == snapshot.revision + 1, "one commit")
        for section in rename.changedSections {
            #expect(written.sections[section] == d.serializedSection(section), "\(section)")
        }

        fs.broken = true
        let again = try d.updateCategory(id: "expense-housing", name: "Rent", iconIdentifier: "house", colorToken: "blue", now: now)
        #expect(await tracker.persist(again.changedSections.map { ($0, serialize($0)) }, serialize: serialize) == false)
        #expect(tracker.unsavedSections == Set(again.changedSections))
        #expect(d.transactions.contains { $0.category == "Rent" }, "kept in memory")
        fs.broken = false
        #expect(await tracker.retry(serialize: serialize))
        let healed = try await store.read()
        for section in again.changedSections {
            #expect(healed.sections[section] == d.serializedSection(section), "\(section)")
        }
    }
}
