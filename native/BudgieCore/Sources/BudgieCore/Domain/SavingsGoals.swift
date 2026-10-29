import Foundation

/// Savings goals, ported from `SavingsGoal` (savings_goal.dart), the goal
/// mutations of `TransactionModel` (transaction_model.dart 868-963) and the
/// private helpers of `SavingsGoalsPage` (savings_goals_page.dart: sort
/// 154-162, status 246-267, pace copy 271-281, summary 620-631, allocation
/// 345-367).
///
/// Dart rewrites the whole `savingsGoals` list from `toJson` on every save.
/// Here only the edited rows are patched, and in an edited row only the keys
/// whose value Dart would write differently:
/// - `id` and unknown keys are never touched;
/// - `name`, `targetAmount`, `currentAmount`, `targetDate`, `createdAt` and
///   `completedAt` keep their stored JSON when it already decodes (with the
///   JSON type Dart writes) to the value Dart would write. Otherwise the
///   Dart value is written: amounts as double lexemes (an int or string
///   amount is rewritten), a date that fell back to "now" at load is written
///   out, and `completedAt` is always present (a string or null).
/// - Untouched rows and unreadable rows are written back verbatim.
/// For data Dart itself wrote, the result is byte-identical to Dart's
/// (Fixtures/goals).
///
/// Non-finite amounts are refused (Dart would keep them in memory and fail
/// every later save of the model).

public enum SavingsGoalStatus: String, Sendable, Hashable, CaseIterable {
    case onTrack, behind, complete

    /// The status pill (savings_goals_page.dart:896-915).
    public var label: String {
        switch self {
        case .onTrack: "On track"
        case .behind: "Behind"
        case .complete: "Complete"
        }
    }
}

extension SavingsGoalRecord {
    // MARK: - Construction

    /// `SavingsGoal._generateId`: `savings_goal_<µs since epoch>_<counter>`,
    /// both in lowercase base 36. Dart's counter is process-wide and starts
    /// at 0; the caller owns it.
    public static func makeID(now: DartDateTime, counter: Int) -> String {
        "savings_goal_\(String(now.microsecondsSinceEpoch, radix: 36))_\(String(counter, radix: 36))"
    }

    /// A new row as Dart `SavingsGoal(...).toJson()` writes it: the
    /// constructor trims the name and clamps a negative target to 0,
    /// `currentAmount` is 0.0, `createdAt` is now, `completedAt` null.
    /// `targetDate` is used as given (the model normalises it first).
    public static func make(
        id: String, name: String, targetAmount: Double, targetDate: DartDateTime, now: DartDateTime
    ) -> SavingsGoalRecord {
        let trimmed = DartString.trim(name)
        let target = targetAmount < 0 ? 0.0 : targetAmount
        let raw = JSONObject(ordered: [
            ("id", .string(id)),
            ("name", .string(trimmed)),
            ("targetAmount", .double(target)),
            ("currentAmount", .double(0)),
            ("targetDate", .string(targetDate.toIso8601String())),
            ("createdAt", .string(now.toIso8601String())),
            ("completedAt", .null),
        ])
        return SavingsGoalRecord(
            id: id, name: trimmed, targetAmount: target, currentAmount: 0, targetDate: targetDate, createdAt: now,
            completedAt: nil, raw: raw)
    }

    /// What the edit form submits (`_GoalFormResult`).
    public struct Edit: Sendable, Hashable {
        public var name: String
        public var targetAmount: Double
        public var currentAmount: Double
        public var targetDate: DartDateTime

        public init(name: String, targetAmount: Double, currentAmount: Double, targetDate: DartDateTime) {
            self.name = name
            self.targetAmount = targetAmount
            self.currentAmount = currentAmount
            self.targetDate = targetDate
        }
    }

    /// `updateSavingsGoal` for one row (after the model's guards): the
    /// trimmed name, the target, `max(current, 0)` and the target date as
    /// given (not normalised, as Dart). `completedAt` is the stored stamp
    /// (or now) when the new amount reaches the target, else null. `id` and
    /// `createdAt` are kept. Nil when an amount is not finite.
    public func applying(_ edit: Edit, now: DartDateTime) -> SavingsGoalRecord? {
        let current = dartClampExact(edit.currentAmount, 0, .infinity)
        let target = edit.targetAmount < 0 ? 0.0 : edit.targetAmount
        return patched(
            name: DartString.trim(edit.name), targetAmount: target, currentAmount: current, targetDate: edit.targetDate,
            completedAt: current >= target ? (completedAt ?? now) : nil)
    }

