import Foundation
import Testing

@testable import BudgieCore

private func fixture() throws -> J {
    try Fixtures.json("tags/mutations.json")
}

private let sections = [Section.transactionTags, Section.categorizationRules]

private func line(_ values: [JSONValue]) -> String { DartJSON.encodeString(.array(values)) }
private func optional(_ text: String?) -> JSONValue { text.map { .string($0) } ?? .null }

/// The generator's `memory()`: tags in stored order, rules in Dart's
/// `rules` order (`rulesByPriority`), numbers as Dart's `toString`.
private func memory(_ data: FinancialData) -> [String: [String]] {
    [
        "tags": data.tags.map { line([.string($0.id), .string($0.name), .string($0.colorToken)]) },
        "rules": data.rulesByPriority.map { r in
            line([
                .string(r.id), .string(r.merchantPattern), .string(r.matchType.rawValue), optional(r.transactionType?.rawValue),
                optional(r.minimumAmount.map(DartDouble.format)), optional(r.maximumAmount.map(DartDouble.format)),
                .string(r.category), .array(r.tagIds.map { .string($0) }), .int(r.priority), .bool(r.isEnabled),
            ])
        },
    ]
}

private func memory(_ j: J) -> [String: [String]] {
    ["tags": j["tags"].array.map { $0.string! }, "rules": j["rules"].array.map { $0.string! }]
}

private func load(_ sections: JSONObject, ids: [String] = []) -> FinancialData.LoadResult {
    let calendar = DartCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
    let now = calendar.date(2026, 9, 28, 9, 15, 30, 250, 125)
    var queue = ids
    return FinancialData.load(
        FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences([:]), calendar: calendar,
        now: { now }, newID: { queue.isEmpty ? "unexpected-\(UUID().uuidString.lowercased())" : queue.removeFirst() })
}

private func type(_ j: J) -> TransactionType? {
    switch j.string {
    case "expense": .expense
    case "income": .income
    default: nil
    }
}

/// The steps' rule, as the Dart `CategorizationRule` it recorded.
private func draft(_ step: J) -> RuleDraft {
    RuleDraft(
        merchantPattern: step["merchantPattern"].string!, matchType: MerchantMatchType(rawValue: step["matchType"].string!)!,
        transactionType: type(step["transactionType"]), minimumAmount: step["minimumAmount"].double,
        maximumAmount: step["maximumAmount"].double, category: step["category"].string!,
        tagIds: step["tagIds"].array.map { $0.string! }, priority: step["priority"].int!, isEnabled: step["isEnabled"].bool!)
}

