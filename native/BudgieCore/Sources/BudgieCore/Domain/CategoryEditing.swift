import Foundation

/// Why a category edit was refused. `message` is Flutter's copy verbatim
/// (the `ArgumentError`/`StateError` messages of category_provider.dart,
/// which the page shows through `_friendlyError`). Nothing changed.
public enum CategoryEditError: Error, Hashable, Sendable {
    /// The trimmed name is empty (category_provider.dart:121-123, 177-179).
    case nameRequired
    /// Another category of the same type has this name after Dart
    /// `toLowerCase`, compared as UTF-16 code units, archived ones included
    /// (:124-127, 180-187).
    case duplicateName
    /// Archiving the last active category of its type (:202-206).
    case lastActive

    public var message: String {
        switch self {
        case .nameRequired: "Category name is required"
        case .duplicateName: "A category with this name already exists"
        case .lastActive: "At least one category must remain active"
        }
    }
}

extension CategoryEditError: LocalizedError {
    public var errorDescription: String? { message }
}

/// What a category edit did in memory.
public struct CategoryEditResult: Equatable, Sendable {
    /// The definition after the edit; nil when nothing changed.
    public var category: CategoryInfo?
    /// The sections to write in one commit, in this order: categories,
    /// transactions, categoryBudgetLimits, recurringTransactions,
    /// categorizationRules. Empty for a Flutter no-op (nothing to write).
    public var changedSections: [String]
    /// The rename cascade, when an update changed the name.
    public var rename: CategoryRename?

    static let unchanged = CategoryEditResult(category: nil, changedSections: [], rename: nil)
}

/// A rename carried to every stored use of the old name.
public struct CategoryRename: Equatable, Sendable {
    public enum BudgetLimit: Equatable, Sendable {
        /// No expense limit under the old name.
        case none
        /// The old key was removed and the new one appended with its value.
        case moved
        /// The new name already had a limit: it stays and the old one is
        /// dropped (Dart `putIfAbsent`).
        case dropped
    }

    public let type: TransactionType
    public let oldName: String
    public let newName: String
    public internal(set) var transactions = 0
    public internal(set) var templates = 0
    public internal(set) var rules = 0
    public internal(set) var budgetLimit = BudgetLimit.none
}

extension CategoryCatalog {
    /// Dart `categoryIconRegistry.containsKey(icon) ? icon : 'square_grid_2x2'`.
    static func registeredIcon(_ identifier: String) -> String {
        iconIdentifiers.contains { DartString.equal($0, identifier) } ? identifier : "square_grid_2x2"
    }
}

/// Category management (`CategoryProvider` add/update/setArchived/move,
/// category_provider.dart:114-224) and the Categories page's rename
/// cascade (category_settings_page.dart:284-323). Every mutator validates
/// before it changes anything, so a thrown error leaves the data untouched.
/// Rows are patched in place: unknown keys and unreadable rows survive, and
/// a new definition has Dart's `toJson` shape.
extension FinancialData {
    /// Dart `categoriesFor(type, includeArchived:)`: by sortOrder, ties in
    /// stored order (a stable sort; Dart's is stable up to 33 rows).
    public func categoryDefinitions(type: TransactionType, includeArchived: Bool) -> [CategoryInfo] {
        categories.filter { $0.type == type && (includeArchived || !$0.isArchived) }.sortedStably { $0.sortOrder }
    }

    /// The error add (`excluding` nil) or update (`excluding` the edited
    /// id) would throw for `name` in `type`, else nil. For live validation
    /// in the editor.
    public func validateCategoryName(_ name: String, type: TransactionType, excluding id: String?) -> CategoryEditError? {
        let trimmed = DartString.trim(name)
        if trimmed.isEmpty { return .nameRequired }
        let wanted = DartString.lowercase(trimmed)
        let clash = categoryRows.contains { row in
            guard let record = row.record, record.type == type else { return false }
            if let id, DartString.equal(record.id, id) { return false }
            return DartString.equal(DartString.lowercase(record.name), wanted)
        }
        return clash ? .duplicateName : nil
    }

    /// Dart `addCategory`: the trimmed name, the `_uniqueId` id (`newID`
    /// supplies the UUID when the slug is taken), an unregistered icon
    /// stored as `square_grid_2x2`, the colour token verbatim, and sortOrder
    /// = the number of definitions of the type, archived ones included.
    @discardableResult
    public mutating func addCategory(
        type: TransactionType, name: String, iconIdentifier: String, colorToken: String, newID: () -> String
    ) throws(CategoryEditError) -> CategoryEditResult {
        if let error = validateCategoryName(name, type: type, excluding: nil) { throw error }
        let trimmed = DartString.trim(name)
        let category = CategoryInfo.make(
            id: uniqueCategoryID(type: type, name: trimmed, newID: newID), type: type, name: trimmed,
            iconIdentifier: CategoryCatalog.registeredIcon(iconIdentifier), colorToken: colorToken,
            sortOrder: categoryRowCount(type: type), isBuiltIn: false)
        categoryRows.append(.record(category))
        return CategoryEditResult(category: category, changedSections: [Section.categories], rename: nil)
    }

