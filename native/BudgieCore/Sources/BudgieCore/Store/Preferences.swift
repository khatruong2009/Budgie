import Foundation

/// A value as Flutter's `shared_preferences` plugin stores it in
/// `NSUserDefaults` (research B section 3): String -> NSString,
/// List<String> -> NSArray of NSString, int -> NSNumber (q),
/// double -> NSNumber (d), bool -> CFBoolean.
public enum PreferenceValue: Hashable, Sendable {
    case string(String)
    case stringList([String])
    case int(Int64)
    case double(Double)
    case bool(Bool)
}

/// Keys the Flutter app keeps in `NSUserDefaults.standard` (with the
/// plugin's `flutter.` prefix), and native-only keys (`native.` prefix, which
/// the Flutter plugin never reads).
public enum PreferenceKey {
    public static let flutterPrefix = "flutter."

    public static func flutter(_ dartKey: String) -> String { flutterPrefix + dartKey }

    // Financial sections (legacy, migrated then removed).
    public static let transactions = flutter("transactions")
    public static let netWorthEntries = flutter("net_worth_entries")
    public static let netWorthSelectedMonth = flutter("net_worth_selected_month")
    public static let categoryBudgetLimits = flutter("category_budget_limits")
    public static let savingsGoals = flutter("savings_goals")
    public static let recurringTransactions = flutter("recurring_transactions")
    public static let categories = flutter("categories_v1")
    public static let transactionTags = flutter("transaction_tags_v1")
    public static let categorizationRules = flutter("categorization_rules_v1")
    public static let legacyEnvelope = flutter("financial_store_v1")
    public static let legacyEnvelopeBackup = flutter("financial_store_v1_backup")

    // Real preferences.
    public static let themeMode = flutter("themeMode")
    public static let onboardingCompleted = flutter("onboarding_completed")
    /// Insight cards dismissed for good (StringList, UTF-16 sorted), and
    /// snoozed until a time (String holding a JSON object of id to local
    /// ISO date). Literals from local_insights_section.dart:21-22.
    public static let localInsightsDismissed = flutter("local_insights_dismissed_v1")
    public static let localInsightsSnoozed = flutter("local_insights_snoozed_v1")

    // Settings mirror (dual-written by the app, never removed).
    public static let baseCurrencyCode = flutter("base_currency_code")
    public static let localeOverride = flutter("locale_override")
    public static let appLockEnabled = flutter("app_lock_enabled")
    public static let autoLockTimeoutSeconds = flutter("auto_lock_timeout_seconds")
    public static let hideBalances = flutter("hide_balances")

    // Legacy starting balances (read by the net worth model, never removed).
    public static let startingAssets = flutter("starting_assets")
    public static let startingLiabilities = flutter("starting_liabilities")

    /// `AtomicFinancialStore.migratedPreferenceKeys`: removed after a
    /// verified migration commit, and only then.
    public static let migratedKeys: [String] = [
        legacyEnvelope, legacyEnvelopeBackup, transactions, netWorthEntries, netWorthSelectedMonth,
        categoryBudgetLimits, savingsGoals, recurringTransactions, categories, transactionTags,
        categorizationRules,
    ]

    // Native-only.
    public static let lastCommittedChecksum = "native.lastCommittedChecksum"
    public static let acknowledgedCorruptFiles = "native.acknowledgedCorruptFiles"
}

public protocol PreferencesStore: AnyObject, Sendable {
    func value(forKey key: String) -> PreferenceValue?
    /// Sets or (with nil) removes a key.
    func set(_ value: PreferenceValue?, forKey key: String)
    func allKeys() -> [String]
}

public extension PreferencesStore {
    func contains(_ key: String) -> Bool { value(forKey: key) != nil }

    /// Dart `getString`. A value of another type reads as absent (Dart would
    /// throw a cast error; nothing in the app writes mismatched types).
    func string(_ key: String) -> String? {
        if case .string(let value) = value(forKey: key) { return value }
        return nil
    }

    /// Dart `getStringList`. A value of another type, or a list holding a
    /// non-string, reads as absent (Dart would throw a cast error).
    func stringList(_ key: String) -> [String]? {
        if case .stringList(let value) = value(forKey: key) { return value }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let value) = value(forKey: key) { return value }
        return nil
    }

    func int(_ key: String) -> Int64? {
        if case .int(let value) = value(forKey: key) { return value }
        return nil
    }

    /// Dart `getDouble`: an int stored for a double key reads as its value
    /// (the plugin hands Dart a num).
    func double(_ key: String) -> Double? {
        switch value(forKey: key) {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }
}

/// The first-launch tour's flag (onboarding_tutorial.dart:29-49), shared
/// with the Flutter build: a CFBoolean `true` under
/// `flutter.onboarding_completed`, only ever written true.
public enum OnboardingFlag {
    /// Flutter `getBool(onboarding_completed) ?? false`. A value of another
    /// type reads as not completed (Dart's `getBool` throws on it and the
    /// gate then shows the tour).
    public static func isCompleted(_ preferences: some PreferencesStore) -> Bool {
        preferences.bool(PreferenceKey.onboardingCompleted) ?? false
    }

    /// Flutter `setBool(onboarding_completed, true)`. The key is removed
    /// first: `NSUserDefaults` treats `@YES` and a stored `@1` as equal and
    /// would skip the set, leaving a number the next launch reads as not
    /// completed.
    public static func markCompleted(_ preferences: some PreferencesStore) {
        preferences.set(nil, forKey: PreferenceKey.onboardingCompleted)
        preferences.set(.bool(true), forKey: PreferenceKey.onboardingCompleted)
    }

    /// Removes the flag so the tour shows again. Neither app does this;
    /// UI tests and scripted runs use it to force a first launch.
    public static func reset(_ preferences: some PreferencesStore) {
        preferences.set(nil, forKey: PreferenceKey.onboardingCompleted)
    }
}

/// `NSUserDefaults.standard`, read through the app's persistent domain (as
/// the Flutter plugin does), so argument and registration domains never leak
/// into what counts as stored data.
public final class UserDefaultsPreferences: PreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let domainName: String

    public init(defaults: UserDefaults = .standard, domainName: String) {
        self.defaults = defaults
        self.domainName = domainName
    }

    private var domain: [String: Any] {
        defaults.persistentDomain(forName: domainName) ?? [:]
    }

    public func value(forKey key: String) -> PreferenceValue? {
        guard let raw = domain[key] else { return nil }
        return UserDefaultsPreferences.decode(raw)
    }

    public func set(_ value: PreferenceValue?, forKey key: String) {
        switch value {
        case nil: defaults.removeObject(forKey: key)
        case .string(let v): defaults.set(v, forKey: key)
        case .stringList(let v): defaults.set(v, forKey: key)
        case .int(let v): defaults.set(NSNumber(value: v), forKey: key)
        case .double(let v): defaults.set(NSNumber(value: v), forKey: key)
        case .bool(let v): defaults.set(v, forKey: key)
        }
    }

    public func allKeys() -> [String] {
        domain.keys.sorted()
    }

    /// The whole persistent domain as a binary plist, for the pre-migration
    /// backup.
    public func exportDomain() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
    }

    /// Maps a property-list value to the type the Flutter plugin would
    /// report. Booleans are CFBoolean; `as? Bool` would also match 0 and 1.
    static func decode(_ raw: Any) -> PreferenceValue? {
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .int(number.int64Value)
        }
        if let string = raw as? String { return .string(string) }
        if let list = raw as? [Any] {
            let strings = list.compactMap { $0 as? String }
            return strings.count == list.count ? .stringList(strings) : nil
        }
        return nil
    }
}
