import Foundation

/// Why a tag or rule edit was refused. Nothing changed.
public enum CategorizationEditError: Error, Hashable, Sendable {
    /// The trimmed tag name is empty (categorization_provider.dart:59). The
    /// Flutter dialog closes silently before this can happen.
    case tagNameRequired
    /// A readable tag has this name after Dart `trim` and `toLowerCase`,
    /// compared as UTF-16 code units (:60-63).
    case duplicateTagName
    /// Swift-only: the trimmed merchant pattern is empty. Flutter's
    /// provider accepts it (the rule then never matches); its dialog keeps
    /// Add inert instead.
    case rulePatternRequired
    /// Swift-only: a bound is NaN or infinite, which JSON cannot hold.
    case ruleAmountNotFinite
    /// Swift-only (the editor and `updateRule`, `RuleDraft.boundsError`;
    /// Dart's `addRule` stores it): a bound is below zero. Every amount a rule is checked
    /// against is 0 or more (the form's `double.tryParse(text) ?? 0` on a
    /// decimal pad with no minus key, and a transaction needs more than 0),
    /// so under Dart's `matches` a negative minimum is no bound at all and
    /// a negative maximum never matches.
    case ruleAmountNegative
    /// Swift-only (as `ruleAmountNegative`): the minimum is above the maximum, so Dart's `matches`
    /// (both bounds inclusive) could never match. Equal bounds are allowed
    /// (that exact amount).
    case ruleMinimumAboveMaximum
    /// Swift-only: the rule names a tag id that no readable tag has. Flutter
    /// accepts it, but its backup import then refuses the whole file
    /// ("Backup rule references an unknown tag", backup.dart:131-133).
    case unknownTag(String)
    /// Swift-only (Flutter cannot edit a rule): no readable rule has the id.
    case ruleNotFound

    /// Flutter's `ArgumentError` copy for the tag errors (the page shows it
    /// in a snackbar); Swift copy for the rest, which Flutter never shows.
    public var message: String {
        switch self {
        case .tagNameRequired: "Tag name is required"
        case .duplicateTagName: "A tag with this name already exists"
        case .rulePatternRequired: "Merchant text is required"
        case .ruleAmountNotFinite: "Rule amounts must be numbers"
        case .ruleAmountNegative: "Amounts can't be negative"
        case .ruleMinimumAboveMaximum: "Minimum can't be more than maximum"
        case .unknownTag: "This rule uses a tag that no longer exists"
        case .ruleNotFound: "This rule no longer exists"
        }
    }
}

extension CategorizationEditError: LocalizedError {
    public var errorDescription: String? { message }
}

/// The fields of a Dart `CategorizationRule` (categorization_rule.dart:19-31)
/// with the constructor's defaults. Flutter's "New merchant rule" dialog
/// sets only the pattern, match type, transaction type, category and tags
/// (categorization_settings_page.dart:236-250); the rest keep their defaults.
public struct RuleDraft: Hashable, Sendable {
    /// Trimmed (Dart `trim`) when the rule is made.
    public var merchantPattern: String
    public var matchType: MerchantMatchType
    /// nil applies to both types; Flutter's dialog always sets one.
    public var transactionType: TransactionType?
    /// Inclusive bounds.
    public var minimumAmount: Double?
    public var maximumAmount: Double?
    public var category: String
    /// Stored as given (Flutter: tap order, a Set, so no duplicates).
    public var tagIds: [String]
    public var priority: Int
    public var isEnabled: Bool

    public init(
        merchantPattern: String, matchType: MerchantMatchType = .contains, transactionType: TransactionType?,
        minimumAmount: Double? = nil, maximumAmount: Double? = nil, category: String, tagIds: [String] = [],
        priority: Int = 0, isEnabled: Bool = true
    ) {
        self.merchantPattern = merchantPattern
        self.matchType = matchType
        self.transactionType = transactionType
        self.minimumAmount = minimumAmount
        self.maximumAmount = maximumAmount
        self.category = category
        self.tagIds = tagIds
        self.priority = priority
        self.isEnabled = isEnabled
    }
}

extension RuleDraft {
    /// Swift-only bound checks of the rule editor and `updateRule`, for
    /// finite bounds: a negative bound, then a minimum above the maximum
    /// (see `CategorizationEditError`). `addRule` does not apply them, as
    /// Dart's provider stores such rules.
    public var boundsError: CategorizationEditError? {
        if [minimumAmount, maximumAmount].contains(where: { ($0 ?? 0) < 0 }) { return .ruleAmountNegative }
        if let minimumAmount, let maximumAmount, minimumAmount > maximumAmount { return .ruleMinimumAboveMaximum }
        return nil
    }
}

/// Tag and rule management (`CategorizationProvider` addTag, deleteTag,
/// addRule, deleteRule; categorization_provider.dart:56-126), plus the
/// Swift-only rule edit and enable switch, which write only fields of
/// Dart's schema that its `matches` already applies. Every mutator
/// validates before it changes anything. Only readable rows take part;
/// unreadable rows stay verbatim. Rows are patched in place, new ones have
/// Dart's `toJson` shape.
extension FinancialData {
    /// Dart's `rules` getter (priority descending): the order the Tags &
    /// rules page lists them and `suggest` tries them.
    public var rulesByPriority: [CategorizationRuleRecord] { CategorizationEngine.ordered(rules) }

