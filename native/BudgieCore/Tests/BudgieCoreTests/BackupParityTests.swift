import Foundation
import Testing

@testable import BudgieCore

/// Fixture text (a JSON string value) as the UTF-8 bytes it stands for.
func fixtureBytes(_ value: J) -> [UInt8] {
    guard case .string(let string)? = value.value else { return [] }
    return Array(String(decoding: string.codeUnits, as: UTF16.self).utf8)
}

/// The zones the backup fixtures are generated in.
let backupZones = ["America/New_York", "Australia/Lord_Howe", "UTC", "America/Santiago"]

func backupFixture(_ zone: String, _ file: String) throws -> J {
    J(try JSONParser.parse([UInt8](Fixtures.data("backup/tz/\(zone.replacingOccurrences(of: "/", with: "_"))/\(file)"))))
}

/// Typed preferences (the harness `typedPrefs` form) as a fixture value.
func typedPreferences(_ value: J) -> [String: PreferenceValue] {
    var result: [String: PreferenceValue] = [:]
    for key in value.keys {
        let entry = value[key]
        switch entry["type"].string {
        case "string": result[key] = .string(entry["value"].string!)
        case "stringList": result[key] = .stringList(entry["value"].array.map { $0.string! })
        case "int": result[key] = .int(Int64(entry["value"].int!))
        case "double": result[key] = .double(entry["value"].double!)
        case "bool": result[key] = .bool(entry["value"].bool!)
        default: Issue.record("pref type \(key)")
        }
    }
    return result
}

/// Every string value in a JSON tree (keys included).
func allStrings(_ value: JSONValue, into set: inout Set<[UInt16]>) {
    switch value {
    case .string(let s): set.insert(s.codeUnits)
    case .array(let items): for item in items { allStrings(item, into: &set) }
    case .object(let object):
        for member in object.members {
            set.insert(member.key.codeUnits)
            allStrings(member.value, into: &set)
        }
    default: break
    }
}

/// Row ids (objects in arrays) not in `known`, in document order: the
/// harness `generatedIds`.
func generatedIDs(_ value: JSONValue, known: Set<[UInt16]>) -> [String] {
    var found: [String] = []
    func walk(_ value: JSONValue) {
        switch value {
        case .array(let items):
            for item in items {
                if case .object(let row) = item, case .string(let id)? = row["id"], !known.contains(id.codeUnits) {
                    found.append(id.value)
                }
                walk(item)
            }
        case .object(let object):
            for member in object.members { walk(member.value) }
        default:
            break
        }
    }
    walk(value)
    return found
}

/// Swift's output with the ids it generated replaced, in order, by the ones
/// Dart generated (both sides draw them at random).
func substitutingGeneratedIDs(_ bytes: [UInt8], dart: [String], known: Set<[UInt16]>) throws -> [UInt8] {
    let swift = generatedIDs(try JSONParser.parse(bytes), known: known)
    guard swift.count == dart.count else {
        Issue.record("generated ids: swift \(swift.count) dart \(dart.count)")
        return bytes
    }
    var text = String(decoding: bytes, as: UTF8.self)
    for (mine, theirs) in zip(swift, dart) {
        text = text.replacingOccurrences(of: "\"\(mine)\"", with: "\"\(theirs)\"")
    }
    return Array(text.utf8)
}

