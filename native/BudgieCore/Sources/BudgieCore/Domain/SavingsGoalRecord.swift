import Foundation

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
