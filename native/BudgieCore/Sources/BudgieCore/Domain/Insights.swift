import Foundation

// A port of budget_app/lib/insights/insight_engine.dart (the rules and the
// candidate order) and of the preference handling in
// budget_app/lib/widgets/local_insights_section.dart (dismiss and snooze).
//
// Ids, headlines, explanations and actions are byte-identical to Dart's, so a
// dismissal made in either app hides the same card in the other. Every
// string comparison is by UTF-16 code units, sums fold in stored order, and
// dates use DartDateTime/DartCalendar.

public enum InsightType: String, Sendable, CaseIterable {
    case budgetPace, monthlySpendingChange, unusualTransaction, savingsRateTrend, recurringAmountChange
    case consistentlyUnderBudget, goalBehindSchedule, negativeCashFlow, possibleDuplicate
}

/// Dart's declaration order; `generate` sorts by `rank` (urgent first).
public enum InsightSeverity: String, Sendable, CaseIterable {
    case info, positive, warning, urgent

    var rank: Int {
        switch self {
        case .urgent: 0
        case .warning: 1
        case .positive: 2
        case .info: 3
        }
    }
}

/// One entry of `LocalInsight.supportingValues` (a Dart map, insertion order).
public struct InsightValue: Sendable, Hashable {
    public let key: String
    public let value: Double
}

/// Dart `LocalInsight`. Not `Identifiable`: two insights in one result can
/// share an id (three identical rows give two `duplicate:` insights), and
/// Flutter shows both and dismisses both together.
public struct LocalInsight: Sendable, Hashable {
    public let id: String
    public let type: InsightType
    public let severity: InsightSeverity
    public let headline: String
    public let explanation: String
    /// Not displayed; in Dart's insertion order.
    public let supportingValues: [InsightValue]
    public let suggestedAction: String
    /// Local midnight of `now` (`DateTime(now.year, now.month, now.day)`).
    public let generatedDate: DartDateTime

    public func supportingValue(_ key: String) -> Double? {
        supportingValues.first { $0.key == key }?.value
    }
}

public enum InsightEngine {
    /// The section's `limit` (Flutter never passes another).
    public static let defaultLimit = 3

    /// Dart `InsightEngine.generate`.
    ///
    /// - `transactions`: every readable row in stored order
    ///   (`FinancialData.transactions`, not a sorted list).
    /// - `budgetLimits`: `FinancialData.budgetLimits` (stored key order).
    /// - `savingsGoals`: `FinancialData.savingsGoals` (stored order).
    /// - `excludedIDs`: dismissed ids plus ids snoozed past `now`
    ///   (`InsightPreferences.excludedIDs(now:)`); matched as UTF-16.
    ///
    /// Where Dart's `double.round()` throws (a NaN or infinite percentage,
    /// only reachable from hand-edited data) the whole call throws in Dart
    /// and the section fails to build; this returns no insights instead.
    public static func generate(
        transactions: [TransactionRecord], budgetLimits: [(String, Double)], savingsGoals: [SavingsGoalRecord],
        selectedMonth: DartDateTime, now: DartDateTime, excludedIDs: [String] = [], limit: Int = defaultLimit,
        calendar: DartCalendar
    ) -> [LocalInsight] {
        if limit <= 0 { return [] }
        let selected = selectedMonth.fields
        let month = calendar.date(selected.year, selected.month)
        let generatedDate = calendar.startOfDay(now)
        let rules = Rules(
            transactions: transactions, calendar: calendar, month: month, now: now, generatedDate: generatedDate)
        var candidates: [LocalInsight]
        do {
            candidates = rules.possibleDuplicates()
            candidates += try rules.budgetPace(budgetLimits)
            candidates += try rules.goalProgress(savingsGoals)
            candidates += try rules.recurringChanges()
            candidates += rules.negativeCashFlow()
            candidates += try rules.monthlySpendingChange()
            candidates += rules.unusualTransactions()
            candidates += try rules.savingsRateTrend()
            candidates += try rules.consistentlyUnderBudget(budgetLimits)
        } catch {
            return []
        }
        let excluded = Set(excludedIDs.map { Array($0.utf16) })
        candidates.removeAll { excluded.contains(Array($0.id.utf16)) }
        // Severity rank, then id by code units, with Dart's tie order for
        // equal (severity, id) pairs (repeated `duplicate:` ids).
        DartSort.sort(&candidates) { a, b in
            let severity = DartSort.compare(a.severity.rank, b.severity.rank)
            return severity != 0 ? severity : DartSort.compare(a.id, b.id)
        }
        return Array(candidates.prefix(limit))
    }

