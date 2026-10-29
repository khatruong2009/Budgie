import Foundation

/// Net worth queries, ported from `TransactionModel` (sections 483-585 and
/// 1326-1450 of transaction_model.dart).
public struct NetWorthHistoryPoint: Hashable, Sendable {
    public enum Granularity: String, Sendable { case day, month }
    public let date: DartDateTime
    public let assets: Double
    public let liabilities: Double
    public let assetCount: Int
    public let liabilityCount: Int
    public let granularity: Granularity
    public var netWorth: Double { assets - liabilities }
}

extension FinancialData {
    /// `getNetWorthEntriesForMonth`: entries with a value, by amount desc
    /// (Dart `compareTo`) then lowercased name asc (Dart `toLowerCase`, UTF-16
    /// order). Stable; Dart's sort is stable only up to 32 entries.
    public func netWorthEntries(forMonth month: DartDateTime, type: NetWorthEntryType? = nil) -> [NetWorthEntryRecord] {
        let keyed = netWorthEntries.compactMap { entry -> (amount: Double, name: [UInt16], entry: NetWorthEntryRecord)? in
            guard type == nil || entry.type == type, let amount = entry.amount(forMonth: month, calendar: calendar) else { return nil }
            return (amount, Array(DartString.lowercase(entry.name).utf16), entry)
        }
        return keyed.enumerated().sorted { a, b in
            let byAmount = dartCompare(b.element.amount, a.element.amount)
            if byAmount != 0 { return byAmount < 0 }
            if a.element.name != b.element.name { return a.element.name.lexicographicallyPrecedes(b.element.name) }
            return a.offset < b.offset
        }.map(\.element.entry)
    }

    /// `hasNetWorthEntries`: any readable entry (the Worth empty state).
    public var hasNetWorthEntries: Bool { !netWorthEntries.isEmpty }

    /// `netWorthEntries.firstWhere((e) => e.id == id)`.
    public func netWorthEntry(id: String) -> NetWorthEntryRecord? {
        netWorthRows.lazy.compactMap(\.record).first { DartString.equal($0.id, id) }
    }

