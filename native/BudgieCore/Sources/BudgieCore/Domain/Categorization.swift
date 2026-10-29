import Foundation

// MARK: - Transaction tag

/// Dart `TransactionTag` (`transaction_tag.dart`).
public struct TransactionTagRecord: Identifiable, Hashable, Sendable {
    public private(set) var id: String
    public private(set) var name: String
    public private(set) var colorToken: String
    public private(set) var raw: JSONObject

    /// Dart `TransactionTag.fromJson`. nil where Dart's casts would throw.
    /// A missing id gets a fresh one (Dart's constructor), written into
    /// `raw` so the next save keeps it, as Dart's `toJson` would.
    static func parse(_ value: JSONValue, newID: () -> String) -> TransactionTagRecord? {
        guard case .object(var object) = value else { return nil }
        guard case .some(let id) = Read.optionalString(object, "id") else { return nil }
        guard case .some(let name) = Read.optionalString(object, "name") else { return nil }
        guard case .some(let colorToken) = Read.optionalString(object, "colorToken") else { return nil }
        let resolvedID = id ?? newID()
        if id == nil { object["id"] = .string(resolvedID) }
        return TransactionTagRecord(
            id: resolvedID, name: DartString.trim(name ?? ""), colorToken: colorToken ?? "accent", raw: object)
    }

    /// A new tag as Dart `TransactionTag(...).toJson()` writes it.
    public static func make(id: String, name: String, colorToken: String = "accent") -> TransactionTagRecord {
        let trimmed = DartString.trim(name)
        return TransactionTagRecord(
            id: id, name: trimmed, colorToken: colorToken,
            raw: JSONObject(ordered: [("id", .string(id)), ("name", .string(trimmed)), ("colorToken", .string(colorToken))]))
    }
}

// MARK: - Categorization rule

public enum MerchantMatchType: String, Sendable, Hashable, CaseIterable {
    case contains, startsWith, exact
}

/// Dart `CategorizationRule` (`categorization_rule.dart`).
public struct CategorizationRuleRecord: Identifiable, Hashable, Sendable {
    public private(set) var id: String
    public private(set) var merchantPattern: String
    public private(set) var matchType: MerchantMatchType
    public private(set) var transactionType: TransactionType?
    public private(set) var minimumAmount: Double?
    public private(set) var maximumAmount: Double?
    public private(set) var category: String
    public private(set) var tagIds: [String]
    public private(set) var priority: Int
    public private(set) var isEnabled: Bool
    public private(set) var raw: JSONObject

    /// Dart `CategorizationRule.fromJson`, with its defaults. nil where
    /// Dart's casts would throw.
    static func parse(_ value: JSONValue, newID: () -> String) -> CategorizationRuleRecord? {
        guard case .object(var object) = value else { return nil }
        guard case .some(let id) = Read.optionalString(object, "id") else { return nil }
        guard case .some(let pattern) = Read.optionalString(object, "merchantPattern") else { return nil }
        guard case .some(let typeName) = Read.optionalString(object, "transactionType") else { return nil }
        guard case .some(let minimum) = Read.optionalDouble(object, "minimumAmount") else { return nil }
        guard case .some(let maximum) = Read.optionalDouble(object, "maximumAmount") else { return nil }
        guard case .some(let category) = Read.optionalString(object, "category") else { return nil }
        guard let tagIds = Read.stringArray(object, "tagIds") else { return nil }
        guard case .some(let storedPriority) = Read.optionalNumber(object, "priority") else { return nil }
        let priority = storedPriority ?? 0
        guard case .some(let enabledFlag) = Read.optionalBool(object, "isEnabled") else { return nil }
        let isEnabled = enabledFlag ?? true
        let resolvedID = id ?? newID()
        if id == nil { object["id"] = .string(resolvedID) }
        // `matchType` accepts any JSON value; an unknown one is `contains`.
        let matchType = object["matchType"]?.stringValue.flatMap(MerchantMatchType.init(rawValue:)) ?? .contains
        return CategorizationRuleRecord(
            id: resolvedID, merchantPattern: DartString.trim(pattern ?? ""), matchType: matchType,
            transactionType: typeName.map { $0 == "income" ? .income : .expense },
            minimumAmount: minimum, maximumAmount: maximum, category: category ?? "General", tagIds: tagIds,
            priority: priority, isEnabled: isEnabled, raw: object)
    }
}

