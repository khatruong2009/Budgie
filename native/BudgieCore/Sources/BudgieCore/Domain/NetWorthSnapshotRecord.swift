import Foundation

public struct NetWorthSnapshotRecord: Hashable, Sendable {
    public let recordedAt: DartDateTime
    public let amount: Double

    /// Dart `NetWorthSnapshot.fromJson`, including the legacy
    /// `monthKey`/`updatedAt` shapes.
    static func parse(_ value: JSONValue, calendar: DartCalendar, now: () -> DartDateTime) -> NetWorthSnapshotRecord? {
        guard case .object(let object) = value else { return nil }
        guard case .some(let recordedAtText) = Read.optionalString(object, "recordedAt"),
            case .some(let monthKey) = Read.optionalString(object, "monthKey"),
            case .some(let updatedAtText) = Read.optionalString(object, "updatedAt")
        else { return nil }
        let recordedAt: DartDateTime
        if let recordedAtText, !recordedAtText.isEmpty {
            guard let parsed = calendar.tryParse(recordedAtText) else { return nil }
            recordedAt = parsed
        } else if let monthKey, !monthKey.isEmpty {
            guard let month = calendar.netWorthMonthFromKey(monthKey) else { return nil }
            let updated = (updatedAtText?.isEmpty ?? true) ? nil : calendar.tryParse(updatedAtText!)
            if let updated, DartCalendar.isSameMonth(updated, month) {
                recordedAt = updated
            } else {
                recordedAt = month
            }
        } else if let updatedAtText, !updatedAtText.isEmpty {
            guard let parsed = calendar.tryParse(updatedAtText) else { return nil }
            recordedAt = parsed
        } else {
            recordedAt = now()
        }
        guard let amount = Read.num(object, "amount") else { return nil }
        return NetWorthSnapshotRecord(recordedAt: recordedAt, amount: amount)
    }
}