    /// `allocateToSavingsGoal` for one row: `max(current + amount, 0)`;
    /// `completedAt` as in `applying` (the `>= target` test is not gated on
    /// a positive target, as Dart). A negative amount withdraws. Nil when
    /// an amount is not finite.
    public func allocating(_ amount: Double, now: DartDateTime) -> SavingsGoalRecord? {
        let updated = dartClampExact(currentAmount + amount, 0, .infinity)
        return patched(
            name: name, targetAmount: targetAmount, currentAmount: updated, targetDate: targetDate,
            completedAt: updated >= targetAmount ? (completedAt ?? now) : nil)
    }

    /// The row with these values, patched as described in the file comment.
    private func patched(
        name: String, targetAmount: Double, currentAmount: Double, targetDate: DartDateTime, completedAt: DartDateTime?
    ) -> SavingsGoalRecord? {
        guard targetAmount.isFinite, currentAmount.isFinite else { return nil }
        var next = self
        next.name = name
        next.targetAmount = targetAmount
        next.currentAmount = currentAmount
        next.targetDate = targetDate
        next.completedAt = completedAt
        if raw["name"]?.stringValue.map({ DartString.equal($0, name) }) != true {
            next.raw["name"] = .string(name)
        }
        for (key, value) in [("targetAmount", targetAmount), ("currentAmount", currentAmount)]
        where !Self.holdsDouble(raw[key], value) {
            next.raw[key] = .double(value)
        }
        for (key, value) in [("targetDate", targetDate), ("createdAt", createdAt)] where !Self.holdsDate(raw[key], value) {
            next.raw[key] = .string(value.toIso8601String())
        }
        if let completedAt {
            if !Self.holdsDate(raw["completedAt"], completedAt) {
                next.raw["completedAt"] = .string(completedAt.toIso8601String())
            }
        } else if raw["completedAt"]?.isNull != true {
            next.raw["completedAt"] = .null
        }
        return next
    }

    /// A stored JSON double (not an int lexeme) with exactly this value.
    private static func holdsDouble(_ stored: JSONValue?, _ value: Double) -> Bool {
        guard case .number(let number)? = stored, !number.isDartInt else { return false }
        return number.doubleValue.bitPattern == value.bitPattern
    }

    /// A stored string that Dart's `DateTime.tryParse` reads as this value
    /// (instant and UTC flag).
    private static func holdsDate(_ stored: JSONValue?, _ value: DartDateTime) -> Bool {
        guard let text = stored?.stringValue, !text.isEmpty,
            let parsed = DartDateTime.tryParse(text, timeZone: value.timeZone)
        else { return false }
        return parsed == value
    }

    // MARK: - Derived values (never persisted)

    /// `progress`: `current / target` clamped to 0...1, 0 when the target
    /// is not positive. NaN stays NaN, as in Dart (only reachable from a
    /// hand-edited "NaN" string amount).
    public var progress: Double {
        if targetAmount <= 0 { return 0 }
        let value = currentAmount / targetAmount
        if value < 0 { return 0 }
        if value > 1 { return 1 }
        return value
    }

    /// `progressPercent`: `(progress * 100).round()`, half away from zero.
    /// Dart throws on a NaN progress (the card fails to build); this gives 0.
    public var progressPercent: Int {
        let value = progress * 100
        return value.isFinite ? Int(value.rounded()) : 0
    }

    /// `isOverdue`: not completed and the target's calendar day is before
    /// today's (both as local midnight, `DateTime(y, m, d)`).
    public func isOverdue(now: DartDateTime, calendar: DartCalendar) -> Bool {
        return !isCompleted && calendar.startOfDay(targetDate).isBefore(calendar.startOfDay(now))
    }

