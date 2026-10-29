import Foundation

/// Typed, lossless views over stored rows.
///
/// Each record keeps the raw JSON object it was read from. Reading follows
/// the Dart `fromJson` of the same model (what is required, defaults for
/// missing keys, type tolerance). Editing changes only the keys it touches,
/// so unknown keys and every untouched lexeme survive. A new record is built
/// with exactly the keys, order and JSON types Dart's `toJson` writes.
///
/// Where Dart would throw on a malformed row (and, for some sections, abort
/// the whole load), the Swift side treats that single row as unreadable:
/// hidden from the UI and written back unchanged.

public enum TransactionType: String, Sendable, Hashable, CaseIterable {
    case income, expense
}

// MARK: - Shared readers (Dart cast semantics)

enum Read {
    /// `x as String` where null is an error.
    static func requiredString(_ object: JSONObject, _ key: String) -> String? {
        object[key]?.stringValue
    }

    /// `x as String?`: nil for missing/null, failure for another type.
    static func optionalString(_ object: JSONObject, _ key: String) -> String?? {
        switch object[key] {
        case nil, .null?: return .some(nil)
        case .string(let s)?: return .some(s.value)
        default: return nil
        }
    }

    /// `(x as num).toDouble()`.
    static func num(_ object: JSONObject, _ key: String) -> Double? {
        object[key]?.numberValue?.doubleValue
    }

    /// `x as bool?`: .some(nil) for missing/null, nil (failure) for another type.
    static func optionalBool(_ object: JSONObject, _ key: String) -> Bool?? {
        switch object[key] {
        case nil, .null?: return .some(nil)
        case .bool(let b)?: return .some(b)
        default: return nil
        }
    }

    /// `x as int?` (strict: a number with a fractional lexeme fails).
    static func optionalInt(_ object: JSONObject, _ key: String) -> Int?? {
        switch object[key] {
        case nil, .null?: return .some(nil)
        case .number(let n)? where n.isDartInt: return .some(n.intValue.map { Int($0) })
        default: return nil
        }
    }

    /// `(x as num?)?.toInt()`: any number, converted as Dart's `toInt`.
    static func optionalNumber(_ object: JSONObject, _ key: String) -> Int?? {
        switch object[key] {
        case nil, .null?: return .some(nil)
        case .number(let n)?: return .some(Int(DartNumbers.toInt(n.doubleValue, lexeme: n)))
        default: return nil
        }
    }

    /// `(x as num?)?.toDouble()`.
    static func optionalDouble(_ object: JSONObject, _ key: String) -> Double?? {
        switch object[key] {
        case nil, .null?: return .some(nil)
        case .number(let n)?: return .some(n.doubleValue)
        default: return nil
        }
    }

    /// A lenient date: nil for a missing, non-string, empty or unparseable value.
    static func optionalDate(_ object: JSONObject, _ key: String, _ calendar: DartCalendar) -> DartDateTime? {
        guard let text = object[key]?.stringValue, !text.isEmpty else { return nil }
        return calendar.tryParse(text)
    }

    /// A list of strings (non-strings dropped): [] for missing/null, nil
    /// (failure) for another type.
    static func stringArray(_ object: JSONObject, _ key: String) -> [String]? {
        switch object[key] {
        case nil, .null?: return []
        case .array(let items)?: return items.compactMap(\.stringValue)
        default: return nil
        }
    }

    /// Dart `DateTime.parse(x)` where x must be a String.
    static func parsedDate(_ object: JSONObject, _ key: String, _ calendar: DartCalendar) -> DartDateTime? {
        guard let text = object[key]?.stringValue else { return nil }
        return calendar.tryParse(text)
    }
}

// MARK: - Transaction

public struct TransactionRecord: Identifiable, Hashable, Sendable {
    public private(set) var id: String
    public private(set) var type: TransactionType
    public private(set) var description: String
    public private(set) var amount: Double
    public private(set) var category: String
    public private(set) var date: DartDateTime
    public private(set) var recurringTemplateId: String?
    public private(set) var tagIds: [String]
    public private(set) var createdAt: DartDateTime
    public private(set) var updatedAt: DartDateTime
    public private(set) var raw: JSONObject

