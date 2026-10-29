import Foundation

/// A stored row: readable (typed, patchable) or not (kept verbatim).
public enum StoredRow<Record: Hashable & Sendable>: Hashable, Sendable {
    case record(Record)
    case unreadable(JSONValue)

    public var record: Record? {
        if case .record(let record) = self { return record }
        return nil
    }
}

/// Everything the app shows, loaded from a `FinancialSnapshot` with the same
/// rules as the Flutter models (`TransactionModel.getTransactions`,
/// `RecurringTransactionModel.loadRecurringTransactions`,
/// `AppSettingsProvider.load`, `CategoryProvider.load`,
/// `CategorizationProvider.load`).
///
/// Every section the app can write has a typed serializer
/// (`serializedSection`), so a save or a retry always writes the current
/// in-memory state, never the JSON that was loaded.
public struct FinancialData: Sendable {
    public let calendar: DartCalendar
    public internal(set) var transactionRows: [StoredRow<TransactionRecord>] = []
    public internal(set) var templateRows: [StoredRow<RecurringTemplate>] = []
    public internal(set) var netWorthRows: [StoredRow<NetWorthEntryRecord>] = []
    public internal(set) var goalRows: [StoredRow<SavingsGoalRecord>] = []
    public internal(set) var categoryRows: [StoredRow<CategoryInfo>] = []
    public internal(set) var tagRows: [StoredRow<TransactionTagRecord>] = []
    public internal(set) var ruleRows: [StoredRow<CategorizationRuleRecord>] = []
    /// The `categoryBudgetLimits` object as stored (edits patch it in place,
    /// so untouched entries keep their lexemes; see Budgets.swift). Empty
    /// when absent or not an object, as Dart reads it.
    public internal(set) var budgetLimitsObject = JSONObject()
    public internal(set) var selectedNetWorthMonth: DartDateTime
    public var appSettings: AppSettings
    /// Raw sections as loaded. Only the `appSettings` serializer reads it
    /// (unknown keys in that object survive a save).
    public private(set) var sections: JSONObject
    /// Whether the launch pass treats a definition stored before it ran as
    /// matching when its trimmed name matches (the padded-name fix, see
    /// `materializeCategories`). `false` is Flutter's rule exactly; the
    /// parity tests load Flutter-written stores with it off. Carried by
    /// every value derived from the loaded data (restore, CSV import).
    public internal(set) var matchesPaddedCategoryNames = true

    public var transactions: [TransactionRecord] { transactionRows.compactMap(\.record) }
    public var templates: [RecurringTemplate] { templateRows.compactMap(\.record) }
    public var netWorthEntries: [NetWorthEntryRecord] { netWorthRows.compactMap(\.record) }
    public var savingsGoals: [SavingsGoalRecord] { goalRows.compactMap(\.record) }
    public var tags: [TransactionTagRecord] { tagRows.compactMap(\.record) }
    /// Stored order (Dart's `rules` getter sorts these by priority).
    public var rules: [CategorizationRuleRecord] { ruleRows.compactMap(\.record) }
    /// The definitions in use: stored rows, or the seeds when none are readable.
    public var categories: [CategoryInfo] { CategoryCatalog.effective(categoryRows) }
    public var unreadableTransactionCount: Int { transactionRows.count - transactions.count }

    /// `categoryBudgetLimits` as Dart loads it: numeric values > 0, in
    /// stored key order. Derived from the stored object on every read, so it
    /// is never stale after a write. Keys compare as UTF-16 code units, and a
    /// repeated key keeps its first position and its last value, as Dart's
    /// `jsonDecode` map does.
    public var budgetLimits: [(String, Double)] {
        var order: [[UInt16]] = []
        var entries: [[UInt16]: (name: String, value: JSONValue)] = [:]
        for member in budgetLimitsObject.members {
            let units = member.key.codeUnits
            if entries[units] == nil { order.append(units) }
            entries[units] = (member.key.value, member.value)
        }
        return order.compactMap { units in
            let entry = entries[units]!
            guard let value = entry.value.numberValue?.doubleValue, value > 0 else { return nil }
            return (entry.name, value)
        }
    }

