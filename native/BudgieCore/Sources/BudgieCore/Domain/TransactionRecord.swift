import Foundation

public enum TransactionType: String, Sendable, Hashable, CaseIterable {
    case income, expense
}

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
}