extension CategorizationRuleRecord {
    /// A new rule as Dart `CategorizationRule(...).toJson()` writes it
    /// (categorization_rule.dart:19-31, 59-70): the pattern trimmed, keys in
    /// Dart's order with null values written, bounds as doubles (`20.0`),
    /// `tagIds` as given (Flutter passes the selection order).
    public static func make(id: String, _ draft: RuleDraft) -> CategorizationRuleRecord {
        let pattern = DartString.trim(draft.merchantPattern)
        func bound(_ value: Double?) -> JSONValue { value.map { .double($0) } ?? .null }
        let raw = JSONObject(ordered: [
            ("id", .string(id)),
            ("merchantPattern", .string(pattern)),
            ("matchType", .string(draft.matchType.rawValue)),
            ("transactionType", draft.transactionType.map { .string($0.rawValue) } ?? .null),
            ("minimumAmount", bound(draft.minimumAmount)),
            ("maximumAmount", bound(draft.maximumAmount)),
            ("category", .string(draft.category)),
            ("tagIds", .array(draft.tagIds.map { .string($0) })),
            ("priority", .int(draft.priority)),
            ("isEnabled", .bool(draft.isEnabled)),
        ])
        return CategorizationRuleRecord(
            id: id, merchantPattern: pattern, matchType: draft.matchType, transactionType: draft.transactionType,
            minimumAmount: draft.minimumAmount, maximumAmount: draft.maximumAmount, category: draft.category,
            tagIds: draft.tagIds, priority: draft.priority, isEnabled: draft.isEnabled, raw: raw)
    }

    /// Dart `deleteTag`'s rebuild of a rule with every occurrence of `tagID`
    /// dropped from `tagIds` (compared as UTF-16). Only that key is patched;
    /// stored elements Dart ignores (non-strings) stay.
    func removingTag(_ tagID: String) -> CategorizationRuleRecord {
        var copy = self
        let units = Array(tagID.utf16)
        copy.tagIds.removeAll { DartString.equal($0, tagID) }
        if case .array(let items)? = raw["tagIds"] {
            copy.raw["tagIds"] = .array(items.filter { item in
                if case .string(let s) = item { return s.codeUnits != units }
                return true
            })
        }
        return copy
    }

    /// Swift-only edit in place: the rule with `draft`'s fields, patching in
    /// `raw` only the keys whose value differs (compared as Dart reads them:
    /// strings as UTF-16 after the pattern's Dart `trim`, bounds as
    /// doubles, so a stored `5` for a draft's 5.0 stays `5`). The id, the
    /// key order, unknown keys and untouched lexemes stay. A cleared bound
    /// or "any type" is written as a present `null`, as Dart's `toJson`
    /// does; a key the row lacks is appended only when its value changes.
    /// nil when nothing differs.
    func applying(_ draft: RuleDraft) -> CategorizationRuleRecord? {
        var copy = self
        var changed = false
        let pattern = DartString.trim(draft.merchantPattern)
        if !DartString.equal(pattern, merchantPattern) {
            copy.merchantPattern = pattern
            copy.raw["merchantPattern"] = .string(pattern)
            changed = true
        }
        if draft.matchType != matchType {
            copy.matchType = draft.matchType
            copy.raw["matchType"] = .string(draft.matchType.rawValue)
            changed = true
        }
        if draft.transactionType != transactionType {
            copy.transactionType = draft.transactionType
            copy.raw["transactionType"] = draft.transactionType.map { .string($0.rawValue) } ?? .null
            changed = true
        }
        if draft.minimumAmount != minimumAmount {
            copy.minimumAmount = draft.minimumAmount
            copy.raw["minimumAmount"] = draft.minimumAmount.map { .double($0) } ?? .null
            changed = true
        }
        if draft.maximumAmount != maximumAmount {
            copy.maximumAmount = draft.maximumAmount
            copy.raw["maximumAmount"] = draft.maximumAmount.map { .double($0) } ?? .null
            changed = true
        }
        if !DartString.equal(draft.category, category) {
            copy.category = draft.category
            copy.raw["category"] = .string(draft.category)
            changed = true
        }
        if draft.tagIds.count != tagIds.count || zip(draft.tagIds, tagIds).contains(where: { !DartString.equal($0, $1) }) {
            copy.tagIds = draft.tagIds
            copy.raw["tagIds"] = .array(draft.tagIds.map { .string($0) })
            changed = true
        }
        if draft.priority != priority {
            copy.priority = draft.priority
            copy.raw["priority"] = .int(draft.priority)
            changed = true
        }
        if draft.isEnabled != isEnabled {
            copy.isEnabled = draft.isEnabled
            copy.raw["isEnabled"] = .bool(draft.isEnabled)
            changed = true
        }
        return changed ? copy : nil
    }