@Suite("Backup: export matches Flutter's encodeBackup byte for byte (Fixtures/backup)")
struct BackupEncodeParityTests {
    @Test("every store and hand-made case, every backup zone", arguments: backupZones)
    func encode(_ zone: String) async throws {
        let timeZone = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: timeZone)
        let fixture = try backupFixture(zone, "encode.json")
        let launchNow = try DartDateTime.parse(fixture["launchNow"].string!, timeZone: timeZone)
        let exportedAt = try DartDateTime.parse(fixture["exportedAt"].string!, timeZone: timeZone)
        let appVersion = fixture["appVersion"].string!
        #expect(fixture["cases"].array.count >= 18)
        var counter = 0
        func newID() -> String {
            counter += 1
            return "swift-new-\(counter)"
        }
        for item in fixture["cases"].array {
            let name = item["name"].string!
            let snapshot: FinancialSnapshot
            let preferences: InMemoryPreferences
            if let store = item["store"].string {
                let scenario = try Scenario(Fixtures.url("store/\(store)"))
                preferences = scenario.preferences
                snapshot = try await FinancialStore(
                    fileSystem: scenario.fileSystem, preferences: preferences, protectedData: AlwaysAvailable(),
                    clock: { launchNow }
                ).read()
            } else {
                let sections = try JSONParser.parse(fixtureBytes(item["sections"])).objectValue!
                snapshot = FinancialSnapshot(revision: 1, sections: sections)
                preferences = InMemoryPreferences(typedPreferences(item["prefs"]))
            }
            let data = FinancialData.load(
                snapshot, preferences: preferences, calendar: calendar, now: { launchNow }, newID: newID, matchesPaddedCategoryNames: false
            ).data
            var bytes = try BackupEnvelope.encode(
                data: data, themeMode: item["themeMode"].string, appVersion: appVersion, now: exportedAt)
            let dartIDs = item["generatedIds"].array.map { $0.string! }
            var known = Set<[UInt16]>()
            allStrings(.object(snapshot.sections), into: &known)
            bytes = try substitutingGeneratedIDs(bytes, dart: dartIDs, known: known)
            if item["expected"].string != nil {
                #expect(bytes == fixtureBytes(item["expected"]), "\(zone) \(name)")
            } else {
                #expect(StoreFile.checksum(bytes) == item["expected"]["fnv"].string, "\(zone) \(name) fnv")
                #expect(bytes.count == item["expected"]["length"].int, "\(zone) \(name) length")
            }
        }
        for vector in fixture["fileNames"].array {
            let date = try DartDateTime.parse(vector["date"].string!, timeZone: timeZone)
            #expect(BackupEnvelope.fileName(now: date) == vector["fileName"].string, "\(zone)")
        }
    }

    @Test("the real Settings page's export: file name, bytes (Fixtures export_flow.json)", arguments: backupZones)
    func exportFlow(_ zone: String) async throws {
        let timeZone = TimeZone(identifier: zone)!
        let flow = try backupFixture(zone, "export_flow.json")
        #expect(flow["subject"].string == "Budgie Backup")
        #expect(flow["snackbar"].string == "Backup exported")
        #expect(flow["fileCount"].int == 1)
        let now = try DartDateTime.parse(flow["now"].string!, timeZone: timeZone)
        #expect(BackupEnvelope.fileName(now: now) == flow["fileName"].string)
        let scenario = try Scenario(Fixtures.url("store/typical"))
        let snapshot = try await FinancialStore(
            fileSystem: scenario.fileSystem, preferences: scenario.preferences, protectedData: AlwaysAvailable(), clock: { now }
        ).read()
        let data = FinancialData.load(
            snapshot, preferences: scenario.preferences, calendar: DartCalendar(timeZone: timeZone), now: { now },
            newID: { UUID().uuidString.lowercased() }, matchesPaddedCategoryNames: false
        ).data
        let bytes = try BackupEnvelope.encode(data: data, themeMode: flow["themeMode"].string, appVersion: "3.4.0", now: now)
        #expect(bytes == fixtureBytes(flow["bytes"]))
    }

    @Test("unreadable rows are left out, and a non-finite amount fails like Dart's encoder")
    func unreadableAndNonFinite() throws {
        let calendar = DartCalendar(timeZone: Scenario.zone)
        let now = calendar.date(2026, 9, 28)
        let sections = try JSONParser.parse(#"""
            {"transactions":[
              {"id":"a","type":"expense","description":"ok","amount":1,"category":"General","date":"2026-09-01"},
              {"id":"b","type":"expense","amount":1.0,"category":"General","date":"2026-09-01"},
              {"id":"c","type":"expense","description":"inf","amount":1e999,"category":"General","date":"2026-09-01"}]}
            """#).objectValue!
        let data = FinancialData.load(
            FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences(), calendar: calendar,
            now: { now }, newID: { "new" }
        ).data
        #expect(data.transactionRows.count == 3 && data.transactions.count == 2)
        #expect(throws: BackupExportError.self) {
            try BackupEnvelope.encode(data: data, themeMode: "system", appVersion: "4.0.0", now: now)
        }
        do {
            _ = try BackupEnvelope.encode(data: data, themeMode: "system", appVersion: "4.0.0", now: now)
        } catch {
            #expect(error.message == "Converting object to an encodable object failed: Infinity")
        }
    }
}

/// Base64 fixture bytes.
func base64Bytes(_ value: J) -> [UInt8] {
    [UInt8](Data(base64Encoded: value.string ?? "") ?? Data())
}

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

@Suite("Backup: restore ends where Flutter's real Settings import ends (Fixtures/backup restore.json)")
struct BackupRestoreParityTests {
    /// Flutter fails these after its dialog; Swift rejects them at decode
    /// with the corrupt message (PARITY_GAPS, D10 list).
    static let failsAtDecodeInSwift: Set<String> = ["timeout inf", "rule min inf"]

    @Test("dialog, snackbar, store sections, preferences and theme", arguments: backupZones)
    func restore(_ zone: String) async throws {
        let timeZone = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: timeZone)
        let fixture = try backupFixture(zone, "restore.json")
        let now = try DartDateTime.parse(fixture["launchNow"].string!, timeZone: timeZone)
        let cases = fixture["cases"].array
        #expect(cases.count >= 24)
        for item in cases {
            let name = item["name"].string!
            let label = "\(zone) \(name)"
            let flutter = item["flutter"]
            #expect(flutter["allowedExtensions"].array.map { $0.string } == ["json"], "\(label) picker")
            let bytes = base64Bytes(fixture["files"][item["file"].string!])

            // The current state, loaded as the app launches it.
            let scenario = try Scenario(Fixtures.url("store/\(item["current"].string!)"))
            let snapshot = try await FinancialStore(
                fileSystem: scenario.fileSystem, preferences: scenario.preferences, protectedData: AlwaysAvailable(),
                clock: { now }
            ).read()
            var counter = 0
            func newID() -> String {
                counter += 1
                return "swift-new-\(counter)"
            }
            let current = FinancialData.load(
                snapshot, preferences: scenario.preferences, calendar: calendar, now: { now }, newID: newID, matchesPaddedCategoryNames: false
            ).data

            let decoded = Result { () throws(BackupError) -> RestorePlan in
                try BackupEnvelope.decode(bytes: bytes, calendar: calendar, now: now, newID: newID)
            }
            let snackbar = flutter["snackbar"].string
            if Self.failsAtDecodeInSwift.contains(name) {
                #expect(throws: BackupError.corrupt, "\(label)") { try decoded.get() }
                #expect(flutter["storeChanged"].bool == false, "\(label)")
                continue
            }
            guard case .success(let plan) = decoded else {
                if case .failure(let error) = decoded {
                    #expect(BackupEnvelope.importFailedMessage(error.message) == snackbar, "\(label)")
                    #expect(flutter["dialog"].isNull && flutter["storeChanged"].bool == false, "\(label)")
                }
                continue
            }
            #expect(flutter["dialog"]["title"].string == RestorePlan.confirmationTitle, "\(label) title")
            #expect(flutter["dialog"]["message"].string == plan.flutterConfirmationMessage, "\(label) message")
            if item["cancel"].bool == true {
                #expect(snackbar == nil && flutter["storeChanged"].bool == false, "\(label)")
                continue
            }
            #expect(snackbar == BackupEnvelope.restoredMessage, "\(label) snackbar")

            // D10 cases compare with Flutter's restore of the same file with
            // the left-out keys filled from the current state.
            let expected = item["d10"].value == nil ? flutter : item["d10"]
            #expect(item["d10"].value == nil || !plan.keptItems.isEmpty, "\(label) d10 needs kept items")
            let result = current.restoring(plan, now: now, newID: newID)

            var known = Set<[UInt16]>()
            for section in Section.all { allStrings(current.serializedSection(section)!, into: &known) }
            var input = bytes[...]
            if input.starts(with: [0xEF, 0xBB, 0xBF]) { input = input.dropFirst(3) }
            var text = String(decoding: input, as: UTF8.self)
            if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
            if let file = try? JSONParser.parse(Array(text.utf8)) { allStrings(file, into: &known) }
            let after = expected["afterRelaunch"]
            #expect(result.sections.map(\.0) == Section.all, "\(label) section order")
            for (key, value) in result.sections {
                let dartIDs = after["generatedIds"][key].array.map { $0.string! }
                func render(_ value: JSONValue) throws -> String {
                    let raw = DartJSON.encode(value, mode: .dartCanonical)
                    let swift = try substitutingGeneratedIDs(
                        DartJSON.encode(.array([try JSONParser.parse(raw)])), dart: dartIDs, known: known)
                    return String(decoding: swift.dropFirst().dropLast(), as: UTF8.self)
                }
                let text = try render(value)
                if let dart = after["sections"][key].string {
                    #expect(text == dart, "\(label) \(key)")
                } else if StoreFile.checksum(Array(text.utf8)) != after["sections"][key]["fnv"].string {
                    // One deliberate difference (MIGRATION_SPEC section 7: untouched
                    // date strings are never re-formatted): a row the file leaves
                    // out stays as stored, so a wall time in a DST gap (Santiago
                    // 2026-09-06 00:00) keeps its text where Flutter's export and
                    // restore writes the shifted one (01:00). Everything else must
                    // match, so the section has to agree once those texts are shifted.
                    let shifted = try render(Self.shiftingGapDates(value, calendar: calendar))
                    #expect(shifted != text, "\(label) \(key) fnv: no gap date to shift, a real mismatch")
                    #expect(StoreFile.checksum(Array(shifted.utf8)) == after["sections"][key]["fnv"].string, "\(label) \(key) fnv")
                }
            }

            // Preferences: what Swift writes equals Flutter's; a setting the
            // file leaves out keeps its preference (Flutter's filled restore
            // rewrites it with the current value).
            var prefs = scenario.preferences.all
            for write in result.preferenceWrites { prefs[write.key] = write.value }
            let currentTheme = scenario.preferences.string(PreferenceKey.themeMode) ?? "system"
            if let theme = result.themeMode, theme != currentTheme { prefs[PreferenceKey.themeMode] = .string(theme) }
            let flutterPrefs = typedPreferences(expected["prefs"])
            let written = Set(result.preferenceWrites.map(\.key))
            for key in Set(prefs.keys).union(flutterPrefs.keys) {
                if written.contains(key) || !Self.settingsMirrors.contains(key) {
                    #expect(prefs[key] == flutterPrefs[key], "\(label) pref \(key)")
                } else {
                    #expect(prefs[key] == scenario.preferences.all[key], "\(label) kept pref \(key)")
                }
            }
            #expect((result.themeMode ?? currentTheme) == flutter["themeAfterRestore"].string, "\(label) theme")
            if name == "due templates over fresh" { #expect(result.generatedTransactions > 0, "\(label) generated") }
        }
    }

    /// The section with each row's `date`, `createdAt` and `updatedAt` text
    /// re-formatted from its parsed value, as a Dart rewrite of the row does.
    static func shiftingGapDates(_ section: JSONValue, calendar: DartCalendar) -> JSONValue {
        guard case .array(let rows) = section else { return section }
        return .array(rows.map { row in
            guard case .object(var object) = row else { return row }
            for key in ["date", "createdAt", "updatedAt"] {
                if let text = object[key]?.stringValue, let parsed = calendar.tryParse(text) {
                    object[key] = .string(JSONString(parsed.toIso8601String()))
                }
            }
            return .object(object)
        })
    }

    static let settingsMirrors: Set<String> = [
        PreferenceKey.baseCurrencyCode, PreferenceKey.localeOverride, PreferenceKey.appLockEnabled,
        PreferenceKey.autoLockTimeoutSeconds, PreferenceKey.hideBalances,
    ]
}

@Suite("Backup: indented JSON matches JsonEncoder.withIndent('  ') (Fixtures/backup)")
struct IndentedJSONTests {
    @Test("every Dart vector, byte for byte, and a lexeme-preserving round trip")
    func vectors() throws {
        let fixture = J(try JSONParser.parse([UInt8](Fixtures.data("backup/indent_vectors.json"))))
        let cases = fixture["cases"].array
        #expect(cases.count > 200)
        for vector in cases {
            let input = fixtureBytes(vector["json"])
            let expected = fixtureBytes(vector["indented"])
            let parsed = try JSONParser.parse(input)
            let actual = DartJSON.encodeIndented(parsed, mode: .dartCanonical)
            #expect(actual == expected, "\(String(decoding: input, as: UTF8.self))")
            // Dart's output is canonical: re-reading it and writing its
            // lexemes gives the same bytes, and the compact form agrees.
            let reparsed = try JSONParser.parse(expected)
            #expect(DartJSON.encodeIndented(reparsed) == expected)
            #expect(DartJSON.encode(reparsed) == DartJSON.encode(parsed, mode: .dartCanonical))
        }
    }

    @Test("layout rules")
    func layout() {
        let value = JSONValue.object(JSONObject(ordered: [
            ("a", .array([])), ("b", .object(JSONObject())), ("c", .array([.int(1), .array([])])),
        ]))
        #expect(DartJSON.encodeIndentedString(value) == "{\n  \"a\": [],\n  \"b\": {},\n  \"c\": [\n    1,\n    []\n  ]\n}")
        #expect(DartJSON.encodeIndentedString(.array([])) == "[]")
        #expect(DartJSON.encodeIndentedString(.string("x")) == "\"x\"")
    }
}