    public var isRecurring: Bool { recurringTemplateId != nil }

    /// Dart `Transaction.fromJson` plus the id fallback of its factory.
    /// Returns nil where Dart would throw (the row is then unreadable).
    static func parse(_ value: JSONValue, calendar: DartCalendar, newID: () -> String) -> TransactionRecord? {
        guard case .object(let object) = value else { return nil }
        guard let date = Read.parsedDate(object, "date", calendar) else { return nil }
        guard case .some(let id) = Read.optionalString(object, "id") else { return nil }
        guard let description = Read.requiredString(object, "description") else { return nil }
        guard let amount = Read.num(object, "amount") else { return nil }
        guard let category = Read.requiredString(object, "category") else { return nil }
        guard case .some(let templateID) = Read.optionalString(object, "recurringTemplateId") else { return nil }
        guard let tagIds = Read.stringArray(object, "tagIds") else { return nil }
        let createdAt = Read.optionalDate(object, "createdAt", calendar) ?? date
        let updatedAt = Read.optionalDate(object, "updatedAt", calendar) ?? createdAt
        let validID = id.map { !DartString.trim($0).isEmpty } ?? false
        return TransactionRecord(
            id: validID ? id! : newID(),
            type: object["type"]?.stringValue == "expense" ? .expense : .income,
            description: description, amount: amount, category: category, date: date,
            recurringTemplateId: templateID, tagIds: tagIds, createdAt: createdAt, updatedAt: updatedAt,
            raw: object)
    }

    /// A new row, exactly as Dart `Transaction(...).toJson()` writes it.
    public static func make(
        id: String, type: TransactionType, description: String, amount: Double, category: String,
        date: DartDateTime, recurringTemplateId: String? = nil, tagIds: [String] = [], now: DartDateTime
    ) -> TransactionRecord {
        let raw = JSONObject(ordered: [
            ("id", .string(id)),
            ("type", .string(type.rawValue)),
            ("description", .string(description)),
            ("amount", .double(amount)),
            ("category", .string(category)),
            ("date", .string(date.toIso8601String())),
            ("recurringTemplateId", recurringTemplateId.map { .string($0) } ?? .null),
            ("tagIds", .array(tagIds.map { .string($0) })),
            ("createdAt", .string(now.toIso8601String())),
            ("updatedAt", .string(now.toIso8601String())),
        ])
        return TransactionRecord(
            id: id, type: type, description: description, amount: amount, category: category, date: date,
            recurringTemplateId: recurringTemplateId, tagIds: tagIds, createdAt: now, updatedAt: now, raw: raw)
    }

    public struct Edit: Sendable, Hashable {
        public var type: TransactionType
        public var description: String
        public var amount: Double
        public var category: String
        public var date: DartDateTime
        /// nil keeps the stored tags.
        public var tagIds: [String]?

        public init(
            type: TransactionType, description: String, amount: Double, category: String, date: DartDateTime,
            tagIds: [String]? = nil
        ) {
            self.type = type
            self.description = description
            self.amount = amount
            self.category = category
            self.date = date
            self.tagIds = tagIds
        }
    }

