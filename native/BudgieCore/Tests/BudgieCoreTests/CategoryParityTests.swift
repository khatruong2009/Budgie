import Foundation
import Testing

@testable import BudgieCore

private func fixture(_ name: String) throws -> J {
    try Fixtures.json("categories/\(name)")
}

/// The sections a category edit can write, in commit order.
private let cascadeSections = [
    Section.categories, Section.transactions, Section.categoryBudgetLimits, Section.recurringTransactions,
    Section.categorizationRules,
]

private func line(_ values: [JSONValue]) -> String { DartJSON.encodeString(.array(values)) }
private func string(_ text: String?) -> JSONValue { text.map { .string($0) } ?? .null }

/// The generator's `memory()`: one JSON line per row, as Dart's models hold
/// them (categories in stored order, pickers, budgets as Dart's `toString`,
/// templates in stored order, rules by id).
private func memory(_ data: FinancialData, transactions: Bool) -> [String: [String]] {
    var result: [String: [String]] = [
        "categories": data.categories.map {
            line([.string($0.id), .string($0.type.rawValue), .string($0.name), .string($0.iconIdentifier),
                  .string($0.colorToken), .int($0.sortOrder), .bool($0.isArchived), .bool($0.isBuiltIn)])
        },
        "expensePicker": [line(data.categoryPicker(for: .expense).map { .string($0.name) })],
        "incomePicker": [line(data.categoryPicker(for: .income).map { .string($0.name) })],
        "budgets": [line(data.budgetLimits.map { .array([.string($0.0), .string(DartDouble.format($0.1))]) })],
        "templates": data.templates.map { line([.string($0.id), .string($0.type.rawValue), .string($0.category)]) },
        "rules": data.rules.sorted { DartString.precedes($0.id, $1.id) }.map {
            line([.string($0.id), string($0.transactionType?.rawValue), .string($0.category)])
        },
    ]
    if transactions {
        result["transactions"] = data.transactions.map {
            line([.string($0.id), .string($0.type.rawValue), .string($0.category), .string($0.updatedAt.toIso8601String())])
        }
    }
    return result
}

private func memory(_ j: J) -> [String: [String]] {
    var result: [String: [String]] = [:]
    for key in j.keys {
        if let single = j[key].string { result[key] = [single] } else { result[key] = j[key].array.map { $0.string! } }
    }
    return result
}

private let zone = TimeZone(identifier: "America/New_York")!

private func load(_ sections: JSONObject, now: DartDateTime) -> FinancialData.LoadResult {
    FinancialData.load(
        FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences([:]),
        calendar: DartCalendar(timeZone: zone), now: { now }, newID: { "unexpected-\(UUID().uuidString.lowercased())" })
}

/// One recorded op applied to `data` (the edit with Flutter's rule pass
/// when `flutterRules`).
private func apply(
    _ step: J, to data: inout FinancialData, now: DartDateTime, flutterRules: Bool = false
) throws(CategoryEditError) -> CategoryEditResult {
    switch step["op"].string! {
    case "add":
        // Dart's id is "<type>-<uuid>" when the slug is taken; `newID` is the uuid.
        let type: TransactionType = step["type"].string == "income" ? .income : .expense
        return try data.addCategory(
            type: type, name: step["name"].string!, iconIdentifier: step["icon"].string!, colorToken: step["color"].string!,
            newID: { String((step["newId"].string ?? "unused").dropFirst(type.rawValue.count + 1)) })
    case "edit":
        return try data.updateCategory(
            id: step["id"].string!, name: step["name"].string!, iconIdentifier: step["icon"].string!,
            colorToken: step["color"].string!, now: now, restrictRulesByType: !flutterRules)
    case "archive":
        return try data.setCategoryArchived(id: step["id"].string!, step["archived"].bool!)
    case "move":
        return data.moveCategory(id: step["id"].string!, offset: step["offset"].int!)
    default:
        Issue.record("unknown op \(step["op"].string!)")
        return .unchanged
    }
}