    /// `_statusFor` (savings_goals_page.dart:246-267). Complete when
    /// completed; behind when overdue; otherwise the expected progress is
    /// the elapsed share of `createdAt ... targetDate` in whole milliseconds
    /// (truncated), clamped to 0...1, and the goal is on track when
    /// `progress + 1e-9` reaches it. `targetDate` is midnight at the START of
    /// the target day, so on that day a goal is behind unless fully funded,
    /// and a goal created today for today is behind at once (span <= 0).
    public func status(now: DartDateTime, calendar: DartCalendar) -> SavingsGoalStatus {
        if isCompleted { return .complete }
        if isOverdue(now: now, calendar: calendar) { return .behind }
        let totalSpan = targetDate.difference(createdAt) / 1000
        if totalSpan <= 0 { return progress >= 1.0 ? .onTrack : .behind }
        let elapsed = now.difference(createdAt) / 1000
        let expected = dartClampExact(Double(elapsed) / Double(totalSpan), 0, 1)
        return progress + 1e-9 >= expected ? .onTrack : .behind
    }

    /// Whether an allocation fires the completion haptic and celebration
    /// (savings_goals_page.dart:350): computed on the goal as shown before
    /// the dialog, `!isCompleted && amount >= remainingAmount`. The model's
    /// own test (`current + amount >= target`) can disagree by rounding.
    public func willComplete(allocating amount: Double) -> Bool {
        !isCompleted && amount >= remainingAmount
    }

    /// What "Finish goal" allocates: the smallest amount at or above
    /// `remainingAmount` whose sum with `currentAmount` reaches the target,
    /// as the model adds it. `target - current` alone can land one ulp short
    /// (14133.23 + (60422.9 - 14133.23) is 60422.899999999994), which would
    /// celebrate (`willComplete`) without the model completing the goal.
    /// 0 when nothing remains.
    public var finishAmount: Double {
        var amount = remainingAmount
        guard amount > 0 else { return 0 }
        while currentAmount + amount < targetAmount, amount.isFinite { amount = amount.nextUp }
        return amount
    }

    /// `_sortedGoals`: incomplete before complete, then `targetDate`
    /// ascending by instant. Stable (Dart's sort is stable up to 32 goals).
    public static func sorted(_ goals: [SavingsGoalRecord]) -> [SavingsGoalRecord] {
        goals.enumerated().sorted { a, b in
            if a.element.isCompleted != b.element.isCompleted { return !a.element.isCompleted }
            let x = a.element.targetDate.microsecondsSinceEpoch, y = b.element.targetDate.microsecondsSinceEpoch
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }
}

/// The summary card (`_SavingsGoalsSummary`, savings_goals_page.dart:620-631).
public struct SavingsGoalsSummary: Hashable, Sendable {
    /// Sum of `currentAmount` in page order (over-funding included).
    public let totalSaved: Double
    public let totalTarget: Double
    public let completedCount: Int
    public let count: Int
    /// The ring value: `totalSaved / totalTarget` clamped to 0...1 (0 when
    /// the target total is not positive).
    public let progress: Double

    /// Sums over the page's sorted order, as Flutter adds them.
    public init(goals: [SavingsGoalRecord]) {
        let sorted = SavingsGoalRecord.sorted(goals)
        var saved = 0.0, target = 0.0
        for goal in sorted {
            saved += goal.currentAmount
            target += goal.targetAmount
        }
        totalSaved = saved
        totalTarget = target
        completedCount = sorted.filter(\.isCompleted).count
        count = sorted.count
        progress = dartClampExact(target <= 0 ? 0 : saved / target, 0, 1)
    }

    /// `(totalProgress * 100).round()`.
    public var percent: Int { Int((progress * 100).rounded()) }
}

/// Copy on the Goals tab that depends on the data. Money goes through
/// `MoneyFormatter`, so Hide balances masks it as Flutter's does; dates are
/// en_US `MMMd`.
public enum SavingsGoalText {
    /// The ring centre: `42%`.
    public static func percent(_ goal: SavingsGoalRecord) -> String { "\(goal.progressPercent)%" }

    /// `_paceCopyFor`: `Nov 30 · $360/mo keeps you on pace`, or when behind
    /// (overdue included) `Nov 30 · bump to $435/mo to catch up`.
    public static func pace(_ goal: SavingsGoalRecord, now: DartDateTime, calendar: DartCalendar, formatter: MoneyFormatter) -> String {
        let date = DartDateFormat.MMMd(goal.targetDate)
        let monthly = formatter.format(goal.suggestedMonthlyContribution(now: now), decimalDigits: 0)
        if goal.status(now: now, calendar: calendar) == .behind {
            return "\(date) \u{00B7} bump to \(monthly)/mo to catch up"
        }
        return "\(date) \u{00B7} \(monthly)/mo keeps you on pace"
    }

