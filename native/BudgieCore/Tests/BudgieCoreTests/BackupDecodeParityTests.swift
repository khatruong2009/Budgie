import Foundation
import Testing

@testable import BudgieCore

@Suite("Backup: decode matches Flutter's decodeBackup, check by check (Fixtures/backup)")
struct BackupDecodeParityTests {
    /// Where Swift differs on purpose (PARITY_GAPS, D10 list).
    static func deviation(_ name: String) -> BackupError? {
        switch name {
        // JSON nested deeper than JSONParser's 128 levels.
        case "deep nesting 200": .notABackup
        default: nil
        }
    }

    @Test("every corpus file: same message, or the same decoded rows and settings", arguments: backupZones)
    func decode(_ zone: String) throws {
        let timeZone = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: timeZone)
        let fixture = try backupFixture(zone, "decode.json")
        let now = try DartDateTime.parse(fixture["now"].string!, timeZone: timeZone)
        let cases = fixture["cases"].array
        #expect(cases.count > 140)
        for item in cases {
            let name = item["name"].string!
            let bytes = base64Bytes(item["file"])
            var counter = 0
            let result = Result { () throws(BackupError) -> RestorePlan in
                try BackupEnvelope.decode(bytes: bytes, calendar: calendar, now: now, newID: {
                    counter += 1
                    return "swift-new-\(counter)"
                })
            }
            if let deviation = Self.deviation(name) {
                #expect(throws: deviation, "\(zone) \(name)") { try result.get() }
                continue
            }
            if let message = item["error"].string {
                #expect(throws: BackupError.self, "\(zone) \(name)") { try result.get() }
                if case .failure(let error) = result { #expect(error.message == message, "\(zone) \(name)") }
                continue
            }
            if item["other"].string != nil || item["restoreFails"].string != nil {
                // Flutter: a non-FormatException ("Unsupported operation:
                // Infinity or NaN toInt") or a failed first write. Swift:
                // corrupt (PARITY_GAPS).
                #expect(throws: BackupError.corrupt, "\(zone) \(name)") { try result.get() }
                continue
            }
            guard case .success(let plan) = result else {
                Issue.record("\(zone) \(name): Swift rejected a file Dart accepts: \(result)")
                continue
            }
            try Self.compare(plan, item["ok"], bytes: bytes, label: "\(zone) \(name)")
        }
    }

    static func compare(_ plan: RestorePlan, _ dart: J, bytes: [UInt8], label: String) throws {
        let counts = dart["counts"].array.map { $0.int! }
        let c = plan.counts
        #expect([c.transactions, c.netWorthEntries, c.budgets, c.goals, c.recurringTemplates] == counts, "\(label) counts")

        // The file as JSON (for "provided" and for the ids it already has).
        var input = bytes[...]
        if input.starts(with: [0xEF, 0xBB, 0xBF]) { input = input.dropFirst(3) }
        var text = String(decoding: input, as: UTF8.self)
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        let file = try JSONParser.parse(Array(text.utf8))
        let data = file.objectValue!["data"]!.objectValue!
        var known = Set<[UInt16]>()
        allStrings(file, into: &known)
        func provided(_ key: String) -> Bool { !(data[key]?.isNull ?? true) }

        let lists: [(String, [JSONObject]?)] = [
            ("transactions", plan.transactions?.map(\.raw)), ("netWorthEntries", plan.netWorthEntries?.map(\.raw)),
            ("savingsGoals", plan.savingsGoals?.map(\.raw)), ("recurringTransactions", plan.templates?.map(\.raw)),
            ("categories", plan.categories?.map(\.raw)), ("transactionTags", plan.tags?.map(\.raw)),
            ("categorizationRules", plan.rules?.map(\.raw)),
        ]
        // Swift's generated ids, swapped for Dart's (same document order).
        let combined = JSONValue.object(JSONObject(ordered: lists.map { ($0.0, .array(($0.1 ?? []).map { .object($0) })) }))
        let swapped = try JSONParser.parse(
            try substitutingGeneratedIDs(DartJSON.encode(combined), dart: dart["generatedIds"].array.map { $0.string! }, known: known))
        for (key, rows) in lists {
            #expect((rows != nil) == provided(key), "\(label) \(key) provided")
            let swift = DartJSON.encodeString(swapped.objectValue![key]!)
            #expect(swift == dart[key].string, "\(label) \(key)")
        }
        let limits = JSONObject(members: (plan.budgetLimits ?? []).map { .init(key: $0.key, value: .double($0.value)) })
        #expect(DartJSON.encodeString(.object(limits)) == dart["categoryBudgetLimits"].string, "\(label) limits")
        #expect((plan.budgetLimits != nil) == provided("categoryBudgetLimits"), "\(label) limits provided")
        #expect(plan.themeMode == dart["themeMode"].string, "\(label) theme")

        // Settings: provided ones as Flutter decodes them; absent or null
        // ones are nil (kept, D10) where Flutter applies its defaults.
        #expect((plan.baseCurrencyCode ?? "USD") == dart["baseCurrencyCode"].string, "\(label) currency")
        #expect((plan.baseCurrencyCode != nil) == provided("baseCurrencyCode"), "\(label) currency provided")
        switch plan.localeOverride {
        case .keep:
            #expect(data["localeOverride"] == nil && dart["localeOverride"].isNull, "\(label) locale")
        case .set(let value):
            #expect(data["localeOverride"] != nil, "\(label) locale present")
            #expect(value == dart["localeOverride"].string, "\(label) locale")
        }
        #expect((plan.appLockEnabled ?? false) == dart["appLockEnabled"].bool, "\(label) lock")
        #expect((plan.appLockEnabled != nil) == provided("appLockEnabled"), "\(label) lock provided")
        #expect((plan.autoLockTimeoutSeconds ?? 60) == dart["autoLockTimeoutSeconds"].int, "\(label) timeout")
        #expect((plan.autoLockTimeoutSeconds != nil) == provided("autoLockTimeoutSeconds"), "\(label) timeout provided")
        #expect((plan.hideBalances ?? false) == dart["hideBalances"].bool, "\(label) hide")
        #expect((plan.hideBalances != nil) == provided("hideBalances"), "\(label) hide provided")
    }

