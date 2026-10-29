import Foundation

/// Month-over-month figures on the Home tab (Flutter `SpendingPage`,
/// spending_page.dart:474-482, 339-345, 1487-1493).
public enum HomeSummary {
    /// `DateTime(month.year, month.month - 1)`: January wraps to December of
    /// the year before.
    public static func previousMonth(of month: DartDateTime, calendar: DartCalendar) -> DartDateTime {
        calendar.addingMonths(month, -1)
    }

    /// `_percentDelta`: nil when both months are zero; +100 when only the
    /// previous month is zero; otherwise `(current - previous) / previous *
    /// 100`, with no sign correction for a negative previous value.
    public static func percentDelta(current: Double, previous: Double) -> Double? {
        if previous == 0 {
            if current == 0 { return nil }
            return 100
        }
        return (current - previous) / previous * 100
    }

    /// The flow chip's delta line (`_FlowChip.build`): "+12.5% vs August"
    /// ("+" when `delta >= 0`, so -0.0 prints "+-0.0%" as in Flutter), or
    /// "No August data" when there is no delta.
    public static func deltaLabel(delta: Double?, previousMonthName: String) -> String {
        guard let delta else { return "No \(previousMonthName) data" }
        let sign = delta >= 0 ? "+" : ""
        return "\(sign)\(DartFixed.toStringAsFixed(delta, 1))% vs \(previousMonthName)"
    }
}
