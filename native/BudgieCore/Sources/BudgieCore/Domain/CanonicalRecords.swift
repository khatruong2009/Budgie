import Foundation

/// Dart `toJson()` of each model, built from the typed fields (never from
/// `raw`): what the Flutter app writes after loading a row into its model.
/// Used by the backup, which Flutter re-serialises from its models, so
/// unknown keys, int lexemes and legacy shapes are normalised away there.
///
/// Strings: a typed field is a Swift `String`, which cannot hold a lone
/// UTF-16 surrogate (Dart strings can). When the row it was read from
/// still holds the field's source (unchanged, or trimmed for the fields
/// the Dart model trims), the source's exact code units are written, as
/// Dart would.
///
/// Numbers: Dart's encoder throws on NaN and infinities; so do these.

/// Dart `JsonUnsupportedObjectError` for a non-finite double.
public struct BackupExportError: Error, Equatable, Sendable {
    public let message: String

    init(nonFinite value: Double) {
        let text = value.isNaN ? "NaN" : value < 0 ? "-Infinity" : "Infinity"
        message = "Converting object to an encodable object failed: \(text)"
    }
}

enum Canonical {
    static func double(_ value: Double) throws(BackupExportError) -> JSONValue {
        guard let number = JSONNumber(double: value) else { throw BackupExportError(nonFinite: value) }
        return .number(number)
    }

    static func optionalDouble(_ value: Double?) throws(BackupExportError) -> JSONValue {
        guard let value else { return .null }
        return try double(value)
    }

    static func date(_ value: DartDateTime) -> JSONValue {
        .string(value.toIso8601String())
    }

    /// `value` as a JSON string, taking the code units from `raw[key]` when
    /// that string (trimmed, if `trimmed`) is `value`.
    static func string(_ value: String, raw: JSONObject, key: String, trimmed: Bool = false) -> JSONValue {
        if case .string(let source)? = raw[key] {
            let units = trimmed ? DartString.trimUnits(source.codeUnits) : source.codeUnits
            if String(decoding: units, as: UTF16.self).utf16.elementsEqual(value.utf16) {
                return .string(JSONString(lexeme: DartJSON.escape(codeUnits: units)))
            }
        }
        return .string(value)
    }

    static func optionalString(_ value: String?, raw: JSONObject, key: String) -> JSONValue {
        guard let value else { return .null }
        return string(value, raw: raw, key: key)
    }

    /// A string list (`tagIds`): the source list's strings when they are
    /// the typed ones.
    static func strings(_ values: [String], raw: JSONObject, key: String) -> JSONValue {
        let source = raw[key]?.arrayValue?.compactMap { item -> JSONString? in
            if case .string(let s) = item { return s }
            return nil
        }
        if let source, source.count == values.count,
            zip(source, values).allSatisfy({ $0.value.utf16.elementsEqual($1.utf16) })
        {
            return .array(source.map { .string(JSONString(lexeme: $0.dartCanonicalLexeme)) })
        }
        return .array(values.map { .string($0) })
    }

}

extension TransactionRecord {
    /// Dart `Transaction.toJson()` (transaction.dart:97-108).
    public func canonicalJSON() throws(BackupExportError) -> JSONObject {
        JSONObject(ordered: [
            ("id", Canonical.string(id, raw: raw, key: "id")),
            ("type", .string(type.rawValue)),
            ("description", Canonical.string(description, raw: raw, key: "description")),
            ("amount", try Canonical.double(amount)),
            ("category", Canonical.string(category, raw: raw, key: "category")),
            ("date", Canonical.date(date)),
            ("recurringTemplateId", Canonical.optionalString(recurringTemplateId, raw: raw, key: "recurringTemplateId")),
            ("tagIds", Canonical.strings(tagIds, raw: raw, key: "tagIds")),
            ("createdAt", Canonical.date(createdAt)),
            ("updatedAt", Canonical.date(updatedAt)),
        ])
    }

    /// The record as Dart holds it after `fromJson`: its row is `toJson()`.
    func canonicalized() throws(BackupExportError) -> TransactionRecord {
        TransactionRecord(
            id: id, type: type, description: description, amount: amount, category: category, date: date,
            recurringTemplateId: recurringTemplateId, tagIds: tagIds, createdAt: createdAt, updatedAt: updatedAt,
            raw: try canonicalJSON())
    }

    /// Dart `copyWith(id:)` on a canonical record.
    func withID(_ newID: String) -> TransactionRecord {
        var object = raw
        object["id"] = .string(newID)
        return TransactionRecord(
            id: newID, type: type, description: description, amount: amount, category: category, date: date,
            recurringTemplateId: recurringTemplateId, tagIds: tagIds, createdAt: createdAt, updatedAt: updatedAt,
            raw: object)
    }
}

extension NetWorthEntryRecord {
    /// Dart `NetWorthEntry.toJson()` (net_worth_entry.dart:139-146).
    public func canonicalJSON() throws(BackupExportError) -> JSONObject {
        var snapshots: [JSONValue] = []
        for snapshot in self.snapshots {
            snapshots.append(.object(JSONObject(ordered: [
                ("recordedAt", Canonical.date(snapshot.recordedAt)),
                ("amount", try Canonical.double(snapshot.amount)),
            ])))
        }
        return JSONObject(ordered: [
            ("id", Canonical.string(id, raw: raw, key: "id")),
            ("name", Canonical.string(name, raw: raw, key: "name")),
            ("type", .string(type.rawValue)),
            ("createdAt", Canonical.date(createdAt)),
            ("snapshots", .array(snapshots)),
        ])
    }

