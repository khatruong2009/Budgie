import Foundation

public enum NetWorthEntryType: String, Sendable, Hashable {
    case asset, liability
}

public struct NetWorthEntryRecord: Identifiable, Hashable, Sendable {
    public let id: String
    // Edited only through NetWorthMutations.swift, which patches `raw` with them.
    public internal(set) var name: String
    public internal(set) var type: NetWorthEntryType
    public let createdAt: DartDateTime
    /// Stored order; aligned one-to-one with `raw["snapshots"]` (see
    /// NetWorthMutations.swift).
    public internal(set) var snapshots: [NetWorthSnapshotRecord]
    public internal(set) var raw: JSONObject

    /// Dart `NetWorthEntry.fromJson` (strict: id, name, type, createdAt required).
    static func parse(_ value: JSONValue, calendar: DartCalendar, now: () -> DartDateTime) -> NetWorthEntryRecord? {
        guard case .object(let object) = value,
            let id = Read.requiredString(object, "id"),
            let name = Read.requiredString(object, "name"),
            let typeName = Read.requiredString(object, "type"),
            let createdAt = Read.parsedDate(object, "createdAt", calendar)
        else { return nil }
        var snapshots: [NetWorthSnapshotRecord] = []
        switch object["snapshots"] {
        case nil, .null?: break
        case .array(let items)?:
            for item in items {
                guard let snapshot = NetWorthSnapshotRecord.parse(item, calendar: calendar, now: now) else { return nil }
                snapshots.append(snapshot)
            }
        default: return nil
        }
        return NetWorthEntryRecord(
            id: id, name: name, type: typeName == "liability" ? .liability : .asset, createdAt: createdAt,
            snapshots: snapshots, raw: object)
    }

    /// A new entry as Dart writes it (used for legacy starting balances).
    static func make(id: String, name: String, type: NetWorthEntryType, createdAt: DartDateTime, snapshot: NetWorthSnapshotRecord) -> NetWorthEntryRecord {
        let raw = JSONObject(ordered: [
            ("id", .string(id)),
            ("name", .string(name)),
            ("type", .string(type.rawValue)),
            ("createdAt", .string(createdAt.toIso8601String())),
            ("snapshots", .array([.object(JSONObject(ordered: [
                ("recordedAt", .string(snapshot.recordedAt.toIso8601String())),
                ("amount", .double(snapshot.amount)),
            ]))])),
        ])
        return NetWorthEntryRecord(id: id, name: name, type: type, createdAt: createdAt, snapshots: [snapshot], raw: raw)
    }

    /// `snapshotForMonth`: latest snapshot recorded in that local month.
    public func snapshot(forMonth month: DartDateTime) -> NetWorthSnapshotRecord? {
        var latest: NetWorthSnapshotRecord?
        let m = month.fields
        for snapshot in snapshots {
            let f = snapshot.recordedAt.fields
            guard f.year == m.year && f.month == m.month else { continue }
            if latest == nil || snapshot.recordedAt.isAfter(latest!.recordedAt) { latest = snapshot }
        }
        return latest
    }

    /// `latestSnapshotThrough`: latest snapshot at or before `date` (carry-forward).
    public func latestSnapshot(through date: DartDateTime) -> NetWorthSnapshotRecord? {
        var latest: NetWorthSnapshotRecord?
        for snapshot in snapshots {
            if snapshot.recordedAt.isAfter(date) { continue }
            if latest == nil || snapshot.recordedAt.isAfter(latest!.recordedAt) { latest = snapshot }
        }
        return latest
    }

    public func amount(at date: DartDateTime) -> Double? {
        latestSnapshot(through: date)?.amount
    }

    public func amount(forMonth month: DartDateTime, calendar: DartCalendar) -> Double? {
        amount(at: calendar.endOfNetWorthMonth(month))
    }
}