    /// `_slug`: trim, lowercase, every run of code units outside `[a-z0-9]`
    /// becomes one "-", then leading and trailing "-" are removed.
    static func slug(_ value: String) -> String {
        var out: [UInt8] = []
        var gap = false
        for unit in DartString.lowercase(DartString.trim(value)).utf16 {
            if (0x61...0x7A).contains(unit) || (0x30...0x39).contains(unit) {
                if gap && !out.isEmpty { out.append(UInt8(ascii: "-")) }
                gap = false
                out.append(UInt8(unit))
            } else {
                gap = true
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Dart `double.round()`: half away from zero, saturating at the 64-bit
    /// range, throwing on NaN and infinities.
    struct NotFinite: Error {}

    static func dartRound(_ value: Double) throws(NotFinite) -> Int {
        guard value.isFinite else { throw NotFinite() }
        let rounded = value.rounded()
        if rounded >= 9_223_372_036_854_775_808.0 { return Int.max }
        if rounded <= -9_223_372_036_854_775_808.0 { return Int.min }
        return Int(rounded)
    }
}

/// The nine rules over one call's inputs. Rows are bucketed by month once;
/// every bucket keeps stored order, so each sum folds exactly as Dart's
/// `where(...).fold(0.0, ...)` over the whole list does.
private struct Rules {
    let transactions: [TransactionRecord]
    let calendar: DartCalendar
    let month: DartDateTime
    let now: DartDateTime
    let generatedDate: DartDateTime
    /// Row indices by `year * 12 + month` of the row's date fields.
    let rowsByMonth: [Int: [Int]]
    let monthKeys: [Int]
    let selectedKey: Int

    init(transactions: [TransactionRecord], calendar: DartCalendar, month: DartDateTime, now: DartDateTime, generatedDate: DartDateTime) {
        self.transactions = transactions
        self.calendar = calendar
        self.month = month
        self.now = now
        self.generatedDate = generatedDate
        var byMonth: [Int: [Int]] = [:]
        var keys: [Int] = []
        keys.reserveCapacity(transactions.count)
        for (index, row) in transactions.enumerated() {
            let key = Rules.key(row.date)
            keys.append(key)
            byMonth[key, default: []].append(index)
        }
        rowsByMonth = byMonth
        monthKeys = keys
        selectedKey = Rules.key(month)
    }

    /// `_sameMonth`: equal year and month fields.
    static func key(_ date: DartDateTime) -> Int {
        DartCalendar.monthKey(date)
    }

    var year: Int { month.fields.year }
    var monthNumber: Int { month.fields.month }
    /// `${month.year}-${month.month}` (not zero padded).
    var yearMonth: String { "\(year)-\(monthNumber)" }

    /// `DateTime(month.year, month.month - offset)`.
    func monthKey(minus offset: Int) -> Int {
        Rules.key(calendar.addingMonths(month, -offset))
    }

    func rows(_ key: Int) -> [TransactionRecord] {
        (rowsByMonth[key] ?? []).map { transactions[$0] }
    }

    /// `_expenses(transactions, month)`.
    func expenses(_ key: Int) -> [TransactionRecord] {
        rows(key).filter { $0.type == .expense }
    }

    /// `_cashFlow`: income and expenses of the month, in stored order.
    func cashFlow(_ key: Int) -> (income: Double, expenses: Double, net: Double) {
        var income = 0.0
        var expenses = 0.0
        for row in rows(key) {
            if row.type == .income { income += row.amount } else { expenses += row.amount }
        }
        return (income, expenses, income - expenses)
    }

    /// Expenses of the month in `category` (code-unit equality), summed.
    func spent(_ key: Int, category: [UInt16]) -> Double {
        var sum = 0.0
        for row in expenses(key) where row.category.utf16.elementsEqual(category) { sum += row.amount }
        return sum
    }

    func insight(
        _ id: String, _ type: InsightType, _ severity: InsightSeverity, headline: String, explanation: String,
        values: [(String, Double)], action: String
    ) -> LocalInsight {
        LocalInsight(
            id: id, type: type, severity: severity, headline: headline, explanation: explanation,
            supportingValues: values.map { InsightValue(key: $0.0, value: $0.1) }, suggestedAction: action,
            generatedDate: generatedDate)
    }

    // MARK: Rules (insight_engine.dart, in candidate order)

    /// `_possibleDuplicates` (lines 390-422): every later row of the month
    /// whose (type, description slug, amount, local day) matches an earlier one.
    func possibleDuplicates() -> [LocalInsight] {
        var seen = Set<String>()
        var result: [LocalInsight] = []
        for row in rows(selectedKey) {
            let day = calendar.startOfDay(row.date)
            let key = [
                row.type.rawValue, InsightEngine.slug(row.description), DartFixed.toStringAsFixed(row.amount, 2),
                day.toIso8601String(),
            ].joined(separator: ":")
            // The key is ASCII: Swift equality is code-unit equality here.
            if seen.insert(key).inserted { continue }
            result.append(insight(
                "duplicate:\(key)", .possibleDuplicate, .warning, headline: "Possible duplicate transaction",
                explanation: "\(row.description) appears more than once with the same amount and date.",
                values: [("amount", row.amount)], action: "Review matching transactions"))
        }
        return result
    }

    /// `_budgetPace` (lines 106-145): only for the real current month.
    func budgetPace(_ limits: [(String, Double)]) throws(InsightEngine.NotFinite) -> [LocalInsight] {
        let n = now.fields
        guard !limits.isEmpty, n.year == year, n.month == monthNumber else { return [] }
        let daysInMonth = calendar.date(year, monthNumber + 1, 0).day
        let elapsedRatio = Double(min(max(n.day, 1), daysInMonth)) / Double(daysInMonth)
        var result: [LocalInsight] = []
        for (key, limit) in limits {
            if limit <= 0 { continue }
            let spent = spent(selectedKey, category: Array(key.utf16))
            let usedRatio = spent / limit
            if spent < 25 || usedRatio < 0.65 || usedRatio <= elapsedRatio + 0.15 { continue }
            let usedPercent = try InsightEngine.dartRound(usedRatio * 100)
            let monthPercent = try InsightEngine.dartRound(elapsedRatio * 100)
            result.append(insight(
                "budget-pace:\(InsightEngine.slug(key)):\(yearMonth)", .budgetPace, usedRatio >= 1 ? .urgent : .warning,
                headline: "\(key) is ahead of budget pace",
                explanation: "You have used \(usedPercent)% of this budget, while \(monthPercent)% of the month has passed.",
                values: [("spent", spent), ("limit", limit), ("usedRatio", usedRatio)],
                action: "Review \(DartString.lowercase(key)) transactions"))
        }
        return result
    }

    /// `_monthlySpendingChange` (lines 147-180).
    func monthlySpendingChange() throws(InsightEngine.NotFinite) -> [LocalInsight] {
        let current = expenses(selectedKey)
        let previous = expenses(monthKey(minus: 1))
        guard current.count >= 3, previous.count >= 3 else { return [] }
        let currentTotal = current.reduce(0.0) { $0 + $1.amount }
        let previousTotal = previous.reduce(0.0) { $0 + $1.amount }
        if previousTotal < 50 { return [] }
        let change = (currentTotal - previousTotal) / previousTotal
        if abs(change) < 0.2 { return [] }
        let percent = try InsightEngine.dartRound(abs(change) * 100)
        let increased = change > 0
        return [insight(
            "monthly-change:\(yearMonth)", .monthlySpendingChange, increased ? .warning : .positive,
            headline: "Spending is \(percent)% \(increased ? "higher" : "lower")",
            explanation: "This compares expenses in the selected month with the previous month.",
            values: [("currentExpenses", currentTotal), ("previousExpenses", previousTotal), ("change", change)],
            action: increased ? "See what changed" : "Keep the momentum")]
    }

    /// `_unusualTransactions` (lines 182-221): the newest expense of the
    /// month that is at least 50 and 2.5x the median of at least four
    /// earlier positive expenses of its category outside the month.
    func unusualTransactions() -> [LocalInsight] {
        // Newest first (`b.date.compareTo(a.date)`), equal instants in
        // Dart's tie order.
        let current = DartSort.sorted((rowsByMonth[selectedKey] ?? []).filter { transactions[$0].type == .expense }) {
            DartSort.compare(transactions[$1].date.microsecondsSinceEpoch, transactions[$0].date.microsecondsSinceEpoch)
        }
        guard !current.isEmpty else { return [] }
        // Positive expenses outside the month, by category, oldest first.
        // A candidate's history is the prefix before its instant; its median
        // depends only on (category, prefix length), so each is computed once.
        var history: [[UInt16]: [(micros: Int64, amount: Double)]] = [:]
        for (index, row) in transactions.enumerated()
        where row.type == .expense && monthKeys[index] != selectedKey && row.amount > 0 {
            history[Array(row.category.utf16), default: []].append((row.date.microsecondsSinceEpoch, row.amount))
        }
        for key in history.keys { history[key]!.sort { $0.micros < $1.micros } }
        var medians: [[UInt16]: [Int: Double]] = [:]
        for index in current {
            let candidate = transactions[index]
            // Dart builds the history first; both checks only `continue`.
            if candidate.amount < 50 { continue }
            let category = Array(candidate.category.utf16)
            guard let items = history[category] else { continue }
            let micros = candidate.date.microsecondsSinceEpoch
            var low = 0, high = items.count
            while low < high {
                let mid = (low + high) / 2
                if items[mid].micros < micros { low = mid + 1 } else { high = mid }
            }
            let count = low
            if count < 4 { continue }
            let median: Double
            if let cached = medians[category]?[count] {
                median = cached
            } else {
                let amounts = items[..<count].map(\.amount).sorted()
                let middle = count / 2
                median = count % 2 == 1 ? amounts[middle] : (amounts[middle - 1] + amounts[middle]) / 2
                medians[category, default: [:]][count] = median
            }
            if candidate.amount < median * 2.5 { continue }
            let multiple = candidate.amount / median
            let day = candidate.date.toIso8601String().split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return [insight(
                "unusual:\(InsightEngine.slug(candidate.category)):\(day):\(DartFixed.toStringAsFixed(candidate.amount, 2))",
                .unusualTransaction, .warning,
                headline: "Unusual \(DartString.lowercase(candidate.category)) expense",
                explanation: "\(candidate.description) was \(DartFixed.toStringAsFixed(multiple, 1))\u{D7} your typical expense in this category.",
                values: [("amount", candidate.amount), ("categoryMedian", median), ("multiple", multiple)],
                action: "Check this transaction")]
        }
        return []
    }

    /// `_savingsRateTrend` (lines 223-255).
    func savingsRateTrend() throws(InsightEngine.NotFinite) -> [LocalInsight] {
        let current = cashFlow(selectedKey)
        let prior = cashFlow(monthKey(minus: 1))
        if current.income <= 0 || prior.income <= 0 { return [] }
        let currentRate = current.net / current.income
        let priorRate = prior.net / prior.income
        let delta = currentRate - priorRate
        if abs(delta) < 0.08 { return [] }
        let points = try InsightEngine.dartRound(abs(delta) * 100)
        let improving = delta > 0
        return [insight(
            "savings-rate:\(yearMonth)", .savingsRateTrend, improving ? .positive : .warning,
            headline: "Savings rate is \(improving ? "up" : "down") \(points) points",
            explanation: "This is the share of income left after expenses compared with last month.",
            values: [("currentRate", currentRate), ("previousRate", priorRate), ("delta", delta)],
            action: improving ? "Keep the momentum" : "Review flexible spending")]
    }

    /// `_recurringChanges` (lines 257-295): the two newest rows of each
    /// recurring template, whatever the selected month.
    func recurringChanges() throws(InsightEngine.NotFinite) -> [LocalInsight] {
        var order: [[UInt16]] = []
        var groups: [[UInt16]: (id: String, rows: [Int])] = [:]
        for (index, row) in transactions.enumerated() {
            guard let templateID = row.recurringTemplateId else { continue }
            let key = Array(templateID.utf16)
            if groups[key] == nil {
                order.append(key)
                groups[key] = (templateID, [])
            }
            groups[key]!.rows.append(index)
        }
        var result: [LocalInsight] = []
        for key in order {
            let group = groups[key]!
            if group.rows.count < 2 { continue }
            // Newest first, equal instants in Dart's tie order.
            let items = DartSort.sorted(group.rows) {
                DartSort.compare(transactions[$1].date.microsecondsSinceEpoch, transactions[$0].date.microsecondsSinceEpoch)
            }
            let latest = transactions[items[0]]
            let previous = transactions[items[1]]
            if previous.amount <= 0 { continue }
            let change = (latest.amount - previous.amount) / previous.amount
            if abs(change) < 0.05 && abs(latest.amount - previous.amount) < 5 { continue }
            let percent = try InsightEngine.dartRound(abs(change) * 100)
            let latestDate = latest.date.fields
            result.append(insight(
                "recurring-change:\(InsightEngine.slug(group.id)):\(latestDate.year)-\(latestDate.month)",
                .recurringAmountChange, change > 0 ? .warning : .positive,
                headline: "\(latest.description) changed by \(percent)%",
                explanation: "The latest recurring amount is \(change > 0 ? "higher" : "lower") than the previous occurrence.",
                values: [("latestAmount", latest.amount), ("previousAmount", previous.amount), ("change", change)],
                action: "Review the recurring transaction"))
        }
        return result
    }

    /// `_consistentlyUnderBudget` (lines 297-331): under 70% of the limit in
    /// each of the three months before the selected one.
    func consistentlyUnderBudget(_ limits: [(String, Double)]) throws(InsightEngine.NotFinite) -> [LocalInsight] {
        var result: [LocalInsight] = []
        for (key, limit) in limits {
            if limit <= 0 { continue }
            let category = Array(key.utf16)
            var ratios: [Double] = []
            for offset in 1...3 {
                let spent = spent(monthKey(minus: offset), category: category)
                if spent <= 0 {
                    ratios.removeAll()
                    break
                }
                ratios.append(spent / limit)
            }
            if ratios.count != 3 || ratios.contains(where: { $0 >= 0.7 }) { continue }
            let average = (ratios[0] + ratios[1] + ratios[2]) / Double(ratios.count)
            let percent = try InsightEngine.dartRound(average * 100)
            result.append(insight(
                "under-budget:\(InsightEngine.slug(key)):\(yearMonth)", .consistentlyUnderBudget, .positive,
                headline: "\(key) has stayed under budget",
                explanation: "You used an average of \(percent)% of this budget over the last three full months.",
                values: [("averageUsedRatio", average), ("limit", limit)],
                action: "Consider adjusting this budget"))
        }
        return result
    }

    /// `_goalProgress` (lines 333-362): day counts are elapsed 24-hour
    /// units, truncated (one short across a DST change).
    func goalProgress(_ goals: [SavingsGoalRecord]) throws(InsightEngine.NotFinite) -> [LocalInsight] {
        let today = generatedDate
        var result: [LocalInsight] = []
        for goal in goals where !goal.isCompleted {
            let duration = goal.targetDate.differenceInDays(goal.createdAt)
            let elapsed = today.differenceInDays(goal.createdAt)
            if duration <= 0 || elapsed < 14 { continue }
            let expected = dartClamp(Double(elapsed) / Double(duration), 0, 1)
            if goal.progress + 0.1 >= expected { continue }
            // `progressPercent`, which throws in Dart on a NaN progress.
            let progressPercent = try InsightEngine.dartRound(goal.progress * 100)
            let expectedPercent = try InsightEngine.dartRound(expected * 100)
            result.append(insight(
                "goal-behind:\(InsightEngine.slug(goal.id))", .goalBehindSchedule,
                goal.targetDate.isBefore(today) ? .urgent : .warning,
                headline: "\(goal.name) is behind schedule",
                explanation: "Progress is \(progressPercent)%; about \(expectedPercent)% would keep this goal on pace.",
                values: [("progress", goal.progress), ("expectedProgress", expected)],
                action: "Review this savings goal"))
        }
        return result
    }

    /// `_negativeCashFlow` (lines 364-388): income recorded and net negative
    /// in the selected month and the two before it.
    func negativeCashFlow() -> [LocalInsight] {
        let flows = (0..<3).map { cashFlow($0 == 0 ? selectedKey : monthKey(minus: $0)) }
        if flows.contains(where: { $0.income <= 0 || $0.net >= 0 }) { return [] }
        return [insight(
            "negative-flow:\(yearMonth)", .negativeCashFlow, .urgent,
            headline: "Cash flow has been negative for 3 months",
            explanation: "Expenses exceeded recorded income in each of the last three months.",
            values: flows.enumerated().map { ("month\($0.offset + 1)", $0.element.net) },
            action: "Review income and recurring expenses")]
    }
}

// MARK: - Preferences

/// The dismissed and snoozed insight ids, as local_insights_section.dart
/// keeps them in two `flutter.`-prefixed preferences (not the store).
///
/// Dismissals are permanent; a snooze hides an id while its time is after
/// `now` (strictly). Neither list is ever pruned, and a dismiss leaves the
/// snoozes alone (and the reverse). Each mutation returns the one
/// preference Flutter rewrites, whole, from memory.
public struct InsightPreferences: Sendable, Equatable {
    public struct Snooze: Sendable {
        public let id: String
        public let until: DartDateTime
    }

    public static let dismissedKey = PreferenceKey.localInsightsDismissed
    public static let snoozedKey = PreferenceKey.localInsightsSnoozed
    /// `Duration(days: 30)`: 30 x 24 hours of elapsed time.
    public static let snoozeDays = 30

    /// Dart's `Set` in insertion order (unique by code units).
    public private(set) var dismissed: [String]
    /// Dart's `Map` in insertion order (unique by code units).
    public private(set) var snoozed: [Snooze]

    public init() {
        dismissed = []
        snoozed = []
    }

    /// `_loadPreferences`. A value of the wrong type (or a list holding a
    /// non-string) reads as absent; Dart throws there and never shows the
    /// section (PARITY_GAPS). The snoozed JSON keeps Dart's quirks: invalid
    /// JSON or a non-object gives no snoozes, a non-string value stops the
    /// load there (earlier entries stay), and an unparseable date skips only
    /// its entry.
    public static func load(from store: PreferencesStore, timeZone: TimeZone) -> InsightPreferences {
        load(dismissed: store.value(forKey: dismissedKey), snoozed: store.value(forKey: snoozedKey), timeZone: timeZone)
    }

    public static func load(dismissed: PreferenceValue?, snoozed: PreferenceValue?, timeZone: TimeZone) -> InsightPreferences {
        var result = InsightPreferences()
        if case .stringList(let ids)? = dismissed {
            var seen = Set<[UInt16]>()
            result.dismissed = ids.filter { seen.insert(Array($0.utf16)).inserted }
        }
        guard case .string(let raw)? = snoozed,
            let decoded = try? JSONParser.parse(Array(raw.utf8)), case .object(let object) = decoded
        else { return result }
        // Dart's map: a repeated key keeps its first position and last value.
        var order: [[UInt16]] = []
        var latest: [[UInt16]: (key: String, value: JSONValue)] = [:]
        for member in object.members {
            let units = member.key.codeUnits
            if latest[units] == nil { order.append(units) }
            latest[units] = (member.key.value, member.value)
        }
        for units in order {
            let entry = latest[units]!
            guard case .string(let text) = entry.value else { break }
            if let until = DartDateTime.tryParse(text.value, timeZone: timeZone) {
                result.snoozed.append(Snooze(id: entry.key, until: until))
            }
        }
        return result
    }

    /// `_excluded(now)`: every dismissed id, and each snoozed id whose time
    /// is after `now`.
    public func excludedIDs(now: DartDateTime) -> [String] {
        dismissed + snoozed.filter { $0.until.isAfter(now) }.map(\.id)
    }

    /// `_dismiss`: adds the id and returns the whole list to write, sorted
    /// by code units.
    public mutating func dismiss(_ id: String) -> (key: String, value: PreferenceValue) {
        if !dismissed.contains(where: { $0.utf16.elementsEqual(id.utf16) }) { dismissed.append(id) }
        return (Self.dismissedKey, .stringList(dismissed.sorted(by: DartString.precedes)))
    }

    /// `_snooze`: the id is hidden until `now + 30 x 24h` (an id already
    /// snoozed keeps its position) and the whole map is returned as Dart's
    /// `jsonEncode` writes it.
    public mutating func snooze(_ id: String, now: DartDateTime) -> (key: String, value: PreferenceValue) {
        let entry = Snooze(id: id, until: now.adding(days: Self.snoozeDays))
        if let index = snoozed.firstIndex(where: { $0.id.utf16.elementsEqual(id.utf16) }) {
            snoozed[index] = entry
        } else {
            snoozed.append(entry)
        }
        let object = JSONObject(ordered: snoozed.map { ($0.id, .string($0.until.toIso8601String())) })
        return (Self.snoozedKey, .string(DartJSON.encodeString(.object(object))))
    }

    /// Code-unit equality of the ids, and Dart `DateTime` equality of the
    /// times.
    public static func == (lhs: InsightPreferences, rhs: InsightPreferences) -> Bool {
        lhs.dismissed.count == rhs.dismissed.count && lhs.snoozed.count == rhs.snoozed.count
            && zip(lhs.dismissed, rhs.dismissed).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
            && zip(lhs.snoozed, rhs.snoozed).allSatisfy { $0.id.utf16.elementsEqual($1.id.utf16) && $0.until == $1.until }
    }
}
