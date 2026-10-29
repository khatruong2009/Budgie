import Foundation

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
