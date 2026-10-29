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

    let index = LedgerIndex.build(data.transactions, calendar: calendar)
    let months = index.availableMonths
    #expect(months.map { $0.toIso8601String() } == dart["availableMonths"].array.compactMap(\.string), "\(label) months")
    for month in months {
        let key = calendar.netWorthMonthKey(month)
        let expectedMonth = dart["monthly"][key]
        let totals = index.summary(forMonth: month)
        #expect(totals.income == expectedMonth["totalIncome"].double, "\(label) \(key) income")
        #expect(totals.expenses == expectedMonth["totalExpenses"].double, "\(label) \(key) expenses")
        #expect(totals.net == expectedMonth["summary"]["net"].double, "\(label) \(key) net")
        let categories = expectedMonth["categoryExpenses"]
        #expect(totals.categoryExpenses.map(\.0).sorted() == categories.keys.sorted(), "\(label) \(key) categories")
        for (name, amount) in totals.categoryExpenses {
            #expect(amount == categories[name].double, "\(label) \(key) \(name)")
        }
        let ids = expectedMonth["transactionIds"].array.compactMap(\.string)
        #expect(totals.transactionCount == ids.count, "\(label) \(key) id count")
        #expect(
            data.transactions.filter { calendar.ledgerMonthKey($0.date) == calendar.ledgerMonthKey(month) }.map(\.id).filter(isKnown)
                == ids.filter(isKnown),
            "\(label) \(key) ids")
    }
    let sorted = index.newestFirst.map(\.id).filter(isKnown)
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
