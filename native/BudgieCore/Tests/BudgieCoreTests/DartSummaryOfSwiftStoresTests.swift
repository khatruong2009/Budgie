import Foundation
import Testing

@testable import BudgieCore

/// Path of the Dart verifier's report (`dart-verification.json`), set by
/// native/scripts/verify-swift-output-in-dart.sh after `run.sh verify`.
let dartVerificationPath = ProcessInfo.processInfo.environment["BUDGIE_DART_VERIFICATION"]

/// The numbers the Flutter app shows for every store the Swift side wrote
/// (the `summary` the verifier computes with its real models at the launch
/// clock, see model_summary.dart) against the numbers Swift shows for the
/// same files: month totals, net worth queries and history, safe-to-spend
/// per month, goals, template cursors, settings and the widget cash flow.
/// Nothing is generated on either side; the ids compared are the ones in
/// the stored bytes.
@Suite("Dart's derived numbers for Swift-written stores equal Swift's", .enabled(if: dartVerificationPath != nil))
struct DartSummaryOfSwiftStores {
    @Test("summary of every verified case")
    func summaries() async throws {
        let path = try #require(dartVerificationPath)
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        let report = J(try JSONParser.parse([UInt8](Data(contentsOf: URL(fileURLWithPath: path)))))
        let zone = Scenario.zone
        #expect(report["tz"].string == zone.identifier, "the verifier ran in another zone than Swift wrote in")
        let calendar = DartCalendar(timeZone: zone)
        // fixture_runner.dart `launchNow`.
        let now = calendar.date(2026, 9, 28, 9, 15, 30, 250, 125)

        var compared: [String] = []
        for name in report["cases"].keys.sorted() {
            let summary = report["cases"][name]["summary"]
            // Dart could not load the store (the verifier reports why), or
            // this is a widget case without a store.
            guard summary.value != nil, !summary.isNull else { continue }
            let dir = root.appendingPathComponent(name)
            #expect(summary["asOf"].string == now.toIso8601String(), "\(name) launch clock")

            var files: [String: [UInt8]] = [:]
            let storeDir = dir.appendingPathComponent("financial_store")
            for file in try FileManager.default.contentsOfDirectory(atPath: storeDir.path) {
                files[file] = [UInt8](try Data(contentsOf: storeDir.appendingPathComponent(file)))
            }
            let prefsURL = dir.appendingPathComponent("prefs.json")
            let prefs = FileManager.default.fileExists(atPath: prefsURL.path) ? try Scenario.loadPrefs(Data(contentsOf: prefsURL)) : [:]
            let preferences = InMemoryPreferences(prefs)
            let store = FinancialStore(
                fileSystem: InMemoryFileSystem(files: files, directories: []), preferences: preferences,
                protectedData: AlwaysAvailable(), clock: { now })
            let snapshot: FinancialSnapshot
            do {
                snapshot = try await store.read()
            } catch {
                Issue.record("\(name): Swift cannot read what it wrote: \(error)")
                continue
            }
            let data = FinancialData.load(
                snapshot, preferences: preferences, calendar: calendar, now: { now }, newID: { UUID().uuidString.lowercased() }, matchesPaddedCategoryNames: false
            ).data
            // Both sides give a row without an id a fresh one at every load
            // (old_schema's): compare the ids the bytes hold.
            var stored = Set<String>()
            for section in [Section.transactions, Section.netWorthEntries] {
                for row in snapshot.sections[section]?.arrayValue ?? [] {
                    if let id = row.objectValue?["id"]?.stringValue { stored.insert(id) }
                }
            }
            assertDartSummary(
                data, summary, known: stored, now: now, label: "\(zone.identifier) \(name)",
                allowUnreadable: name.contains("old_schema"), templateIDsComparable: true)
            compared.append(name)
        }
        #expect(compared.count >= 20, "only \(compared.count) cases compared: \(compared)")
    }
}
