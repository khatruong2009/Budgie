import Foundation

/// Port of `TransactionGenerator` (MIGRATION_SPEC 7.4), bug-compatible by
/// decision (14.0 Q1): weekly/biweekly steps are 7/14 x 24 h of elapsed
/// time, so they drift an hour across DST exactly as in the Flutter app.
public enum RecurringGenerator {
    /// `_calculateNextOccurrence`.
    public static func nextOccurrence(of template: RecurringTemplate, after from: DartDateTime, calendar: DartCalendar) -> DartDateTime {
        nextOccurrence(pattern: template.pattern, dayOfMonth: template.dayOfMonth, after: from, calendar: calendar)
    }

    /// `_calculateNextOccurrence` for a bare schedule. The generator, the
    /// model's `calculateNextOccurrence` and the form's
    /// `_calculatePreviewDates` share this arithmetic character for
    /// character. Monthly: the day, clamped to the next month's length, at
    /// midnight (Dart's lenient `DateTime(y, m, d)`, so a midnight that does
    /// not exist becomes 01:00). Dart dereferences `dayOfMonth!`; without a
    /// day this falls back to `from`'s day (Dart would crash).
    public static func nextOccurrence(
        pattern: RecurrencePattern, dayOfMonth: Int?, after from: DartDateTime, calendar: DartCalendar
    ) -> DartDateTime {
        switch pattern {
        case .weekly: return from.adding(days: 7)
        case .biweekly: return from.adding(days: 14)
        case .monthly:
            // `_calculateNextMonthlyOccurrence`.
            let f = from.fields
            var nextMonth = f.month + 1
            var nextYear = f.year
            if nextMonth > 12 {
                nextMonth = 1
                nextYear += 1
            }
            let daysInMonth = calendar.date(nextYear, nextMonth + 1, 0).day
            let day = dayOfMonth ?? f.day
            return calendar.date(nextYear, nextMonth, day > daysInMonth ? daysInMonth : day)
        }
    }

    /// The form's "Next 3 Occurrences" (`_calculatePreviewDates`,
    /// recurring_transaction_form.dart:713-743): `start` verbatim (time of
    /// day and microseconds kept), then each next occurrence from the one
    /// before. For a new template this is exactly what the generator writes.
    public static func previewOccurrences(
        pattern: RecurrencePattern, start: DartDateTime, dayOfMonth: Int?, count: Int = 3, calendar: DartCalendar
    ) -> [DartDateTime] {
        guard count > 0 else { return [] }
        var dates = [start]
        while dates.count < count {
            dates.append(nextOccurrence(pattern: pattern, dayOfMonth: dayOfMonth, after: dates[dates.count - 1], calendar: calendar))
        }
        return dates
    }

    /// The preview while editing (approved divergence): from the cursor the
    /// edit will leave (`RecurringTemplate.editedCursor`), so it shows what
    /// will really be generated next. Flutter previews from the start date
    /// because its edit resets the cursor there.
    public static func previewOccurrences(
        editing template: RecurringTemplate, _ edit: RecurringTemplate.Edit, lastGenerated: DartDateTime?, count: Int = 3,
        calendar: DartCalendar
    ) -> [DartDateTime] {
        let cursor = RecurringTemplate.editedCursor(previous: template, edit: edit, lastGenerated: lastGenerated, calendar: calendar)
        return previewOccurrences(pattern: edit.pattern, start: cursor, dayOfMonth: edit.dayOfMonth, count: count, calendar: calendar)
    }

    /// The cursor a resumed template continues from (Swift only: Flutter
    /// has no pause): its cursor stepped with the generator's arithmetic
    /// until it is on or after `now`'s local day, never moved back. The
    /// generator treats an occurrence on `now`'s day as due, so one due
    /// today is still generated; the ones missed while paused are not.
    public static func resumedCursor(of template: RecurringTemplate, now: DartDateTime, calendar: DartCalendar) -> DartDateTime {
        var cursor = template.nextOccurrence
        while cursor.isBefore(now) && !calendar.isSameDay(cursor, now) {
            cursor = nextOccurrence(of: template, after: cursor, calendar: calendar)
        }
        return cursor
    }

    public struct Result: Sendable {
        public var generated: [TransactionRecord] = []
        public var advancedTemplates: [String] = []
        public var changed: Bool { !generated.isEmpty || !advancedTemplates.isEmpty }
    }

    /// `generateDueTransactions`. Appends generated rows and advances the
    /// cursors in `data`; the caller commits both sections in one write.
    public static func generateDue(
        in data: inout FinancialData, now: DartDateTime, clock: () -> DartDateTime, newID: () -> String
    ) -> Result {
        let calendar = data.calendar
        var result = Result()
        func isDue(_ date: DartDateTime) -> Bool { date.isBefore(now) || calendar.isSameDay(date, now) }
        let due = data.templates.filter { $0.isActive && isDue($0.nextOccurrence) }
        for template in due {
            // A monthly template without a day would crash the Dart app on the
            // same data; leave it untouched rather than guess.
            if template.pattern == .monthly && template.dayOfMonth == nil { continue }
            let maxLookback = now.adding(days: -90)
            var current = template.nextOccurrence
            while isDue(current) {
                if current.isAfter(maxLookback) || calendar.isSameDay(current, maxLookback) {
                    let record = data.addTransaction(
                        type: template.type, description: template.description, amount: template.amount,
                        category: template.category, date: current, recurringTemplateId: template.id,
                        id: newID(), now: clock())
                    result.generated.append(record)
                }
                current = nextOccurrence(of: template, after: current, calendar: calendar)
            }
            data.replaceTemplate(template.with(nextOccurrence: current))
            result.advancedTemplates.append(template.id)
        }
        return result
    }
}