    /// Dart `TransactionModel.updateTransaction`: id, createdAt and the
    /// template link are kept; `updatedAt` = now, or the old value + 1 µs
    /// when now is not after it. Only changed keys are rewritten.
    public func applying(_ edit: Edit, now: DartDateTime) -> TransactionRecord {
        var next = self
        if edit.type != type {
            next.type = edit.type
            next.raw["type"] = .string(edit.type.rawValue)
        }
        if edit.description != description {
            next.description = edit.description
            next.raw["description"] = .string(edit.description)
        }
        if edit.amount.bitPattern != amount.bitPattern || raw["amount"]?.numberValue?.isDartInt == true {
            next.amount = edit.amount
            next.raw["amount"] = .double(edit.amount)
        }
        if edit.category != category {
            next.category = edit.category
            next.raw["category"] = .string(edit.category)
        }
        if edit.date != date {
            next.date = edit.date
            next.raw["date"] = .string(edit.date.toIso8601String())
        }
        if let tagIds = edit.tagIds, tagIds != self.tagIds {
            next.tagIds = tagIds
            next.raw["tagIds"] = .array(tagIds.map { .string($0) })
        }
        let updatedAt = now.isAfter(updatedAt) ? now : updatedAt.adding(microseconds: 1)
        next.updatedAt = updatedAt
        next.raw["updatedAt"] = .string(updatedAt.toIso8601String())
        if raw["createdAt"]?.stringValue == nil {
            // Dart would write the resolved createdAt on any save.
            next.raw["createdAt"] = .string(createdAt.toIso8601String())
        }
        return next
    }

    /// The category rename cascade (Dart `TransactionModel.renameCategory`,
    /// transaction_model.dart:783-829): `copyWith(category:, updatedAt:
    /// DateTime.now())`, so `updatedAt` is plain `now`, not the
    /// `applying` rule. Only those keys are rewritten (plus `createdAt`
    /// when it is not a string, which Dart's `toJson` would write).
    func renamingCategory(to name: String, now: DartDateTime) -> TransactionRecord {
        var next = self
        next.category = name
        next.raw["category"] = .string(name)
        next.updatedAt = now
        next.raw["updatedAt"] = .string(now.toIso8601String())
        if raw["createdAt"]?.stringValue == nil { next.raw["createdAt"] = .string(createdAt.toIso8601String()) }
        return next
    }

    /// Identity backfill (Dart `getTransactions` needsIdentityMigration):
    /// a fresh id, and createdAt/updatedAt written when they were not strings.
    func withBackfilledIdentity(id newID: String?) -> TransactionRecord {
        var next = self
        if let newID {
            next.id = newID
            next.raw["id"] = .string(newID)
        }
        if raw["createdAt"]?.stringValue == nil { next.raw["createdAt"] = .string(createdAt.toIso8601String()) }
        if raw["updatedAt"]?.stringValue == nil { next.raw["updatedAt"] = .string(updatedAt.toIso8601String()) }
        return next
    }

    /// `Transaction.compareNewestFirst`: local calendar day desc, then
    /// createdAt desc, then id desc (UTF-16 order, as Dart compares strings).
    public static func newestFirst(_ a: TransactionRecord, _ b: TransactionRecord, calendar: DartCalendar) -> Bool {
        let keyA = calendar.startOfDay(a.date)
        let keyB = calendar.startOfDay(b.date)
        if keyA != keyB { return keyA.microsecondsSinceEpoch > keyB.microsecondsSinceEpoch }
        if a.createdAt.microsecondsSinceEpoch != b.createdAt.microsecondsSinceEpoch {
            return a.createdAt.microsecondsSinceEpoch > b.createdAt.microsecondsSinceEpoch
        }
        // Dart `b.id.compareTo(a.id)`: the larger id (UTF-16 order) first.
        return Array(b.id.utf16).lexicographicallyPrecedes(Array(a.id.utf16))
    }
}

// MARK: - Recurring template

public enum RecurrencePattern: String, Sendable, Hashable, CaseIterable {
    case weekly, biweekly, monthly
}

public struct RecurringTemplate: Identifiable, Hashable, Sendable {
    public private(set) var id: String
    public private(set) var type: TransactionType
    public private(set) var description: String
    public private(set) var amount: Double
    public private(set) var category: String
    public private(set) var pattern: RecurrencePattern
    public private(set) var startDate: DartDateTime
    public private(set) var nextOccurrence: DartDateTime
    public private(set) var dayOfMonth: Int?
    public private(set) var dayOfWeek: Int?
    public private(set) var isActive: Bool
    public private(set) var raw: JSONObject

