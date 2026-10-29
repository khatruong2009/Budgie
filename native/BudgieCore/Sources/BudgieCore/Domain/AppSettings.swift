import Foundation

public struct AppSettings: Hashable, Sendable {
    public var baseCurrencyCode: String
    public var localeOverride: String?
    public var appLockEnabled: Bool
    public var autoLockTimeoutSeconds: Int
    public var hideBalances: Bool

    /// Dart `AppSettingsProvider.load`: the store section wins per field,
    /// the mirrored preference is the fallback, then the default. A field of
    /// the wrong type reads as absent (Dart would throw).
    static func load(section: JSONValue?, preferences: PreferencesStore) -> AppSettings {
        let object = section?.objectValue ?? JSONObject()
        func string(_ key: String) -> String? { object[key]?.stringValue }
        func bool(_ key: String) -> Bool? { object[key]?.boolValue }
        let timeout: Int? = object["autoLockTimeoutSeconds"]?.numberValue.map { Int(DartNumbers.toInt($0.doubleValue, lexeme: $0)) }
        return AppSettings(
            baseCurrencyCode: string("baseCurrencyCode") ?? preferences.string(PreferenceKey.baseCurrencyCode) ?? "USD",
            localeOverride: string("localeOverride") ?? preferences.string(PreferenceKey.localeOverride),
            appLockEnabled: bool("appLockEnabled") ?? preferences.bool(PreferenceKey.appLockEnabled) ?? false,
            autoLockTimeoutSeconds: timeout ?? preferences.int(PreferenceKey.autoLockTimeoutSeconds).map { Int($0) } ?? 60,
            hideBalances: bool("hideBalances") ?? preferences.bool(PreferenceKey.hideBalances) ?? false)
    }

    /// The section as Dart `_persistAtomic` writes it, patched over the
    /// existing object so unknown keys survive.
    func section(over existing: JSONValue?) -> JSONValue {
        var object = existing?.objectValue ?? JSONObject()
        object["baseCurrencyCode"] = .string(baseCurrencyCode)
        object["localeOverride"] = localeOverride.map { .string($0) } ?? .null
        object["appLockEnabled"] = .bool(appLockEnabled)
        object["autoLockTimeoutSeconds"] = .int(autoLockTimeoutSeconds)
        object["hideBalances"] = .bool(hideBalances)
        return .object(object)
    }
}
