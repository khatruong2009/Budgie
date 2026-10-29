import BudgieCore
import Foundation

extension AppModel {
    // MARK: - Savings goals

    /// The Goals tab's list (`_sortedGoals`): incomplete first, then target
    /// date ascending, stable.
    var savingsGoals: [SavingsGoalRecord] { SavingsGoalRecord.sorted(data?.savingsGoals ?? []) }

    /// The summary card's totals and ring.
    var savingsGoalsSummary: SavingsGoalsSummary { SavingsGoalsSummary(goals: data?.savingsGoals ?? []) }

    private func persistGoals() async -> SaveOutcome {
        await persist([Section.savingsGoals]) ? .saved : .failed
    }

    /// Dart `addSavingsGoal`: the trimmed name, the target date's local
    /// midnight, a Flutter-format id. Rejected (no write) for a blank name
    /// or a target that is not a positive finite number.
    @discardableResult
    func addSavingsGoal(name: String, targetAmount: Double, targetDate: DartDateTime) async -> SaveOutcome {
        let now = self.now
        guard targetAmount.isFinite,
            applyMutation(
                {
                    $0.addSavingsGoal(
                        name: name, targetAmount: targetAmount, targetDate: targetDate,
                        id: SavingsGoalRecord.makeID(now: now, counter: savingsGoalIDCounter), now: now) != nil
                },
                after: { savingsGoalIDCounter += 1 })
        else { return .rejected }
        return await persistGoals()
    }

    /// Dart `updateSavingsGoal` (the edit form): name, target, saved amount
    /// and target date (not normalised); `completedAt` follows the amount.
    @discardableResult
    func updateSavingsGoal(id: String, _ edit: SavingsGoalRecord.Edit) async -> SaveOutcome {
        guard edit.targetAmount.isFinite, edit.currentAmount.isFinite,
            applyMutation({ $0.updateSavingsGoal(id: id, edit, now: now) })
        else { return .rejected }
        return await persistGoals()
    }

    /// Dart `deleteSavingsGoal`: every goal with this id.
    @discardableResult
    func deleteSavingsGoal(id: String) async -> SaveOutcome {
        guard applyMutation({ $0.deleteSavingsGoal(id: id) }) else { return .rejected }
        return await persistGoals()
    }

    /// Dart `allocateToSavingsGoal` (Add money): no transaction is created.
    /// Whether it completes the goal is `willComplete(allocating:)` on the
    /// goal as shown before the dialog, as in Flutter.
    @discardableResult
    func allocateToSavingsGoal(id: String, amount: Double) async -> SaveOutcome {
        guard amount.isFinite, applyMutation({ $0.allocateToSavingsGoal(id: id, amount: amount, now: now) }) else {
            return .rejected
        }
        return await persistGoals()
    }
}