    /// Section writes the load itself requires (Dart saves these during
    /// load): identity backfill and legacy starting balances.
    public struct LoadResult: Sendable {
        public var data: FinancialData
        public var pendingWrites: [(String, JSONValue)]
    }

    /// Existing sections with unsupported container types cannot safely be
    /// edited by the typed models. Stop app bootstrap before a default or
    /// launch-time migration replaces them. Missing/null sections retain
    /// Flutter's defaults; individual unreadable rows are kept verbatim.
    public static func incompatibleSectionNames(in snapshot: FinancialSnapshot) -> [String] {
        Section.all.filter { name in
            guard let value = snapshot.sections[name], !value.isNull else { return false }
            switch name {
            case Section.categoryBudgetLimits, Section.appSettings: return value.objectValue == nil
            case Section.selectedNetWorthMonth: return value.stringValue == nil
            default: return value.arrayValue == nil
            }
        }
    }

    public static func load(
        _ snapshot: FinancialSnapshot, preferences: PreferencesStore, calendar: DartCalendar,
        now: () -> DartDateTime, newID: () -> String, matchesPaddedCategoryNames: Bool = true
    ) -> LoadResult {
        let sections = snapshot.sections
        var pending: [(String, JSONValue)] = []
        let launch = now()
        var data = FinancialData(
            calendar: calendar,
            selectedNetWorthMonth: calendar.month(of: launch),
            appSettings: AppSettings.load(section: sections[Section.appSettings], preferences: preferences),
            sections: sections)
        data.matchesPaddedCategoryNames = matchesPaddedCategoryNames

        // Transactions (getTransactions): unreadable rows are skipped by Dart
        // and kept verbatim here; blank or duplicate ids get fresh ones and
        // are persisted only if every row was readable.
        if case .array(let rows)? = sections[Section.transactions], !rows.isEmpty {
            var seen = Set<String>()
            var needsIdentityMigration = false
            var unreadable = 0
            for row in rows {
                guard var record = TransactionRecord.parse(row, calendar: calendar, newID: newID) else {
                    unreadable += 1
                    data.transactionRows.append(.unreadable(row))
                    continue
                }
                let persisted = record.raw["id"]?.stringValue
                let hasIdentity = persisted.map { !DartString.trim($0).isEmpty } ?? false
                var newIdentity: String? = nil
                if !hasIdentity || !seen.insert(record.id).inserted {
                    newIdentity = newID()
                    seen.insert(newIdentity!)
                    needsIdentityMigration = true
                }
                if record.raw["createdAt"]?.stringValue == nil || record.raw["updatedAt"]?.stringValue == nil {
                    needsIdentityMigration = true
                }
                record = record.withBackfilledIdentity(id: newIdentity)
                data.transactionRows.append(.record(record))
            }
            if needsIdentityMigration && unreadable == 0 {
                pending.append((Section.transactions, data.transactionsSection()))
            }
        }

        // Net worth entries, or the legacy starting balances when empty.
        if case .array(let rows)? = sections[Section.netWorthEntries], !rows.isEmpty {
            data.netWorthRows = rows.map { row in
                NetWorthEntryRecord.parse(row, calendar: calendar, now: now).map { .record($0) } ?? .unreadable(row)
            }
        } else {
            let assets = preferences.double(PreferenceKey.startingAssets) ?? 0
            let liabilities = preferences.double(PreferenceKey.startingLiabilities) ?? 0
            var migrated: [NetWorthEntryRecord] = []
            for (name, type, amount) in [("Starting Assets", NetWorthEntryType.asset, assets), ("Starting Liabilities", .liability, liabilities)]
            where amount > 0 {
                let at = now()
                migrated.append(.make(id: newID(), name: name, type: type, createdAt: at,
                                      snapshot: NetWorthSnapshotRecord(recordedAt: at, amount: amount)))
            }
            if !migrated.isEmpty {
                data.netWorthRows = migrated.map { .record($0) }
                pending.append((Section.netWorthEntries, data.netWorthSection()))
            }
        }

        if let text = sections[Section.selectedNetWorthMonth]?.stringValue, !text.isEmpty,
            let parsed = calendar.tryParse(text)
        {
            data.selectedNetWorthMonth = calendar.month(of: parsed)
        }

        // Categories: Dart reads the legacy preference when the section is
        // not a list. The launch materialisation runs after the templates.
        if case .array? = sections[Section.categories] {
            data.categoryRows = CategoryCatalog.rows(sections[Section.categories])
        } else if let text = preferences.string(PreferenceKey.categories), !text.isEmpty, let legacy = try? JSONParser.parse(text) {
            data.categoryRows = CategoryCatalog.rows(legacy)
        }

        // Tags and rules: Dart reads the legacy preference when the section
        // is not a list (normally removed by the store migration).
        func listSection(_ section: String, legacyKey: String) -> [JSONValue] {
            if case .array(let rows)? = sections[section] { return rows }
            guard let text = preferences.string(legacyKey), !text.isEmpty, case .array(let rows)? = try? JSONParser.parse(text) else {
                return []
            }
            return rows
        }
        data.tagRows = listSection(Section.transactionTags, legacyKey: PreferenceKey.transactionTags).map { row in
            TransactionTagRecord.parse(row, newID: newID).map { .record($0) } ?? .unreadable(row)
        }
        data.ruleRows = listSection(Section.categorizationRules, legacyKey: PreferenceKey.categorizationRules).map { row in
            CategorizationRuleRecord.parse(row, newID: newID).map { .record($0) } ?? .unreadable(row)
        }

        if case .object(let limits)? = sections[Section.categoryBudgetLimits] {
            data.budgetLimitsObject = limits
        }

        if case .array(let goals)? = sections[Section.savingsGoals] {
            data.goalRows = goals.map { row in
                SavingsGoalRecord.parse(row, calendar: calendar, now: launch, newID: newID).map { .record($0) } ?? .unreadable(row)
            }
        }

        if case .array(let rows)? = sections[Section.recurringTransactions], !rows.isEmpty {
            data.templateRows = rows.map { row in
                RecurringTemplate.parse(row, calendar: calendar, newID: newID).map { .record($0) } ?? .unreadable(row)
            }
        }

        if data.ensureLegacyCategories(stored: sections[Section.categories], newID: newID) {
            pending.append((Section.categories, data.categoriesSection()))
        }
        return LoadResult(data: data, pendingWrites: pending)
    }