    /// Dart `updateCategory` followed by the page's rename cascade, as one
    /// change. An unknown id changes nothing (Dart returns before
    /// validating). Name, icon (unregistered ones become `square_grid_2x2`)
    /// and colour are set; type, sortOrder, archived and built-in are kept.
    /// The `categories` section is always written, as Dart does even when
    /// nothing differs.
    ///
    /// When the trimmed name differs from the stored one as UTF-16 (a
    /// case-only rename included), every transaction, template and rule
    /// using the old name exactly follows, and an expense budget limit moves
    /// to the new key (see `CategoryRename`). Transactions get
    /// `updatedAt = now`. Rules of the other type keep the old name (D6:
    /// Flutter renames them too).
    @discardableResult
    public mutating func updateCategory(
        id: String, name: String, iconIdentifier: String, colorToken: String, now: DartDateTime
    ) throws(CategoryEditError) -> CategoryEditResult {
        try updateCategory(
            id: id, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, now: now, restrictRulesByType: true)
    }

    /// `restrictRulesByType: false` is Flutter's rule pass (every rule with
    /// the old name, whatever its type), for the parity tests only.
    mutating func updateCategory(
        id: String, name: String, iconIdentifier: String, colorToken: String, now: DartDateTime, restrictRulesByType: Bool
    ) throws(CategoryEditError) -> CategoryEditResult {
        guard let index = categoryRows.index(ofID: id), let existing = categoryRows[index].record else { return .unchanged }
        if let error = validateCategoryName(name, type: existing.type, excluding: id) { throw error }
        let trimmed = DartString.trim(name)
        let updated = existing.with(
            name: trimmed, iconIdentifier: CategoryCatalog.registeredIcon(iconIdentifier), colorToken: colorToken)
        categoryRows[index] = .record(updated)
        var result = CategoryEditResult(category: updated, changedSections: [Section.categories], rename: nil)
        if !DartString.equal(trimmed, existing.name) {
            let cascade = renameCategoryUses(
                type: existing.type, from: existing.name, to: trimmed, now: now, restrictRulesByType: restrictRulesByType)
            result.changedSections += cascade.sections
            result.rename = cascade.rename
        }
        return result
    }

    /// Dart `setArchived`: unknown id or already in that state changes
    /// nothing; archiving the last active definition of its type is refused;
    /// restoring has no check. Only `isArchived` changes (no cascade).
    @discardableResult
    public mutating func setCategoryArchived(id: String, _ archived: Bool) throws(CategoryEditError) -> CategoryEditResult {
        guard let index = categoryRows.index(ofID: id), let existing = categoryRows[index].record, existing.isArchived != archived else {
            return .unchanged
        }
        if archived {
            let otherActive = categoryRows.contains { row in
                guard let record = row.record else { return false }
                return record.type == existing.type && !record.isArchived && !DartString.equal(record.id, id)
            }
            if !otherActive { throw .lastActive }
        }
        let updated = existing.with(isArchived: archived)
        categoryRows[index] = .record(updated)
        return CategoryEditResult(category: updated, changedSections: [Section.categories], rename: nil)
    }

    /// Dart `moveCategory`: `offset` counts in the type's whole ordered list
    /// (archived rows included), clamped to its ends; every row of the type
    /// is renumbered 0..n-1 (only changed numbers are patched). A move to
    /// the same slot, or an unknown id (a Dart `StateError`, unreachable from
    /// the UI), changes nothing. See `categoryMoveOffset` for moves relative
    /// to the rows the page shows.
    @discardableResult
    public mutating func moveCategory(id: String, offset: Int) -> CategoryEditResult {
        guard let index = categoryRows.index(ofID: id), let existing = categoryRows[index].record else { return .unchanged }
        var ordered = categoryRowIndices(type: existing.type)
        guard let from = ordered.firstIndex(where: { DartString.equal(categoryRows[$0].record!.id, id) }) else { return .unchanged }
        // Dart's 64-bit int wraps on overflow; `&+` does the same.
        let to = max(0, min(ordered.count - 1, from &+ offset))
        guard from != to else { return .unchanged }
        ordered.insert(ordered.remove(at: from), at: to)
        for (position, rowIndex) in ordered.enumerated() {
            let record = categoryRows[rowIndex].record!
            if record.sortOrder != position { categoryRows[rowIndex] = .record(record.with(sortOrder: position)) }
        }
        return CategoryEditResult(category: categoryRows[ordered[to]].record, changedSections: [Section.categories], rename: nil)
    }