    @Test("confirmation copy: Flutter's verbatim, plus what a partial file keeps")
    func confirmation() throws {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let now = calendar.date(2026, 9, 28)
        func plan(_ text: String) throws -> RestorePlan {
            try BackupEnvelope.decode(bytes: Array(text.utf8), calendar: calendar, now: now, newID: { "id" })
        }
        let v1 = try plan(#"""
            {"schemaVersion":1,"data":{"transactions":[{"id":"a","type":"expense","description":"d","amount":1,"category":"c","date":"2026-01-01"}],
             "netWorthEntries":[],"categoryBudgetLimits":{"a":-5,"b":0},"savingsGoals":[],"recurringTransactions":[],"themeMode":"dark"}}
            """#)
        #expect(RestorePlan.confirmationTitle == "Replace all data?")
        #expect(v1.flutterConfirmationMessage
            == "This will import 1 transactions, 0 net worth entries, 2 budgets, 0 goals and 0 recurring templates, replacing everything currently in Budgie. This cannot be undone.")
        #expect(v1.keptItems == ["categories", "tags", "rules", "settings"])
        #expect(v1.confirmationMessage == v1.flutterConfirmationMessage + " Your categories, tags, rules and settings are kept.")
        let settingsOnly = try plan(#"{"schemaVersion":3,"data":{"transactions":[],"netWorthEntries":[],"categoryBudgetLimits":{},"savingsGoals":[],"recurringTransactions":[],"categories":[],"transactionTags":[],"categorizationRules":[],"baseCurrencyCode":"USD","localeOverride":null,"appLockEnabled":false,"autoLockTimeoutSeconds":60}}"#)
        #expect(settingsOnly.keptItems == ["settings"])
        #expect(settingsOnly.confirmationMessage.hasSuffix(" Your settings are kept."))
        let empty = try plan(#"{"schemaVersion":3,"data":{}}"#)
        #expect(empty.confirmationMessage.hasSuffix(
            " Your transactions, net worth entries, budgets, goals, recurring templates, categories, tags, rules and settings are kept."))
        let full = try plan(#"{"schemaVersion":3,"data":{"transactions":[],"netWorthEntries":[],"categoryBudgetLimits":{},"savingsGoals":[],"recurringTransactions":[],"categories":[],"transactionTags":[],"categorizationRules":[],"baseCurrencyCode":"USD","localeOverride":null,"appLockEnabled":false,"autoLockTimeoutSeconds":60,"hideBalances":false}}"#)
        #expect(full.keptItems.isEmpty && full.confirmationMessage == full.flutterConfirmationMessage)
    }
}