    /// `getNetWorthEntryHistory`: the entry's snapshots, ascending by
    /// instant (stable); empty when the id is unknown.
    public func netWorthEntryHistory(id: String) -> [NetWorthSnapshotRecord] {
        guard let entry = netWorthEntry(id: id) else { return [] }
        return entry.snapshots.enumerated().sorted { a, b in
            let x = a.element.recordedAt.microsecondsSinceEpoch, y = b.element.recordedAt.microsecondsSinceEpoch
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// `entries` defaults to the readable accounts; a caller summing many
    /// dates passes them in once (`netWorthEntries` decodes every row).
    func sum(at date: DartDateTime, _ type: NetWorthEntryType, in entries: [NetWorthEntryRecord]? = nil) -> Double {
        (entries ?? netWorthEntries).filter { $0.type == type }.map { $0.amount(at: date) ?? 0 }.reduce(0, +)
    }

    func count(at date: DartDateTime, _ type: NetWorthEntryType, in entries: [NetWorthEntryRecord]? = nil) -> Int {
        (entries ?? netWorthEntries).filter { $0.type == type && $0.amount(at: date) != nil }.count
    }

    public func totalAssets(forMonth month: DartDateTime) -> Double {
        sum(at: calendar.endOfNetWorthMonth(month), .asset)
    }

    public func totalLiabilities(forMonth month: DartDateTime) -> Double {
        sum(at: calendar.endOfNetWorthMonth(month), .liability)
    }

    public func netWorth(forMonth month: DartDateTime) -> Double {
        totalAssets(forMonth: month) - totalLiabilities(forMonth: month)
    }

    public func hasNetWorthData(forMonth month: DartDateTime) -> Bool {
        netWorthEntries.contains { $0.amount(forMonth: month, calendar: calendar) != nil }
    }

    // Test-only: checked against Fixtures/worth
    public func trackedNetWorthEntryCount(forMonth month: DartDateTime) -> Int {
        netWorthEntries.filter { $0.amount(forMonth: month, calendar: calendar) != nil }.count
    }

    public func updatedNetWorthEntryCount(forMonth month: DartDateTime) -> Int {
        netWorthEntries.filter { $0.snapshot(forMonth: month) != nil }.count
    }

    // Test-only: checked against Fixtures/worth
    public func staleNetWorthEntryCount(forMonth month: DartDateTime) -> Int {
        let key = calendar.netWorthMonthKey(month)
        return netWorthEntries.filter { entry in
            guard let latest = entry.latestSnapshot(through: calendar.endOfNetWorthMonth(month)) else { return false }
            return calendar.netWorthMonthKey(latest.recordedAt) != key
        }.count
    }

    public func netWorthChange(forMonth month: DartDateTime) -> Double? {
        if updatedNetWorthEntryCount(forMonth: month) == 0 { return nil }
        let previous = calendar.addingMonths(month, -1)
        if !hasNetWorthData(forMonth: previous) { return nil }
        return netWorth(forMonth: month) - netWorth(forMonth: previous)
    }

    /// `getNetWorthAvailableMonths`: current month, selected month, and every
    /// snapshot's month; newest first.
    public func netWorthAvailableMonths(now: DartDateTime) -> [DartDateTime] {
        var keys = Set([calendar.netWorthMonthKey(calendar.month(of: now)), calendar.netWorthMonthKey(selectedNetWorthMonth)])
        for entry in netWorthEntries {
            for snapshot in entry.snapshots { keys.insert(calendar.netWorthMonthKey(snapshot.recordedAt)) }
        }
        return keys.compactMap { calendar.netWorthMonthFromKey($0) }.sorted { $0 > $1 }
    }

    /// `getNetWorthHistory` / `_buildNetWorthHistoryPoints`. Points are
    /// built newest first and Dart returns the first `limit`, so building
    /// stops there (each point sums every account's snapshots).
    public func netWorthHistory(limit: Int = 24) -> [NetWorthHistoryPoint] {
        let entries = netWorthEntries
        var dayKeys = Set<String>()
        for entry in entries {
            for snapshot in entry.snapshots { dayKeys.insert(calendar.netWorthDayKey(snapshot.recordedAt)) }
        }
        if dayKeys.isEmpty || limit <= 0 { return [] }
        let sortedKeys = dayKeys.sorted(by: >)
        var bucketOrder: [String] = []
        var buckets: [String: [String]] = [:]
        for dayKey in sortedKeys {
            let monthKey = calendar.netWorthMonthKey(dayFromKey(dayKey))
            if buckets[monthKey] == nil { bucketOrder.append(monthKey) }
            buckets[monthKey, default: []].append(dayKey)
        }
        var compressed = Set<String>()
        var pointCount = sortedKeys.count
        for monthKey in buckets.keys.sorted() {
            if pointCount <= limit { break }
            let reducible = buckets[monthKey]!.count - 1
            if reducible <= 0 { continue }
            compressed.insert(monthKey)
            pointCount -= reducible
        }
        var points: [NetWorthHistoryPoint] = []
        months: for monthKey in bucketOrder {
            if compressed.contains(monthKey) {
                let end = calendar.endOfNetWorthMonth(calendar.netWorthMonthFromKey(monthKey)!)
                points.append(point(display: end, effective: end, granularity: .month, entries: entries))
            } else {
                for dayKey in buckets[monthKey]! {
                    if points.count == limit { break months }
                    let day = dayFromKey(dayKey)
                    points.append(point(display: day, effective: calendar.endOfNetWorthDay(day), granularity: .day, entries: entries))
                }
            }
            if points.count == limit { break }
        }
        return points
    }

    private func dayFromKey(_ key: String) -> DartDateTime {
        let parts = key.split(separator: "-").map { Int($0)! }
        return calendar.date(parts[0], parts[1], parts[2])
    }

    private func point(
        display: DartDateTime, effective: DartDateTime, granularity: NetWorthHistoryPoint.Granularity,
        entries: [NetWorthEntryRecord]
    ) -> NetWorthHistoryPoint {
        NetWorthHistoryPoint(
            date: display, assets: sum(at: effective, .asset, in: entries),
            liabilities: sum(at: effective, .liability, in: entries), assetCount: count(at: effective, .asset, in: entries),
            liabilityCount: count(at: effective, .liability, in: entries), granularity: granularity)
    }
}
