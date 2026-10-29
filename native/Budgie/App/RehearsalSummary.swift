#if DEBUG
import BudgieCore
import Foundation

/// Upgrade rehearsal support (UPGRADE_VERIFICATION.md), debug builds only:
/// when launched with BUDGIE_REHEARSAL_SUMMARY=1, writes what the app shows
/// to Library/Caches/budgie-rehearsal.json so the script can compare it with
/// the numbers the Flutter models compute from the same files.
@MainActor
enum RehearsalSummary {
    /// BUDGIE_REHEARSAL_EDIT=1: makes one of every MVP edit through the
    /// model, so the rehearsal can reinstall the Flutter build over
    /// Swift-written data.
    static func performScriptedEditsIfRequested(_ model: AppModel) async {
        guard ProcessInfo.processInfo.environment["BUDGIE_REHEARSAL_EDIT"] == "1", let data = model.data else { return }
        let calendar = model.calendar
        let today = calendar.month(of: model.now)
        await model.addTransaction(type: .expense, description: "Rehearsal ☕️ \"swift\", edit", amount: 1200, category: "Groceries", date: model.now)
        await model.addTransaction(type: .income, description: "Rehearsal income", amount: 0.1 + 0.2, category: "Salary", date: calendar.date(today.year, today.month, 1))
        if let first = data.transactions.first {
            await model.updateTransaction(id: first.id, .init(type: first.type, description: first.description + " (edited in Swift)", amount: 42, category: first.category, date: first.date))
        }
        if data.transactions.count > 5 { await model.deleteTransaction(id: data.transactions[4].id) }
        await model.addTemplate(.init(type: .expense, description: "Rehearsal monthly", amount: 99.5, category: "Housing", pattern: .monthly, startDate: calendar.date(today.year, today.month, 1), dayOfMonth: 31, dayOfWeek: nil))
        if let template = model.data?.templates.first { await model.setTemplateActive(id: template.id, false) }
        await model.setBaseCurrency("gbp")
        model.setThemeMode(.light)
    }

    static func writeIfRequested(_ model: AppModel) {
        guard ProcessInfo.processInfo.environment["BUDGIE_REHEARSAL_SUMMARY"] == "1", let data = model.data else { return }
        let calendar = data.calendar
        let now = model.now
        var monthly: [String: Any] = [:]
        let ledger = LedgerIndex.build(data.transactions, calendar: calendar)
        for month in ledger.availableMonths {
            let totals = ledger.summary(forMonth: month)
            monthly[calendar.netWorthMonthKey(month)] = [
                "totalIncome": totals.income, "totalExpenses": totals.expenses, "count": totals.transactionCount,
            ]
        }
        var netWorth: [String: Any] = [:]
        for month in data.netWorthAvailableMonths(now: now) {
            netWorth[calendar.netWorthMonthKey(month)] = [
                "assets": data.totalAssets(forMonth: month), "liabilities": data.totalLiabilities(forMonth: month),
                "netWorth": data.netWorth(forMonth: month),
            ]
        }
        let widget = data.widgetCashFlow(now: now)
        let summary: [String: Any] = [
            "now": now.toIso8601String(),
            "transactionCount": data.transactions.count,
            "unreadableTransactionRows": data.unreadableTransactionCount,
            "monthly": monthly,
            "netWorth": netWorth,
            "recurring": data.templates.map { ["id": $0.id, "nextOccurrence": $0.nextOccurrence.toIso8601String(), "isActive": $0.isActive] },
            "appSettings": [
                "baseCurrencyCode": data.appSettings.baseCurrencyCode, "localeOverride": data.appSettings.localeOverride as Any,
                "appLockEnabled": data.appSettings.appLockEnabled, "autoLockTimeoutSeconds": data.appSettings.autoLockTimeoutSeconds,
                "hideBalances": data.appSettings.hideBalances,
            ],
            "theme": model.themeMode.rawValue,
            "widget": ["amount": widget.amount, "month": widget.month],
            "hasUnsavedChanges": model.hasUnsavedChanges,
            "loadReport": String(describing: model.loadReport),
            "backup": String(describing: model.backupOutcome),
        ]
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("budgie-rehearsal.json")
        if let json = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: url, options: .atomic)
        }
    }
}
#endif