    // MARK: - Section serialization (lossless)

    /// The current value of a store section, for every section the app can
    /// write (`Section.all`); nil for any other name. Readable rows are
    /// written from their patched `raw` objects, unreadable rows verbatim.
    public func serializedSection(_ section: String) -> JSONValue? {
        switch section {
        case Section.transactions: transactionsSection()
        case Section.netWorthEntries: netWorthSection()
        case Section.selectedNetWorthMonth: selectedNetWorthMonthSection()
        case Section.categoryBudgetLimits: budgetLimitsSection()
        case Section.savingsGoals: savingsGoalsSection()
        case Section.recurringTransactions: templatesSection()
        case Section.categories: categoriesSection()
        case Section.transactionTags: tagsSection()
        case Section.categorizationRules: rulesSection()
        case Section.appSettings: appSettingsSection()
        default: nil
        }
    }

    private static func rowsSection<Record>(_ rows: [StoredRow<Record>], raw: (Record) -> JSONObject) -> JSONValue {
        .array(rows.map { row in
            switch row {
            case .record(let record): .object(raw(record))
            case .unreadable(let value): value
            }
        })
    }

    public func transactionsSection() -> JSONValue { Self.rowsSection(transactionRows, raw: \.raw) }
    public func templatesSection() -> JSONValue { Self.rowsSection(templateRows, raw: \.raw) }
    public func netWorthSection() -> JSONValue { Self.rowsSection(netWorthRows, raw: \.raw) }
    public func savingsGoalsSection() -> JSONValue { Self.rowsSection(goalRows, raw: \.raw) }
    public func categoriesSection() -> JSONValue { Self.rowsSection(categoryRows, raw: \.raw) }
    public func tagsSection() -> JSONValue { Self.rowsSection(tagRows, raw: \.raw) }
    public func rulesSection() -> JSONValue { Self.rowsSection(ruleRows, raw: \.raw) }
    public func budgetLimitsSection() -> JSONValue { .object(budgetLimitsObject) }