    /// The rule's fields as a draft (the editor's prefill; `applying` it
    /// changes nothing).
    public var draft: RuleDraft {
        RuleDraft(
            merchantPattern: merchantPattern, matchType: matchType, transactionType: transactionType,
            minimumAmount: minimumAmount, maximumAmount: maximumAmount, category: category, tagIds: tagIds,
            priority: priority, isEnabled: isEnabled)
    }

    /// The category rename (Dart `CategorizationProvider.renameCategory`
    /// rebuilds the rule with only `category` changed).
    func with(category: String) -> CategorizationRuleRecord {
        var copy = self
        copy.category = category
        copy.raw["category"] = .string(category)
        return copy
    }

    /// Dart `CategorizationRule.matches` (categorization_rule.dart:72-89):
    /// disabled or an empty pattern never matches; the type must agree when
    /// the rule has one; both amount bounds are inclusive; then the trimmed,
    /// lowercased description is compared with the lowercased pattern as
    /// UTF-16 code units.
    public func matches(type: TransactionType, description: String, amount: Double) -> Bool {
        if !isEnabled || merchantPattern.isEmpty { return false }
        if let transactionType, transactionType != type { return false }
        if let minimumAmount, amount < minimumAmount { return false }
        if let maximumAmount, amount > maximumAmount { return false }

        let candidate = DartString.lowercase(DartString.trim(description))
        let pattern = DartString.lowercase(merchantPattern)
        switch matchType {
        case .contains: return DartString.contains(candidate, pattern)
        case .startsWith: return DartString.hasPrefix(candidate, pattern)
        case .exact: return DartString.equal(candidate, pattern)
        }
    }
}

/// Dart `CategorizationProvider.rules` and `suggest`
/// (categorization_provider.dart:26-30, 152-167).
public enum CategorizationEngine {
    /// Dart's `rules` getter: a copy sorted by priority descending with
    /// Dart's `List.sort` (`DartSort`), so equal priorities come out in
    /// Dart's order too: stored order up to 33 rules, the quicksort's order
    /// from 34.
    public static func ordered(_ rules: [CategorizationRuleRecord]) -> [CategorizationRuleRecord] {
        DartSort.sorted(rules) { DartSort.compare($1.priority, $0.priority) }
    }

    /// Dart `suggest`: the first rule in `ordered` order that matches.
    public static func suggest(
        rules: [CategorizationRuleRecord], type: TransactionType, description: String, amount: Double
    ) -> CategorizationRuleRecord? {
        ordered(rules).first { $0.matches(type: type, description: description, amount: amount) }
    }

    /// The transaction form's use of `suggest` (`applySuggestion`,
    /// transaction_form.dart:106-121): the first matching rule, or nil when
    /// its category is not one of `activeCategoryNames` (the form's list for
    /// the type, compared as UTF-16). A later matching rule is not tried.
    public static func suggestion(
        rules: [CategorizationRuleRecord], type: TransactionType, description: String, amount: Double,
        activeCategoryNames: [String]
    ) -> CategorizationRuleRecord? {
        guard let rule = suggest(rules: rules, type: type, description: description, amount: amount),
            activeCategoryNames.contains(where: { DartString.equal($0, rule.category) })
        else { return nil }
        return rule
    }
}
