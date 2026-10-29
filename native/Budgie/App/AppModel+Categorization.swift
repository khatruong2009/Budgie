import BudgieCore
import Foundation

extension AppModel {
    // MARK: - Categories (category management)

    /// Runs one edit on a copy (a refused edit leaves `data` untouched),
    /// then memory first and one awaited commit of the sections it returns.
    /// A change to the transactions rebuilds the ledger.
    private func editCopy<E: Error>(
        _ edit: (inout FinancialData) throws(E) -> [String]
    ) async -> EditOutcome<E> {
        guard var copy = data else { return .unchanged }
        let sections: [String]
        do throws(E) {
            sections = try edit(&copy)
        } catch {
            return .rejected(error)
        }
        guard !sections.isEmpty else { return .unchanged }
        data = copy
        if sections.contains(Section.transactions) { transactionsChanged() }
        return await persist(sections) ? .saved : .failed
    }

    /// Dart `categoriesFor(type, includeArchived:)`: the management list.
    func categoryDefinitions(type: TransactionType, includeArchived: Bool) -> [CategoryInfo] {
        data?.categoryDefinitions(type: type, includeArchived: includeArchived) ?? []
    }

    /// The error saving `name` would give (live editor validation);
    /// `excluding` is the edited category's id, nil when adding.
    func validateCategoryName(_ name: String, type: TransactionType, excluding id: String?) -> CategoryEditError? {
        data?.validateCategoryName(name, type: type, excluding: id)
    }

    /// The `moveCategory` offset for Move up (`direction` -1) or Move down
    /// (+1) relative to the rows shown; nil when that move is not offered.
    func categoryMoveOffset(id: String, direction: Int, includeArchived: Bool) -> Int? {
        data?.categoryMoveOffset(id: id, direction: direction, includeArchived: includeArchived)
    }

    /// Dart `addCategory` (the type is the page's selected segment).
    @discardableResult
    func addCategory(type: TransactionType, name: String, iconIdentifier: String, colorToken: String) async -> EditOutcome<CategoryEditError> {
        await editCategories { data throws(CategoryEditError) in
            try data.addCategory(type: type, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, newID: newID)
        }
    }

    /// Dart `updateCategory` plus the page's rename cascade (transactions,
    /// the expense budget key, templates, rules of the same type or none),
    /// all in one commit.
    @discardableResult
    func updateCategory(id: String, name: String, iconIdentifier: String, colorToken: String) async -> EditOutcome<CategoryEditError> {
        let now = self.now
        return await editCategories { data throws(CategoryEditError) in
            try data.updateCategory(id: id, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, now: now)
        }
    }

    /// Dart `setArchived` (Archive / Restore).
    @discardableResult
    func setCategoryArchived(id: String, _ archived: Bool) async -> EditOutcome<CategoryEditError> {
        await editCategories { data throws(CategoryEditError) in try data.setCategoryArchived(id: id, archived) }
    }

    /// Dart `moveCategory`: `offset` in the type's whole list (use
    /// `categoryMoveOffset` for Move up / Move down).
    @discardableResult
    func moveCategory(id: String, offset: Int) async -> EditOutcome<CategoryEditError> {
        await editCategories { data in data.moveCategory(id: id, offset: offset) }
    }

    /// One category edit through `editCopy` (every changed section in one
    /// commit). A rename that touched transactions rebuilds the ledger,
    /// which keys totals by category name.
    private func editCategories(
        _ edit: (inout FinancialData) throws(CategoryEditError) -> CategoryEditResult
    ) async -> EditOutcome<CategoryEditError> {
        await editCopy { (data: inout FinancialData) throws(CategoryEditError) in try edit(&data).changedSections }
    }

    func categories(for type: TransactionType) -> [CategoryInfo] {
        data?.categoryPicker(for: type) ?? CategoryCatalog.pickerList(CategoryCatalog.builtIn, type: type, usedNames: [])
    }

    // MARK: - Tags and rules

    /// Transaction tags (`transactionTags`), in stored order (Flutter's
    /// `tags`: the page, the form chips and the Flow filter chips).
    var tags: [TransactionTagRecord] { data?.tags ?? [] }

    /// Flutter's `rules` getter, priority descending: the order the Tags &
    /// rules page lists them and suggestions try them.
    var rules: [CategorizationRuleRecord] { data?.rulesByPriority ?? [] }

    /// The error adding this tag name would give, else nil.
    func validateTagName(_ name: String) -> CategorizationEditError? {
        data?.validateTagName(name)
    }

    /// Dart `addTag`: the trimmed name, "accent" colour. Writes
    /// `transactionTags`.
    @discardableResult
    func addTag(name: String, colorToken: String = "accent") async -> EditOutcome<CategorizationEditError> {
        let id = newID()
        return await editTagsAndRules { data throws(CategorizationEditError) in
            try data.addTag(name: name, colorToken: colorToken, id: id)
            return [Section.transactionTags]
        }
    }