    func canonicalized() throws(BackupExportError) -> NetWorthEntryRecord {
        var copy = self
        copy.raw = try canonicalJSON()
        return copy
    }
}

extension SavingsGoalRecord {
    /// Dart `SavingsGoal.toJson()` (savings_goal.dart:99-107).
    public func canonicalJSON() throws(BackupExportError) -> JSONObject {
        JSONObject(ordered: [
            ("id", Canonical.string(id, raw: raw, key: "id")),
            ("name", Canonical.string(name, raw: raw, key: "name", trimmed: true)),
            ("targetAmount", try Canonical.double(targetAmount)),
            ("currentAmount", try Canonical.double(currentAmount)),
            ("targetDate", Canonical.date(targetDate)),
            ("createdAt", Canonical.date(createdAt)),
            ("completedAt", completedAt.map(Canonical.date) ?? .null),
        ])
    }

    func canonicalized() throws(BackupExportError) -> SavingsGoalRecord {
        var copy = self
        copy.raw = try canonicalJSON()
        return copy
    }
}

extension RecurringTemplate {
    /// Dart `RecurringTransaction.toJson()` (recurring_transaction.dart:46-58).
    public func canonicalJSON() throws(BackupExportError) -> JSONObject {
        JSONObject(ordered: [
            ("id", Canonical.string(id, raw: raw, key: "id")),
            ("type", .string(type.rawValue)),
            ("description", Canonical.string(description, raw: raw, key: "description")),
            ("amount", try Canonical.double(amount)),
            ("category", Canonical.string(category, raw: raw, key: "category")),
            ("pattern", .string(pattern.rawValue)),
            ("startDate", Canonical.date(startDate)),
            ("nextOccurrence", Canonical.date(nextOccurrence)),
            ("dayOfMonth", dayOfMonth.map { .int($0) } ?? .null),
            ("dayOfWeek", dayOfWeek.map { .int($0) } ?? .null),
            ("isActive", .bool(isActive)),
        ])
    }

    func canonicalized() throws(BackupExportError) -> RecurringTemplate {
        RecurringTemplate(
            id: id, type: type, description: description, amount: amount, category: category, pattern: pattern,
            startDate: startDate, nextOccurrence: nextOccurrence, dayOfMonth: dayOfMonth, dayOfWeek: dayOfWeek,
            isActive: isActive, raw: try canonicalJSON())
    }
}

extension CategoryInfo {
    /// Dart `BudgetCategory.toJson()` (category_definition.dart:39-48).
    public func canonicalJSON() -> JSONObject {
        JSONObject(ordered: [
            ("id", Canonical.string(id, raw: raw, key: "id")),
            ("type", .string(type.rawValue)),
            ("name", Canonical.string(name, raw: raw, key: "name")),
            ("iconIdentifier", Canonical.string(iconIdentifier, raw: raw, key: "iconIdentifier")),
            ("colorToken", Canonical.string(colorToken, raw: raw, key: "colorToken")),
            ("sortOrder", .int(sortOrder)),
            ("isArchived", .bool(isArchived)),
            ("isBuiltIn", .bool(isBuiltIn)),
        ])
    }

    func canonicalized() -> CategoryInfo {
        CategoryInfo(
            id: id, type: type, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, sortOrder: sortOrder,
            isArchived: isArchived, isBuiltIn: isBuiltIn, raw: canonicalJSON())
    }
}

extension TransactionTagRecord {
    /// Dart `TransactionTag.toJson()` (transaction_tag.dart:23-27).
    public func canonicalJSON() -> JSONObject {
        JSONObject(ordered: [
            ("id", Canonical.string(id, raw: raw, key: "id")),
            ("name", Canonical.string(name, raw: raw, key: "name", trimmed: true)),
            ("colorToken", Canonical.string(colorToken, raw: raw, key: "colorToken")),
        ])
    }

    func canonicalized() -> TransactionTagRecord {
        TransactionTagRecord(id: id, name: name, colorToken: colorToken, raw: canonicalJSON())
    }
}

extension CategorizationRuleRecord {
    /// Dart `CategorizationRule.toJson()` (categorization_rule.dart:58-70).
    public func canonicalJSON() throws(BackupExportError) -> JSONObject {
        JSONObject(ordered: [
            ("id", Canonical.string(id, raw: raw, key: "id")),
            ("merchantPattern", Canonical.string(merchantPattern, raw: raw, key: "merchantPattern", trimmed: true)),
            ("matchType", .string(matchType.rawValue)),
            ("transactionType", transactionType.map { .string($0.rawValue) } ?? .null),
            ("minimumAmount", try Canonical.optionalDouble(minimumAmount)),
            ("maximumAmount", try Canonical.optionalDouble(maximumAmount)),
            ("category", Canonical.string(category, raw: raw, key: "category")),
            ("tagIds", Canonical.strings(tagIds, raw: raw, key: "tagIds")),
            ("priority", .int(priority)),
            ("isEnabled", .bool(isEnabled)),
        ])
    }

    func canonicalized() throws(BackupExportError) -> CategorizationRuleRecord {
        CategorizationRuleRecord(
            id: id, merchantPattern: merchantPattern, matchType: matchType, transactionType: transactionType,
            minimumAmount: minimumAmount, maximumAmount: maximumAmount, category: category, tagIds: tagIds,
            priority: priority, isEnabled: isEnabled, raw: try canonicalJSON())
    }
}
