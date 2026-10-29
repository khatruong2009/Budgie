import Foundation

extension RecurrencePattern {
    /// `_getPatternDisplayName` (form wheel, page card "Pattern" value).
    public var displayName: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Bi-weekly"
        case .monthly: "Monthly"
        }
    }
}

/// The recurring form's rules (recurring_transaction_form.dart), pure so the
/// view and the tests share them. Flutter's copy is verbatim.
public enum RecurringForm {
    public static let amountRequired = "Amount is required"
    public static let amountInvalid = "Please enter a valid number"
    public static let amountNotPositive = "Amount must be greater than 0"
    public static let descriptionRequired = "Description is required"
    public static let startDateTooOld = "Start date cannot be more than 1 year in the past"

    /// The Day of Month wheel (`1`..`31`).
    public static let daysOfMonth = 1...31

    /// What Save found (`validateForm`, :88-123): all three fields are
    /// checked together, every Save.
    public struct Validation: Equatable, Sendable {
        public var amountError: String?
        public var descriptionError: String?
        public var startDateError: String?
        /// The amount to store when the amount is valid: the stored value
        /// exactly when the field still shows its prefill, else the parsed
        /// text.
        public var amount: Double?
        /// The description to store (Dart `trim`, U+FEFF included).
        public var description: String

        public var isValid: Bool { amountError == nil && descriptionError == nil && startDateError == nil }
    }

    /// - `amountText`: empty (not trimmed) is required; Dart
    ///   `double.tryParse` (the locale's decimal separator read as '.') nil
    ///   or non-finite is invalid (Flutter lets NaN and Infinity through;
    ///   fixed like the transaction form); `<= 0` is not positive.
    /// - `description`: blank after Dart `trim` is required.
    /// - `start`: before `now - 365 days` is too old, but only when the start
    ///   was set in this form (`storedStart` is nil when adding, else the
    ///   template's start): an untouched stored start never blocks a save.
    /// - `storedAmount`: the edited template's amount, kept exactly when
    ///   `amountText` is still its `toStringAsFixed(2)` prefill.
    public static func validate(
        amountText: String, description: String, start: DartDateTime, storedStart: DartDateTime?, storedAmount: Double?,
        now: DartDateTime, locale: Locale = .current
    ) -> Validation {
        var result = Validation(description: DartString.trim(description))
        if amountText.isEmpty {
            result.amountError = amountRequired
        } else if let parsed = DartDouble.tryParse(normalizedAmount(amountText, locale: locale)), parsed.isFinite {
            if parsed <= 0 {
                result.amountError = amountNotPositive
            } else if let storedAmount, amountText == DartFixed.toStringAsFixed(storedAmount, 2) {
                result.amount = storedAmount
            } else {
                result.amount = parsed
            }
        } else {
            result.amountError = amountInvalid
        }
        if result.description.isEmpty { result.descriptionError = descriptionRequired }
        result.startDateError = startDateError(start: start, storedStart: storedStart, now: now)
        return result
    }

    /// The start-date rule alone (Flutter re-checks it when a day is
    /// picked, to clear the error).
    public static func startDateError(start: DartDateTime, storedStart: DartDateTime?, now: DartDateTime) -> String? {
        if let storedStart, start == storedStart { return nil }
        return start.isBefore(now.adding(days: -365)) ? startDateTooOld : nil
    }

    /// The days the start-date picker offers, as local midnights. Flutter
    /// offers `now - 365 days` .. `now + 365 days` by calendar day, but a
    /// picked day is midnight, so its first day always fails the rule
    /// (unless `now` is exactly midnight); here the first day is the
    /// earliest one whose midnight passes it. An edit's stored start
    /// (`storedStart`) is always offered: for a template that started over
    /// a year ago the range reaches down to its day, so the picker opens on
    /// it and OK keeps it (the days in between still fail the rule).
    public static func startDateRange(
        now: DartDateTime, calendar: DartCalendar, storedStart: DartDateTime? = nil
    ) -> ClosedRange<DartDateTime> {
        let floor = now.adding(days: -365)
        var earliest = calendar.startOfDay(floor)
        if earliest.isBefore(floor) { earliest = calendar.date(floor.year, floor.month, floor.day + 1) }
        let top = now.adding(days: 365)
        var latest = calendar.startOfDay(top)
        if let storedStart {
            let day = calendar.startOfDay(storedStart)
            if day.isBefore(earliest) { earliest = day }
            if day.isAfter(latest) { latest = day }
        }
        return earliest...latest
    }

    /// The Day of Month wheel when the form opens, and whether it follows
    /// a picked start day: when adding, the day the form opened (Flutter's
    /// default), following; when editing, the stored day (the start's day
    /// for a weekly template), following only while it equals the start's
    /// day (a different day was set on purpose).
    public static func initialDayOfMonth(template: RecurringTemplate?, openedAt: DartDateTime) -> (day: Int, followsStart: Bool) {
        guard let template else { return (openedAt.day, true) }
        let startDay = template.startDate.day
        guard let stored = template.dayOfMonth else { return (startDay, true) }
        return (stored, stored == startDay)
    }

    /// The start date a save stores: the picked day (a local midnight, as
    /// Flutter's picker returns); without a pick, the template's stored
    /// start, or for a new template the moment the form opened, time of
    /// day included (Flutter's `DateTime.now()` default). Re-picking the
    /// stored start's own day keeps the stored value (and its time), so
    /// the schedule, and with it the cursor, does not change.
    public static func resolvedStart(
        picked: DartDateTime?, stored: DartDateTime?, openedAt: DartDateTime, calendar: DartCalendar
    ) -> DartDateTime {
        guard let picked else { return stored ?? openedAt }
        if let stored, calendar.isSameDay(stored, picked) { return stored }
        return picked
    }

    /// The template fields a save writes: `dayOfMonth` for monthly only;
    /// `dayOfWeek` for weekly/biweekly only, as the start date's weekday
    /// (1 Monday .. 7 Sunday). Flutter stores its Day of Week wheel there;
    /// nothing in either app reads it, and the wheel is not shown here.
    public static func edit(
        type: TransactionType, description: String, amount: Double, category: String, pattern: RecurrencePattern,
        start: DartDateTime, dayOfMonth: Int
    ) -> RecurringTemplate.Edit {
        RecurringTemplate.Edit(
            type: type, description: description, amount: amount, category: category, pattern: pattern, startDate: start,
            dayOfMonth: pattern == .monthly ? dayOfMonth : nil, dayOfWeek: pattern == .monthly ? nil : start.weekday)
    }

    /// The text with the locale's decimal separator (e.g. ',') as '.'.
    public static func normalizedAmount(_ text: String, locale: Locale) -> String {
        guard let separator = locale.decimalSeparator, separator != "." else { return text }
        return text.replacingOccurrences(of: separator, with: ".")
    }
}