    /// Dart `_selectedNetWorthMonth.toIso8601String()`.
    public func selectedNetWorthMonthSection() -> JSONValue { .string(selectedNetWorthMonth.toIso8601String()) }

    public func appSettingsSection() -> JSONValue {
        appSettings.section(over: sections[Section.appSettings])
    }

    // MARK: - Transactions (TransactionModel mutations)

    public mutating func addTransaction(
        type: TransactionType, description: String, amount: Double, category: String, date: DartDateTime,
        recurringTemplateId: String? = nil, tagIds: [String] = [], id: String, now: DartDateTime
    ) -> TransactionRecord {
        let record = TransactionRecord.make(
            id: id, type: type, description: description, amount: amount, category: category, date: date,
            recurringTemplateId: recurringTemplateId, tagIds: tagIds, now: now)
        transactionRows.append(.record(record))
        return record
    }

    @discardableResult
    public mutating func updateTransaction(id: String, _ edit: TransactionRecord.Edit, now: DartDateTime) -> Bool {
        guard let index = transactionRows.firstIndex(where: { $0.record?.id == id }), let record = transactionRows[index].record else {
            return false
        }
        transactionRows[index] = .record(record.applying(edit, now: now))
        return true
    }

    @discardableResult
    public mutating func deleteTransaction(id: String) -> Bool {
        let before = transactionRows.count
        transactionRows.removeAll { $0.record?.id == id }
        return transactionRows.count != before
    }

    // MARK: - Ledger queries

    // Straightforward O(N) versions, kept as the test oracle for
    // `LedgerIndex` (which the app reads) and for the rehearsal summary.

    public struct MonthTotals: Sendable {
        public var income = 0.0
        public var expenses = 0.0
        public var net: Double { income - expenses }
        /// Insertion order of first appearance (Dart map order).
        public var categoryExpenses: [(String, Double)] = []
        public var transactionIDs: [String] = []
    }

    /// Dart `_monthLedger`: per `year*12+month`, sums in list order.
    /// Category names are distinct as UTF-16 code units, like Dart map keys
    /// (Swift `==` would merge "é" and "e\u{301}").
    public func monthLedger() -> [Int: MonthTotals] {
        var months: [Int: MonthTotals] = [:]
        for transaction in transactions {
            let key = calendar.ledgerMonthKey(transaction.date)
            var totals = months[key] ?? MonthTotals()
            totals.transactionIDs.append(transaction.id)
            if transaction.type == .income {
                totals.income += transaction.amount
            } else {
                totals.expenses += transaction.amount
                let units = Array(transaction.category.utf16)
                if let index = totals.categoryExpenses.firstIndex(where: { $0.0.utf16.elementsEqual(units) }) {
                    totals.categoryExpenses[index].1 += transaction.amount
                } else {
                    totals.categoryExpenses.append((transaction.category, transaction.amount))
                }
            }
            months[key] = totals
        }
        return months
    }

    public func totals(forMonth month: DartDateTime) -> MonthTotals {
        monthLedger()[calendar.ledgerMonthKey(month)] ?? MonthTotals()
    }

    /// `getAvailableMonths`: months with transactions, newest first.
    public func availableMonths() -> [DartDateTime] {
        monthLedger().keys.map { calendar.month(fromLedgerKey: $0) }.sorted { $0 > $1 }
    }

    /// `getAllTransactionsSorted` (compareNewestFirst).
    public func transactionsNewestFirst() -> [TransactionRecord] {
        FinancialData.sortNewestFirst(transactions, calendar: calendar)
    }

    /// One month's transactions, newest first.
    public func transactionsNewestFirst(inMonth month: DartDateTime) -> [TransactionRecord] {
        let key = calendar.ledgerMonthKey(month)
        return FinancialData.sortNewestFirst(transactions.filter { calendar.ledgerMonthKey($0.date) == key }, calendar: calendar)
    }

