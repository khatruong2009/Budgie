import Foundation
import Testing

@testable import BudgieCore

private let calendar = DartCalendar(timeZone: newYorkZone)
private let now = calendar.date(2026, 9, 28, 9, 15, 30, 250, 125)

/// Loads sections given as JSON text.
private func data(_ json: String) throws -> FinancialData {
    try loadFinancialData(JSONParser.parse(json).objectValue!, calendar: calendar, now: now, newID: { "new-id" }).data
}

private let twoTags = #"{"transactionTags":[{"id":"t1","name":"Work","colorToken":"accent"},{"id":"t2","name":"Café","colorToken":"cyan"}]}"#

@Suite("Tags and rules: add and delete as CategorizationProvider does")
struct TagRuleEditingTests {
    @Test("addTag: Dart trim, empty before duplicate, UTF-16 case-insensitive duplicates, toJson shape")
    func addTag() throws {
        var d = try data(twoTags)
        for name in ["", "   ", "\u{FEFF}", "\u{85}\u{A0}\u{3000}"] {
            #expect(throws: CategorizationEditError.tagNameRequired) { try d.addTag(name: name, id: "x") }
        }
        for name in ["work", " WORK ", "\u{FEFF}Work", "CAFÉ"] {
            #expect(throws: CategorizationEditError.duplicateTagName) { try d.addTag(name: name, id: "x") }
        }
        #expect(CategorizationEditError.tagNameRequired.message == "Tag name is required")
        #expect(CategorizationEditError.duplicateTagName.message == "A tag with this name already exists")
        #expect(d.tags.count == 2)

        // NFD differs from the stored NFC "Café" as UTF-16, as in Dart.
        try d.addTag(name: " Cafe\u{301} ", id: "t3")
        // Dart lowercases U+0130 to plain "i".
        try d.addTag(name: "İstanbul", id: "t4")
        #expect(throws: CategorizationEditError.duplicateTagName) { try d.addTag(name: "istanbul", id: "x") }
        // Georgian Mtavruli is not in Dart's case tables: no duplicate.
        try d.addTag(name: "\u{10D0}", id: "t5")
        try d.addTag(name: "\u{1C90}", id: "t6")
        let tag = try d.addTag(name: "\u{FEFF} Travel planning\u{2028}", colorToken: "green", id: "t7")
        #expect(tag.name == "Travel planning")
        #expect(d.tags.map(\.id) == ["t1", "t2", "t3", "t4", "t5", "t6", "t7"])
        #expect(text(d.tagsSection()).hasSuffix(#",{"id":"t7","name":"Travel planning","colorToken":"green"}]"#))
        #expect(d.validateTagName("travel PLANNING") == .duplicateTagName)
        #expect(d.validateTagName("New") == nil)
    }