    /// Dart `RecurringTransaction.fromJson`. Dart casts `amount` to double
    /// without coercion, so an int lexeme is an error there (and here).
    static func parse(_ value: JSONValue, calendar: DartCalendar, newID: () -> String) -> RecurringTemplate? {
        guard case .object(let object) = value else { return nil }
        guard case .some(let id) = Read.optionalString(object, "id") else { return nil }
        guard let description = Read.requiredString(object, "description") else { return nil }
        guard let number = object["amount"]?.numberValue, !number.isDartInt else { return nil }
        guard let category = Read.requiredString(object, "category") else { return nil }
        guard let patternName = object["pattern"]?.stringValue, let pattern = RecurrencePattern(rawValue: patternName) else { return nil }
        guard let start = Read.parsedDate(object, "startDate", calendar) else { return nil }
        guard let next = Read.parsedDate(object, "nextOccurrence", calendar) else { return nil }
        guard case .some(let dayOfMonth) = Read.optionalInt(object, "dayOfMonth") else { return nil }
        guard case .some(let dayOfWeek) = Read.optionalInt(object, "dayOfWeek") else { return nil }
        guard case .some(let activeFlag) = Read.optionalBool(object, "isActive") else { return nil }
        let isActive = activeFlag ?? true
        return RecurringTemplate(
            id: id ?? newID(), type: object["type"]?.stringValue == "expense" ? .expense : .income,
            description: description, amount: number.doubleValue, category: category, pattern: pattern,
            startDate: start, nextOccurrence: next, dayOfMonth: dayOfMonth, dayOfWeek: dayOfWeek,
            isActive: isActive, raw: object)
    }

    /// A new template as Dart `RecurringTransaction(...).toJson()` writes it
    /// (`nextOccurrence` = `startDate`).
    public static func make(
        id: String, type: TransactionType, description: String, amount: Double, category: String,
        pattern: RecurrencePattern, startDate: DartDateTime, dayOfMonth: Int?, dayOfWeek: Int?, isActive: Bool = true
    ) -> RecurringTemplate {
        let raw = JSONObject(ordered: [
            ("id", .string(id)),
            ("type", .string(type.rawValue)),
            ("description", .string(description)),
            ("amount", .double(amount)),
            ("category", .string(category)),
            ("pattern", .string(pattern.rawValue)),
            ("startDate", .string(startDate.toIso8601String())),
            ("nextOccurrence", .string(startDate.toIso8601String())),
            ("dayOfMonth", dayOfMonth.map { .int($0) } ?? .null),
            ("dayOfWeek", dayOfWeek.map { .int($0) } ?? .null),
            ("isActive", .bool(isActive)),
        ])
        return RecurringTemplate(
            id: id, type: type, description: description, amount: amount, category: category, pattern: pattern,
            startDate: startDate, nextOccurrence: startDate, dayOfMonth: dayOfMonth, dayOfWeek: dayOfWeek,
            isActive: isActive, raw: raw)
    }

    func with(nextOccurrence: DartDateTime) -> RecurringTemplate {
        var copy = self
        copy.nextOccurrence = nextOccurrence
        copy.raw["nextOccurrence"] = .string(nextOccurrence.toIso8601String())
        return copy
    }

    func with(isActive: Bool) -> RecurringTemplate {
        var copy = self
        copy.isActive = isActive
        copy.raw["isActive"] = .bool(isActive)
        return copy
    }

    /// The category rename cascade (Dart `copyWith(category:)`).
    func with(category: String) -> RecurringTemplate {
        var copy = self
        copy.category = category
        copy.raw["category"] = .string(category)
        return copy
    }

    /// Fields a user edits. The schedule is pattern, start date and day.
    public struct Edit: Sendable, Hashable {
        public var type: TransactionType
        public var description: String
        public var amount: Double
        public var category: String
        public var pattern: RecurrencePattern
        public var startDate: DartDateTime
        public var dayOfMonth: Int?
        public var dayOfWeek: Int?

