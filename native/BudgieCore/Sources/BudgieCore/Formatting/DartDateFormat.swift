import Foundation

/// The `intl` `DateFormat` patterns the Flutter app uses, in en_US (the
/// Flutter app never initialises another intl locale). Each function names
/// the Dart pattern it reproduces; fields come from the local wall clock of
/// the `DartDateTime`, as `DateFormat.format` reads them.
public enum DartDateFormat {
    static let monthNames = [
        "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November",
        "December",
    ]
    static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    /// Dart weekday 1 = Monday ... 7 = Sunday.
    static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    private static func pad(_ value: Int, _ width: Int) -> String { DartCalendar.pad(value, width) }

    /// `DateFormat.MMMM()`: "September".
    public static func MMMM(_ d: DartDateTime) -> String { monthNames[d.month - 1] }

    /// `DateFormat.MMM()`: "Sep".
    public static func MMM(_ d: DartDateTime) -> String { monthAbbreviations[d.month - 1] }

    /// `DateFormat.y()`: "2026".
    public static func y(_ d: DartDateTime) -> String { String(d.year) }

    /// `DateFormat.MMMd()`: "Sep 8".
    public static func MMMd(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(monthAbbreviations[f.month - 1]) \(f.day)"
    }

    /// `DateFormat.yMMMd()` and `DateFormat('MMM d, y')`: "Sep 8, 2026".
    public static func yMMMd(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(monthAbbreviations[f.month - 1]) \(f.day), \(f.year)"
    }

    /// `DateFormat('MMM dd, yyyy')`: "Sep 08, 2026".
    public static func MMMddyyyy(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(monthAbbreviations[f.month - 1]) \(pad(f.day, 2)), \(pad(f.year, 4))"
    }

    /// `DateFormat.yMMMM()`, `DateFormat('MMMM y')`: "September 2026".
    public static func yMMMM(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(monthNames[f.month - 1]) \(f.year)"
    }

    /// `DateFormat('MMMM yyyy')`: "September 2026" (year padded to 4).
    public static func MMMMyyyy(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(monthNames[f.month - 1]) \(pad(f.year, 4))"
    }

    /// `DateFormat.yMMMMd()`: "September 8, 2026".
    public static func yMMMMd(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(monthNames[f.month - 1]) \(f.day), \(f.year)"
    }

    /// `DateFormat("MMM ''yy")`: "Sep '26".
    public static func MMMyy(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(monthAbbreviations[f.month - 1]) '\(pad(f.year % 100, 2))"
    }

    /// `DateFormat('EEEE')`: "Monday".
    public static func EEEE(_ d: DartDateTime) -> String { weekdayNames[d.weekday - 1] }

    /// `DateFormat('EEEE, MMM dd, yyyy')`: "Monday, Sep 08, 2026".
    public static func EEEEMMMddyyyy(_ d: DartDateTime) -> String {
        "\(EEEE(d)), \(MMMddyyyy(d))"
    }

    /// `DateFormat('yyyy-MM-dd')`. intl's `formatYear` prints the year
    /// without its sign (date_format_field.dart:401-408): year -1 is "0001".
    public static func yyyyMMdd(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(pad(abs(f.year), 4))-\(pad(f.month, 2))-\(pad(f.day, 2))"
    }

    /// `DateFormat('yyyyMMdd_HHmmss')` (file names): the signed year, as
    /// `DartCalendar.pad` writes it.
    public static func yyyyMMdd_HHmmss(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(pad(f.year, 4))\(pad(f.month, 2))\(pad(f.day, 2))_\(pad(f.hour, 2))\(pad(f.minute, 2))\(pad(f.second, 2))"
    }

    /// `DateFormat('yyyy-MM')`.
    public static func yyyyMM(_ d: DartDateTime) -> String {
        let f = d.fields
        return "\(pad(f.year, 4))-\(pad(f.month, 2))"
    }

    /// `DateFormat.jm()` in en_US: "9:05 AM". intl 0.20 separates the time
    /// and the marker with U+202F (NARROW NO-BREAK SPACE), per CLDR 42+.
    public static func jm(_ d: DartDateTime) -> String {
        let f = d.fields
        let hour12 = f.hour % 12 == 0 ? 12 : f.hour % 12
        return "\(hour12):\(pad(f.minute, 2))\u{202F}\(f.hour < 12 ? "AM" : "PM")"
    }
}