    @Test("a new rule is Dart's toJson: key order, null keys, double lexemes, int priority")
    func ruleShape() throws {
        var d = try data(twoTags)
        try d.addRule(RuleDraft(merchantPattern: "  Whole \"Foods\" ", transactionType: .expense, category: "Groceries", tagIds: ["t2", "t1"]), id: "r1")
        try d.addRule(
            RuleDraft(
                merchantPattern: "pay", matchType: .startsWith, transactionType: nil, minimumAmount: 0.1 + 0.2, maximumAmount: 1e21,
                category: "Salary", priority: -3, isEnabled: false), id: "r2")
        try d.addRule(
            RuleDraft(merchantPattern: "x", matchType: .exact, transactionType: .income, minimumAmount: -0.0, maximumAmount: 20, category: "C"),
            id: "r3")
        try d.addRule(RuleDraft(merchantPattern: "y", transactionType: .expense, minimumAmount: 1e-7, category: "C", priority: 1 << 53 + 1), id: "r4")
        #expect(text(d.rulesSection()) == "[" + [
            #"{"id":"r1","merchantPattern":"Whole \"Foods\"","matchType":"contains","transactionType":"expense","minimumAmount":null,"maximumAmount":null,"category":"Groceries","tagIds":["t2","t1"],"priority":0,"isEnabled":true}"#,
            #"{"id":"r2","merchantPattern":"pay","matchType":"startsWith","transactionType":null,"minimumAmount":0.30000000000000004,"maximumAmount":1e+21,"category":"Salary","tagIds":[],"priority":-3,"isEnabled":false}"#,
            #"{"id":"r3","merchantPattern":"x","matchType":"exact","transactionType":"income","minimumAmount":-0.0,"maximumAmount":20.0,"category":"C","tagIds":[],"priority":0,"isEnabled":true}"#,
            #"{"id":"r4","merchantPattern":"y","matchType":"contains","transactionType":"expense","minimumAmount":1e-7,"maximumAmount":null,"category":"C","tagIds":[],"priority":\#(1 << 53 + 1),"isEnabled":true}"#,
        ].joined(separator: ",") + "]")
        // The made record reads back as itself.
        let reparsed = try data(#"{"transactionTags":"# + text(d.tagsSection()) + #","categorizationRules":"# + text(d.rulesSection()) + "}")
        #expect(reparsed.rules == d.rules)
        #expect(d.rulesByPriority.map(\.id) == ["r4", "r1", "r3", "r2"])
    }

    @Test("addRule: the same id moves to the end; Swift-only checks refuse without changing anything")
    func addRule() throws {
        var d = try data(twoTags)
        try d.addRule(RuleDraft(merchantPattern: "a", transactionType: .expense, category: "A"), id: "r1")
        try d.addRule(RuleDraft(merchantPattern: "b", transactionType: .expense, category: "B"), id: "r2")
        try d.addRule(RuleDraft(merchantPattern: "a2", transactionType: .income, category: "A2"), id: "r1")
        #expect(d.rules.map(\.id) == ["r2", "r1"])
        #expect(d.rules.last?.merchantPattern == "a2")

        let before = text(d.rulesSection())
        #expect(throws: CategorizationEditError.rulePatternRequired) {
            try d.addRule(RuleDraft(merchantPattern: " \u{FEFF}", transactionType: .expense, category: "A"), id: "r9")
        }
        for bound in [Double.nan, .infinity, -.infinity] {
            #expect(throws: CategorizationEditError.ruleAmountNotFinite) {
                try d.addRule(RuleDraft(merchantPattern: "a", transactionType: .expense, maximumAmount: bound, category: "A"), id: "r9")
            }
        }
        #expect(throws: CategorizationEditError.unknownTag("t9")) {
            try d.addRule(RuleDraft(merchantPattern: "a", transactionType: .expense, category: "A", tagIds: ["t1", "t9"]), id: "r9")
        }
        #expect(text(d.rulesSection()) == before)
    }

    @Test("deleteTag: strips every occurrence from rules (only that key), keeps transactions' ids, unreadable rows")
    func deleteTag() throws {
        var d = try data(#"""
            {"transactionTags":[{"id":"t1","name":"Work"},{"id":"t2","name":"Home","colorToken":"accent"},{"id":"t1","name":"Dup","colorToken":"x"},7],
             "categorizationRules":[
               {"merchantPattern":"a","category":"A","tagIds":["t1",1,"t2","t1",null],"id":"r1","future":{"k":[1.50]}},
               {"id":"r2","merchantPattern":"b","category":"B","tagIds":["t2"],"minimumAmount":5},
               {"id":"r3","merchantPattern":"c","category":"C"},
               "bad"],
             "transactions":[{"id":"x1","type":"expense","description":"d","amount":1.0,"category":"A","date":"2026-09-01T00:00:00.000","recurringTemplateId":null,"tagIds":["t1"],"createdAt":"2026-09-01T10:00:00.000","updatedAt":"2026-09-01T10:00:00.000"}]}
            """#)
        let transactions = text(d.transactionsSection())
        let deleted = d.deleteTag(id: "t1")
        #expect(deleted == [Section.transactionTags, Section.categorizationRules])
        #expect(text(d.tagsSection()) == #"[{"id":"t2","name":"Home","colorToken":"accent"},7]"#)
        #expect(text(d.rulesSection()) == "[" + [
            #"{"merchantPattern":"a","category":"A","tagIds":[1,"t2",null],"id":"r1","future":{"k":[1.50]}}"#,
            #"{"id":"r2","merchantPattern":"b","category":"B","tagIds":["t2"],"minimumAmount":5}"#,
            #"{"id":"r3","merchantPattern":"c","category":"C"}"#,
            #""bad""#,
        ].joined(separator: ",") + "]")
        #expect(d.rules.map(\.tagIds) == [["t2"], ["t2"], []])
        #expect(text(d.transactionsSection()) == transactions)
        #expect(d.transactions.first?.tagIds == ["t1"])

        // Unknown everywhere: nothing to write.
        let none = d.deleteTag(id: "nope")
        #expect(none.isEmpty)
        // An orphan id only a rule still names: the rule changes.
        var orphan = try data(#"{"categorizationRules":[{"id":"r1","merchantPattern":"a","category":"A","tagIds":["gone"]}]}"#)
        let stripped = orphan.deleteTag(id: "gone")
        #expect(stripped == [Section.transactionTags, Section.categorizationRules])
        #expect(orphan.rules.first?.tagIds == [])
    }

    @Test("deleteRule: every rule with the id; unknown ids change nothing")
    func deleteRule() throws {
        var d = try data(#"{"categorizationRules":[{"id":"r1","merchantPattern":"a","category":"A"},{"id":"r2","merchantPattern":"b","category":"B"},{"id":"r1","merchantPattern":"c","category":"C"},[]]}"#)
        let caseVariant = d.deleteRule(id: "R1")
        let known = d.deleteRule(id: "r1")
        #expect(!caseVariant && known)
        #expect(text(d.rulesSection()) == #"[{"id":"r2","merchantPattern":"b","category":"B"},[]]"#)
        let again = d.deleteRule(id: "r1")
        #expect(!again)
    }

    @Test("suggestion: the first match wins; nil when its category is not active (later rules are not tried)")
    func suggestion() throws {
        let d = try data(#"""
            {"categorizationRules":[
              {"id":"low","merchantPattern":"shop","category":"Groceries","priority":0},
              {"id":"high","merchantPattern":"shop","category":"Archived","priority":5},
              {"id":"income","merchantPattern":"shop","category":"Salary","transactionType":"income","priority":9}]}
            """#)
        let active = ["Groceries", "Housing"]
        #expect(CategorizationEngine.suggest(rules: d.rules, type: .expense, description: "Shop", amount: 1)?.id == "high")
        #expect(CategorizationEngine.suggestion(rules: d.rules, type: .expense, description: "Shop", amount: 1, activeCategoryNames: active) == nil)
        #expect(
            CategorizationEngine.suggestion(rules: d.rules, type: .expense, description: "Shop", amount: 1, activeCategoryNames: active + ["Archived"])?.id
                == "high")
        #expect(CategorizationEngine.suggestion(rules: d.rules, type: .income, description: "shop", amount: 1, activeCategoryNames: ["Salary"])?.id == "income")
    }

    // MARK: - Swift-only: edit, enable, bounds, any type

    @Test("updateRule: in place (id and position), only the changed keys, Dart lexemes, present nulls")
    func updateRuleInPlace() throws {
        var d = try data(twoTags)
        try d.addRule(RuleDraft(merchantPattern: "a", transactionType: .expense, category: "A"), id: "r1")
        try d.addRule(RuleDraft(merchantPattern: "Whole Foods", transactionType: .expense, category: "Groceries", tagIds: ["t1"]), id: "r2")
        try d.addRule(RuleDraft(merchantPattern: "c", transactionType: .income, category: "C"), id: "r3")

        var draft = d.rules[1].draft
        draft.merchantPattern = "  Whole Foods Market "
        draft.category = "Food"
        draft.transactionType = nil
        draft.minimumAmount = 0
        draft.maximumAmount = 0.1 + 0.2
        draft.tagIds = ["t2", "t1"]
        let changed = try d.updateRule(id: "r2", draft)
        #expect(changed)
        #expect(d.rules.map(\.id) == ["r1", "r2", "r3"], "position kept")
        #expect(text(d.rulesSection()) == "[" + [
            #"{"id":"r1","merchantPattern":"a","matchType":"contains","transactionType":"expense","minimumAmount":null,"maximumAmount":null,"category":"A","tagIds":[],"priority":0,"isEnabled":true}"#,
            #"{"id":"r2","merchantPattern":"Whole Foods Market","matchType":"contains","transactionType":null,"minimumAmount":0.0,"maximumAmount":0.30000000000000004,"category":"Food","tagIds":["t2","t1"],"priority":0,"isEnabled":true}"#,
            #"{"id":"r3","merchantPattern":"c","matchType":"contains","transactionType":"income","minimumAmount":null,"maximumAmount":null,"category":"C","tagIds":[],"priority":0,"isEnabled":true}"#,
        ].joined(separator: ",") + "]")

        // Clearing a bound writes a present null; a type comes back.
        draft = d.rules[1].draft
        draft.minimumAmount = nil
        draft.maximumAmount = 20
        draft.transactionType = .income
        draft.matchType = .exact
        try d.updateRule(id: "r2", draft)
        #expect(text(d.rulesSection()).contains(
            #"{"id":"r2","merchantPattern":"Whole Foods Market","matchType":"exact","transactionType":"income","minimumAmount":null,"maximumAmount":20.0,"category":"Food","tagIds":["t2","t1"],"priority":0,"isEnabled":true}"#))

        // The same draft again changes nothing.
        let before = text(d.rulesSection())
        let again = try d.updateRule(id: "r2", d.rules[1].draft)
        #expect(!again)
        #expect(text(d.rulesSection()) == before)
        // The edited record reads back as itself.
        let reparsed = try data(#"{"transactionTags":"# + text(d.tagsSection()) + #","categorizationRules":"# + before + "}")
        #expect(reparsed.rules == d.rules)
    }

    @Test("updateRule on a foreign row: unknown keys, lexemes and key order stay; missing keys appended only when changed")
    func updateForeignRule() throws {
        var d = try data(#"""
            {"transactionTags":[{"id":"t1","name":"Work","colorToken":"accent"}],
             "categorizationRules":[
               {"future":{"k":[1.50]},"category":"Rent","merchantPattern":"  rent ","id":"r1","minimumAmount":5,"matchType":"fuzzy","transactionType":"weird","tagIds":["t1",1,"gone"],"priority":2.7},
               "bad",
               {"id":"r2","merchantPattern":"x","category":"X"}]}
            """#)
        let foreign = d.rules[0]
        #expect(foreign.minimumAmount == 5 && foreign.matchType == .contains && foreign.transactionType == .expense && foreign.priority == 2)
        // The prefill changes nothing (the stored `5`, "fuzzy", "weird",
        // 2.7, the padded pattern and the orphan "gone" all stay).
        let untouched = try d.updateRule(id: "r1", foreign.draft)
        #expect(!untouched)
        var draft = foreign.draft
        draft.maximumAmount = 1500
        draft.category = "Housing"
        let changed = try d.updateRule(id: "r1", draft)
        #expect(changed)
        #expect(text(d.rulesSection()) == "[" + [
            #"{"future":{"k":[1.50]},"category":"Housing","merchantPattern":"  rent ","id":"r1","minimumAmount":5,"matchType":"fuzzy","transactionType":"weird","tagIds":["t1",1,"gone"],"priority":2.7,"maximumAmount":1500.0}"#,
            #""bad""#,
            #"{"id":"r2","merchantPattern":"x","category":"X"}"#,
        ].joined(separator: ",") + "]")
        // A new orphan is refused; the stored one may stay.
        draft.tagIds = ["t1", "gone", "t9"]
        #expect(throws: CategorizationEditError.unknownTag("t9")) { try d.updateRule(id: "r1", draft) }
        // A row without the key already reads as any type; switching a type
        // on and back off leaves a present null.
        var plain = d.rules[1].draft
        plain.transactionType = nil
        let unchanged = try d.updateRule(id: "r2", plain)
        #expect(!unchanged)
        plain.transactionType = .income
        try d.updateRule(id: "r2", plain)
        plain.transactionType = nil
        try d.updateRule(id: "r2", plain)
        #expect(text(d.rulesSection()).hasSuffix(#"{"id":"r2","merchantPattern":"x","category":"X","transactionType":null}]"#))
    }

    @Test("updateRule refuses (nothing changes): unknown id, blank text, non-finite, negative, min above max")
    func updateRuleRefusals() throws {
        var d = try data(twoTags)
        try d.addRule(RuleDraft(merchantPattern: "a", transactionType: .expense, category: "A"), id: "r1")
        let before = text(d.rulesSection())
        let draft = d.rules[0].draft
        #expect(throws: CategorizationEditError.ruleNotFound) { try d.updateRule(id: "R1", draft) }
        func refused(_ error: CategorizationEditError, _ change: (inout RuleDraft) -> Void) {
            var edited = draft
            change(&edited)
            #expect(throws: error) { try d.updateRule(id: "r1", edited) }
            #expect((d.validateRule(edited) ?? edited.boundsError) == error)
        }
        refused(.rulePatternRequired) { $0.merchantPattern = "\u{FEFF} " }
        refused(.ruleAmountNotFinite) { $0.minimumAmount = .nan }
        refused(.ruleAmountNotFinite) { $0.maximumAmount = -.infinity }
        refused(.ruleAmountNegative) { $0.minimumAmount = -0.01 }
        refused(.ruleAmountNegative) { $0.maximumAmount = -5 }
        refused(.ruleMinimumAboveMaximum) {
            $0.minimumAmount = 20.01
            $0.maximumAmount = 20
        }
        refused(.unknownTag("t9")) { $0.tagIds = ["t9"] }
        #expect(text(d.rulesSection()) == before)
        #expect(CategorizationEditError.ruleMinimumAboveMaximum.message == "Minimum can't be more than maximum")
        #expect(CategorizationEditError.ruleAmountNegative.message == "Amounts can't be negative")
        #expect(CategorizationEditError.ruleNotFound.message == "This rule no longer exists")
        // Equal bounds (one exact amount) and zero are fine; -0.0 is not negative.
        var exact = draft
        exact.minimumAmount = 20
        exact.maximumAmount = 20
        #expect(exact.boundsError == nil)
        exact.minimumAmount = -0.0
        exact.maximumAmount = 0
        #expect(exact.boundsError == nil)
        // Dart's addRule stores such bounds (Fixtures/tags has one), so
        // Swift's does too; only the editor and updateRule refuse them.
        exact.minimumAmount = 3
        exact.maximumAmount = 2
        #expect(exact.boundsError == .ruleMinimumAboveMaximum)
        #expect(d.validateRule(exact) == nil)
        try d.addRule(exact, id: "r2")
        #expect(d.rules.map(\.id) == ["r1", "r2"])
    }

    @Test("updateRule and setRuleEnabled edit every readable row with the id")
    func repeatedIDs() throws {
        var d = try data(#"{"categorizationRules":[{"id":"r1","merchantPattern":"a","category":"A","isEnabled":true},7,{"id":"r1","merchantPattern":"b","category":"B"}]}"#)
        let off = d.setRuleEnabled(id: "r1", false)
        #expect(off)
        #expect(text(d.rulesSection()) == #"[{"id":"r1","merchantPattern":"a","category":"A","isEnabled":false},7,{"id":"r1","merchantPattern":"b","category":"B","isEnabled":false}]"#)
        let offAgain = d.setRuleEnabled(id: "r1", false)
        let unknown = d.setRuleEnabled(id: "nope", true)
        #expect(!offAgain && !unknown)
        let on = d.setRuleEnabled(id: "r1", true)
        #expect(on)
        #expect(text(d.rulesSection()) == #"[{"id":"r1","merchantPattern":"a","category":"A","isEnabled":true},7,{"id":"r1","merchantPattern":"b","category":"B","isEnabled":true}]"#)
        var draft = d.rules[1].draft
        draft.category = "C"
        try d.updateRule(id: "r1", draft)
        #expect(d.rules.map(\.category) == ["C", "C"])
    }

    @Test("edited rules suggest as Dart's matches: inclusive bounds, any type, disabled rules skipped")
    func editedRulesSuggest() throws {
        var d = try data(twoTags)
        try d.addRule(RuleDraft(merchantPattern: "Cafe", transactionType: .expense, category: "Coffee"), id: "bounded")
        try d.addRule(RuleDraft(merchantPattern: "cafe", transactionType: .expense, category: "Eating Out"), id: "fallback")
        try d.addRule(RuleDraft(merchantPattern: "Gift", matchType: .startsWith, transactionType: .expense, category: "Gift"), id: "any")
        try d.addRule(RuleDraft(merchantPattern: "salary", transactionType: .income, category: "Salary"), id: "off")

        var bounded = d.rules[0].draft
        bounded.minimumAmount = 5
        bounded.maximumAmount = 20.5
        try d.updateRule(id: "bounded", bounded)
        func suggested(_ type: TransactionType, _ description: String, _ amount: Double) -> String? {
            CategorizationEngine.suggest(rules: d.rules, type: type, description: description, amount: amount)?.id
        }
        // Both bounds inclusive; just outside falls to the next rule.
        #expect(suggested(.expense, "Corner cafe", 5) == "bounded")
        #expect(suggested(.expense, "Corner cafe", 20.5) == "bounded")
        #expect(suggested(.expense, "Corner cafe", 12) == "bounded")
        #expect(suggested(.expense, "Corner cafe", 5.0.nextDown) == "fallback")
        #expect(suggested(.expense, "Corner cafe", 20.5.nextUp) == "fallback")
        #expect(suggested(.expense, "Corner cafe", 0) == "fallback", "an empty amount reads as 0")
        // NaN passes both bounds (every comparison is false), as in Dart.
        #expect(suggested(.expense, "Corner cafe", .nan) == "bounded")
        #expect(suggested(.expense, "Corner cafe", .infinity) == "fallback")

        // Any type: income too.
        #expect(suggested(.income, "Gift from Sam", 10) == nil)
        var any = d.rules[2].draft
        any.transactionType = nil
        try d.updateRule(id: "any", any)
        #expect(suggested(.income, "Gift from Sam", 10) == "any")
        #expect(suggested(.expense, "gift shop", 10) == "any")

        // Disabled: skipped, and a later match is tried.
        #expect(suggested(.income, "Salary September", 3000) == "off")
        let disabled = d.setRuleEnabled(id: "off", false)
        #expect(disabled)
        #expect(suggested(.income, "Salary September", 3000) == nil)
        let offBounded = d.setRuleEnabled(id: "bounded", false)
        #expect(offBounded)
        #expect(suggested(.expense, "Corner cafe", 12) == "fallback")
        #expect(d.rules.map(\.isEnabled) == [false, true, true, false])
    }
}
