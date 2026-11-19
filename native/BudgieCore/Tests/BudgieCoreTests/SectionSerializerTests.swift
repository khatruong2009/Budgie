import Foundation
import Testing

@testable import BudgieCore

private func loadData(_ sections: JSONObject, preferences: [String: PreferenceValue] = [:]) -> FinancialData {
    let calendar = DartCalendar(timeZone: Scenario.zone)
    return loadFinancialData(
        sections, preferences: preferences, calendar: calendar, now: calendar.date(2026, 9, 28, 9, 15), newID: sequentialIDs("new-")
    ).data
}

private func parse(_ json: String) -> JSONValue {
    try! JSONParser.parse(json)
}

@Suite("Section serializers: every writable section round-trips losslessly")
struct SectionSerializerTests {
    @Test("every Section.all name has a serializer; other names have none")
    func coverage() {
        let data = loadData(JSONObject())
        for section in Section.all {
            #expect(data.serializedSection(section) != nil, "\(section)")
        }
        #expect(data.serializedSection("probe") == nil)
        #expect(Set(Section.all).count == 10)
    }

    /// Loading then serializing an untouched section reproduces its bytes,
    /// except where the load itself normalises (the pending identity writes
    /// Dart also makes, and the net worth month Dart re-serialises).
    @Test("load -> serialize is byte-identical for every fixture store", arguments: storeScenarioNames + legacyScenarioNames)
    func roundTrip(_ name: String) async throws {
        let group = storeScenarioNames.contains(name) ? "store" : "legacy"
        let scenario = try Scenario(Fixtures.url("\(group)/\(name)"))
        let store = scenario.makeStore()
        let snapshot: FinancialSnapshot
        do { snapshot = try await store.read() } catch { return }
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let now = scenario.launchNow
        let loaded = FinancialData.load(
            snapshot, preferences: scenario.preferences, calendar: calendar, now: { now }, newID: { "generated" })
        let pending = Dictionary(loaded.pendingWrites, uniquingKeysWith: { $1 })
        for section in snapshot.sections.keys where Section.all.contains(section) {
            let stored = snapshot.sections[section]!
            let written = loaded.data.serializedSection(section)!
            if let expected = pending[section] {
                #expect(text(written) == text(expected), "\(name) \(section) pending write")
                continue
            }
            switch section {
            case Section.selectedNetWorthMonth:
                // Dart writes `DateTime(y, m).toIso8601String()` of what it parsed.
                let month = stored.stringValue.flatMap(calendar.tryParse).map { calendar.month(of: $0).toIso8601String() }
                #expect(written.stringValue == (month ?? calendar.month(of: now).toIso8601String()), "\(name) month")
            case Section.appSettings:
                // Patched over the stored object: every stored key keeps its
                // position; the five typed keys hold the loaded values.
                let object = written.objectValue!
                #expect(Array(object.keys.prefix(stored.objectValue?.keys.count ?? 0)) == (stored.objectValue?.keys ?? []))
            case Section.categoryBudgetLimits where stored.objectValue == nil,
                Section.categories where stored.arrayValue == nil,
                Section.transactionTags where stored.arrayValue == nil,
                Section.categorizationRules where stored.arrayValue == nil,
                Section.savingsGoals where stored.arrayValue == nil:
                // Not the type Dart expects: Dart reads it as empty and
                // would write its own value on the next save.
                break
            case Section.savingsGoals, Section.transactionTags, Section.categorizationRules:
                // A readable row without an id gets the generated one
                // appended (Dart's toJson would write it); nothing else moves.
                let rows = stored.arrayValue!, out = written.arrayValue!
                #expect(rows.count == out.count, "\(name) \(section) count")
                for (row, outRow) in zip(rows, out) where text(row) != text(outRow) {
                    var backfilled = row.objectValue
                    backfilled?["id"] = .string("generated")
                    #expect(row.objectValue?["id"] == nil && text(backfilled.map { .object($0) }) == text(outRow), "\(name) \(section)")
                }
            default:
                #expect(text(written) == text(stored), "\(name) \(section)")
            }
        }
    }

