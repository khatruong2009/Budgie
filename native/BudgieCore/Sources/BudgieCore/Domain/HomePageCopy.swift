import Foundation

/// The text Home shows, computed from numbers and a `MoneyFormatter`, so the
/// views and the parity tests share one definition (Flutter computes all of
/// this inline in `SpendingPage`'s private widgets, spending_page.dart).
/// Each function cites the Flutter lines it mirrors.
extension HomeSummary {
    /// `_HeroCashFlow.build` (:1102-1131, 1134-1136, 1190-1211).
    public struct Hero: Equatable, Sendable {
        public let isNegative: Bool
        /// `MoneyFormatter.format(cashFlow.abs())`: never a minus sign.
        public let amount: String
        /// "$3,200 in   ·   $43 out" (whole units, three spaces either side of the dot).
        public let subline: String
        /// "SAVED THIS MONTH", "SHORT THIS MONTH" or "BREAKING EVEN".
        public let status: String
        public let accessibilityLabel: String
    }

    public static func hero(income: Double, expenses: Double, formatter: MoneyFormatter) -> Hero {
        let cashFlow = income - expenses
        let isNegative = cashFlow < 0
        let amount = formatter.format(abs(cashFlow))
        return Hero(
            isNegative: isNegative, amount: amount,
            subline: "\(formatter.format(income, decimalDigits: 0)) in   \u{00B7}   \(formatter.format(expenses, decimalDigits: 0)) out",
            status: cashFlow > 0 ? "SAVED THIS MONTH" : cashFlow < 0 ? "SHORT THIS MONTH" : "BREAKING EVEN",
            accessibilityLabel: isNegative ? "Cash flow, \(amount) short this month." : "Cash flow, \(amount) this month.")
    }

    /// `_SpendGauge` (:1398-1401): the fill fraction (unclamped).
    // Test-only: checked against Fixtures/home/tz (gauge value)
    public static func gaugeFraction(spent: Double, income: Double) -> Double {
        income <= 0 ? 0 : spent / income
    }

    /// `_SpendGauge` labels (:1400-1401), whole units. The view prefixes
    /// "SPENT  " and "INCOME  ".
    // Test-only: checked against Fixtures/home/tz (gauge texts)
    public static func gaugeLabels(spent: Double, income: Double, formatter: MoneyFormatter) -> (spent: String, income: String) {
        (formatter.format(spent, decimalDigits: 0), formatter.format(income, decimalDigits: 0))
    }

    /// `_FlowChip` amount (:1485): whole units.
    public static func chipAmount(_ amount: Double, formatter: MoneyFormatter) -> String {
        formatter.format(amount, decimalDigits: 0)
    }

    /// `_SafeToSpendCard.build` (:1234-1255, 1259).
    public struct SafeToSpendCard: Equatable, Sendable {
        public let isOver: Bool
        public let title: String
        public let amount: String
        public let subtitle: String
        public let accessibilityLabel: String
    }

    public static func safeToSpendCard(_ breakdown: SafeToSpendBreakdown, formatter: MoneyFormatter) -> SafeToSpendCard {
        let isOver = breakdown.isOverCommitted
        let title = isOver ? "Projected shortfall" : "Safe to spend"
        let amount = formatter.format(isOver ? breakdown.overCommitment : breakdown.safeToSpend, decimalDigits: 0)
        let days = breakdown.daysRemaining
        let subtitle: String
        if days <= 0 {
            subtitle = "This month is already closed out"
        } else if isOver {
            subtitle = "Add income or reduce planned spending"
        } else {
            let daily = formatter.format(breakdown.dailyAllowance, decimalDigits: 0)
            subtitle = "\(daily)/day for \(days == 1 ? "1 day left" : "\(days) days left")"
        }
        return SafeToSpendCard(
            isOver: isOver, title: title, amount: amount, subtitle: subtitle,
            accessibilityLabel: "\(title) \(amount). \(subtitle). Double tap for breakdown.")
    }

    /// `_showSafeToSpendBreakdown` (:362-446) with `_BreakdownRow` (:1330-1385)
    /// and `_breakdownFooter` (:350-360): every text of the sheet, in order.
    public struct BreakdownSheet: Sendable {
        public let title: String
        public let blurb: String
        /// The six rows, label then signed value.
        public let rows: [(label: String, value: String)]
        public let totalLabel: String
        public let totalValue: String
        public let footer: String

