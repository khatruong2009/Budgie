import BudgieCore
import Foundation

extension AppModel {
    // MARK: - Net worth

    /// The month the Worth tab shows (Flutter `selectedNetWorthMonth`):
    /// persisted, loaded as stored even when stale or in the future.
    var selectedNetWorthMonth: DartDateTime { data?.selectedNetWorthMonth ?? calendar.month(of: now) }

    struct WorthCache {
        var revision = -1
        var history: [NetWorthHistoryPoint]?
        var months: (current: DartDateTime, value: [DartDateTime])?
        var changes: [DartDateTime: Double?] = [:]
    }

    /// The cache for the current revision (emptied when it moved on).
    /// Reading `netWorthRevision` here makes views observe it.
    func currentWorthCache() -> WorthCache {
        if worthCache.revision != netWorthRevision { worthCache = WorthCache(revision: netWorthRevision) }
        return worthCache
    }

    /// The Worth month strip (`getNetWorthAvailableMonths`), newest first.
    var netWorthAvailableMonths: [DartDateTime] {
        guard let data else { return [] }
        let current = calendar.month(of: now)
        if let months = currentWorthCache().months, months.current == current { return months.value }
        let value = data.netWorthAvailableMonths(now: now)
        worthCache.months = (current, value)
        return value
    }

    /// The growth chart's points (`getNetWorthHistory(limit: 24)`), newest
    /// first.
    var netWorthHistory: [NetWorthHistoryPoint] {
        guard let data else { return [] }
        if let history = currentWorthCache().history { return history }
        let history = data.netWorthHistory(limit: 24)
        worthCache.history = history
        return history
    }

    /// `getNetWorthChange(month)`: nil without a change to show.
    func netWorthChange(forMonth month: DartDateTime) -> Double? {
        guard let data else { return nil }
        if let change = currentWorthCache().changes[month] { return change }
        let change = data.netWorthChange(forMonth: month)
        worthCache.changes[month] = .some(change)
        return change
    }

    /// Whether any readable account exists (the Worth empty state).
    var hasNetWorthEntries: Bool { data?.hasNetWorthEntries ?? false }

    /// The account with this id (the history page follows it live).
    func netWorthEntry(id: String) -> NetWorthEntryRecord? {
        data?.netWorthEntry(id: id)
    }

    /// `getNetWorthEntryHistory`: ascending; empty for an unknown id.
    func netWorthEntryHistory(id: String) -> [NetWorthSnapshotRecord] {
        data?.netWorthEntryHistory(id: id) ?? []
    }

    /// Dart `selectNetWorthMonth`: normalised to the month, then written,
    /// even when it is already selected (as Flutter).
    @discardableResult
    func selectNetWorthMonth(_ month: DartDateTime) async -> Bool {
        await mutateNetWorth([Section.selectedNetWorthMonth]) {
            $0.selectNetWorthMonth(month)
            return true
        }
    }

    /// Dart `addNetWorthEntry`: the snapshot lands on `recordedAt`, else
    /// `now` for the current month or the month's end-of-month sentinel.
    /// False without a write for an empty name or a non-finite amount.
    @discardableResult
    func addNetWorthEntry(
        name: String, type: NetWorthEntryType, amount: Double, month: DartDateTime? = nil, recordedAt: DartDateTime? = nil
    ) async -> Bool {
        guard amount.isFinite else { return false }
        return await mutateNetWorth([Section.netWorthEntries]) {
            $0.addNetWorthEntry(
                name: name, type: type, amount: amount, month: month, recordedAt: recordedAt, id: newID(), now: now) != nil
        }
    }

    /// Dart `updateNetWorthEntry` (also "update balance" for a month): name
    /// and type, plus one added or replaced snapshot.
    @discardableResult
    func updateNetWorthEntry(
        id: String, name: String, type: NetWorthEntryType, amount: Double, month: DartDateTime? = nil,
        recordedAt: DartDateTime? = nil
    ) async -> Bool {
        guard amount.isFinite else { return false }
        return await mutateNetWorth([Section.netWorthEntries]) {
            $0.updateNetWorthEntry(
                id: id, name: name, type: type, amount: amount, month: month, recordedAt: recordedAt, now: now)
        }
    }

    /// Dart `deleteNetWorthEntry`: the account and all its snapshots.
    @discardableResult
    func deleteNetWorthEntry(id: String) async -> Bool {
        await mutateNetWorth([Section.netWorthEntries], { $0.deleteNetWorthEntry(id: id) })
    }

    /// Dart `deleteNetWorthSnapshot`: the snapshot recorded at exactly
    /// `recordedAt`; false without a write when there is none.
    @discardableResult
    func deleteNetWorthSnapshot(entryID: String, recordedAt: DartDateTime) async -> Bool {
        await mutateNetWorth(
            [Section.netWorthEntries], { $0.deleteNetWorthSnapshot(entryID: entryID, recordedAt: recordedAt) })
    }
}
