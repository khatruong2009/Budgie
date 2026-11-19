import BudgieCore
import Foundation

extension AppModel {
    // MARK: - Savings goals

    /// The Goals tab's list (`_sortedGoals`): incomplete first, then target
    /// date ascending, stable.
    var savingsGoals: [SavingsGoalRecord] { SavingsGoalRecord.sorted(data?.savingsGoals ?? []) }

    /// The summary card's totals and ring.
    var savingsGoalsSummary: SavingsGoalsSummary { SavingsGoalsSummary(goals: data?.savingsGoals ?? []) }

    /// Dart `addSavingsGoal`: the trimmed name, the target date's local
    /// midnight, a Flutter-format id. Rejected (no write) for a blank name
    /// or a target that is not a positive finite number.
    @discardableResult
    func addSavingsGoal(name: String, targetAmount: Double, targetDate: DartDateTime) async -> SaveOutcome {
        let now = self.now
        guard targetAmount.isFinite else { return .rejected }
        return await mutateOutcome(
            [Section.savingsGoals],
            {
                $0.addSavingsGoal(
                    name: name, targetAmount: targetAmount, targetDate: targetDate,
                    id: SavingsGoalRecord.makeID(now: now, counter: savingsGoalIDCounter), now: now) != nil
            },
            after: { savingsGoalIDCounter += 1 })
    }

    /// Dart `updateSavingsGoal` (the edit form): name, target, saved amount
    /// and target date (not normalised); `completedAt` follows the amount.
    @discardableResult
    func updateSavingsGoal(id: String, _ edit: SavingsGoalRecord.Edit) async -> SaveOutcome {
        guard edit.targetAmount.isFinite, edit.currentAmount.isFinite else { return .rejected }
        return await mutateOutcome([Section.savingsGoals], { $0.updateSavingsGoal(id: id, edit, now: now) })
    }

    /// Dart `deleteSavingsGoal`: every goal with this id.
    @discardableResult
    func deleteSavingsGoal(id: String) async -> SaveOutcome {
        await mutateOutcome([Section.savingsGoals], { $0.deleteSavingsGoal(id: id) })
    }

    /// Dart `allocateToSavingsGoal` (Add money): no transaction is created.
    /// Whether it completes the goal is `willComplete(allocating:)` on the
    /// goal as shown before the dialog, as in Flutter.
    @discardableResult
    func allocateToSavingsGoal(id: String, amount: Double) async -> SaveOutcome {
        guard amount.isFinite else { return .rejected }
        return await mutateOutcome([Section.savingsGoals], { $0.allocateToSavingsGoal(id: id, amount: amount, now: now) })
    }
}