    @Test("budget limits: derived from the stored object; <= 0 and non-numbers kept but not used")
    func budgetLimits() {
        let data = loadData(JSONObject(ordered: [
            ("categoryBudgetLimits", parse(#"{"Groceries":400,"Old":0,"Bad":"x","Travel":150.5,"Neg":-1.0}"#)),
        ]))
        #expect(data.budgetLimits.map(\.0) == ["Groceries", "Travel"])
        #expect(data.budgetLimits.map(\.1) == [400, 150.5])
        #expect(text(data.budgetLimitsSection()) == #"{"Groceries":400,"Old":0,"Bad":"x","Travel":150.5,"Neg":-1.0}"#)
        #expect(text(loadData(JSONObject()).budgetLimitsSection()) == "{}")
    }

    @Test("savings goals: unreadable rows kept verbatim; a missing id is backfilled")
    func goals() {
        let data = loadData(JSONObject(ordered: [
            ("savingsGoals", parse(#"[{"name":"Trip","targetAmount":"1200","x":1},7,{"id":"g2","name":" ","targetAmount":-5}]"#)),
        ]))
        #expect(data.savingsGoals.map(\.id) == ["new-1", "g2"])
        #expect(data.savingsGoals.map(\.name) == ["Trip", "Savings Goal"])
        #expect(data.savingsGoals.map(\.targetAmount) == [1200, 0])
        #expect(text(data.savingsGoalsSection())
            == #"[{"name":"Trip","targetAmount":"1200","x":1,"id":"new-1"},7,{"id":"g2","name":" ","targetAmount":-5}]"#)
    }

    @Test("categories: Dart fromJson defaults, strict casts, seeds when nothing is readable")
    func categories() {
        let data = loadData(JSONObject(ordered: [
            ("categories", parse(#"[{"id":"expense-x","type":"expense","name":"X","extra":true},{"id":"b","name":"B","sortOrder":"1"},{"id":"income-y","type":"income","name":"Y","iconIdentifier":"gift","sortOrder":2.9,"isArchived":true,"isBuiltIn":true}]"#)),
        ]))
        #expect(data.categories.map(\.id) == ["expense-x", "income-y"])
        let x = data.categories[0]
        #expect(x.iconIdentifier == "square_grid_2x2" && x.colorToken == "accent" && x.sortOrder == 0 && !x.isArchived && !x.isBuiltIn)
        let y = data.categories[1]
        // Load renumbers sort orders per type (Dart `_normalizeSortOrders`).
        #expect(y.type == .income && y.sortOrder == 0 && y.isArchived && y.isBuiltIn)
        #expect(data.categoryRows.count == 3 && data.categoryRows[1].record == nil)
        #expect(text(data.categoriesSection()).contains(#""extra":true"#))

        #expect(loadData(JSONObject()).categories == CategoryCatalog.builtIn)
        let onlyBad = loadData(JSONObject(ordered: [("categories", parse(#"[{"name":"x"}]"#))]))
        #expect(onlyBad.categories == CategoryCatalog.builtIn)
        // The unreadable row is kept; the seeds are materialised after it.
        #expect(onlyBad.categoryRows.first?.record == nil && onlyBad.categoryRows.count == 18)
    }

    @Test("built-in seeds serialise exactly as Dart's toJson")
    func seeds() {
        #expect(CategoryCatalog.builtIn.count == 17)
        #expect(CategoryCatalog.builtIn.allSatisfy { $0.isBuiltIn })
        #expect(text(.object(CategoryCatalog.builtIn[1].raw))
            == #"{"id":"expense-eating-out","type":"expense","name":"Eating Out","iconIdentifier":"asterisk_circle","colorToken":"orange","sortOrder":1,"isArchived":false,"isBuiltIn":true}"#)
    }

    @Test("tags: defaults, trimmed name, strict casts, missing id backfilled")
    func tags() {
        let data = loadData(JSONObject(ordered: [
            ("transactionTags", parse(#"[{"id":"t1","name":"  Trip﻿"},{"name":"No id","colorToken":"green"},{"id":3,"name":"bad"},"junk"]"#)),
        ]))
        #expect(data.tags.map(\.id) == ["t1", "new-1"])
        #expect(data.tags.map(\.name) == ["Trip", "No id"])
        #expect(data.tags.map(\.colorToken) == ["accent", "green"])
        #expect(text(data.tagsSection())
            == #"[{"id":"t1","name":"  Trip﻿"},{"name":"No id","colorToken":"green","id":"new-1"},{"id":3,"name":"bad"},"junk"]"#)
    }

    @Test("rules: fromJson defaults and casts")
    func rules() {
        let data = loadData(JSONObject(ordered: [
            ("categorizationRules", parse(#"""
            [{"id":"r1","merchantPattern":" Whole Foods ","matchType":"startsWith","transactionType":"weird","minimumAmount":5,"maximumAmount":null,"category":"Groceries","tagIds":["a",1,"b"],"priority":2.7,"isEnabled":false,"z":0},
             {"id":"r2","matchType":7},
             {"id":"r3","minimumAmount":"5"},
             {"id":"r4","tagIds":"a"},
             {"id":"r5","priority":true},
             {"id":"r6","transactionType":"income","priority":1e30}]
            """#)),
        ]))
        #expect(data.rules.map(\.id) == ["r1", "r2", "r6"])
        let r1 = data.rules[0]
        #expect(r1.merchantPattern == "Whole Foods" && r1.matchType == .startsWith && r1.transactionType == .expense)
        #expect(r1.minimumAmount == 5 && r1.maximumAmount == nil && r1.category == "Groceries" && r1.tagIds == ["a", "b"])
        #expect(r1.priority == 2 && !r1.isEnabled)
        let r2 = data.rules[1]
        #expect(r2.merchantPattern == "" && r2.matchType == .contains && r2.transactionType == nil && r2.category == "General")
        #expect(r2.priority == 0 && r2.isEnabled && r2.tagIds.isEmpty)
        #expect(data.rules[2].transactionType == .income && data.rules[2].priority == Int.max)
        #expect(data.ruleRows.count == 6)
    }

    @Test("tags and rules fall back to the legacy preference when the section is not a list")
    func legacyPreferenceFallback() {
        let prefs: [String: PreferenceValue] = [
            PreferenceKey.transactionTags: .string(#"[{"id":"t","name":"Legacy"}]"#),
            PreferenceKey.categorizationRules: .string("not json"),
        ]
        let data = loadData(JSONObject(ordered: [("transactionTags", .null)]), preferences: prefs)
        #expect(data.tags.map(\.name) == ["Legacy"])
        #expect(data.rules.isEmpty)
        let fromSection = loadData(JSONObject(ordered: [("transactionTags", parse("[]"))]), preferences: prefs)
        #expect(fromSection.tags.isEmpty)
    }

    @Test("the net worth month serialises as Dart's DateTime(y, m).toIso8601String()")
    func selectedMonth() {
        let data = loadData(JSONObject(ordered: [("selectedNetWorthMonth", .string("2026-05-17T13:00:00.000"))]))
        #expect(data.selectedNetWorthMonthSection().stringValue == "2026-05-01T00:00:00.000")
    }
}

@Suite("Transaction edits: tags")
struct TransactionTagEditTests {
    @Test("tagIds are written only when they change, in the given order; other keys stay untouched")
    func tags() throws {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let now = calendar.date(2026, 9, 28, 12)
        let row = try JSONParser.parse(
            #"{"id":"t","type":"expense","description":"x","amount":5,"category":"Food","date":"2026-09-01T00:00:00.000","tagIds":["b",7,"a"],"z":true,"createdAt":"2026-09-01T00:00:00.000","updatedAt":"2026-09-01T00:00:00.000"}"#)
        let record = try #require(TransactionRecord.parse(row, calendar: calendar, newID: { "n" }))
        #expect(record.tagIds == ["b", "a"])
        let same = record.applying(.init(type: .expense, description: "x", amount: 5, category: "Food", date: record.date, tagIds: ["b", "a"]), now: now)
        #expect(DartJSON.encodeString(same.raw["tagIds"]!) == #"["b",7,"a"]"#)
        let kept = record.applying(.init(type: .expense, description: "x", amount: 5, category: "Food", date: record.date), now: now)
        #expect(DartJSON.encodeString(kept.raw["tagIds"]!) == #"["b",7,"a"]"#)
        let changed = record.applying(.init(type: .expense, description: "x", amount: 5, category: "Food", date: record.date, tagIds: ["a", "c"]), now: now)
        #expect(changed.tagIds == ["a", "c"])
        #expect(DartJSON.encodeString(.object(changed.raw))
            // (An int amount lexeme is always rewritten as a double on edit.)
            == #"{"id":"t","type":"expense","description":"x","amount":5.0,"category":"Food","date":"2026-09-01T00:00:00.000","tagIds":["a","c"],"z":true,"createdAt":"2026-09-01T00:00:00.000","updatedAt":"2026-09-28T12:00:00.000"}"#)
        let noKey = try #require(TransactionRecord.parse(
            try JSONParser.parse(#"{"id":"u","type":"income","description":"y","amount":1.0,"category":"Pay","date":"2026-09-01T00:00:00.000"}"#),
            calendar: calendar, newID: { "n" }))
        let tagged = noKey.applying(.init(type: .income, description: "y", amount: 1, category: "Pay", date: noKey.date, tagIds: ["t1"]), now: now)
        #expect(DartJSON.encodeString(tagged.raw["tagIds"]!) == #"["t1"]"#)
    }
}