        /// The texts as Flutter's widget tree lists them.
        public var texts: [String] {
            [title, blurb] + rows.flatMap { [$0.label, $0.value] } + [totalLabel, totalValue, footer]
        }
    }

    public static func breakdownSheet(_ breakdown: SafeToSpendBreakdown, formatter: MoneyFormatter) -> BreakdownSheet {
        let isOver = breakdown.isOverCommitted
        let title = isOver ? "Projected shortfall" : "Safe to spend"
        /// `_BreakdownRow`: negated unless `positive`, "+" only on positive non-total rows.
        func value(_ v: Double, positive: Bool = false, emphasized: Bool = false) -> String {
            formatter.formatSigned(positive ? v : -v, plusForPositive: positive && !emphasized)
        }
        return BreakdownSheet(
            title: title,
            blurb: isOver
                ? "What you have spent and reserved for the rest of this month is more than the income you expect."
                : "A forward-looking estimate for the rest of this month.",
            rows: [
                ("Income recorded", value(breakdown.actualIncome, positive: true)),
                ("Income still expected", value(breakdown.expectedIncome, positive: true)),
                ("Expenses recorded", value(breakdown.actualExpenses)),
                ("Upcoming recurring bills", value(breakdown.upcomingRecurringExpenses)),
                ("Flexible budget reserve", value(breakdown.flexibleBudgetReserve)),
                ("Suggested goal contributions", value(breakdown.plannedGoalContributions)),
            ],
            totalLabel: title,
            totalValue: value(isOver ? breakdown.overCommitment : breakdown.safeToSpend, positive: true, emphasized: true),
            footer: breakdownFooter(breakdown, formatter: formatter))
    }

    /// `_breakdownFooter` (:350-360).
    public static func breakdownFooter(_ breakdown: SafeToSpendBreakdown, formatter: MoneyFormatter) -> String {
        let days = breakdown.daysRemaining
        if days <= 0 { return "This month is already closed out." }
        let daysLabel = days == 1 ? "1 day remaining" : "\(days) days remaining"
        if breakdown.isOverCommitted {
            return "Add income or reduce planned spending to close the shortfall \u{00B7} \(daysLabel)"
        }
        return "\(formatter.format(breakdown.dailyAllowance)) per day \u{00B7} \(daysLabel)"
    }

    /// `_BudgetRow._formatCurrency` (:1695-1700): whole units from 100 up,
    /// else cents, decided on the unrounded value (99.999 is "$100.00").
    public static func budgetAmount(_ value: Double, formatter: MoneyFormatter) -> String {
        formatter.format(value, decimalDigits: abs(value) >= 100 ? 0 : 2)
    }

    /// `_BudgetRow._subtitle` and `_statusChip` (:1652-1693) for a budgeted
    /// category (every Home row has a limit > 0).
    public static func budgetRow(_ item: BudgetProgress, formatter: MoneyFormatter) -> (subtitle: String, chip: String) {
        let subtitle = "\(budgetAmount(item.spent, formatter: formatter)) of \(budgetAmount(item.limit, formatter: formatter))"
        let chip =
            item.isOver
            ? "\(budgetAmount(abs(item.remaining), formatter: formatter)) over"
            : "\(budgetAmount(item.remaining, formatter: formatter)) left"
        return (subtitle, chip)
    }

    /// `_BudgetsCard` add row subtitle (:1577-1579).
    public static func addBudgetSubtitle(hasBudgets: Bool) -> String {
        hasBudgets ? "Set a limit for another category" : "No monthly limits yet"
    }

    /// `_RecentActivityRow` (:1759-1767, 1795, 1806): title, "Category · Mon d"
    /// and the signed amount ("+" on income, "-" on expense).
    public static func recentRow(_ record: TransactionRecord, formatter: MoneyFormatter) -> (title: String, subtitle: String, amount: String) {
        let isIncome = record.type == .income
        return (
            record.description.isEmpty ? "Transaction" : record.description,
            "\(record.category) \u{00B7} \(DartDateFormat.MMMd(record.date))",
            formatter.formatSigned(isIncome ? record.amount : -record.amount, plusForPositive: true)
        )
    }
}