    /// The error `addTag` would throw for `name`, else nil.
    public func validateTagName(_ name: String) -> CategorizationEditError? {
        let trimmed = DartString.trim(name)
        if trimmed.isEmpty { return .tagNameRequired }
        let wanted = DartString.lowercase(trimmed)
        return tags.contains { DartString.equal(DartString.lowercase($0.name), wanted) } ? .duplicateTagName : nil
    }

    /// Dart `addTag`: the trimmed name, appended. `id` is Dart's
    /// `Uuid().v4()`. Write `transactionTags`.
    @discardableResult
    public mutating func addTag(name: String, colorToken: String = "accent", id: String) throws(CategorizationEditError)
        -> TransactionTagRecord
    {
        if let error = validateTagName(name) { throw error }
        let tag = TransactionTagRecord.make(id: id, name: name, colorToken: colorToken)
        tagRows.append(.record(tag))
        return tag
    }

    /// Dart `deleteTag`: every tag with this id goes, and every rule drops
    /// the id from its `tagIds`. Transactions keep it (D9: orphan ids, as in
    /// Flutter). Returns the sections to write in one commit, tags then
    /// rules (Dart writes both, as two commits, even when nothing changed);
    /// empty when nothing changed.
    @discardableResult
    public mutating func deleteTag(id: String) -> [String] {
        var changed = tagRows.removeRows(id: id)
        for index in ruleRows.indices {
            guard let rule = ruleRows[index].record, rule.tagIds.contains(where: { DartString.equal($0, id) }) else { continue }
            ruleRows[index] = .record(rule.removingTag(id))
            changed = true
        }
        return changed ? [Section.transactionTags, Section.categorizationRules] : []
    }

    /// The error `addRule` would throw for `draft`, else nil (Swift-only
    /// checks; see `CategorizationEditError`). `keepingTagIDs` are ids the
    /// edited rule already stores: they may stay without a tag (an edit
    /// does not refuse over an orphan it did not add; the editor cannot
    /// show a chip for it).
    public func validateRule(_ draft: RuleDraft, keepingTagIDs: [String] = []) -> CategorizationEditError? {
        if DartString.trim(draft.merchantPattern).isEmpty { return .rulePatternRequired }
        if [draft.minimumAmount, draft.maximumAmount].contains(where: { !($0 ?? 0).isFinite }) { return .ruleAmountNotFinite }
        let known = tags.map(\.id) + keepingTagIDs
        if let unknown = draft.tagIds.first(where: { id in !known.contains { DartString.equal($0, id) } }) {
            return .unknownTag(unknown)
        }
        return nil
    }

    /// Dart `addRule`: rules with the same id go, then the new rule is
    /// appended (so re-adding an id moves it to the end). Write
    /// `categorizationRules`. Bounds Dart's provider stores are accepted
    /// (a minimum above the maximum, a negative bound: Fixtures/tags has
    /// one); the rule editor refuses them first (`RuleDraft.boundsError`).
    @discardableResult
    public mutating func addRule(_ draft: RuleDraft, id: String) throws(CategorizationEditError) -> CategorizationRuleRecord {
        if let error = validateRule(draft) { throw error }
        let rule = CategorizationRuleRecord.make(id: id, draft)
        ruleRows.removeRows(id: id)
        ruleRows.append(.record(rule))
        return rule
    }

    /// Swift-only (Flutter can only add and delete a rule): edits the rule
    /// in place, keeping its id and stored position, and patches only the
    /// keys whose value changed (`CategorizationRuleRecord.applying`), so a
    /// row Dart wrote stays Dart's `toJson` shape and a foreign row keeps
    /// its unknown keys and lexemes. Every readable row with the id is
    /// edited (ids are what Dart's add and delete go by; the backup import
    /// refuses repeated ids anyway). Validated as `addRule`, except that
    /// tag ids the rule already stores may stay without a tag, plus the
    /// editor's `RuleDraft.boundsError`. Returns whether anything changed
    /// (write `categorizationRules` then).
    @discardableResult
    public mutating func updateRule(id: String, _ draft: RuleDraft) throws(CategorizationEditError) -> Bool {
        let indices = ruleRows.indices.filter { ruleRows[$0].hasID(id) }
        guard let first = indices.first, let current = ruleRows[first].record else { throw .ruleNotFound }
        if let error = validateRule(draft, keepingTagIDs: current.tagIds) ?? draft.boundsError { throw error }
        var changed = false
        for index in indices {
            guard let updated = ruleRows[index].record?.applying(draft) else { continue }
            ruleRows[index] = .record(updated)
            changed = true
        }
        return changed
    }

    /// Swift-only: turns the rule on or off (`isEnabled`, which Dart's
    /// `matches` honours), patching only that key of every readable row
    /// with the id. False when nothing changed (unknown id, or already so).
    @discardableResult
    public mutating func setRuleEnabled(id: String, _ enabled: Bool) -> Bool {
        var changed = false
        for index in ruleRows.indices {
            guard let rule = ruleRows[index].record, DartString.equal(rule.id, id) else { continue }
            var draft = rule.draft
            draft.isEnabled = enabled
            guard let updated = rule.applying(draft) else { continue }
            ruleRows[index] = .record(updated)
            changed = true
        }
        return changed
    }

    /// Dart `deleteRule`: every rule with this id. False when there was none
    /// (Dart still writes the unchanged list). Write `categorizationRules`.
    @discardableResult
    public mutating func deleteRule(id: String) -> Bool {
        ruleRows.removeRows(id: id)
    }
}