        public init(
            type: TransactionType, description: String, amount: Double, category: String, pattern: RecurrencePattern,
            startDate: DartDateTime, dayOfMonth: Int?, dayOfWeek: Int?
        ) {
            self.type = type
            self.description = description
            self.amount = amount
            self.category = category
            self.pattern = pattern
            self.startDate = startDate
            self.dayOfMonth = dayOfMonth
            self.dayOfWeek = dayOfWeek
        }
    }

    var scheduleKey: [String] {
        [pattern.rawValue, startDate.toIso8601String(), dayOfMonth.map(String.init) ?? "-"]
    }

    /// The cursor an edit leaves (approved divergence Q2; Dart resets it to
    /// the start date, which re-generates occurrences that already exist).
    /// An unchanged schedule (pattern, start date, day of month) keeps the
    /// cursor. A changed one restarts at the new start date, stepped until
    /// it is strictly after `lastGenerated` (the latest occurrence already
    /// generated for this template, not on the same day either).
    public static func editedCursor(
        previous: RecurringTemplate, edit: Edit, lastGenerated: DartDateTime?, calendar: DartCalendar
    ) -> DartDateTime {
        let next = previous.applying(edit)
        guard next.scheduleKey != previous.scheduleKey else { return previous.nextOccurrence }
        var cursor = next.startDate
        if let last = lastGenerated {
            var guardCount = 0
            while (cursor < last || calendar.isSameDay(cursor, last)) && guardCount < 5000 {
                cursor = RecurringGenerator.nextOccurrence(of: next, after: cursor, calendar: calendar)
                guardCount += 1
            }
        }
        return cursor
    }

    func applying(_ edit: Edit) -> RecurringTemplate {
        var next = self
        if edit.type != type { next.type = edit.type; next.raw["type"] = .string(edit.type.rawValue) }
        if edit.description != description { next.description = edit.description; next.raw["description"] = .string(edit.description) }
        if edit.amount.bitPattern != amount.bitPattern { next.amount = edit.amount; next.raw["amount"] = .double(edit.amount) }
        if edit.category != category { next.category = edit.category; next.raw["category"] = .string(edit.category) }
        if edit.pattern != pattern { next.pattern = edit.pattern; next.raw["pattern"] = .string(edit.pattern.rawValue) }
        if edit.startDate != startDate {
            next.startDate = edit.startDate
            next.raw["startDate"] = .string(edit.startDate.toIso8601String())
        }
        // Dart writes both keys always (null when unused).
        next.dayOfMonth = edit.dayOfMonth
        next.raw["dayOfMonth"] = edit.dayOfMonth.map { .int($0) } ?? .null
        next.dayOfWeek = edit.dayOfWeek
        next.raw["dayOfWeek"] = edit.dayOfWeek.map { .int($0) } ?? .null
        return next
    }
}

// MARK: - Net worth

public enum NetWorthEntryType: String, Sendable, Hashable {
    case asset, liability
}

public struct NetWorthSnapshotRecord: Hashable, Sendable {
    public let recordedAt: DartDateTime
    public let amount: Double

    /// Dart `NetWorthSnapshot.fromJson`, including the legacy
    /// `monthKey`/`updatedAt` shapes.
    static func parse(_ value: JSONValue, calendar: DartCalendar, now: () -> DartDateTime) -> NetWorthSnapshotRecord? {
        guard case .object(let object) = value else { return nil }
        guard case .some(let recordedAtText) = Read.optionalString(object, "recordedAt"),
            case .some(let monthKey) = Read.optionalString(object, "monthKey"),
            case .some(let updatedAtText) = Read.optionalString(object, "updatedAt")
        else { return nil }
        let recordedAt: DartDateTime
        if let recordedAtText, !recordedAtText.isEmpty {
            guard let parsed = calendar.tryParse(recordedAtText) else { return nil }
            recordedAt = parsed
        } else if let monthKey, !monthKey.isEmpty {
            guard let month = calendar.netWorthMonthFromKey(monthKey) else { return nil }
            let updated = (updatedAtText?.isEmpty ?? true) ? nil : calendar.tryParse(updatedAtText!)
            if let updated, DartCalendar.isSameMonth(updated, month) {
                recordedAt = updated
            } else {
                recordedAt = month
            }
        } else if let updatedAtText, !updatedAtText.isEmpty {
            guard let parsed = calendar.tryParse(updatedAtText) else { return nil }
            recordedAt = parsed
        } else {
            recordedAt = now()
        }
        guard let amount = Read.num(object, "amount") else { return nil }
        return NetWorthSnapshotRecord(recordedAt: recordedAt, amount: amount)
    }
}