    /// `Transaction.compareNewestFirst` with its keys computed once per row
    /// (calendar day, createdAt, id as UTF-16), so 10k rows sort quickly.
    static func sortNewestFirst(_ rows: [TransactionRecord], calendar: DartCalendar) -> [TransactionRecord] {
        let keyed = rows.map { record -> (day: Int64, created: Int64, id: [UInt16], record: TransactionRecord) in
            return (calendar.startOfDay(record.date).microsecondsSinceEpoch, record.createdAt.microsecondsSinceEpoch,
                    Array(record.id.utf16), record)
        }
        return keyed.sorted { a, b in
            if a.day != b.day { return a.day > b.day }
            if a.created != b.created { return a.created > b.created }
            return b.id.lexicographicallyPrecedes(a.id)
        }.map(\.record)
    }

    /// Widget value (`_syncWidgetCashFlow`): current calendar month's income
    /// minus expenses, summed in list order.
    public func widgetCashFlow(now: DartDateTime) -> (amount: Double, month: String) {
        let n = now.fields
        var cashFlow = 0.0
        for transaction in transactions {
            let f = transaction.date.fields
            guard f.year == n.year && f.month == n.month else { continue }
            cashFlow += transaction.type == .income ? transaction.amount : -transaction.amount
        }
        return (cashFlow, "\(n.year)-\(DartCalendar.pad(n.month, 2))")
    }

    // MARK: - Recurring templates

    public mutating func addTemplate(_ template: RecurringTemplate) {
        templateRows.append(.record(template))
    }

    /// Edit (approved divergence Q2): Dart resets `nextOccurrence` and
    /// `isActive`, which duplicates already generated transactions. Here the
    /// cursor and pause state are kept; if the schedule changed, the cursor
    /// restarts from the new start date but never lands on or before the
    /// last occurrence already generated for this template.
    @discardableResult
    public mutating func updateTemplate(id: String, _ edit: RecurringTemplate.Edit) -> Bool {
        guard let index = templateRows.firstIndex(where: { $0.record?.id == id }), let template = templateRows[index].record else {
            return false
        }
        var next = template.applying(edit)
        if next.scheduleKey != template.scheduleKey {
            next = next.with(nextOccurrence: RecurringTemplate.editedCursor(
                previous: template, edit: edit, lastGenerated: lastGeneratedDate(forTemplate: id), calendar: calendar))
        }
        templateRows[index] = .record(next)
        return true
    }

    /// The latest date among readable transactions generated from this
    /// template (`recurringTemplateId`), or nil when there are none.
    public func lastGeneratedDate(forTemplate id: String) -> DartDateTime? {
        transactions.filter { $0.recurringTemplateId == id }.map(\.date).max()
    }

    /// Pause or resume (Swift only; Flutter has no pause). Resuming a paused
    /// template moves its cursor to the first occurrence on or after `now`'s
    /// day (`RecurringGenerator.resumedCursor`), so the occurrences missed
    /// while it was paused are skipped rather than back-filled; one due
    /// today stays due. Pausing, or resuming an active template, keeps the
    /// cursor.
    @discardableResult
    public mutating func setTemplateActive(id: String, _ active: Bool, now: DartDateTime) -> Bool {
        guard let index = templateRows.firstIndex(where: { $0.record?.id == id }), let template = templateRows[index].record else {
            return false
        }
        var next = template.with(isActive: active)
        if active && !template.isActive {
            let cursor = RecurringGenerator.resumedCursor(of: template, now: now, calendar: calendar)
            if cursor != template.nextOccurrence { next = next.with(nextOccurrence: cursor) }
        }
        templateRows[index] = .record(next)
        return true
    }

    @discardableResult
    public mutating func deleteTemplate(id: String) -> Bool {
        let before = templateRows.count
        templateRows.removeAll { $0.record?.id == id }
        return templateRows.count != before
    }

    mutating func replaceTemplate(_ template: RecurringTemplate) {
        if let index = templateRows.firstIndex(where: { $0.record?.id == template.id }) {
            templateRows[index] = .record(template)
        }
    }
}
