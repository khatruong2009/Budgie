import Foundation
import Testing

@testable import BudgieCore

private func fixture(_ name: String) throws -> J {
    try Fixtures.json("settings/\(name)")
}

private func settings(_ section: J) -> AppSettings {
    AppSettings.load(section: section.value, preferences: InMemoryPreferences())
}

/// A preference as the generator's `dumpPrefs` types it.
private func typed(_ value: PreferenceValue) -> String {
    switch value {
    case .string(let v): "string:\(v)"
    case .bool(let v): "bool:\(v)"
    case .int(let v): "int:\(v)"
    case .double(let v): "double:\(v)"
    case .stringList(let v): "stringList:\(v)"
    }
}

private func typed(_ value: J) -> String {
    switch value["type"].string! {
    case "string": "string:\(value["value"].string!)"
    case "bool": "bool:\(value["value"].bool!)"
    case "int": "int:\(value["value"].int!)"
    default: "unexpected:\(value["type"].string!)"
    }
}

@Suite("Settings: labels, choice lists and setters match the Flutter page and provider (Fixtures/settings)")
struct SettingsParityTests {
    /// The subtitles the real SettingsPage renders for stored sections,
    /// including values outside its lists (backups, the Flutter build).
    @Test("row subtitles")
    func labels() throws {
        let cases = try fixture("labels.json")["cases"].array
        #expect(cases.count == 45)
        for c in cases {
            let s = settings(c["section"])
            let label = "\(s)"
            #expect(SettingsOptions.currencyLabel(s.baseCurrencyCode) == c["currency"].string, "\(label) currency")
            #expect(SettingsOptions.localeLabel(s.localeOverride) == c["numberFormat"].string, "\(label) locale")
            let delay = SettingsOptions.lockTimeoutLabel(s.autoLockTimeoutSeconds)
            #expect((s.appLockEnabled ? "Lock after \(delay)" : "Require device authentication") == c["appLock"].string, "\(label) lock")
            #expect((s.appLockEnabled ? delay : nil) == c["lockDelay"].string, "\(label) delay row")
            #expect(c["hideBalances"].string == "Mask amounts throughout the app")
        }
    }

    /// The three sheets: rows in order, the tick on the current value only
    /// when it is listed, and what each row stores.
    @Test("choice sheets")
    func sheets() throws {
        let cases = try fixture("sheets.json")["cases"].array
        #expect(cases.count == 2)
        for c in cases {
            let s = settings(c["section"])
            let name = c["name"].string!

            let currency = c["Currency"]
            #expect(currency["title"].string == "Base currency")
            #expect(currency["rows"].array.map { $0["label"].string! } == SettingsOptions.currencies.map(\.label), "\(name)")
            #expect(currency["rows"].array.map { $0["checked"].bool! } == SettingsOptions.currencies.map { $0.value == s.baseCurrencyCode })

            let locale = c["Number format"]
            #expect(locale["title"].string == "Number format")
            #expect(locale["rows"].array.map { $0["label"].string! } == SettingsOptions.locales.map(\.label), "\(name)")
            #expect(locale["rows"].array.map { $0["checked"].bool! } == SettingsOptions.locales.map { $0.value == s.localeOverride })

            let delay = c["Lock delay"]
            #expect(delay["title"].string == "Lock delay")
            #expect(delay["rows"].array.map { $0["label"].string! } == SettingsOptions.lockDelays.map(\.label), "\(name)")
            #expect(delay["rows"].array.map { $0["checked"].bool! } == SettingsOptions.lockDelays.map { $0.value == s.autoLockTimeoutSeconds })

            guard name == "listed" else { continue }
            #expect(c["Currency picks"].array.map { $0["stored"].string! } == SettingsOptions.currencies.map(\.value))
            #expect(c["Number format picks"].array.map { $0["stored"].string } == SettingsOptions.locales.map(\.value))
            #expect(c["Lock delay picks"].array.map { $0["stored"].int! } == SettingsOptions.lockDelays.map(\.value))
        }
        // Every listed delay's label is what the subtitle function says.
        for choice in SettingsOptions.lockDelays {
            #expect(SettingsOptions.lockTimeoutLabel(choice.value) == choice.label)
        }
    }

    /// Real setter calls through a real store and SharedPreferences,
    /// replayed on `AppSettings`: after every call the two agree on whether
    /// anything was written, the stored section's bytes, the preferences
    /// and the fields.
    @Test("setters")
    func setters() throws {
        let f = try fixture("setters.json")
        let preferences = InMemoryPreferences()
        var s = AppSettings.load(section: nil, preferences: preferences)
        var section: JSONValue? = nil
        #expect(s == settings(f["loaded"]))
        for (index, step) in f["steps"].array.enumerated() {
            let op = step["op"].string!, arg = step["arg"]
            let at = "step \(index) \(op) \(String(describing: arg.value))"
            let update: SettingsUpdate
            switch op {
            case "currency": update = s.setBaseCurrencyCode(arg.string!)
            case "locale": update = s.setLocaleOverride(arg.string)
            case "lock": update = s.setAppLockEnabled(arg.bool!)
            case "timeout": update = s.setAutoLockTimeoutSeconds(arg.int!)
            case "hide": update = s.setHideBalances(arg.bool!)
            default:
                Issue.record("unknown op \(op)")
                continue
            }
            if case .write(let key, let value) = update {
                preferences.set(value, forKey: key)
                section = s.section(over: section)
            }
            #expect(step["wrote"].bool == { if case .write = update { true } else { false } }(), "\(at) wrote")
            #expect(s == settings(step["memory"]), "\(at) memory")
            #expect(section.map { DartJSON.encodeString($0) } == step["section"].string, "\(at) section")
            let dartPrefs = Dictionary(uniqueKeysWithValues: step["prefs"].keys.map { ($0, typed(step["prefs"][$0])) })
            #expect(preferences.all.mapValues(typed) == dartPrefs, "\(at) prefs")
        }
    }
}
