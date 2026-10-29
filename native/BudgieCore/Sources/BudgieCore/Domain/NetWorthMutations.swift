import Foundation

/// Net worth mutations, ported from `TransactionModel` (transaction_model.dart
/// 236-243, 587-726, 1441-1450) and `NetWorthEntry.copyWith`/`withSnapshot`
/// (net_worth_entry.dart 149-226).
///
/// Dart rewrites the whole `netWorthEntries` list from `toJson` on every
/// save. Here each edited entry's stored object is patched instead:
/// - `name` and `type` are written only when they change; `id`, `createdAt`
///   and unknown keys stay as stored.
/// - An edited entry's `snapshots` array is rebuilt in Dart's order. A kept
///   snapshot keeps its stored object when it has a `recordedAt` string (so
///   its lexemes and unknown keys survive); a legacy one (`monthKey` /
///   `updatedAt`, or no date) is written as Dart's `toJson` writes it, which
///   pins the date it resolved to. New snapshots are `{recordedAt, amount}`
///   with a double lexeme.
/// - Untouched entries and unreadable rows are written back verbatim.
/// For data Dart itself wrote, the result is byte-identical to Dart's
/// (Fixtures/worth).
///
/// Non-finite amounts are rejected (Dart would keep them in memory and fail
/// every later save).

extension NetWorthSnapshotRecord {
    /// Dart `NetWorthSnapshot.toJson`.
    var dartJSON: JSONValue {
        .object(JSONObject(ordered: [
            ("recordedAt", .string(recordedAt.toIso8601String())),
            ("amount", .double(amount)),
        ]))
    }
}

extension NetWorthEntryRecord {
    /// Each snapshot with the JSON it is written as (see the file comment).
    /// `raw["snapshots"]` is aligned with `snapshots`: `parse` reads it item
    /// by item, and every edit below writes both together.
    private var storedSnapshots: [(snapshot: NetWorthSnapshotRecord, json: JSONValue)] {
        let items = raw["snapshots"]?.arrayValue ?? []
        guard items.count == snapshots.count else { return snapshots.map { ($0, $0.dartJSON) } }
        return zip(snapshots, items).map { snapshot, item in
            if let text = item.objectValue?["recordedAt"]?.stringValue, !text.isEmpty { return (snapshot, item) }
            return (snapshot, snapshot.dartJSON)
        }
    }

    private func with(snapshots pairs: [(snapshot: NetWorthSnapshotRecord, json: JSONValue)]) -> NetWorthEntryRecord {
        var next = self
        next.snapshots = pairs.map(\.snapshot)
        next.raw["snapshots"] = .array(pairs.map(\.json))
        return next
    }

    /// `copyWith(name:, type:)`: keeps `id`, `createdAt` and the snapshots.
    func with(name: String, type: NetWorthEntryType) -> NetWorthEntryRecord {
        var next = self
        if !DartString.equal(name, self.name) {
            next.name = name
            next.raw["name"] = .string(name)
        }
        if type != self.type {
            next.type = type
            next.raw["type"] = .string(type.rawValue)
        }
        return next
    }

    /// `withSnapshot(date:, amount:)`: drops every snapshot recorded at the
    /// same instant (Dart `==`: instant and UTC flag), appends the new one and
    /// sorts ascending by instant. Dart's `List.sort` is an insertion sort
    /// (stable) up to 32 snapshots; this sort is stable at any length.
    func withSnapshot(_ snapshot: NetWorthSnapshotRecord) -> NetWorthEntryRecord {
        var pairs = storedSnapshots.filter { $0.snapshot.recordedAt != snapshot.recordedAt }
        pairs.append((snapshot, snapshot.dartJSON))
        let sorted = pairs.enumerated().sorted { a, b in
            let x = a.element.snapshot.recordedAt.microsecondsSinceEpoch
            let y = b.element.snapshot.recordedAt.microsecondsSinceEpoch
            return x != y ? x < y : a.offset < b.offset
        }
        return with(snapshots: sorted.map(\.element))
    }

    /// `deleteNetWorthSnapshot`'s filter: nil when no snapshot was recorded
    /// at `recordedAt` (Dart `==`). Order is kept (Dart does not sort here).
    func removingSnapshots(recordedAt: DartDateTime) -> NetWorthEntryRecord? {
        let pairs = storedSnapshots
        let kept = pairs.filter { $0.snapshot.recordedAt != recordedAt }
        return kept.count == pairs.count ? nil : with(snapshots: kept)
    }

    /// `hasSnapshotForMonth`.
    public func hasSnapshot(forMonth month: DartDateTime) -> Bool {
        snapshot(forMonth: month) != nil
    }

    /// `_previousSnapshotBefore` (net_worth_page.dart:1348-1366): the latest
    /// snapshot strictly before `recordedAt`; nil when `recordedAt` is nil.
    public func previousSnapshot(before recordedAt: DartDateTime?) -> NetWorthSnapshotRecord? {
        guard let recordedAt else { return nil }
        var previous: NetWorthSnapshotRecord?
        for snapshot in snapshots where snapshot.recordedAt.isBefore(recordedAt) {
            if previous == nil || snapshot.recordedAt.isAfter(previous!.recordedAt) { previous = snapshot }
        }
        return previous
    }
}