    /// The `moveCategory` offset for "Move up" (`direction` < 0) or "Move
    /// down" (> 0) relative to the rows the page shows: every definition of
    /// the type when `includeArchived`, else the active ones. The row lands
    /// just past its previous or next shown row, hopping over hidden
    /// archived rows (Flutter moves by one in the full list, so with
    /// archived rows hidden a move can seem to do nothing; PARITY_GAPS).
    /// With `includeArchived` this is always -1 or +1, as in Flutter. nil
    /// when the page offers no such move: no shown row in that direction,
    /// an archived row (Flutter's menu has no moves for them), or an
    /// unknown id.
    public func categoryMoveOffset(id: String, direction: Int, includeArchived: Bool) -> Int? {
        guard direction != 0, let category = categories.first(where: { DartString.equal($0.id, id) }) else { return nil }
        let ordered = categoryDefinitions(type: category.type, includeArchived: true)
        guard let from = ordered.firstIndex(where: { DartString.equal($0.id, id) }), !ordered[from].isArchived else { return nil }
        let shown: (CategoryInfo) -> Bool = { includeArchived || !$0.isArchived }
        let target = direction < 0
            ? ordered[..<from].lastIndex(where: shown)
            : ordered[(from + 1)...].firstIndex(where: shown)
        return target.map { $0 - from }
    }

    /// The rename part of the cascade for the rules only (Dart
    /// `CategorizationProvider.renameCategory`, restricted by type per D6):
    /// every readable rule whose category equals `from` as UTF-16 and whose
    /// `transactionType` is `type` or nil (any) gets `to`. Rules of the other
    /// type keep `from`. `restrictedTo` nil is Flutter's pass (every type).
    /// Returns the count (the caller then writes `categorizationRules` in the
    /// same commit).
    mutating func renameRuleCategory(from: String, to: String, restrictedTo type: TransactionType?) -> Int {
        var count = 0
        for index in ruleRows.indices {
            guard let rule = ruleRows[index].record, DartString.equal(rule.category, from) else { continue }
            if let type, let ruleType = rule.transactionType, ruleType != type { continue }
            ruleRows[index] = .record(rule.with(category: to))
            count += 1
        }
        return count
    }

    /// Dart's cascade after a rename (`TransactionModel.renameCategory`,
    /// `RecurringTransactionModel.renameCategory`,
    /// `CategorizationProvider.renameCategory`): exact (UTF-16) matches of
    /// type and name. Returns the changed sections in commit order.
    mutating func renameCategoryUses(
        type: TransactionType, from old: String, to new: String, now: DartDateTime, restrictRulesByType: Bool
    ) -> (sections: [String], rename: CategoryRename) {
        var rename = CategoryRename(type: type, oldName: old, newName: new)
        var sections: [String] = []
        // Dart's guard (transaction_model.dart:788-789); the page only
        // cascades a changed, non-empty name, so it never trips there.
        guard !DartString.equal(old, new), !new.isEmpty else { return (sections, rename) }

        for index in transactionRows.indices {
            guard let record = transactionRows[index].record, record.type == type, DartString.equal(record.category, old) else {
                continue
            }
            transactionRows[index] = .record(record.renamingCategory(to: new, now: now))
            rename.transactions += 1
        }
        if rename.transactions > 0 { sections.append(Section.transactions) }

        // Dart: `Map.from(limits)..remove(old)..putIfAbsent(new, () => limit)`
        // on the loaded map (limits > 0 only). Patched in place: the old key
        // goes, the new one is appended (where Dart's map puts it) unless
        // Dart already holds a limit for it, whose value then wins.
        if type == .expense, let limit = budgetLimit(for: old) {
            removeBudgetMembers(Array(old.utf16))
            if budgetLimit(for: new) == nil {
                // A stored member Dart's load dropped (limit <= 0) goes too.
                removeBudgetMembers(Array(new.utf16))
                budgetLimitsObject.members.append(JSONObject.Member(key: JSONString(new), value: .double(limit)))
                rename.budgetLimit = .moved
            } else {
                rename.budgetLimit = .dropped
            }
            sections.append(Section.categoryBudgetLimits)
        }

        for index in templateRows.indices {
            guard let template = templateRows[index].record, template.type == type, DartString.equal(template.category, old) else {
                continue
            }
            templateRows[index] = .record(template.with(category: new))
            rename.templates += 1
        }
        if rename.templates > 0 { sections.append(Section.recurringTransactions) }

        rename.rules = renameRuleCategory(from: old, to: new, restrictedTo: restrictRulesByType ? type : nil)
        if rename.rules > 0 { sections.append(Section.categorizationRules) }
        return (sections, rename)
    }

    /// Row indices of the type's definitions (archived included) by
    /// sortOrder, ties in stored order.
    func categoryRowIndices(type: TransactionType) -> [Int] {
        categoryRows.indices.filter { categoryRows[$0].record?.type == type }.sortedStably { categoryRows[$0].record!.sortOrder }
    }
}
