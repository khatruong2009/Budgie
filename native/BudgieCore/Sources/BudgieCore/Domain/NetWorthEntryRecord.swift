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
            let id = object["id"]?.stringValue,
            let name = object["name"]?.stringValue,
            let typeName = object["type"]?.stringValue,
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
            ("snapshots", .array([snapshot.dartJSON])),
        ])
        return NetWorthEntryRecord(id: id, name: name, type: type, createdAt: createdAt, snapshots: [snapshot], raw: raw)
    }

    /// The latest-recorded snapshot satisfying `matches`; the first of equal instants.
    func latestSnapshot(where matches: (NetWorthSnapshotRecord) -> Bool) -> NetWorthSnapshotRecord? {
        var latest: NetWorthSnapshotRecord?
        for snapshot in snapshots where matches(snapshot) {
            if latest == nil || snapshot.recordedAt.isAfter(latest!.recordedAt) { latest = snapshot }
        }
        return latest
    }

    /// `snapshotForMonth`: latest snapshot recorded in that local month.
    public func snapshot(forMonth month: DartDateTime) -> NetWorthSnapshotRecord? {
        latestSnapshot { DartCalendar.isSameMonth($0.recordedAt, month) }
    }

    /// `latestSnapshotThrough`: latest snapshot at or before `date` (carry-forward).
    public func latestSnapshot(through date: DartDateTime) -> NetWorthSnapshotRecord? {
        latestSnapshot { !$0.recordedAt.isAfter(date) }
    }

    public func amount(at date: DartDateTime) -> Double? {
        latestSnapshot(through: date)?.amount
    }

    public func amount(forMonth month: DartDateTime, calendar: DartCalendar) -> Double? {
        amount(at: calendar.endOfNetWorthMonth(month))
    }
}