public struct NetWorthEntryRecord: Identifiable, Hashable, Sendable {
    public let id: String
    // Edited only through NetWorthMutations.swift, which patches `raw` with them.
    public internal(set) var name: String
    public internal(set) var type: NetWorthEntryType
    public let createdAt: DartDateTime
    /// Stored order; aligned one-to-one with `raw["snapshots"]` (see
    /// NetWorthMutations.swift).
    public internal(set) var snapshots: [NetWorthSnapshotRecord]
    public internal(set) var raw: JSONObject

    /// Dart `NetWorthEntry.fromJson` (strict: id, name, type, createdAt required).
    static func parse(_ value: JSONValue, calendar: DartCalendar, now: () -> DartDateTime) -> NetWorthEntryRecord? {
        guard case .object(let object) = value,
            let id = Read.requiredString(object, "id"),
            let name = Read.requiredString(object, "name"),
            let typeName = Read.requiredString(object, "type"),
            let createdAt = Read.parsedDate(object, "createdAt", calendar)
        else { return nil }
        var snapshots: [NetWorthSnapshotRecord] = []
        switch object["snapshots"] {
        case nil, .null?: break
        case .array(let items)?:
            for item in items {
                guard let snapshot = NetWorthSnapshotRecord.parse(item, calendar: calendar, now: now) else { return nil }
                snapshots.append(snapshot)
            }
        default: return nil
        }
        return NetWorthEntryRecord(
            id: id, name: name, type: typeName == "liability" ? .liability : .asset, createdAt: createdAt,
            snapshots: snapshots, raw: object)
    }

    /// A new entry as Dart writes it (used for legacy starting balances).
    static func make(id: String, name: String, type: NetWorthEntryType, createdAt: DartDateTime, snapshot: NetWorthSnapshotRecord) -> NetWorthEntryRecord {
        let raw = JSONObject(ordered: [
            ("id", .string(id)),
            ("name", .string(name)),
            ("type", .string(type.rawValue)),
            ("createdAt", .string(createdAt.toIso8601String())),
            ("snapshots", .array([.object(JSONObject(ordered: [
                ("recordedAt", .string(snapshot.recordedAt.toIso8601String())),
                ("amount", .double(snapshot.amount)),
            ]))])),
        ])
        return NetWorthEntryRecord(id: id, name: name, type: type, createdAt: createdAt, snapshots: [snapshot], raw: raw)
    }

    /// `snapshotForMonth`: latest snapshot recorded in that local month.
    public func snapshot(forMonth month: DartDateTime) -> NetWorthSnapshotRecord? {
        var latest: NetWorthSnapshotRecord?
        let m = month.fields
        for snapshot in snapshots {
            let f = snapshot.recordedAt.fields
            guard f.year == m.year && f.month == m.month else { continue }
            if latest == nil || snapshot.recordedAt.isAfter(latest!.recordedAt) { latest = snapshot }
        }
        return latest
    }

    /// `latestSnapshotThrough`: latest snapshot at or before `date` (carry-forward).
    public func latestSnapshot(through date: DartDateTime) -> NetWorthSnapshotRecord? {
        var latest: NetWorthSnapshotRecord?
        for snapshot in snapshots {
            if snapshot.recordedAt.isAfter(date) { continue }
            if latest == nil || snapshot.recordedAt.isAfter(latest!.recordedAt) { latest = snapshot }
        }
        return latest
    }

