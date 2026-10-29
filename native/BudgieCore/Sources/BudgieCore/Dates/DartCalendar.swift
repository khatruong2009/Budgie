import Foundation

/// Calendar helpers with the exact semantics of the Flutter app's Dart code
/// (net_worth_entry.dart, recurring_transaction.dart, transaction_model.dart).
public struct DartCalendar: Sendable {
    public let timeZone: TimeZone

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    /// Dart `DateTime(y, m, d, ...)` (local, lenient). Only nil for years
    /// far outside anything the app stores.
    public func date(
        _ year: Int, _ month: Int = 1, _ day: Int = 1, _ hour: Int = 0, _ minute: Int = 0,
        _ second: Int = 0, _ millisecond: Int = 0, _ microsecond: Int = 0
    ) -> DartDateTime {
        guard
            let value = DartDateTime(
                year, month, day, hour, minute, second, millisecond, microsecond, timeZone: timeZone)
        else {
            preconditionFailure("date out of Dart's range: \(year)-\(month)-\(day)")
        }
        return value
    }

    public func parse(_ text: String) throws(DartDateTime.ParseError) -> DartDateTime {
        try DartDateTime.parse(text, timeZone: timeZone)
    }

    public func tryParse(_ text: String) -> DartDateTime? {
        DartDateTime.tryParse(text, timeZone: timeZone)
    }

    public func now(_ clock: Date = Date()) -> DartDateTime {
        DartDateTime.now(clock, timeZone: timeZone)
    }

    /// `DateTime(d.year, d.month)`: first of the month, midnight.
    public func month(of d: DartDateTime) -> DartDateTime {
        let f = d.fields
        return date(f.year, f.month)
    }

    /// `netWorthMonthKey`: `DateFormat('yyyy-MM')` of the month, ASCII digits.
    public func netWorthMonthKey(_ d: DartDateTime) -> String {
        let f = month(of: d).fields
        return "\(DartCalendar.pad(f.year, 4))-\(DartCalendar.pad(f.month, 2))"
    }

    /// `netWorthDayKey`: `DateFormat('yyyy-MM-dd')`.
    public func netWorthDayKey(_ d: DartDateTime) -> String {
        let f = d.fields
        let day = date(f.year, f.month, f.day).fields
        return "\(DartCalendar.pad(day.year, 4))-\(DartCalendar.pad(day.month, 2))-\(DartCalendar.pad(day.day, 2))"
    }

    /// `netWorthMonthFromKey`: split on '-', `DateTime(int.parse(y), int.parse(m))`.
    public func netWorthMonthFromKey(_ key: String) -> DartDateTime? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return date(y, m)
    }

    /// `endOfNetWorthMonth`: next month's first instant minus 1 ms (elapsed).
    public func endOfNetWorthMonth(_ m: DartDateTime) -> DartDateTime {
        let f = m.fields
        return date(f.year, f.month + 1).adding(microseconds: -1_000)
    }

    /// `endOfNetWorthDay`: next day's first instant minus 1 ms (elapsed).
    public func endOfNetWorthDay(_ d: DartDateTime) -> DartDateTime {
        let f = d.fields
        return date(f.year, f.month, f.day + 1).adding(microseconds: -1_000)
    }

    /// `isSameDay` (recurring_transaction.dart): same local y/m/d.
    public func isSameDay(_ a: DartDateTime, _ b: DartDateTime) -> Bool {
        let x = a.fields
        let y = b.fields
        return x.year == y.year && x.month == y.month && x.day == y.day
    }

    /// `TransactionModel._monthKey`: year * 12 + month.
    public func ledgerMonthKey(_ d: DartDateTime) -> Int {
        DartCalendar.monthKey(d)
    }

    /// `year * 12 + month` of the date's fields.
    public static func monthKey(_ d: DartDateTime) -> Int {
        let f = d.fields
        return f.year * 12 + f.month
    }

    /// `DateTime(d.year, d.month, d.day)`: local midnight of the day.
    public func startOfDay(_ d: DartDateTime) -> DartDateTime {
        let f = d.fields
        return date(f.year, f.month, f.day)
    }

    /// `DateTime(d.year, d.month + months)`: first of the month, lenient.
    public func addingMonths(_ d: DartDateTime, _ months: Int) -> DartDateTime {
        let f = d.fields
        return date(f.year, f.month + months)
    }

    /// Equal year and month fields.
    public static func isSameMonth(_ a: DartDateTime, _ b: DartDateTime) -> Bool {
        let x = a.fields
        let y = b.fields
        return x.year == y.year && x.month == y.month
    }

    /// Inverse of `ledgerMonthKey` (`getAvailableMonths`).
    public func month(fromLedgerKey key: Int) -> DartDateTime {
        let year = (key - 1) / 12
        return date(year, key - year * 12)
    }

    /// intl `DateFormat` zero padding (minimum width, no truncation).
    static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(abs(value))
        let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
        return value < 0 ? "-" + padded : padded
    }
}
