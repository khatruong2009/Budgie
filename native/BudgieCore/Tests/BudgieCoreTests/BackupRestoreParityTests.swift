import Foundation
import Testing

@testable import BudgieCore

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
