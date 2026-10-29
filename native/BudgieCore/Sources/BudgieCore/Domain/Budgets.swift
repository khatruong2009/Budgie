import Foundation

/// One Home budget row (Flutter `_CategoryBudgetProgress` and
/// `_BudgetRow._statusColor`, spending_page.dart:1948-1968, 1672-1683).
/// Only budgeted categories get a row, so `limit` is always > 0.
public struct BudgetProgress: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Income green.
        case ok
        /// `progress >= 0.85` and not over (spent == limit lands here).
        case warning
        /// `remaining < 0`: spent strictly above the limit.
        case over
    }

    public let category: String
    public let spent: Double
    public let limit: Double

    public init(category: String, spent: Double, limit: Double) {
        self.category = category
        self.spent = spent
        self.limit = limit
    }

    public var remaining: Double { limit - spent }
    /// Unclamped; the bar clamps to 0...1.
    public var progress: Double { spent / limit }
    public var isOver: Bool { remaining < 0 }

    public var status: Status {
        if isOver { return .over }
        return progress >= 0.85 ? .warning : .ok
    }
}

extension FinancialData {
    // MARK: - Budget limits (TransactionModel, transaction_model.dart:746-777)

    /// Dart `getCategoryBudgetLimit`: an exact (UTF-16) key match. nil when
    /// the key is absent or its stored value is not > 0 (Dart's load drops
    /// those, `transaction_model.dart:413-420`).
    public func budgetLimit(for category: String) -> Double? {
        let key = Array(category.utf16)
        return budgetLimits.first { Array($0.0.utf16) == key }?.1
    }

    /// Dart `setCategoryBudgetLimit`: the category is trimmed and an empty
    /// one is ignored; `limit <= 0` removes the trimmed key. Non-finite
    /// limits are rejected (Dart would fail every save after taking one).
    ///
    /// Dart rebuilds the map as `{...old, key: limit}` and rewrites it whole
    /// as doubles. This patches the stored object in place instead, so
    /// untouched entries keep their lexemes: a key Dart holds keeps its
    /// position; any other key (absent, or stored with a value Dart's load
    /// dropped) is appended, which is where Dart's map puts it. The value is
    /// written as a Dart double (`100.0`).
    ///
    /// Returns true when the section must be written. Like Dart, setting
    /// the same value again still writes.
    @discardableResult
    public mutating func setBudgetLimit(category: String, limit: Double) -> Bool {
        let name = DartString.trim(category)
        guard !name.isEmpty, limit.isFinite else { return false }
        guard limit > 0 else { return removeBudgetLimit(category: name) }

        let key = Array(name.utf16)
        var members = budgetLimitsObject.members
        if budgetLimit(for: name) != nil, let first = members.firstIndex(where: { $0.key.codeUnits == key }) {
            // Replace at the first occurrence (keeping its key lexeme) and
            // drop later duplicates so the value is unambiguous.
            members[first].value = .double(limit)
            var index = members.count - 1
            while index > first {
                if members[index].key.codeUnits == key { members.remove(at: index) }
                index -= 1
            }
        } else {
            members.removeAll { $0.key.codeUnits == key }
            members.append(JSONObject.Member(key: JSONString(name), value: .double(limit)))
        }
        budgetLimitsObject.members = members
        return true
    }

    /// Dart `removeCategoryBudgetLimit`: an exact key, not trimmed. Returns
    /// false (nothing to write) when Dart holds no limit for it.
    @discardableResult
    public mutating func removeBudgetLimit(category: String) -> Bool {
        guard budgetLimit(for: category) != nil else { return false }
        let key = Array(category.utf16)
        budgetLimitsObject.members.removeAll { $0.key.codeUnits == key }
        return true
    }

    // MARK: - Home budget rows (spending_page.dart:107-150)

    /// The expense categories as Dart's `expenseCategories` map holds them:
    /// the picker order, one entry per exact name (a map key).
    private func expenseCategoryKeys() -> [CategoryInfo] {
        var seen = Set<[UInt16]>()
        return categoryPicker(for: .expense).filter { seen.insert(Array($0.name.utf16)).inserted }
    }

    /// Everything Home's budgets section shows, from one pass over the
    /// expense categories and the limits (`budgetProgress`,
    /// `budgetedCategories` and `unbudgetedCategories` together).
    public struct BudgetOverview: Sendable {
        public let progress: [BudgetProgress]
        public let budgeted: [CategoryInfo]
        public let unbudgeted: [CategoryInfo]
        /// The limits Dart holds, by exact (UTF-16) name.
        let limits: [[UInt16]: Double]

        public static let empty = BudgetOverview(progress: [], budgeted: [], unbudgeted: [], limits: [:])

        /// `budgetLimit(for:)` from the same pass.
        public func limit(for category: String) -> Double? { limits[Array(category.utf16)] }
    }

    public func budgetOverview(_ summary: MonthSummary) -> BudgetOverview {
        // `budgetLimits` has one entry per exact key, so this is `budgetLimit(for:)`.
        var limits: [[UInt16]: Double] = [:]
        for (name, limit) in budgetLimits { limits[Array(name.utf16)] = limit }
        var budgeted: [CategoryInfo] = [], unbudgeted: [CategoryInfo] = []
        for info in expenseCategoryKeys() {
            if limits[Array(info.name.utf16)] != nil { budgeted.append(info) } else { unbudgeted.append(info) }
        }
        return BudgetOverview(
            progress: Self.budgetRows(budgeted, limits: limits, summary: summary), budgeted: budgeted,
            unbudgeted: unbudgeted, limits: limits)
    }

    /// `_buildBudgetProgressItems` for one month's ledger summary: every
    /// expense category with a limit > 0, spent from the month's category
    /// totals by exact name (0 when absent), sorted by spent descending, then
    /// name in UTF-16 order. Limits whose name is not an expense category
    /// (archived, or a case variant of one) get no row.
    public func budgetProgress(_ summary: MonthSummary) -> [BudgetProgress] {
        budgetOverview(summary).progress
    }

    private static func budgetRows(_ budgeted: [CategoryInfo], limits: [[UInt16]: Double], summary: MonthSummary) -> [BudgetProgress] {
        var spentByName: [[UInt16]: Double] = [:]
        for entry in summary.categoryExpenses where spentByName[Array(entry.name.utf16)] == nil {
            spentByName[Array(entry.name.utf16)] = entry.amount
        }
        let rows = budgeted.map { info in
            BudgetProgress(category: info.name, spent: spentByName[Array(info.name.utf16)] ?? 0, limit: limits[Array(info.name.utf16)]!)
        }
        // `b.spent.compareTo(a.spent)`, then `a.category.compareTo(b.category)`.
        return rows.enumerated().sorted { a, b in
            let bySpent = dartCompare(b.element.spent, a.element.spent)
            if bySpent != 0 { return bySpent < 0 }
            if DartString.precedes(a.element.category, b.element.category) { return true }
            if DartString.precedes(b.element.category, a.element.category) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// `_budgetedCategories`: expense categories with a limit, in category
    /// order (the EDIT sheet).
    public func budgetedCategories() -> [CategoryInfo] {
        expenseCategoryKeys().filter { budgetLimit(for: $0.name) != nil }
    }

    /// `_unbudgetedCategories`: expense categories without a limit, in
    /// category order (the Add a budget sheet).
    public func unbudgetedCategories() -> [CategoryInfo] {
        expenseCategoryKeys().filter { budgetLimit(for: $0.name) == nil }
    }
}