@Suite("Categories: add, edit (with the rename cascade), archive and move match the Flutter app (Fixtures/categories)")
struct CategoryParityTests {
    /// Real `CategoryProvider` calls and the Categories page's save path
    /// (updateCategory + the three rename passes) through a real store,
    /// replayed on `FinancialData`: the same errors, the one commit Swift
    /// writes covers exactly the sections Dart changed, the stored bytes of
    /// all five sections are identical for data Dart wrote itself, the
    /// models' memory agrees, and what Swift wrote loads back unchanged with
    /// nothing for the launch pass to add. D6 (rules of the other type keep
    /// their name) is the one expected difference: at those steps Swift with
    /// Flutter's rule pass reproduces Dart's real rules section.
    @Test("mutation scenarios")
    func mutations() throws {
        let f = try fixture("mutations.json")
        #expect(f["tz"].string == "America/New_York")
        let calendar = DartCalendar(timeZone: zone)
        let scenarios = f["scenarios"].array
        #expect(scenarios.map { $0["name"].string! } == [
            "add", "edit", "archive_move", "cascade", "foreign", "sequence_11", "sequence_22", "sequence_33",
        ])
        var d6Steps = 0, cascades = 0
        for s in scenarios {
            let name = s["name"].string!
            let byteComparable = s["byteComparable"].bool!
            let launch = try calendar.parse(s["launch"].string!)
            let initial = try JSONParser.parse(s["initialSections"].string!).objectValue!
            let loaded = load(initial, now: launch)
            var data = loaded.data

            // The launch pass (materialisation, sort orders) agrees.
            var expected: [String: String] = [:]
            for section in cascadeSections {
                if let json = s["launched"]["sections"][section].string { expected[section] = json }
            }
            var lastMemory = memory(s["launched"]["memory"])
            #expect(memory(data, transactions: !byteComparable) == lastMemory, "\(name) launch memory")
            if byteComparable {
                for (section, json) in expected {
                    let swift = DartJSON.encodeString(data.serializedSection(section)!)
                    #expect(Array(swift.utf16) == Array(json.utf16), "\(name) launch \(section)")
                }
            }

            for (index, step) in s["steps"].array.enumerated() {
                let at = "\(name) step \(index) \(step["op"].string!) \(step["id"].string ?? step["name"].string ?? "")"
                let now = try calendar.parse(step["now"].string!)
                let before = data

                var result = CategoryEditResult.unchanged
                var message: String?
                do {
                    result = try apply(step, to: &data, now: now)
                } catch {
                    message = error.message
                }
                #expect(message == step["error"].string, "\(at) error")
                if message != nil { #expect(DartJSON.encode(data.categoriesSection()) == DartJSON.encode(before.categoriesSection()), "\(at) untouched") }
                #expect(result.changedSections == step["changedSections"].array.map { $0.string! }, "\(at) sections")
                #expect(step["wrote"].bool == !result.changedSections.isEmpty, "\(at) wrote")
                if step["op"].string == "add", let newID = step["newId"].string {
                    #expect(result.category?.id == newID, "\(at) id")
                }
                if result.rename != nil { cascades += 1 }

                // D6 isolated: Flutter's rule pass gives Dart's real rules.
                if step["d6"].bool == true {
                    d6Steps += 1
                    var flutter = before
                    _ = try? apply(step, to: &flutter, now: now, flutterRules: true)
                    let dartRules = step["dartRules"].string!
                    if byteComparable {
                        let swift = DartJSON.encodeString(flutter.rulesSection())
                        #expect(Array(swift.utf16) == Array(dartRules.utf16), "\(at) Flutter rule pass")
                    }
                    let dartCategories = try JSONParser.parse(dartRules).arrayValue!.map { row in
                        [row.objectValue!["id"]!.stringValue!, row.objectValue!["category"]?.stringValue ?? "General"]
                    }
                    #expect(flutter.rules.map { [$0.id, $0.category] } == dartCategories, "\(at) Flutter rule pass categories")
                    #expect(DartJSON.encode(data.rulesSection()) != DartJSON.encode(flutter.rulesSection()), "\(at) D6 differs")
                }

                for section in step["sections"].keys { expected[section] = step["sections"][section].string! }
                if byteComparable {
                    for (section, json) in expected {
                        let swift = DartJSON.encodeString(data.serializedSection(section)!)
                        #expect(Array(swift.utf16) == Array(json.utf16), "\(at) \(section):\n\(swift.prefix(600))\n\(json.prefix(600))")
                    }
                }
                if !step["memory"].isNull { lastMemory = memory(step["memory"]) }
                #expect(memory(data, transactions: !byteComparable) == lastMemory, "\(at) memory")

                // What Swift wrote loads back as the same memory. The launch
                // pass may append definitions only for names in use that
                // have none, as Flutter's does on the same bytes: a padded
                // legacy name at every launch (typical's "  Padded Cat "),
                // or a case variant a rename left behind ("gift" after
                // "Gift" became "Presents"); nothing is renumbered.
                if !result.changedSections.isEmpty {
                    var written = initial
                    for section in Section.all { written[section] = data.serializedSection(section)! }
                    let reloaded = load(written, now: now)
                    var want = memory(data, transactions: !byteComparable)
                    var got = memory(reloaded.data, transactions: !byteComparable)
                    let extras = reloaded.data.categories.dropFirst(data.categories.count)
                    #expect(extras.allSatisfy { !data.containsCategory(type: $0.type, name: $0.name) }, "\(at) reload adds \(extras.map(\.name))")
                    if extras.isEmpty {
                        #expect(reloaded.pendingWrites.isEmpty, "\(at) reload writes \(reloaded.pendingWrites.map(\.0))")
                    } else {
                        got["categories"] = Array(got["categories"]!.prefix(data.categories.count))
                        for key in ["expensePicker", "incomePicker"] { got[key] = nil; want[key] = nil }
                    }
                    #expect(got == want, "\(at) reload")
                }
            }
        }
        #expect(d6Steps >= 6, "the fixtures exercise D6")
        #expect(cascades >= 20, "the fixtures exercise the cascade")
    }

    @Test("the editor's icon registry order and colour tokens")
    func catalog() throws {
        let f = try fixture("catalog.json")
        #expect(CategoryCatalog.iconIdentifiers == f["iconIdentifiers"].array.map { $0.string! })
        #expect(CategoryCatalog.colorTokens == f["colorTokens"].array.map { $0.string! })
        #expect(CategoryCatalog.iconIdentifiers.count == 18 && CategoryCatalog.colorTokens.count == 8)
        // Every registered identifier has its own glyph; only unknown ones fall back.
        for identifier in CategoryCatalog.iconIdentifiers where identifier != "square_grid_2x2" {
            #expect(CategoryCatalog.symbol(for: identifier) != CategoryCatalog.symbol(for: "unknown"), "\(identifier)")
        }
    }
}
