import Foundation

/// A decoded backup (`BackupEnvelope.decode`): what it replaces, what it
/// leaves alone (D10), and the confirmation Flutter shows before restoring.
///
/// Every row is already in canonical Dart `toJson` form. A nil section or
/// setting was absent or null in the file: the restore keeps the current
/// one (Flutter resets it; D10).
public struct RestorePlan: Sendable {
    /// One `categoryBudgetLimits` entry as decoded (Dart map: first position,
    /// last value; limits <= 0 included, the restore drops them).
    public struct BudgetLimit: Hashable, Sendable {
        /// The key's exact code units (it can hold a lone surrogate).
        let key: JSONString
        public let value: Double
        public var name: String { key.value }
    }

    public enum LocaleChange: Hashable, Sendable {
        /// `localeOverride` absent: keep the current one.
        case keep
        /// Present: the value (nil = "Match device"), trimmed at restore.
        case set(String?)
    }

    public let schemaVersion: Int64
    public let transactions: [TransactionRecord]?
    public let netWorthEntries: [NetWorthEntryRecord]?
    public let budgetLimits: [BudgetLimit]?
    public let savingsGoals: [SavingsGoalRecord]?
    public let templates: [RecurringTemplate]?
    /// "light", "dark" or "system"; nil leaves the theme alone (Flutter too).
    public let themeMode: String?
    public let categories: [CategoryInfo]?
    public let tags: [TransactionTagRecord]?
    /// File order (a Flutter export writes them by priority, highest first).
    public let rules: [CategorizationRuleRecord]?
    /// Trimmed and uppercased.
    public let baseCurrencyCode: String?
    public let localeOverride: LocaleChange
    public let appLockEnabled: Bool?
    public let autoLockTimeoutSeconds: Int?
    public let hideBalances: Bool?

    // MARK: - Confirmation (`_confirmRestore`, settings_page.dart:525-577)

    public static let confirmationTitle = "Replace all data?"
    public static let cancelButtonTitle = "Cancel"
    public static let replaceButtonTitle = "Replace"

    /// The counts Flutter's dialog shows: decoded list sizes (duplicate
    /// transaction ids and budgets <= 0 included), 0 for an absent key.
    public struct Counts: Hashable, Sendable {
        public let transactions: Int
        public let netWorthEntries: Int
        public let budgets: Int
        public let goals: Int
        public let recurringTemplates: Int
    }

    public var counts: Counts {
        Counts(
            transactions: transactions?.count ?? 0, netWorthEntries: netWorthEntries?.count ?? 0,
            budgets: budgetLimits?.count ?? 0, goals: savingsGoals?.count ?? 0,
            recurringTemplates: templates?.count ?? 0)
    }

    /// Flutter's message, verbatim (no pluralisation: "1 transactions").
    public var flutterConfirmationMessage: String {
        let c = counts
        return "This will import \(c.transactions) transactions, \(c.netWorthEntries) net worth entries, "
            + "\(c.budgets) budgets, \(c.goals) goals and \(c.recurringTemplates) recurring templates, "
            + "replacing everything currently in Budgie. This cannot be undone."
    }

    /// What the restore keeps (D10), in the words of the dialog, in `data`
    /// order: "transactions", "net worth entries", "budgets", "goals",
    /// "recurring templates", "categories", "tags", "rules", "settings"
    /// (any of the five settings not provided). Empty for a full backup.
    public var keptItems: [String] {
        var items: [String] = []
        if transactions == nil { items.append("transactions") }
        if netWorthEntries == nil { items.append("net worth entries") }
        if budgetLimits == nil { items.append("budgets") }
        if savingsGoals == nil { items.append("goals") }
        if templates == nil { items.append("recurring templates") }
        if categories == nil { items.append("categories") }
        if tags == nil { items.append("tags") }
        if rules == nil { items.append("rules") }
        if baseCurrencyCode == nil || localeOverride == .keep || appLockEnabled == nil || autoLockTimeoutSeconds == nil
            || hideBalances == nil
        {
            items.append("settings")
        }
        return items
    }

    /// The dialog message: Flutter's, plus "Your categories, tags, rules
    /// and settings are kept." (the actual kept items) when the file leaves
    /// something unchanged.
    public var confirmationMessage: String {
        let kept = keptItems
        guard let last = kept.last else { return flutterConfirmationMessage }
        let list = kept.count == 1 ? last : kept.dropLast().joined(separator: ", ") + " and " + last
        return flutterConfirmationMessage + " Your \(list) are kept."
    }
}

extension FinancialData {
    public struct RestoreResult: Sendable {
        /// The data after the restore (and the recurring generator).
        public let data: FinancialData
        /// All ten sections in `Section.all` order, for one `updateSections`.
        public let sections: [(String, JSONValue)]
        /// `plan.preferenceWrites`: the settings mirrors to write after the
        /// commit, in Flutter's order; a nil value removes the key.
        public let preferenceWrites: [(key: String, value: PreferenceValue?)]
        /// Apply through the theme setter (a no-op when unchanged, as Flutter).
        public let themeMode: String?
        /// Rows the recurring generator added.
        public let generatedTransactions: Int
    }

