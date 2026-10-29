import Foundation

/// Port of `SafeToSpendCalculator` (research E section 1.2), bug-compatible
/// by decision (14.0 Q1): actuals compare full timestamps against a midnight
/// "as of" (so an expense stamped later today is not yet counted), day
/// counts truncate elapsed 24 h units, and weekly steps drift across DST.
public struct SafeToSpendBreakdown: Hashable, Sendable {
    public let month: DartDateTime
    public let asOf: DartDateTime
    public let actualIncome: Double
    public let expectedIncome: Double
    public let actualExpenses: Double
    public let upcomingRecurringExpenses: Double
    public let flexibleBudgetReserve: Double
    public let plannedGoalContributions: Double
    public let daysRemaining: Int

    public var projectedIncome: Double { actualIncome + expectedIncome }
    public var totalReserved: Double { upcomingRecurringExpenses + flexibleBudgetReserve + plannedGoalContributions }
    public var safeToSpend: Double { projectedIncome - actualExpenses - totalReserved }
    public var isOverCommitted: Bool { safeToSpend < 0 }
    public var overCommitment: Double { isOverCommitted ? -safeToSpend : 0 }
    public var dailyAllowance: Double {
        daysRemaining <= 0 || safeToSpend <= 0 ? 0 : safeToSpend / Double(daysRemaining)
    }
}

public enum SafeToSpend {
    public static func calculate(
        transactions: [TransactionRecord], templates: [RecurringTemplate], budgetLimits: [(String, Double)],
        savingsGoals: [SavingsGoalRecord], month: DartDateTime, asOf: DartDateTime, wallClock: DartDateTime,
        calendar: DartCalendar, includeExpectedIncome: Bool = true, reserveSuggestedGoalContributions: Bool = true
    ) -> SafeToSpendBreakdown {
        let m = month.fields
        let normalizedMonth = calendar.date(m.year, m.month)
        let monthEnd = calendar.date(m.year, m.month + 1, 0)
        let effectiveAsOf = clamp(asOf, normalizedMonth, monthEnd, calendar)

        func inMonth(_ d: DartDateTime) -> Bool {
            let f = d.fields
            return f.year == m.year && f.month == m.month
        }

        var actualIncome = 0.0
        var actualExpenses = 0.0
        var actualByCategory: [String: Double] = [:]
        for transaction in transactions {
            guard inMonth(transaction.date), !transaction.date.isAfter(effectiveAsOf) else { continue }
            if transaction.type == .income {
                actualIncome += transaction.amount
            } else {
                actualExpenses += transaction.amount
                actualByCategory[transaction.category, default: 0] += transaction.amount
            }
        }

        var expectedIncome = 0.0
        var upcoming = 0.0
        var upcomingByCategory: [String: Double] = [:]
        for template in templates where template.isActive {
            for occurrence in remainingOccurrences(template, effectiveAsOf, monthEnd, calendar) where inMonth(occurrence) {
                if template.type == .income {
                    if includeExpectedIncome { expectedIncome += template.amount }
                } else {
                    upcoming += template.amount
                    upcomingByCategory[template.category, default: 0] += template.amount
                }
            }
        }

        var reserve = 0.0
        for (category, limit) in budgetLimits {
            if limit <= 0 { continue }
            let remaining = limit - (actualByCategory[category] ?? 0) - (upcomingByCategory[category] ?? 0)
            if remaining > 0 { reserve += remaining }
        }

        var goals = 0.0
        let asOfMonth = calendar.date(asOf.year, asOf.month)
        if reserveSuggestedGoalContributions && !isBeforeMonth(normalizedMonth, asOfMonth) {
            for goal in savingsGoals where !goal.isCompleted {
                goals += goal.suggestedMonthlyContribution(now: wallClock)
            }
        }

        let days: Int
        if DartCalendar.isSameMonth(asOf, month) {
            days = monthEnd.differenceInDays(calendar.startOfDay(asOf)) + 1
        } else if isBeforeMonth(asOfMonth, normalizedMonth) {
            days = monthEnd.day
        } else {
            days = 0
        }

        return SafeToSpendBreakdown(
            month: normalizedMonth, asOf: effectiveAsOf, actualIncome: actualIncome, expectedIncome: expectedIncome,
            actualExpenses: actualExpenses, upcomingRecurringExpenses: upcoming, flexibleBudgetReserve: reserve,
            plannedGoalContributions: goals, daysRemaining: days)
    }

    static func isBeforeMonth(_ a: DartDateTime, _ b: DartDateTime) -> Bool {
        a.year < b.year || (a.year == b.year && a.month < b.month)
    }

    /// `_clampDate`: time stripped; before the month -> the day before it
    /// (24 h earlier); after -> the month's last day.
    static func clamp(_ value: DartDateTime, _ start: DartDateTime, _ end: DartDateTime, _ calendar: DartCalendar) -> DartDateTime {
        let date = calendar.startOfDay(value)
        if date < start { return start.adding(days: -1) }
        if date > end { return end }
        return date
    }

    /// `_remainingOccurrences`: from the cursor, occurrences after `asOf` up
    /// to `monthEnd` (midnight of the last day), capped at 400 steps.
    static func remainingOccurrences(_ template: RecurringTemplate, _ asOf: DartDateTime, _ monthEnd: DartDateTime, _ calendar: DartCalendar) -> [DartDateTime] {
        var result: [DartDateTime] = []
        var occurrence = template.nextOccurrence
        var guardCount = 0
        while !occurrence.isAfter(monthEnd) && guardCount < 400 {
            if occurrence.isAfter(asOf) { result.append(occurrence) }
            occurrence = next(template, occurrence, calendar)
            guardCount += 1
        }
        return result
    }

    /// `_nextOccurrence` in the calculator: like the generator, but a monthly
    /// day falls back to the occurrence's day and is clamped to 1...last.
    static func next(_ template: RecurringTemplate, _ occurrence: DartDateTime, _ calendar: DartCalendar) -> DartDateTime {
        switch template.pattern {
        case .weekly: return occurrence.adding(days: 7)
        case .biweekly: return occurrence.adding(days: 14)
        case .monthly:
            let nextMonth = calendar.addingMonths(occurrence, 1)
            let lastDay = calendar.date(nextMonth.year, nextMonth.month + 1, 0).day
            let day = min(max(template.dayOfMonth ?? occurrence.day, 1), lastDay)
            return calendar.date(nextMonth.year, nextMonth.month, day)
        }
    }
}
