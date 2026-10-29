import Foundation

@testable import BudgieCore

/// A fixture scenario (native/Fixtures/{store,legacy}/<name>/) loaded into
/// in-memory stand-ins for the store directory and NSUserDefaults.
struct Scenario {
    let name: String
    let url: URL
    let expected: [String: Any]
    let fileSystem: InMemoryFileSystem
    let preferences: InMemoryPreferences

    /// The zone every scenario runs in. The fixtures were generated in
    /// America/New_York; the Swift-written-store checks run in other zones
    /// (BUDGIE_SWIFT_ZONE, see native/scripts/verify-swift-output-in-dart.sh).
    static let zone = TimeZone(identifier: ProcessInfo.processInfo.environment["BUDGIE_SWIFT_ZONE"] ?? "America/New_York")!

    init(_ url: URL) throws {
        self.url = url
        name = url.lastPathComponent
        expected = try JSONSerialization.jsonObject(with: Data(contentsOf: url.appendingPathComponent("expected.json"))) as! [String: Any]
        var files: [String: [UInt8]] = [:]
        let input = url.appendingPathComponent("input")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: input.path) {
            for fileName in names {
                var isDirectory: ObjCBool = false
                let file = input.appendingPathComponent(fileName)
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                files[fileName] = [UInt8](try Data(contentsOf: file))
            }
        }
        // Git does not keep the empty directory this scenario places where
        // the primary file belongs; recreate it.
        let directories: Set<String> = name == "primary_is_directory" ? [StoreFile.primaryName] : []
        fileSystem = InMemoryFileSystem(files: files, directories: directories)
        preferences = InMemoryPreferences(try Scenario.loadPrefs(Data(contentsOf: url.appendingPathComponent("prefs.json"))))
    }

    static func loadPrefs(_ data: Data) throws -> [String: PreferenceValue] {
        let typed = try JSONSerialization.jsonObject(with: data) as! [String: [String: Any]]
        var result: [String: PreferenceValue] = [:]
        for (key, entry) in typed {
            let raw = entry["value"]!
            switch entry["type"] as! String {
            case "string": result[key] = .string(raw as! String)
            case "stringList": result[key] = .stringList(raw as! [String])
            case "int": result[key] = .int((raw as! NSNumber).int64Value)
            case "double": result[key] = .double((raw as! NSNumber).doubleValue)
            case "bool": result[key] = .bool(raw as! Bool)
            default: fatalError("unknown pref type")
            }
        }
        return result
    }

    /// The Dart launch clock for every expectation.
    var launchNow: DartDateTime { launchNow(in: Scenario.zone) }

    /// The same local launch clock text in another zone (the launch fixtures
    /// pin `DateTime(2026, 9, 28, 9, 15, 30, 250, 125)` under every zone).
    func launchNow(in zone: TimeZone) -> DartDateTime {
        try! DartDateTime.parse(expected["launchNow"] as! String, timeZone: zone)
    }

    func makeStore(protectedData: ProtectedDataAvailability = AlwaysAvailable(), zone: TimeZone = Scenario.zone) -> FinancialStore {
        let now = launchNow(in: zone)
        return FinancialStore(fileSystem: fileSystem, preferences: preferences, protectedData: protectedData, clock: { now })
    }

    /// Same shape as the harness `listing()`: name (corrupt stamps
    /// normalised) -> size and FNV of the bytes.
    func listing() -> [String: [String: AnyHashable]] {
        var out: [String: [String: AnyHashable]] = [:]
        for (name, bytes) in fileSystem.snapshot {
            let normalized = name.replacingOccurrences(of: #"\.corrupt-\d+$"#, with: ".corrupt-*", options: .regularExpression)
            out[normalized] = ["size": bytes.count, "fnv": StoreFile.checksum(bytes)]
        }
        return out
    }

    static func listing(_ json: Any?) -> [String: [String: AnyHashable]] {
        guard let dict = json as? [String: [String: Any]] else { return [:] }
        return dict.mapValues { entry in
            ["size": (entry["size"] as! NSNumber).intValue, "fnv": entry["fnv"] as! String]
        }
    }

    func prefsSnapshot() -> [String: PreferenceValue] {
        preferences.all
    }
}

/// Dart-canonical sections checksum, comparable with expected.json.
func canonicalSections(_ snapshot: FinancialSnapshot) -> (fnv: String, length: Int, keys: [String]) {
    let bytes = DartJSON.encode(.object(snapshot.sections), mode: .dartCanonical)
    return (StoreFile.checksum(bytes), bytes.count, snapshot.sections.keys)
}
