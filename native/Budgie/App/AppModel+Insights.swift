import BudgieCore
import Foundation

extension AppModel {
    // MARK: - Insights (Flutter `LocalInsightsSection` on the Flow tab)

    /// Everything `InsightEngine.generate` depends on. The engine reads
    /// `now` only through its calendar day, and the preferences through the
    /// ids they exclude at `now`. The stored rows are compared, not the
    /// derived lists: an array whose storage an edit did not touch (net
    /// worth, settings, tags, rules) compares in O(1), and one that grew or
    /// shrank by its count.
    struct InsightInputs: Equatable {
        let transactions: [StoredRow<TransactionRecord>]
        let budgetLimits: JSONObject
        let goals: [StoredRow<SavingsGoalRecord>]
        let selectedMonth: DartDateTime
        let day: DartDateTime.Fields
        let excludedIDs: [String]

        static func == (lhs: InsightInputs, rhs: InsightInputs) -> Bool {
            lhs.transactions == rhs.transactions && lhs.budgetLimits == rhs.budgetLimits && lhs.goals == rhs.goals
                && lhs.selectedMonth == rhs.selectedMonth
                && (lhs.day.year, lhs.day.month, lhs.day.day) == (rhs.day.year, rhs.day.month, rhs.day.day)
                && lhs.excludedIDs.count == rhs.excludedIDs.count
                && zip(lhs.excludedIDs, rhs.excludedIDs).allSatisfy { $0.utf16.elementsEqual($1.utf16) }
        }
    }

    private func currentInsightInputs(_ data: FinancialData, now: DartDateTime) -> InsightInputs {
        InsightInputs(
            transactions: data.transactionRows, budgetLimits: data.budgetLimitsObject, goals: data.goalRows,
            selectedMonth: selectedMonth, day: now.fields, excludedIDs: insightPreferences.excludedIDs(now: now))
    }

    /// Recomputes `insights` off the main thread when an input changed: the
    /// transactions, budget limits or goals, the selected month, the
    /// preferences, or the clock (a snooze ending, a new day moving budget
    /// pace). Called on every data change, month change, dismiss and snooze;
    /// Flow also calls it when it appears and when the scene becomes active.
    /// Several calls in one turn compute once.
    func refreshInsights() {
        guard let data else { return }
        let inputs = currentInsightInputs(data, now: now)
        guard inputs != insightInputs else { return }
        insightInputs = inputs
        insightsGeneration &+= 1
        let generation = insightsGeneration
        insightsTask?.cancel()
        insightsTask = Task {
            guard !Task.isCancelled else { return }
            await updateInsights(generation: generation)
        }
    }

    /// The engine's lists are derived from `data` inside the detached task,
    /// not on the main thread.
    func updateInsights(generation: Int) async {
        guard let data else { return }
        let now = self.now
        let inputs = currentInsightInputs(data, now: now)
        insightInputs = inputs
        let selectedMonth = inputs.selectedMonth, excluded = inputs.excludedIDs, calendar = self.calendar
        let result = await Task.detached(priority: .userInitiated) {
            Signpost.ledger.withIntervalSignpost("insights.generate") {
                InsightEngine.generate(
                    transactions: data.transactions, budgetLimits: data.budgetLimits, savingsGoals: data.savingsGoals,
                    selectedMonth: selectedMonth, now: now, excludedIDs: excluded, calendar: calendar)
            }
        }.value
        guard generation == insightsGeneration, result != insights else { return }
        insights = result
    }

    /// `_dismiss`: hidden for good; the whole dismissed list is rewritten.
    /// Like Flutter, no confirmation and no undo.
    func dismissInsight(id: String) {
        let write = insightPreferences.dismiss(id)
        preferences.set(write.value, forKey: write.key)
        hideInsight(id)
    }

    /// `_snooze`: hidden for 30 x 24 hours from now; the whole snoozed map
    /// is rewritten.
    func snoozeInsight(id: String) {
        let write = insightPreferences.snooze(id, now: now)
        preferences.set(write.value, forKey: write.key)
        hideInsight(id)
    }

    /// Every card with the id goes at once, as Flutter's rebuild does; the
    /// next candidate fills in when the recomputation lands.
    private func hideInsight(_ id: String) {
        insights.removeAll { $0.id.utf16.elementsEqual(id.utf16) }
        refreshInsights()
    }
}
