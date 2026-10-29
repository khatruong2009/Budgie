import BudgieCore
import Foundation

extension AppModel {
    // MARK: - Transactions

    @discardableResult
    func addTransaction(
        type: TransactionType, description: String, amount: Double, category: String, date: DartDateTime, tagIds: [String] = []
    ) async -> Bool {
        guard amount.isFinite else { return false }
        return await mutate(
            [Section.transactions],
            { data in
                _ = data.addTransaction(
                    type: type, description: description, amount: amount, category: category, date: date, tagIds: tagIds,
                    id: newID(), now: now)
                return true
            },
            after: transactionsChanged)
    }

    /// `.rejected` (nothing changed or written, no save-failed toast) for a
    /// missing row or a non-finite amount.
    @discardableResult
    func updateTransaction(id: String, _ edit: TransactionRecord.Edit) async -> SaveOutcome {
        guard edit.amount.isFinite,
            applyMutation({ $0.updateTransaction(id: id, edit, now: now) }, after: transactionsChanged)
        else { return .rejected }
        return await persist([Section.transactions]) ? .saved : .failed
    }

    /// `.rejected` (nothing written, no save-failed toast) for a missing row.
    @discardableResult
    func deleteTransaction(id: String) async -> SaveOutcome {
        guard applyMutation({ $0.deleteTransaction(id: id) }, after: transactionsChanged) else { return .rejected }
        return await persist([Section.transactions]) ? .saved : .failed
    }

    // MARK: - Recurring

    /// Dart generates due occurrences right after a template is added.
    @discardableResult
    func addTemplate(_ edit: RecurringTemplate.Edit) async -> Bool {
        guard edit.amount.isFinite else { return false }
        var generated = false
        return await mutate(
            [Section.recurringTransactions, Section.transactions],
            { data in
                data.addTemplate(.make(
                    id: newID(), type: edit.type, description: edit.description, amount: edit.amount, category: edit.category,
                    pattern: edit.pattern, startDate: edit.startDate, dayOfMonth: edit.dayOfMonth, dayOfWeek: edit.dayOfWeek))
                generated = RecurringGenerator.generateDue(
                    in: &data, now: now, clock: { [calendar] in calendar.now() }, newID: newID).changed
                return true
            },
            after: { if generated { transactionsChanged() } })
    }

    @discardableResult
    func updateTemplate(id: String, _ edit: RecurringTemplate.Edit) async -> Bool {
        guard edit.amount.isFinite else { return false }
        return await mutate([Section.recurringTransactions], { $0.updateTemplate(id: id, edit) })
    }

    @discardableResult
    func setTemplateActive(id: String, _ active: Bool) async -> Bool {
        await mutate([Section.recurringTransactions], { $0.setTemplateActive(id: id, active, now: now) })
    }

    @discardableResult
    func deleteTemplate(id: String) async -> Bool {
        await mutate([Section.recurringTransactions], { $0.deleteTemplate(id: id) })
    }

    /// `_generateDueTransactions` (recurring_transactions_page.dart:120-146):
    /// the launch generator, run now for every due template; the rows and
    /// the advanced cursors go to disk in one write.
    @discardableResult
    func generateDueNow() async -> DueGeneration {
        guard data != nil else { return DueGeneration(generated: 0, saved: true) }
        let result = RecurringGenerator.generateDue(in: &data!, now: now, clock: { [calendar] in calendar.now() }, newID: newID)
        guard result.changed else {
            // Nothing due, but an earlier failed write may still be in
            // memory only: retry it, and report success only once it is saved.
            if hasUnsavedChanges { await retrySaves() }
            return DueGeneration(generated: 0, saved: !hasUnsavedChanges)
        }
        if !result.generated.isEmpty { transactionsChanged() }
        let saved = await persist([Section.transactions, Section.recurringTransactions])
        return DueGeneration(generated: result.generated.count, saved: saved)
    }

    /// The latest transaction generated from a template, for the edit
    /// form's preview (`RecurringGenerator.previewOccurrences(editing:...)`).
    /// Read it once when the form opens: it scans the ledger.
    func lastGeneratedDate(forTemplate id: String) -> DartDateTime? {
        data?.lastGeneratedDate(forTemplate: id)
    }

    // MARK: - Budgets

    /// Dart `getCategoryBudgetLimit`: exact name, nil when there is none.
    func budgetLimit(for category: String) -> Double? {
        data?.budgetLimit(for: category)
    }

    /// Dart `setCategoryBudgetLimit` (trimmed; `limit <= 0` removes).
    @discardableResult
    func setBudgetLimit(category: String, limit: Double) async -> Bool {
        await mutate([Section.categoryBudgetLimits], { $0.setBudgetLimit(category: category, limit: limit) })
    }

    /// Dart `removeCategoryBudgetLimit`.
    @discardableResult
    func removeBudgetLimit(category: String) async -> Bool {
        await mutate([Section.categoryBudgetLimits], { $0.removeBudgetLimit(category: category) })
    }

    /// Home's budget rows and the Edit/Add picker lists for `month`, in
    /// one pass over the categories and the ledger month summary.
    func budgetOverview(forMonth month: DartDateTime) -> FinancialData.BudgetOverview {
        data?.budgetOverview(ledger.summary(forMonth: month)) ?? .empty
    }
}