    /// Dart `deleteTag`: the tag goes and every rule drops it; transactions
    /// keep the id (D9). One commit of `transactionTags` and
    /// `categorizationRules` (Flutter makes two).
    @discardableResult
    func deleteTag(id: String) async -> EditOutcome<CategorizationEditError> {
        await editTagsAndRules { data in data.deleteTag(id: id) }
    }

    /// Dart `addRule` with a new id. The Flutter dialog's rule sets only
    /// the pattern, match, type, category and tags (`RuleDraft` defaults
    /// for the rest). Writes `categorizationRules`.
    @discardableResult
    func addRule(_ draft: RuleDraft) async -> EditOutcome<CategorizationEditError> {
        let id = newID()
        return await editTagsAndRules { data throws(CategorizationEditError) in
            try data.addRule(draft, id: id)
            return [Section.categorizationRules]
        }
    }

    /// Dart `deleteRule`. Writes `categorizationRules`.
    @discardableResult
    func deleteRule(id: String) async -> EditOutcome<CategorizationEditError> {
        await editTagsAndRules { data in data.deleteRule(id: id) ? [Section.categorizationRules] : [] }
    }

    /// Swift-only rule edit: in place (id and stored position kept), only
    /// the changed keys patched. Writes `categorizationRules`;
    /// `.unchanged` when the draft matches the rule.
    @discardableResult
    func updateRule(id: String, _ draft: RuleDraft) async -> EditOutcome<CategorizationEditError> {
        await editTagsAndRules { data throws(CategorizationEditError) in
            try data.updateRule(id: id, draft) ? [Section.categorizationRules] : []
        }
    }

    /// Swift-only enable switch (`isEnabled`). Writes `categorizationRules`;
    /// `.unchanged` when the rule is unknown or already so.
    @discardableResult
    func setRuleEnabled(id: String, _ enabled: Bool) async -> EditOutcome<CategorizationEditError> {
        await editTagsAndRules { data in data.setRuleEnabled(id: id, enabled) ? [Section.categorizationRules] : [] }
    }

    /// One tag or rule edit through `editCopy` (the sections it returns in
    /// one commit; Flutter is silent on a failed write, the callers toast).
    private func editTagsAndRules(
        _ edit: (inout FinancialData) throws(CategorizationEditError) -> [String]
    ) async -> EditOutcome<CategorizationEditError> {
        await editCopy(edit)
    }

    /// The form's auto-categorisation (`applySuggestion`,
    /// transaction_form.dart:106-121): the amount text parses with Dart's
    /// `double.tryParse(text) ?? 0`. The caller applies the rule only if its
    /// category is in the current picker list.
    func suggestion(type: TransactionType, description: String, amountText: String) -> CategorizationRuleRecord? {
        guard let data else { return nil }
        return CategorizationEngine.suggest(
            rules: data.rules, type: type, description: description, amount: DartDouble.tryParse(amountText) ?? 0)
    }

    /// `applySuggestion` with its gate, for a caller that has no picker
    /// list of its own (the voice prefill, transaction_form.dart:78-88): the
    /// first matching rule, or nil when its category is not an active
    /// category of `type`. Set the category and replace the selected tags
    /// with `tagIds` (a Set in Flutter: duplicates collapse).
    func gatedSuggestion(type: TransactionType, description: String, amount: Double) -> CategorizationRuleRecord? {
        guard let data else { return nil }
        return CategorizationEngine.suggestion(
            rules: data.rules, type: type, description: description, amount: amount,
            activeCategoryNames: categories(for: type).map(\.name))
    }

    /// `FinancialData.categoryInfo(named:type:)` through a dictionary built
    /// once per `dataRevision` (`categories` is derived on every read): the
    /// same match (type, then the lowercased names equal as UTF-16) and the
    /// first definition in `categories` order wins on a duplicate.
    func categoryInfo(named name: String, type: TransactionType) -> CategoryInfo? {
        guard let data else { return nil }
        let index: CategoryInfoIndex
        if let current = categoryInfoIndex, current.revision == dataRevision {
            index = current
        } else {
            var byKey: [CategoryInfoIndex.Key: CategoryInfo] = [:]
            for info in data.categories {
                let key = CategoryInfoIndex.Key(type: info.type, name: Array(DartString.lowercase(info.name).utf16))
                if byKey[key] == nil { byKey[key] = info }
            }
            index = CategoryInfoIndex(revision: dataRevision, byKey: byKey)
            categoryInfoIndex = index
        }
        return index.byKey[CategoryInfoIndex.Key(type: type, name: Array(DartString.lowercase(name).utf16))]
    }
}

struct CategoryInfoIndex {
    struct Key: Hashable {
        let type: TransactionType
        let name: [UInt16]
    }

    let revision: Int
    let byKey: [Key: CategoryInfo]
}