    /// A completed card: `Fully funded on Nov 30 — nice work` (the
    /// completion stamp, else the target date).
    public static func fullyFunded(_ goal: SavingsGoalRecord) -> String {
        "Fully funded on \(DartDateFormat.MMMd(goal.completedAt ?? goal.targetDate)) \u{2014} nice work"
    }

    /// The summary ring: `42%`.
    public static func summaryPercent(_ summary: SavingsGoalsSummary) -> String { "\(summary.percent)%" }

    /// The summary caption: `of $12,000 · 1 of 3 complete`.
    public static func summaryCaption(_ summary: SavingsGoalsSummary, formatter: MoneyFormatter) -> String {
        "of \(formatter.format(summary.totalTarget, decimalDigits: 0)) \u{00B7} \(summary.completedCount) of \(summary.count) complete"
    }
}

extension FinancialData {
    /// The readable goal with this id (the first, if ids repeat).
    public func savingsGoal(id: String) -> SavingsGoalRecord? {
        savingsGoals.first { DartString.equal($0.id, id) }
    }

    /// `addSavingsGoal`: nil (nothing to write) for a blank name or a target
    /// that is not a positive finite number. The target date becomes its
    /// local midnight (`DateTime(y, m, d)`); the goal is appended.
    @discardableResult
    public mutating func addSavingsGoal(
        name: String, targetAmount: Double, targetDate: DartDateTime, id: String, now: DartDateTime
    ) -> SavingsGoalRecord? {
        let trimmed = DartString.trim(name)
        guard !trimmed.isEmpty, targetAmount > 0, targetAmount.isFinite else { return nil }
        let goal = SavingsGoalRecord.make(
            id: id, name: trimmed, targetAmount: targetAmount, targetDate: calendar.startOfDay(targetDate), now: now)
        goalRows.append(.record(goal))
        return goal
    }

    /// `updateSavingsGoal`: every goal with this id takes the edit (see
    /// `SavingsGoalRecord.applying`). False, with nothing to write, for a
    /// blank name, a target that is not positive, a non-finite amount or an
    /// unknown id.
    @discardableResult
    public mutating func updateSavingsGoal(id: String, _ edit: SavingsGoalRecord.Edit, now: DartDateTime) -> Bool {
        guard !DartString.trim(edit.name).isEmpty, edit.targetAmount > 0, edit.targetAmount.isFinite,
            edit.currentAmount.isFinite
        else { return false }
        return replaceGoals(id: id) { $0.applying(edit, now: now) }
    }

    /// `deleteSavingsGoal`: removes every goal with this id. False, with
    /// nothing to write, for an unknown id.
    @discardableResult
    public mutating func deleteSavingsGoal(id: String) -> Bool {
        let before = goalRows.count
        goalRows.removeAll { $0.record.map { DartString.equal($0.id, id) } ?? false }
        return goalRows.count != before
    }

    /// `allocateToSavingsGoal`: adds `amount` (negative withdraws, floored
    /// at 0) to every goal with this id. False, with nothing to write, for a
    /// zero or non-finite amount, an unknown id, or a result that is not
    /// finite. Creates no transaction.
    @discardableResult
    public mutating func allocateToSavingsGoal(id: String, amount: Double, now: DartDateTime) -> Bool {
        guard amount != 0, amount.isFinite else { return false }
        return replaceGoals(id: id) { $0.allocating(amount, now: now) }
    }

    /// Replaces every readable goal with this id by `transform`'s result,
    /// all or nothing: if any result is nil nothing changes.
    private mutating func replaceGoals(id: String, _ transform: (SavingsGoalRecord) -> SavingsGoalRecord?) -> Bool {
        var replacements: [(Int, SavingsGoalRecord)] = []
        for index in goalRows.indices {
            guard let goal = goalRows[index].record, DartString.equal(goal.id, id) else { continue }
            guard let next = transform(goal) else { return false }
            replacements.append((index, next))
        }
        for (index, next) in replacements { goalRows[index] = .record(next) }
        return !replacements.isEmpty
    }
}
