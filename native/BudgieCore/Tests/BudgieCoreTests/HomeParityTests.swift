import Foundation
import Testing

@testable import BudgieCore

/// Loads a `FinancialData` from raw sections, as the app does at launch.
func homeData(_ sections: JSONObject, zone: TimeZone = Scenario.zone) -> FinancialData {
    let calendar = DartCalendar(timeZone: zone)
    let now = calendar.date(2026, 9, 28, 9, 15)
    return FinancialData.load(
        FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences([:]), calendar: calendar,
        now: { now }, newID: { UUID().uuidString.lowercased() }
    ).data
}

private func fixture(_ name: String) throws -> J {
    try Fixtures.json("home/\(name)")
}

private func bits(_ value: J) -> Double? {
    value.string.flatMap { UInt64($0, radix: 16) }.map { Double(bitPattern: $0) }
}

private func hex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}

private func pairs(_ limits: [(String, Double)]) -> [[UInt16]] {
    limits.map { Array($0.0.utf16) + [0] + Array(hex($0.1).utf16) }
}

private func pairs(_ memory: J) -> [[UInt16]] {
    memory.array.map { Array($0[0].string!.utf16) + [0] + Array($0[1].string!.utf16) }
}

@Suite("Home: budgets, deltas, rules and number parsing match the Flutter code (Fixtures/home)")
struct HomeParityTests {
    /// Each Dart call and the Swift mutation agree on whether a write is due
    /// and on the limits Dart holds afterwards (names as UTF-16, values as
    /// bits). Where Dart's whole-map rewrite and Swift's in-place patch
    /// coincide (every stored value already a positive double lexeme, no
    /// repeated keys), the written section is byte-identical.
    @Test("budget limit set/remove sequences")
    func budgetMutations() throws {
        let cases = try fixture("budget_mutations.json")["cases"].array
        #expect(cases.count == 4)
        for c in cases {
            let label = c["label"].string!
            var sections = JSONObject()
            if let initial = c["initial"].string {
                sections[Section.categoryBudgetLimits] = try JSONParser.parse(initial)
            }
            var data = homeData(sections)
            #expect(pairs(data.budgetLimits) == pairs(c["loaded"]["memory"]), "\(label) load")
            let byteComparable = label == "double lexemes" || label == "absent section"
            for (index, step) in c["steps"].array.enumerated() {
                let category = step["category"].string!
                let wrote: Bool
                if step["op"].string == "set" {
                    wrote = data.setBudgetLimit(category: category, limit: bits(step["limit"])!)
                } else {
                    wrote = data.removeBudgetLimit(category: category)
                }
                #expect(wrote == step["wrote"].bool, "\(label) step \(index)")
                #expect(pairs(data.budgetLimits) == pairs(step["memory"]), "\(label) step \(index) memory")
                if byteComparable, let dart = step["section"].string {
                    let swift = DartJSON.encodeString(data.budgetLimitsSection())
                    #expect(Array(swift.utf16) == Array(dart.utf16), "\(label) step \(index): \(swift) vs \(dart)")
                }
                // What Swift wrote loads in Dart's terms as the same limits.
                var reloaded = JSONObject()
                reloaded[Section.categoryBudgetLimits] = data.budgetLimitsSection()
                #expect(pairs(homeData(reloaded).budgetLimits) == pairs(step["memory"]), "\(label) step \(index) reload")
            }
        }
    }

