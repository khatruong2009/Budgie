import Foundation
import Testing

@testable import BudgieCore

let storeScenarioNames = (try? Fixtures.scenarios("store").map(\.lastPathComponent)) ?? []
let legacyScenarioNames = (try? Fixtures.scenarios("legacy").map(\.lastPathComponent)) ?? []
let blockedLegacyScenarioNames = ["bare_malformed", "v1_schema2_rejected"]

@Suite("Store: load, restore, migrate and commit exactly like the Dart store")
struct StoreParityTests {
    @Test("checksum format matches Dart (signed hex, padding before the sign)")
    func checksumVectors() {
        #expect(StoreFile.checksum(Array("".utf8)) == "-340d631b7bdddcdb")
        #expect(StoreFile.checksum(Array("{}".utf8)) == "08f44b07b5901a25")
        #expect(StoreFile.checksum(Array("a".utf8)) == "-509c23b379fe1374")
        #expect(StoreFile.checksum(Array(#"{"transactions":[]}"#.utf8)) == "72b86e4d16d871bc")
    }

    @Test("store scenarios", arguments: storeScenarioNames)
    func store(_ name: String) async throws {
        try await checkScenario(Scenario(Fixtures.url("store/\(name)")))
    }

    @Test("legacy SharedPreferences scenarios", arguments: legacyScenarioNames)
    func legacy(_ name: String) async throws {
        try await checkScenario(Scenario(Fixtures.url("legacy/\(name)")))
    }

    /// Runs the Swift store over the fixture input and compares with what
    /// the Dart store did: loaded revision and sections, files and
    /// preferences afterwards (byte-level via FNV), and the effect of one
    /// more commit.
    func checkScenario(_ scenario: Scenario) async throws {
        let expected = scenario.expected
        let load = expected["load"] as! [String: Any]
        let store = scenario.makeStore()

        var snapshot: FinancialSnapshot
        let originalPrefs = scenario.preferences.all
        do {
            snapshot = try await store.read()
        } catch .readFailed {
            if blockedLegacyScenarioNames.contains(scenario.name) {
                // Safety divergence: Flutter discards these damaged keys.
                // Swift blocks before writing or removing any preference.
                #expect(scenario.fileSystem.snapshot.isEmpty)
                #expect(scenario.preferences.all == originalPrefs)
                return
            }
            #expect(load["error"] as? String == "FinancialStoreException", "\(scenario.name): Swift failed to read")
            #expect(scenario.listing() == Scenario.listing(expected["filesAfterLoad"]), "\(scenario.name) files")
            return
        } catch .dataUnreadable(let corrupt) {
            // Approved divergence: Dart opens an empty store here. Swift
            // stops until the user acknowledges, then behaves like Dart.
            #expect(load["revision"] as? Int == 0 || scenario.name == "both_corrupt_with_legacy",
                    "\(scenario.name): damaged files require explicit acknowledgement before fallback")
            #expect(!corrupt.isEmpty)
            if scenario.name != "both_corrupt_with_legacy" {
                #expect(scenario.listing() == Scenario.listing(expected["filesAfterLoad"]), "\(scenario.name) files")
            } else {
                #expect(scenario.fileSystem.snapshot[StoreFile.primaryName] == nil)
                #expect(scenario.preferences.all == originalPrefs)
            }
            try await store.acknowledgeUnreadableData(corrupt)
            snapshot = try await store.read()
        }
        #expect(load["error"] == nil, "\(scenario.name): Dart failed but Swift loaded")
        #expect(snapshot.revision == (load["revision"] as! NSNumber).int64Value, "\(scenario.name) revision")
        let sections = load["sections"] as! [String: Any]
        let canonical = canonicalSections(snapshot)
        #expect(canonical.fnv == sections["fnv"] as! String, "\(scenario.name) sections")
        #expect(canonical.length == sections["length"] as! Int, "\(scenario.name) length")
        #expect(canonical.keys == sections["keys"] as! [String], "\(scenario.name) key order")

        #expect(scenario.listing() == Scenario.listing(expected["filesAfterLoad"]), "\(scenario.name) files after load")
        let prefsAfter = try Scenario.loadPrefsJSON(expected["prefsAfterLoad"])
        var swiftPrefs = scenario.prefsSnapshot()
        swiftPrefs = swiftPrefs.filter { !$0.key.hasPrefix("native.") }
        #expect(swiftPrefs == prefsAfter, "\(scenario.name) preferences after load")

        // One more commit on a relaunched store over the same files.
        if let after = expected["afterOneCommit"] as? [String: Any], after["error"] == nil {
            let relaunched = scenario.makeStore()
            let committed = try await relaunched.updateSections([
                (Section.selectedNetWorthMonth, .string("2026-05-01T00:00:00.000"))
            ])
            #expect(committed.revision == (after["revision"] as! NSNumber).int64Value, "\(scenario.name) commit revision")
            #expect(scenario.listing() == Scenario.listing(after["files"]), "\(scenario.name) files after commit")
        }
    }

    @Test("a load -> save of every readable store reproduces the payload bytes")
    func losslessResave() async throws {
        for name in storeScenarioNames + legacyScenarioNames {
            let scenario = try Scenario(Fixtures.url(name.hasPrefix("v1") || legacyScenarioNames.contains(name) ? "legacy/\(name)" : "store/\(name)"))
            guard let primary = scenario.fileSystem.snapshot[StoreFile.primaryName],
                let header = StoreFile.verify(primary), StoreFile.decode(primary) != nil
            else { continue }
            let store = scenario.makeStore()
            let loaded = try await store.read()
            guard loaded.revision == header.revision else { continue }  // restored from backup
            try await store.replace(sections: loaded.sections)
            let written = scenario.fileSystem.snapshot[StoreFile.primaryName]!
            let writtenHeader = StoreFile.verify(written)!
            #expect(Array(written[writtenHeader.payloadRange]) == Array(primary[header.payloadRange]), "\(name)")
            // The previous primary became the backup, byte for byte.
            #expect(scenario.fileSystem.snapshot[StoreFile.backupName] == primary, "\(name) backup")
        }
    }
}

extension Scenario {
    static func loadPrefsJSON(_ json: Any?) throws -> [String: PreferenceValue] {
        try loadPrefs(JSONSerialization.data(withJSONObject: json ?? [String: Any]()))
    }
}
