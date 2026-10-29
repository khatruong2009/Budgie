import Foundation
import Testing

@testable import BudgieCore

/// Ids that existed in the input (generated ids differ between runs).
func inputIDs(_ scenario: Scenario) -> Set<String> {
    var ids = Set<String>()
    for (_, bytes) in scenario.fileSystem.snapshot {
        guard let snapshot = StoreFile.decode(bytes) else { continue }
        for section in [Section.transactions, Section.netWorthEntries] {
            for row in snapshot.sections[section]?.arrayValue ?? [] {
                if let id = row.objectValue?["id"]?.stringValue { ids.insert(id) }
            }
        }
    }
    for (_, value) in scenario.preferences.all {
        if case .string(let text) = value, let parsed = try? JSONParser.parse(text) {
            for row in parsed.arrayValue ?? [] {
                if let id = row.objectValue?["id"]?.stringValue { ids.insert(id) }
            }
        }
    }
    return ids
}

/// What the Flutter app shows for a store (the harness `summarize()`:
/// model_summary.dart) against what `data` shows, number for number. `known`
/// limits the row-id comparisons to ids that existed before a launch (or a
/// load of rows without an id) generated its own; nil compares every id.
func assertDartSummary(
    _ data: FinancialData, _ dart: J, known: Set<String>?, now: DartDateTime, label: String, allowUnreadable: Bool = false,
    templateIDsComparable: Bool? = nil
) {
    let calendar = data.calendar
    func isKnown(_ id: String) -> Bool { known?.contains(id) ?? true }
    // Generated template ids only differ when a launch generated some.
    let idsComparable = templateIDsComparable ?? (known == nil || known!.isEmpty)

    #expect(data.transactions.count == dart["transactionCount"].int, "\(label) count")
    #expect(data.unreadableTransactionCount == 0 || allowUnreadable, "\(label) unreadable rows")

    let months = data.availableMonths()
    #expect(months.map { $0.toIso8601String() } == dart["availableMonths"].array.compactMap(\.string), "\(label) months")
    let ledger = data.monthLedger()
    for month in months {
        let key = calendar.netWorthMonthKey(month)
        let expectedMonth = dart["monthly"][key]
        let totals = ledger[calendar.ledgerMonthKey(month)]!
        #expect(totals.income == expectedMonth["totalIncome"].double, "\(label) \(key) income")
        #expect(totals.expenses == expectedMonth["totalExpenses"].double, "\(label) \(key) expenses")
        #expect(totals.net == expectedMonth["summary"]["net"].double, "\(label) \(key) net")
        let categories = expectedMonth["categoryExpenses"]
        #expect(totals.categoryExpenses.map(\.0).sorted() == categories.keys.sorted(), "\(label) \(key) categories")
        for (name, amount) in totals.categoryExpenses {
            #expect(amount == categories[name].double, "\(label) \(key) \(name)")
        }
        let ids = expectedMonth["transactionIds"].array.compactMap(\.string)
        #expect(totals.transactionIDs.filter(isKnown) == ids.filter(isKnown), "\(label) \(key) ids")
        #expect(totals.transactionIDs.count == ids.count, "\(label) \(key) id count")
    }
    let sorted = data.transactionsNewestFirst().map(\.id).filter(isKnown)
    #expect(sorted == dart["sortedIds"].array.compactMap(\.string).filter(isKnown), "\(label) newest-first order")

    #expect(data.selectedNetWorthMonth.toIso8601String() == dart["selectedNetWorthMonth"].string, "\(label) nw month")
    let nwMonths = data.netWorthAvailableMonths(now: now)
    #expect(nwMonths.map { $0.toIso8601String() } == dart["netWorthAvailableMonths"].array.compactMap(\.string), "\(label) nw months")
    for month in nwMonths {
        let key = calendar.netWorthMonthKey(month)
        let e = dart["netWorth"][key]
        #expect(data.totalAssets(forMonth: month) == e["assets"].double, "\(label) \(key) assets")
        #expect(data.totalLiabilities(forMonth: month) == e["liabilities"].double, "\(label) \(key) liabilities")
        #expect(data.netWorth(forMonth: month) == e["netWorth"].double, "\(label) \(key) net worth")
        #expect(data.netWorthChange(forMonth: month) == e["change"].double, "\(label) \(key) change")
        #expect(data.hasNetWorthData(forMonth: month) == e["hasData"].bool, "\(label) \(key) hasData")
        #expect(data.trackedNetWorthEntryCount(forMonth: month) == e["tracked"].int, "\(label) \(key) tracked")
        #expect(data.updatedNetWorthEntryCount(forMonth: month) == e["updated"].int, "\(label) \(key) updated")
        #expect(data.staleNetWorthEntryCount(forMonth: month) == e["stale"].int, "\(label) \(key) stale")
        let entries = data.netWorthEntries(forMonth: month)
        let expectedEntries = e["entries"].array
        #expect(entries.count == expectedEntries.count, "\(label) \(key) entry count")
        for (entry, want) in zip(entries, expectedEntries) {
            if isKnown(entry.id) { #expect(entry.id == want["id"].string, "\(label) \(key) entry order") }
            #expect(entry.amount(forMonth: month, calendar: calendar) == want["amount"].double, "\(label) \(key) entry amount")
        }
    }
    for (limit, field) in [(24, "netWorthHistory24"), (4, "netWorthHistory4")] {
        let points = data.netWorthHistory(limit: limit)
        let want = dart[field].array
        #expect(points.count == want.count, "\(label) \(field) count")
        for (point, w) in zip(points, want) {
            #expect(point.date.toIso8601String() == w["date"].string, "\(label) \(field) date")
            #expect(point.assets == w["assets"].double && point.liabilities == w["liabilities"].double, "\(label) \(field) values")
            #expect(point.assetCount == w["assetCount"].int && point.liabilityCount == w["liabilityCount"].int, "\(label) \(field) counts")
            #expect(point.granularity.rawValue == w["granularity"].string, "\(label) \(field) granularity")
        }
    }

    #expect(data.budgetLimits.map(\.0).sorted() == dart["categoryBudgetLimits"].keys.sorted(), "\(label) budgets")
    for (name, limit) in data.budgetLimits { #expect(limit == dart["categoryBudgetLimits"][name].double, "\(label) budget \(name)") }

    let goals = dart["savingsGoals"].array
    #expect(data.savingsGoals.count == goals.count, "\(label) goals")
    for (goal, want) in zip(data.savingsGoals, goals) {
        #expect(goal.isCompleted == want["isCompleted"].bool, "\(label) goal completed")
        #expect(goal.suggestedMonthlyContribution(now: now) == want["suggestedMonthlyContribution"].double, "\(label) goal")
    }

    let templates = dart["recurring"].array
    #expect(data.templates.count == templates.count, "\(label) templates")
    for (template, want) in zip(data.templates, templates) {
        #expect(template.id == want["id"].string || !idsComparable, "\(label) template id")
        #expect(template.nextOccurrence.toIso8601String() == want["nextOccurrence"].string, "\(label) cursor \(template.description)")
        #expect(template.isActive == want["isActive"].bool, "\(label) template active")
    }

    for month in months {
        let key = calendar.netWorthMonthKey(month)
        let b = SafeToSpend.calculate(
            transactions: data.transactions, templates: data.templates, budgetLimits: data.budgetLimits,
            savingsGoals: data.savingsGoals, month: month, asOf: now, wallClock: now, calendar: calendar)
        let w = dart["safeToSpend"][key]
        #expect(b.month.toIso8601String() == w["month"].string && b.asOf.toIso8601String() == w["asOf"].string, "\(label) \(key) sts dates")
        #expect(b.actualIncome == w["actualIncome"].double, "\(label) \(key) sts actualIncome")
        #expect(b.expectedIncome == w["expectedIncome"].double, "\(label) \(key) sts expectedIncome")
        #expect(b.actualExpenses == w["actualExpenses"].double, "\(label) \(key) sts actualExpenses")
        #expect(b.upcomingRecurringExpenses == w["upcomingRecurringExpenses"].double, "\(label) \(key) sts upcoming")
        #expect(b.flexibleBudgetReserve == w["flexibleBudgetReserve"].double, "\(label) \(key) sts reserve")
        #expect(b.plannedGoalContributions == w["plannedGoalContributions"].double, "\(label) \(key) sts goals")
        #expect(b.daysRemaining == w["daysRemaining"].int, "\(label) \(key) sts days")
        #expect(b.safeToSpend == w["safeToSpend"].double && b.dailyAllowance == w["dailyAllowance"].double, "\(label) \(key) sts result")
    }

    let settings = dart["appSettings"]
    #expect(data.appSettings.baseCurrencyCode == settings["baseCurrencyCode"].string, "\(label) currency")
    #expect(data.appSettings.localeOverride == settings["localeOverride"].string, "\(label) locale")
    #expect(data.appSettings.appLockEnabled == settings["appLockEnabled"].bool, "\(label) lock")
    #expect(data.appSettings.autoLockTimeoutSeconds == settings["autoLockTimeoutSeconds"].int, "\(label) timeout")
    #expect(data.appSettings.hideBalances == settings["hideBalances"].bool, "\(label) hide")

    let widget = data.widgetCashFlow(now: now)
    #expect(widget.amount == dart["widgetCashFlow"]["amount"].double && widget.month == dart["widgetCashFlow"]["month"].string, "\(label) widget")
}

@Suite("Domain: what the app shows matches the Flutter app for every fixture store")
struct DomainParityTests {
    static let cases: [String] =
        storeScenarioNames.map { "store/\($0)" } + legacyScenarioNames.map { "legacy/\($0)" }

    @Test("launch + summary parity", arguments: cases)
    func parity(_ path: String) async throws {
        let url = Fixtures.url(path)
        let scenario = try Scenario(url)
        let expected = try loadExpected(url)
        let dart = expected["appAfterGenerate"]
        guard dart.value != nil else {
            // Dart could not launch either (read error): only this scenario has no Dart data.
            if path != "store/primary_is_directory" { Issue.record("\(path): no appAfterGenerate in expected.json") }
            return
        }
        if blockedLegacyScenarioNames.contains(url.lastPathComponent), path.hasPrefix("legacy/") {
            // Swift deliberately refuses the partial migration Dart performs.
            let before = scenario.preferences.all
            await #expect(throws: FinancialStoreError.self) { try await scenario.makeStore().read() }
            #expect(scenario.fileSystem.snapshot.isEmpty)
            #expect(scenario.preferences.all == before)
            return
        }
        let known = inputIDs(scenario)
        guard let data = try await launch(scenario) else {
            Issue.record("\(path): Swift could not launch but Dart could")
            return
        }
        assertDartSummary(
            data, dart, known: known, now: scenario.launchNow, label: path, allowUnreadable: path.contains("old_schema"))
    }
}

@Suite("Domain: generator and safe-to-spend against Dart in four time zones")
struct LogicParityTests {
    @Test("recurring generator cases", arguments: fixtureZones)
    func generator(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let fixture = try Fixtures.json(zoneDirectory(zone) + "/generator.json")
        for c in fixture["cases"].array {
            let template = RecurringTemplate.parse(c["template"].value!, calendar: calendar, newID: { "x" })!
            var data = FinancialData.load(
                FinancialSnapshot(revision: 0, sections: JSONObject(ordered: [(Section.recurringTransactions, .array([.object(template.raw)]))])),
                preferences: InMemoryPreferences(), calendar: calendar, now: { calendar.date(2026, 1, 1, 12) }, newID: { "id" }
            ).data
            let now = try calendar.parse(c["now"]["iso"].string!)
            _ = RecurringGenerator.generateDue(in: &data, now: now, clock: { now }, newID: { UUID().uuidString })
            let label = "\(zone) \(c["label"].string!) @ \(c["now"]["iso"].string!)"
            #expect(data.transactions.map { $0.date.toIso8601String() } == c["generated"].array.compactMap { $0["date"].string }, "\(label) dates")
            #expect(data.transactions.allSatisfy { $0.recurringTemplateId == template.id && $0.amount == 10.0 }, "\(label) rows")
            #expect(data.templates[0].nextOccurrence.toIso8601String() == c["nextOccurrence"].string, "\(label) cursor")
        }
    }

    @Test("safe-to-spend cases", arguments: fixtureZones)
    func safeToSpend(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let fixture = try Fixtures.json(zoneDirectory(zone) + "/safe_to_spend.json")
        let transactions = fixture["transactions"].array.map { TransactionRecord.parse($0.value!, calendar: calendar, newID: { "x" })! }
        let templates = fixture["recurring"].array.map { RecurringTemplate.parse($0.value!, calendar: calendar, newID: { "x" })! }
        let limits = fixture["limits"].keys.map { ($0, fixture["limits"][$0].double!) }
        for (index, result) in fixture["results"].array.enumerated() {
            let asOfText = result["asOf"].string!
            // The harness pinned the wall clock to asOf before building goals
            // and calculating; asOf itself is the unclamped value it passed.
            let month = try calendar.parse(result["month"].string!)
            let original = LogicParityTests.asOfInputs[index]
            let asOf = try calendar.parse(original)
            let goals = fixture["goals"].array.map { SavingsGoalRecord.parse($0.value!, calendar: calendar, now: asOf, newID: { "g" })! }
            let b = SafeToSpend.calculate(
                transactions: transactions, templates: templates, budgetLimits: limits, savingsGoals: goals,
                month: month, asOf: asOf, wallClock: asOf, calendar: calendar)
            let label = "\(zone) \(original)"
            #expect(b.asOf.toIso8601String() == asOfText, "\(label) asOf")
            #expect(b.actualIncome == result["actualIncome"].double, "\(label) actualIncome")
            #expect(b.expectedIncome == result["expectedIncome"].double, "\(label) expectedIncome")
            #expect(b.actualExpenses == result["actualExpenses"].double, "\(label) actualExpenses")
            #expect(b.upcomingRecurringExpenses == result["upcomingRecurringExpenses"].double, "\(label) upcoming")
            #expect(b.flexibleBudgetReserve == result["flexibleBudgetReserve"].double, "\(label) reserve")
            #expect(b.plannedGoalContributions == result["plannedGoalContributions"].double, "\(label) goals")
            #expect(b.daysRemaining == result["daysRemaining"].int, "\(label) days")
            #expect(b.safeToSpend == result["safeToSpend"].double, "\(label) result")
            #expect(b.dailyAllowance == result["dailyAllowance"].double, "\(label) daily")
        }
    }

    /// The `asOf` values the harness passed (logic_fixtures_test.dart), in order.
    static let asOfInputs = [
        "2026-03-08T10:30:00.000", "2026-03-01T00:00:00.000", "2026-03-31T23:59:00.000",
        "2026-03-08T10:30:00.000", "2026-03-08T10:30:00.000", "2026-11-01T08:00:00.000",
        "2026-11-02T00:00:00.000", "2026-10-04T12:00:00.000",
    ]

    @Test("newest-first ordering")
    func ordering() throws {
        let calendar = DartCalendar(timeZone: TimeZone(identifier: "UTC")!)
        let fixture = try Fixtures.json("logic/ordering.json")
        let rows = fixture["transactions"].array.map { TransactionRecord.parse($0.value!, calendar: calendar, newID: { "x" })! }
        let sorted = rows.sorted { TransactionRecord.newestFirst($0, $1, calendar: calendar) }
        #expect(sorted.map(\.id) == fixture["newestFirst"].array.compactMap(\.string))
    }
}

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

@Suite("Safe-to-spend: randomized differential corpus against the Dart calculator")
struct SafeToSpendRandomTests {
    @Test("400 random scenarios per zone", arguments: fixtureZones)
    func random(zone: String) throws {
        let calendar = DartCalendar(timeZone: TimeZone(identifier: zone)!)
        let fixture = try Fixtures.json(zoneDirectory(zone) + "/safe_to_spend_random.json")
        let cases = fixture["cases"].array
        #expect(cases.count == 400)
        var failures: [String] = []
        for (index, c) in cases.enumerated() {
            let asOf = try calendar.parse(c["asOf"].string!)
            let month = try calendar.parse(c["month"].string!)
            let transactions = c["transactions"].array.map { TransactionRecord.parse($0.value!, calendar: calendar, newID: { "x" })! }
            let templates = c["recurring"].array.map { RecurringTemplate.parse($0.value!, calendar: calendar, newID: { "x" })! }
            let limits = c["limits"].keys.map { ($0, c["limits"][$0].double!) }
            let goals = c["goals"].array.map { SavingsGoalRecord.parse($0.value!, calendar: calendar, now: asOf, newID: { "g" })! }
            let b = SafeToSpend.calculate(
                transactions: transactions, templates: templates, budgetLimits: limits, savingsGoals: goals,
                month: month, asOf: asOf, wallClock: asOf, calendar: calendar)
            let w = c["result"]
            let pairs: [(String, Double?, Double?)] = [
                ("actualIncome", b.actualIncome, w["actualIncome"].double),
                ("expectedIncome", b.expectedIncome, w["expectedIncome"].double),
                ("actualExpenses", b.actualExpenses, w["actualExpenses"].double),
                ("upcoming", b.upcomingRecurringExpenses, w["upcomingRecurringExpenses"].double),
                ("reserve", b.flexibleBudgetReserve, w["flexibleBudgetReserve"].double),
                ("goals", b.plannedGoalContributions, w["plannedGoalContributions"].double),
                ("safeToSpend", b.safeToSpend, w["safeToSpend"].double),
                ("daily", b.dailyAllowance, w["dailyAllowance"].double),
                ("days", Double(b.daysRemaining), w["daysRemaining"].double),
            ]
            for (name, swift, dart) in pairs where swift != dart {
                failures.append("#\(index) \(name): swift \(String(describing: swift)) dart \(String(describing: dart))")
            }
            if b.asOf.toIso8601String() != w["asOf"].string || b.month.toIso8601String() != w["month"].string {
                failures.append("#\(index) dates: swift \(b.asOf.toIso8601String()) dart \(w["asOf"].string ?? "")")
            }
        }
        #expect(failures.isEmpty, "\(zone): \(failures.count) mismatches, first: \(failures.prefix(10))")
    }
}