    public func amount(at date: DartDateTime) -> Double? {
        latestSnapshot(through: date)?.amount
    }

    public func amount(forMonth month: DartDateTime, calendar: DartCalendar) -> Double? {
        amount(at: calendar.endOfNetWorthMonth(month))
    }
}

// MARK: - Savings goal

public struct SavingsGoalRecord: Identifiable, Hashable, Sendable {
    public let id: String
    // Edited only through SavingsGoals.swift, which patches `raw` with them.
    public internal(set) var name: String
    public internal(set) var targetAmount: Double
    public internal(set) var currentAmount: Double
    public internal(set) var targetDate: DartDateTime
    public let createdAt: DartDateTime
    public internal(set) var completedAt: DartDateTime?
    public internal(set) var raw: JSONObject

    /// Dart `SavingsGoal.fromJson` (lenient) and constructor clamping. A
    /// missing id gets a fresh one, written into `raw` so the next save
    /// keeps it, as Dart's `toJson` would.
    static func parse(_ value: JSONValue, calendar: DartCalendar, now: DartDateTime, newID: () -> String) -> SavingsGoalRecord? {
        guard case .object(var object) = value else { return nil }
        guard case .some(let id) = Read.optionalString(object, "id") else { return nil }
        guard case .some(let rawName) = Read.optionalString(object, "name") else { return nil }
        func readDouble(_ key: String) -> Double {
            switch object[key] {
            case .number(let n)?: return n.doubleValue
            case .string(let s)?: return DartNumbers.tryParseDouble(s.value) ?? 0
            default: return 0
            }
        }
        let trimmed = DartString.trim(rawName ?? "")
        let target = readDouble("targetAmount")
        let current = readDouble("currentAmount")
        let resolvedID = id ?? newID()
        if id == nil { object["id"] = .string(resolvedID) }
        return SavingsGoalRecord(
            id: resolvedID, name: trimmed.isEmpty ? "Savings Goal" : trimmed,
            targetAmount: target < 0 ? 0 : target, currentAmount: current < 0 ? 0 : current,
            targetDate: Read.optionalDate(object, "targetDate", calendar) ?? now,
            createdAt: Read.optionalDate(object, "createdAt", calendar) ?? now,
            completedAt: Read.optionalDate(object, "completedAt", calendar), raw: object)
    }

    public var remainingAmount: Double {
        let remaining = targetAmount - currentAmount
        return remaining <= 0 ? 0 : remaining
    }

    public var isCompleted: Bool { targetAmount > 0 && currentAmount >= targetAmount }

    /// Uses the wall clock like Dart (`DateTime.now()`), not the as-of date.
    public func suggestedMonthlyContribution(now: DartDateTime) -> Double {
        if isCompleted || remainingAmount <= 0 { return 0 }
        let t = targetDate.fields, n = now.fields
        let monthsRemaining = (t.year - n.year) * 12 + t.month - n.month + 1
        if monthsRemaining <= 1 { return remainingAmount }
        return remainingAmount / Double(monthsRemaining)
    }
}

// MARK: - App settings

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

/// Dart number helpers.
enum DartNumbers {
    /// `double.tryParse` (accepts what Dart accepts for plain decimals; the
    /// app only ever stores `toString()` output here).
    static func tryParseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "NaN" { return .nan }
        if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
        if trimmed == "-Infinity" { return -.infinity }
        return Double(trimmed)
    }

    /// `num.toInt()`: truncation toward zero; out-of-range doubles clamp
    /// to the int64 bounds, as the Dart VM does.
    static func toInt(_ value: Double, lexeme: JSONNumber) -> Int64 {
        if let int = lexeme.intValue { return int }
        let truncated = value.rounded(.towardZero)
        if truncated >= 9_223_372_036_854_775_807.0 { return .max }
        if truncated <= -9_223_372_036_854_775_808.0 { return .min }
        return Int64(truncated)
    }
}
