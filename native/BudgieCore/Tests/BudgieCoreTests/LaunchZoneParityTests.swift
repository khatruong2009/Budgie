import Foundation
import Testing

@testable import BudgieCore

/// Zones the launch fixtures were generated under (launch_fixtures_test.dart,
/// run by native/ParityHarness/run.sh).
let launchZones = ["America/New_York", "UTC", "Australia/Lord_Howe", "Asia/Kolkata", "America/Santiago", "Asia/Beirut"]

/// Store scenarios the launch fixtures cover.
let launchScenarioNames = ["typical", "old_schema", "unknown_data", "large_10k"]

@Suite("Launch: Swift's launch of the store fixtures matches the Flutter launch in every zone")
struct LaunchZoneParityTests {
    /// The row ids in `sections` (canonical JSON) that are not strings of
    /// `known`, in document order: the ids a launch generated
    /// (harness_support.dart `generatedIds`).
    static func generatedIDs(_ sections: JSONValue, known: Set<String>) -> [String] {
        var found: [String] = []
        func walk(_ value: JSONValue) {
            if let items = value.arrayValue {
                for item in items {
                    if let object = item.objectValue, case .string(let id)? = object["id"], !known.contains(id.value) {
                        found.append(id.value)
                    }
                    walk(item)
                }
            } else if let object = value.objectValue {
                for key in object.keys { if let child = object[key] { walk(child) } }
            }
        }
        walk(sections)
        return found
    }

    /// Every string (and object key) under `value`.
    static func strings(in value: JSONValue, into set: inout Set<String>) {
        if case .string(let text) = value {
            set.insert(text.value)
        } else if let items = value.arrayValue {
            for item in items { strings(in: item, into: &set) }
        } else if let object = value.objectValue {
            for key in object.keys {
                set.insert(key)
                if let child = object[key] { strings(in: child, into: &set) }
            }
        }
    }

    /// Stored date strings under `value` that Dart rewrites to other text
    /// (a nonexistent local time: old text to the text of the instant it
    /// parses to).
    static func gapDates(in value: JSONValue, timeZone: TimeZone, into pairs: inout [String: String]) {
        if case .string(let text) = value {
            let string = text.value
            if string.utf8.count >= 19, string.utf8.count <= 26, string.dropFirst(10).first == "T",
                let parsed = DartDateTime.tryParse(string, timeZone: timeZone), parsed.toIso8601String() != string
            {
                pairs[string] = parsed.toIso8601String()
            }
        } else if let items = value.arrayValue {
            for item in items { gapDates(in: item, timeZone: timeZone, into: &pairs) }
        } else if let object = value.objectValue {
            for key in object.keys { if let child = object[key] { gapDates(in: child, timeZone: timeZone, into: &pairs) } }
        }
    }

    /// `bytes` with every occurrence of each quoted `from[i]` replaced by
    /// the quoted `to[i]` (ids are ASCII), like the harness'
    /// `alignGeneratedIds`.
    static func replacingIDs(in bytes: [UInt8], from: [String], to: [String]) -> [UInt8] {
        var out = bytes
        for (old, new) in zip(from, to) {
            let pattern = Array("\"\(old)\"".utf8)
            let replacement = Array("\"\(new)\"".utf8)
            var result: [UInt8] = []
            result.reserveCapacity(out.count)
            var index = 0
            while index < out.count {
                if index + pattern.count <= out.count, out[index] == pattern[0], out[index..<(index + pattern.count)].elementsEqual(pattern) {
                    result += replacement
                    index += pattern.count
                } else {
                    result.append(out[index])
                    index += 1
                }
            }
            out = result
        }
        return out
    }

    @Test("launch summary and stored sections, per zone", arguments: launchZones)
    func launchMatchesDart(zone: String) async throws {
        let tz = TimeZone(identifier: zone)!
        for name in launchScenarioNames {
            let label = "\(zone) \(name)"
            let fixture = try Fixtures.json("\(Fixtures.zonePath("launch", zone))/\(name).json")
            #expect(fixture["tz"].string == zone, "\(label) tz")
            #expect(fixture["scenario"].string == name, "\(label) scenario")

            let scenario = try Scenario(Fixtures.url("store/\(name)"))
            let now = scenario.launchNow(in: tz)
            #expect(fixture["launchNow"].string == now.toIso8601String(), "\(label) launch clock")
            let known = inputIDs(scenario)
            let before = try? await scenario.makeStore(zone: tz).read()
            guard let launched = try await launchWithSnapshot(scenario, zone: tz) else {
                Issue.record("\(label): Swift could not launch but Dart could")
                continue
            }
            assertDartSummary(launched.data, fixture["summary"], known: known, now: now, label: label, allowUnreadable: name == "old_schema")

            // The bytes the launch leaves behind, with the ids each side
            // generated aligned in order.
            let dart = fixture["sectionsAfterGenerate"]
            let canonical = DartJSON.encode(.object(launched.snapshot.sections), mode: .dartCanonical)
            #expect(launched.snapshot.sections.keys == dart["keys"].array.compactMap(\.string), "\(label) section keys")
            // Swift writes rows it did not touch as stored (unknown keys,
            // rows without ids, stored lexemes), where Flutter re-encodes
            // every row it saves: the old-schema and unknown-keys inputs
            // differ in bytes by design, so only the inputs Flutter wrote
            // itself are compared byte for byte.
            guard name == "typical" || name == "large_10k", let before else { continue }
            var knownStrings = Set<String>()
            Self.strings(in: .object(before.sections), into: &knownStrings)
            let swiftIDs = Self.generatedIDs(.object(launched.snapshot.sections), known: knownStrings)
            let dartIDs = fixture["generatedIds"].array.compactMap(\.string)
            #expect(swiftIDs.count == dartIDs.count, "\(label) generated id count")
            guard swiftIDs.count == dartIDs.count else { continue }
            var aligned = Self.replacingIDs(in: canonical, from: swiftIDs, to: dartIDs)
            // A stored local time that does not exist in the zone (the
            // spring-forward hour) is written back as stored by Swift, for
            // a row it did not touch; Flutter's re-encode writes the instant
            // it parsed to. Same instant, different text: align the text.
            var shifted: [String: String] = [:]
            Self.gapDates(in: .object(before.sections), timeZone: tz, into: &shifted)
            // The zones whose DST change is at midnight hold inputs on it.
            if name == "typical" && (zone == "America/Santiago") {
                #expect(!shifted.isEmpty, "\(label) expected a stored date in the spring-forward hour")
            }
            if !shifted.isEmpty {
                aligned = Self.replacingIDs(in: aligned, from: Array(shifted.keys), to: shifted.keys.map { shifted[$0]! })
            }
            #expect(aligned.count == dart["length"].int, "\(label) sections length")
            #expect(StoreFile.checksum(aligned) == dart["fnv"].string, "\(label) sections after launch")
            if let json = dart["json"].string {
                // Reports the first differing offset when the checksum fails.
                let want = Array(json.utf8)
                if aligned != want {
                    let offset = zip(aligned, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(aligned.count, want.count)
                    let from = max(0, offset - 60)
                    Issue.record(
                        "\(label) first difference at \(offset): swift «\(String(decoding: aligned[from..<min(aligned.count, offset + 60)], as: UTF8.self))» dart «\(String(decoding: want[from..<min(want.count, offset + 60)], as: UTF8.self))»"
                    )
                }
            }
        }
    }
}