    /// The state after restoring `plan` over this data, as Flutter ends up
    /// after its restore sequence (settings_page.dart:421-475), in one step:
    ///
    /// - transactions: duplicate ids regenerated (the first keeps its id);
    /// - budget limits <= 0 dropped; empty categories become the built-ins,
    ///   sort orders renumbered per type; tags and rules in file order;
    /// - settings: currency as decoded, locale trimmed (blank = Match device);
    /// - `selectedNetWorthMonth` stays the current one (Flutter too);
    /// - then the recurring generator (Flutter runs it after the restore),
    ///   and the launch pass `ensureLegacyCategories`, which Flutter runs
    ///   only at its next launch (the end state after a relaunch is equal).
    ///
    /// Sections the plan does not provide (D10) keep the current rows,
    /// unreadable ones included. Pure: nothing is written.
    public func restoring(_ plan: RestorePlan, now: DartDateTime, newID: () -> String) -> RestoreResult {
        var next = self
        if let transactions = plan.transactions {
            var seen = Set<[UInt16]>()
            next.transactionRows = transactions.map { record in
                let units = record.raw["id"]?.stringCodeUnits ?? Array(record.id.utf16)
                if seen.insert(units).inserted { return .record(record) }
                let fresh = record.withID(newID())
                seen.insert(Array(fresh.id.utf16))
                return .record(fresh)
            }
        }
        if let entries = plan.netWorthEntries { next.netWorthRows = entries.map { .record($0) } }
        if let limits = plan.budgetLimits {
            next.budgetLimitsObject = JSONObject(members: limits.filter { $0.value > 0 }.map {
                JSONObject.Member(key: $0.key, value: .double($0.value))
            })
        }
        if let goals = plan.savingsGoals { next.goalRows = goals.map { .record($0) } }
        if let templates = plan.templates { next.templateRows = templates.map { .record($0) } }
        if let categories = plan.categories {
            next.categoryRows = (categories.isEmpty ? CategoryCatalog.builtIn : categories).map { .record($0) }
            next.normalizeCategorySortOrders()
        }
        if let tags = plan.tags { next.tagRows = tags.map { .record($0) } }
        if let rules = plan.rules { next.ruleRows = rules.map { .record($0) } }

        if let currency = plan.baseCurrencyCode { next.appSettings.baseCurrencyCode = currency }
        if case .set = plan.localeOverride { next.appSettings.localeOverride = plan.resolvedLocaleOverride }
        if let lock = plan.appLockEnabled { next.appSettings.appLockEnabled = lock }
        if let timeout = plan.autoLockTimeoutSeconds { next.appSettings.autoLockTimeoutSeconds = timeout }
        if let hide = plan.hideBalances { next.appSettings.hideBalances = hide }

        let generated = RecurringGenerator.generateDue(in: &next, now: now, clock: { now }, newID: newID)
        _ = next.ensureLegacyCategories(stored: nil, newID: newID)

        return RestoreResult(
            data: next, sections: Section.all.map { ($0, next.serializedSection($0)!) },
            preferenceWrites: plan.preferenceWrites, themeMode: plan.themeMode,
            generatedTransactions: generated.generated.count)
    }
}

extension RestorePlan {
    /// `AppSettingsProvider.restoreFromBackup`: trimmed, blank is Match
    /// device (nil). Only meaningful when `localeOverride` is `.set`.
    var resolvedLocaleOverride: String? {
        guard case .set(let value) = localeOverride, let trimmed = value.map(DartString.trim), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// The settings mirrors to write after the commit, in Flutter's order
    /// (app_settings_provider.dart:127-138); a nil value removes the key.
    /// Only settings the file provides (D10).
    public var preferenceWrites: [(key: String, value: PreferenceValue?)] {
        var writes: [(key: String, value: PreferenceValue?)] = []
        if let currency = baseCurrencyCode { writes.append((PreferenceKey.baseCurrencyCode, .string(currency))) }
        if case .set = localeOverride {
            writes.append((PreferenceKey.localeOverride, resolvedLocaleOverride.map { .string($0) }))
        }
        if let lock = appLockEnabled { writes.append((PreferenceKey.appLockEnabled, .bool(lock))) }
        if let timeout = autoLockTimeoutSeconds { writes.append((PreferenceKey.autoLockTimeoutSeconds, .int(Int64(timeout)))) }
        if let hide = hideBalances { writes.append((PreferenceKey.hideBalances, .bool(hide))) }
        return writes
    }

    /// Store sections whose content comes from the file (`appSettings` when
    /// it provides any setting). The restore still writes all ten sections
    /// in one commit; the others are rewritten unchanged.
    public var replacedSections: [String] {
        var sections: [String] = []
        if transactions != nil { sections.append(Section.transactions) }
        if netWorthEntries != nil { sections.append(Section.netWorthEntries) }
        if budgetLimits != nil { sections.append(Section.categoryBudgetLimits) }
        if savingsGoals != nil { sections.append(Section.savingsGoals) }
        if templates != nil { sections.append(Section.recurringTransactions) }
        if categories != nil { sections.append(Section.categories) }
        if tags != nil { sections.append(Section.transactionTags) }
        if rules != nil { sections.append(Section.categorizationRules) }
        if !preferenceWrites.isEmpty { sections.append(Section.appSettings) }
        return sections
    }
}

extension JSONValue {
    /// A string's exact code units (lone surrogates included).
    var stringCodeUnits: [UInt16]? {
        if case .string(let s) = self { return s.codeUnits }
        return nil
    }
}