extension FinancialData {
    /// `_defaultSnapshotDateForMonth`: `now` itself (with its time and
    /// microseconds) when `month` is now's local month, else the end-of-month
    /// sentinel (`endOfNetWorthMonth`), so a past month's value is replaced,
    /// not duplicated, by a later save for the same month.
    public func defaultSnapshotDate(forMonth month: DartDateTime, now: DartDateTime) -> DartDateTime {
        let normalized = calendar.month(of: month)
        if DartCalendar.isSameMonth(normalized, now) { return now }
        return calendar.endOfNetWorthMonth(normalized)
    }

    /// `addNetWorthEntry`: the trimmed name (empty: no-op), one snapshot at
    /// `recordedAt ?? defaultSnapshotDate(month ?? selectedNetWorthMonth)`,
    /// `createdAt = now`, appended at the end. Does not change the selected
    /// month. Returns the new entry, or nil when nothing changed.
    @discardableResult
    public mutating func addNetWorthEntry(
        name: String, type: NetWorthEntryType, amount: Double, month: DartDateTime? = nil,
        recordedAt: DartDateTime? = nil, id: String, now: DartDateTime
    ) -> NetWorthEntryRecord? {
        let trimmed = DartString.trim(name)
        guard !trimmed.isEmpty, amount.isFinite else { return nil }
        let date = recordedAt ?? defaultSnapshotDate(forMonth: month ?? selectedNetWorthMonth, now: now)
        let entry = NetWorthEntryRecord.make(
            id: id, name: trimmed, type: type, createdAt: now, snapshot: NetWorthSnapshotRecord(recordedAt: date, amount: amount))
        netWorthRows.append(.record(entry))
        return entry
    }

    /// `updateNetWorthEntry`: every entry with this id takes the trimmed name
    /// and the type, and gains (or replaces, at the same instant) one
    /// snapshot. History is never rewritten; a type change moves the whole
    /// history to the other side. Position, `id` and `createdAt` are kept.
    /// Returns false (nothing to write) for an empty name, a non-finite
    /// amount, or an unknown id (Dart writes the unchanged list anyway).
    @discardableResult
    public mutating func updateNetWorthEntry(
        id: String, name: String, type: NetWorthEntryType, amount: Double, month: DartDateTime? = nil,
        recordedAt: DartDateTime? = nil, now: DartDateTime
    ) -> Bool {
        let trimmed = DartString.trim(name)
        guard !trimmed.isEmpty, amount.isFinite else { return false }
        let date = recordedAt ?? defaultSnapshotDate(forMonth: month ?? selectedNetWorthMonth, now: now)
        let snapshot = NetWorthSnapshotRecord(recordedAt: date, amount: amount)
        var changed = false
        for index in netWorthRows.indices {
            guard let entry = netWorthRows[index].record, DartString.equal(entry.id, id) else { continue }
            netWorthRows[index] = .record(entry.with(name: trimmed, type: type).withSnapshot(snapshot))
            changed = true
        }
        return changed
    }

    /// `deleteNetWorthEntry`: removes every entry with this id and all its
    /// snapshots. No other section changes. False for an unknown id (Dart
    /// writes the unchanged list anyway).
    @discardableResult
    public mutating func deleteNetWorthEntry(id: String) -> Bool {
        let before = netWorthRows.count
        netWorthRows.removeAll { $0.record.map { DartString.equal($0.id, id) } ?? false }
        return netWorthRows.count != before
    }

    /// `deleteNetWorthSnapshot`: drops the entry's snapshots recorded at
    /// exactly `recordedAt` (instant and UTC flag). False, with nothing to
    /// write, when none matched (as Dart). The last snapshot may go: the
    /// entry then has no value in any month (the UI prevents that).
    @discardableResult
    public mutating func deleteNetWorthSnapshot(entryID: String, recordedAt: DartDateTime) -> Bool {
        var changed = false
        for index in netWorthRows.indices {
            guard let entry = netWorthRows[index].record, DartString.equal(entry.id, entryID),
                let next = entry.removingSnapshots(recordedAt: recordedAt)
            else { continue }
            netWorthRows[index] = .record(next)
            changed = true
        }
        return changed
    }

    /// `carryNetWorthMonthForward` (no UI caller in Flutter): every entry
    /// with no snapshot in `month` but a value at the end of the previous
    /// month gets that value at `defaultSnapshotDate(month)`. Returns whether
    /// anything changed (only then does Dart save).
    @discardableResult
    public mutating func carryNetWorthMonthForward(_ month: DartDateTime, now: DartDateTime) -> Bool {
        let previousEnd = calendar.endOfNetWorthMonth(calendar.addingMonths(month, -1))
        let date = defaultSnapshotDate(forMonth: month, now: now)
        var changed = false
        for index in netWorthRows.indices {
            guard let entry = netWorthRows[index].record, !entry.hasSnapshot(forMonth: month),
                let previous = entry.latestSnapshot(through: previousEnd)
            else { continue }
            netWorthRows[index] = .record(entry.withSnapshot(NetWorthSnapshotRecord(recordedAt: date, amount: previous.amount)))
            changed = true
        }
        return changed
    }

    /// `selectNetWorthMonth`: normalised to `DateTime(year, month)`. Written
    /// as `selectedNetWorthMonthSection()`.
    public mutating func selectNetWorthMonth(_ date: DartDateTime) {
        selectedNetWorthMonth = calendar.month(of: date)
    }
}