@Suite("Tags and rules: add and delete match the Flutter app (Fixtures/tags)")
struct TagsRulesParityTests {
    /// Real `CategorizationProvider` calls through a real store, replayed on
    /// `FinancialData`: the same error copy; Swift writes (one commit) when
    /// and only when Dart's stored content changed; the section bytes are
    /// identical for data Dart wrote itself; the memory (`rules` in the
    /// getter's order) and `suggest` agree; what Swift wrote loads back
    /// unchanged. From 34 tied rules Dart's sort reorders ties; `DartSort`
    /// reproduces that order (the `sort_*` scenarios).
    @Test("mutation scenarios")
    func mutations() throws {
        let f = try fixture()
        #expect(f["tz"].string == "America/New_York")
        let scenarios = f["scenarios"].array
        #expect(scenarios.map { $0["name"].string! } == [
            "canonical", "names_unicode", "typical", "sort_33_tied", "sort_34_tied", "sort_40_mixed", "sort_70_tied", "foreign",
            "malformed",
        ])
        var deleteTags = 0, noOps = 0, probes = 0, unstableSortSteps = 0
        for s in scenarios where s["name"].string != "malformed" {
            let name = s["name"].string!
            let byteComparable = s["byteComparable"].bool!
            let initial = try JSONParser.parse(s["initialSections"].string!).objectValue!
            var data = load(initial, ids: s["launched"]["generatedIds"].array.map { $0.string! }).data
            // Dart's List.sort is stable only up to 33 elements.
            var dartSortUnstable: Bool { data.rules.count >= 34 }

            var expected: [String: String] = [:]
            for section in sections {
                if let json = s["launched"]["sections"][section].string { expected[section] = json }
            }
            func compareMemory(_ want: J, _ at: String) {
                let swift = memory(data), dart = memory(want)
                #expect(swift["tags"] == dart["tags"], "\(at) tags")
                // DartSort: Dart's tie order also from 34 rules.
                if dartSortUnstable { unstableSortSteps += 1 }
                #expect(swift["rules"] == dart["rules"], "\(at) rules")
            }
            compareMemory(s["launched"]["memory"], "\(name) launch")
            if byteComparable {
                for (section, json) in expected {
                    #expect(Array(DartJSON.encodeString(data.serializedSection(section)!).utf16) == Array(json.utf16), "\(name) launch \(section)")
                }
            }

            for (index, step) in s["steps"].array.enumerated() {
                let op = step["op"].string!
                let at = "\(name) step \(index) \(op) \(step["id"].string ?? step["name"].string ?? "")"
                var changed: [String] = []
                var message: String?
                switch op {
                case "addTag":
                    do {
                        try data.addTag(name: step["name"].string!, colorToken: step["colorToken"].string!, id: step["newId"].string ?? "unused")
                        changed = [Section.transactionTags]
                    } catch {
                        message = error.message
                    }
                case "deleteTag":
                    changed = data.deleteTag(id: step["id"].string!)
                    deleteTags += 1
                    // Dart: two commits (tags, then rules), even for an unknown id.
                    #expect(step["commits"].int == 2, "\(at) Dart commits")
                case "addRule":
                    do {
                        let rule = try data.addRule(draft(step), id: step["id"].string!)
                        #expect(rule.id == step["id"].string, "\(at) id")
                        changed = [Section.categorizationRules]
                    } catch {
                        message = error.message
                    }
                case "deleteRule":
                    changed = data.deleteRule(id: step["id"].string!) ? [Section.categorizationRules] : []
                case "check":
                    for probe in step["probes"].array {
                        let swift = CategorizationEngine.suggest(
                            rules: data.rules, type: type(probe["type"])!, description: probe["description"].string!,
                            amount: probe["amount"].double!)
                        #expect(swift?.id == probe["rule"].string, "\(at) \(probe["description"].string!) \(probe["amount"].double!)")
                        probes += 1
                    }
                default:
                    Issue.record("unknown op \(op)")
                }
                #expect(message == step["error"].string, "\(at) error")

                // Swift writes exactly when Dart's stored content changed.
                let dartChanged = step["sections"].keys
                if op == "deleteTag" {
                    #expect(changed == (dartChanged.isEmpty ? [] : sections), "\(at) sections \(dartChanged)")
                } else {
                    #expect(changed == dartChanged, "\(at) sections")
                }
                if changed.isEmpty && op != "check" && message == nil { noOps += 1 }

                for section in dartChanged { expected[section] = step["sections"][section].string! }
                if byteComparable {
                    for (section, json) in expected {
                        let swift = DartJSON.encodeString(data.serializedSection(section)!)
                        #expect(Array(swift.utf16) == Array(json.utf16), "\(at) \(section):\n\(swift.prefix(700))\n\(json.prefix(700))")
                    }
                }
                compareMemory(step["memory"], at)

                // What Swift wrote loads back as the same memory.
                if !changed.isEmpty {
                    var written = initial
                    for section in sections { written[section] = data.serializedSection(section)! }
                    let reloaded = load(written).data
                    #expect(memory(reloaded) == memory(data), "\(at) reload")
                }
            }
        }
        #expect(deleteTags == 9 && noOps == 2 && probes == 75 && unstableSortSteps == 14, "\(deleteTags) \(noOps) \(probes) \(unstableSortSteps)")
    }

    /// Dart loads tags and rules all or nothing: one row its casts reject
    /// (a numeric id, a string row, a numeric transactionType) empties the
    /// list, and its next write of the section destroys the stored rows.
    /// Swift keeps the readable rows and the unreadable ones verbatim
    /// (PARITY_GAPS); new rows are the same bytes Dart writes.
    @Test("malformed rows: Dart drops the whole list, Swift keeps every row")
    func malformed() throws {
        let s = try fixture()["scenarios"].array.first { $0["name"].string == "malformed" }!
        let initial = try JSONParser.parse(s["initialSections"].string!).objectValue!
        var data = load(initial).data
        #expect(memory(s["launched"]["memory"]) == ["tags": [], "rules": []])
        #expect(data.tags.map(\.id) == ["m1"] && data.rules.map(\.id) == ["mr1"])
        let storedTags = initial[Section.transactionTags]!.arrayValue!
        let storedRules = initial[Section.categorizationRules]!.arrayValue!

        let steps = s["steps"].array
        try data.addTag(name: "New", id: steps[0]["newId"].string!)
        let dartTags = try JSONParser.parse(steps[0]["sections"][Section.transactionTags].string!).arrayValue!
        #expect(dartTags.count == 1)
        #expect(data.tagsSection() == .array(storedTags + dartTags))

        let deleted = data.deleteRule(id: "mr1")
        #expect(deleted)
        #expect(steps[1]["sections"][Section.categorizationRules].string == "[]")
        #expect(data.rulesSection() == .array(Array(storedRules.dropFirst())))
    }

    /// The real page's "New merchant rule" dialog (text, chips tapped Home
    /// then Work, other fields left at their defaults) stores exactly what
    /// `RuleDraft` makes; a case variant of a tag shows Flutter's copy.
    @Test("canary: the page's rule shape and duplicate-tag copy")
    func canary() throws {
        let c = try fixture()["canary"]
        let tagIDs = c["tagIds"].array.map { $0.string! }
        var data = load(JSONObject()).data
        try data.addTag(name: "Work", id: tagIDs[0])
        try data.addTag(name: "Home", id: tagIDs[1])
        let stored = try JSONParser.parse(c["rules"].string!).arrayValue!
        let id = stored[0].objectValue!["id"]!.stringValue!
        #expect(c["firstExpenseCategory"].string == data.categoryPicker(for: .expense).first?.name)
        try data.addRule(
            RuleDraft(
                merchantPattern: "  Whole Foods ", transactionType: .expense, category: c["firstExpenseCategory"].string!,
                tagIds: [tagIDs[1], tagIDs[0]]), id: id)
        #expect(DartJSON.encodeString(data.rulesSection()) == c["rules"].string)
        #expect(data.validateTagName(" work ")?.message == c["duplicateSnackBar"].string)
    }
}