    @Test("budget rows, EDIT and Add lists, and the expense category order")
    func budgetRows() throws {
        let f = try fixture("budget_rows.json")
        let data = homeData(try JSONParser.parse(f["sections"].string!).objectValue!)
        let ledger = LedgerIndex.build(data.transactions, calendar: data.calendar)

        #expect(data.categoryPicker(for: .expense).map(\.name) == f["expenseCategories"].array.map { $0.string! })
        #expect(pairs(data.budgetLimits) == pairs(f["limits"]))
        #expect(data.budgetedCategories().map(\.name) == f["budgeted"].array.map { $0.string! })
        #expect(data.unbudgetedCategories().map(\.name) == f["unbudgeted"].array.map { $0.string! })

        let months = f["months"].array
        #expect(months.count == 4)
        for m in months {
            let month = try data.calendar.parse(m["month"].string!)
            let swift = data.budgetProgress(ledger.summary(forMonth: month))
            let dart = m["rows"].array
            #expect(swift.map(\.category) == dart.map { $0["category"].string! }, "\(m["month"].string!)")
            for (s, d) in zip(swift, dart) {
                #expect(s.spent.bitPattern == bits(d["spent"])!.bitPattern, "\(s.category) spent")
                #expect(s.limit.bitPattern == bits(d["limit"])!.bitPattern, "\(s.category) limit")
                #expect(s.remaining.bitPattern == bits(d["remaining"])!.bitPattern, "\(s.category) remaining")
                #expect(s.progress.bitPattern == bits(d["progress"])!.bitPattern, "\(s.category) progress")
                #expect(s.isOver == d["isOver"].bool, "\(s.category) isOver")
                let status: String = switch s.status {
                case .ok: "ok"
                case .warning: "warning"
                case .over: "over"
                }
                #expect(status == d["status"].string, "\(s.category) status")
            }
            // The one-pass overview Home reads agrees with the separate queries.
            let overview = data.budgetOverview(ledger.summary(forMonth: month))
            #expect(overview.progress == swift)
            #expect(overview.budgeted.map(\.id) == data.budgetedCategories().map(\.id))
            #expect(overview.unbudgeted.map(\.id) == data.unbudgetedCategories().map(\.id))
            for info in overview.budgeted + overview.unbudgeted {
                #expect(overview.limit(for: info.name) == data.budgetLimit(for: info.name), "\(info.name) limit")
            }
        }
    }

    @Test("percent deltas, delta labels, previous month")
    func deltas() throws {
        let f = try fixture("deltas.json")
        let deltas = f["deltas"].array
        #expect(deltas.count > 50)
        for d in deltas {
            let current = bits(d["current"])!, previous = bits(d["previous"])!
            let swift = HomeSummary.percentDelta(current: current, previous: previous)
            if d["delta"].isNull {
                #expect(swift == nil, "\(current) \(previous)")
            } else {
                #expect(swift?.bitPattern == bits(d["delta"]["bits"])!.bitPattern, "\(current) \(previous)")
            }
            #expect(HomeSummary.deltaLabel(delta: swift, previousMonthName: "August") == d["label"].string, "\(current) \(previous)")
        }
        let calendar = DartCalendar(timeZone: Scenario.zone)
        for p in f["previousMonths"].array {
            let month = try calendar.parse(p["month"].string!)
            let previous = HomeSummary.previousMonth(of: month, calendar: calendar)
            #expect(previous.toIso8601String() == p["previous"].string)
            #expect(DartDateFormat.MMMM(previous) == p["label"].string)
        }
    }

    @Test("rule matching and suggestions over a query corpus")
    func rules() throws {
        let f = try fixture("rules.json")
        let rules = try JSONParser.parse(f["rules"].string!).arrayValue!.map {
            CategorizationRuleRecord.parse($0, newID: { "generated" })!
        }
        let stable = rules.enumerated().sorted {
            $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset
        }
        #expect(stable.map(\.element.id) == f["sortedIds"].array.map { $0.string! })

        let queries = f["queries"].array
        #expect(queries.count == 2 * 23 * 10)
        for q in queries {
            let type: TransactionType = q["type"].string == "income" ? .income : .expense
            let description = q["description"].string!
            let amount = bits(q["amount"])!
            let label = "\(type) \(Array(description.unicodeScalars)) \(amount)"
            let matching = rules.filter { $0.matches(type: type, description: description, amount: amount) }.map(\.id)
            #expect(matching == q["matches"].array.map { $0.string! }, "\(label)")
            let suggestion = CategorizationEngine.suggest(rules: rules, type: type, description: description, amount: amount)
            #expect(suggestion?.id == q["suggestion"].string, "\(label)")
        }
    }

    @Test("double.tryParse over an adversarial corpus")
    func tryParse() throws {
        let cases = try fixture("try_parse.json")["cases"].array
        #expect(cases.count > 100)
        for c in cases {
            let input = c["input"].string!
            let swift = DartDouble.tryParse(input)
            let label = "\(Array(input.unicodeScalars.prefix(40)))"
            if c["result"].isNull {
                #expect(swift == nil, "\(label)")
            } else if c["result"]["isNaN"].bool == true {
                #expect(swift?.isNaN == true, "\(label)")
            } else {
                #expect(swift?.bitPattern == bits(c["result"]["bits"])!.bitPattern, "\(label)")
            }
        }
    }
}
