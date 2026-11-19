import Foundation
import Testing

@testable import BudgieCore

/// The recurring form's pure rules (recurring_transaction_form.dart copy)
/// and the Swift-only edit rules (cursor-preserving edit, preview from the
/// cursor). The clock is 2026-09-28 09:15:30.250125 New York.
@Suite("Recurring form rules")
struct RecurringFormTests {
    let calendar = DartCalendar(timeZone: newYorkZone)
    var now: DartDateTime { calendar.date(2026, 9, 28, 9, 15, 30, 250, 125) }
    let en = Locale(identifier: "en_US")

    func validate(
        _ amount: String, _ description: String = "Rent", start: DartDateTime? = nil, stored: DartDateTime? = nil,
        storedAmount: Double? = nil, locale: Locale? = nil
    ) -> RecurringForm.Validation {
        RecurringForm.validate(
            amountText: amount, description: description, start: start ?? now, storedStart: stored, storedAmount: storedAmount,
            now: now, locale: locale ?? en)
    }

    @Test("amount: Flutter's three messages; non-finite rejected; locale separator; untouched prefill kept exactly")
    func amount() {
        #expect(validate("").amountError == "Amount is required")
        #expect(validate(" ").amountError == "Please enter a valid number")
        #expect(validate("abc").amountError == "Please enter a valid number")
        #expect(validate("1,5").amountError == "Please enter a valid number")
        #expect(validate("NaN").amountError == "Please enter a valid number")
        #expect(validate("Infinity").amountError == "Please enter a valid number")
        #expect(validate("0").amountError == "Amount must be greater than 0")
        #expect(validate("-5").amountError == "Amount must be greater than 0")
        #expect(validate("12.50").amount == 12.5)
        #expect(validate(" 12 ").amount == 12)
        #expect(validate(".5").amount == 0.5)
        #expect(validate("12,5", locale: Locale(identifier: "de_DE")).amount == 12.5)
        // The edit prefill is toStringAsFixed(2); untouched keeps the value.
        #expect(validate("12.35", storedAmount: 12.345).amount == 12.345)
        #expect(validate("12.36", storedAmount: 12.345).amount == 12.36)
        // Flutter validates the prefill text itself: a sub-cent amount fails.
        #expect(validate("0.00", storedAmount: 0.001).amountError == "Amount must be greater than 0")
        #expect(validate("12").amountError == nil && validate("12").isValid)
    }

    @Test("description: Dart trim (U+FEFF included) and the required message")
    func description() {
        #expect(validate("1", "\u{FEFF} \n\t").descriptionError == "Description is required")
        #expect(validate("1", "").descriptionError == "Description is required")
        let valid = validate("1", "  Rent \u{FEFF}")
        #expect(valid.descriptionError == nil && valid.description == "Rent")
    }

    @Test("start date: more than 365 days back fails, only when set in this form")
    func startDate() {
        let floor = now.adding(days: -365)
        #expect(validate("1", start: floor).startDateError == nil)
        #expect(validate("1", start: floor.adding(microseconds: -1)).startDateError == "Start date cannot be more than 1 year in the past")
        // Editing an old template without touching its start saves.
        let old = calendar.date(2024, 1, 15, 8)
        #expect(validate("1", start: old, stored: old).startDateError == nil)
        #expect(validate("1", start: old, stored: calendar.date(2024, 1, 16)).startDateError != nil)
        // The future is never refused.
        #expect(validate("1", start: calendar.date(2027, 9, 28)).startDateError == nil)
        // All three at once, as Flutter's validateForm.
        let all = validate("", " ", start: old)
        #expect(all.amountError != nil && all.descriptionError != nil && all.startDateError != nil && !all.isValid)
        #expect(RecurringForm.startDateError(start: old, storedStart: nil, now: now) == RecurringForm.startDateTooOld)
    }

    @Test("picker range: every offered day validates; Flutter's first day (a partial day) is left out")
    func range() {
        let range = RecurringForm.startDateRange(now: now, calendar: calendar)
        #expect(range.lowerBound.toIso8601String() == "2025-09-29T00:00:00.000")
        #expect(range.upperBound.toIso8601String() == "2027-09-28T00:00:00.000")
        #expect(validate("1", start: range.lowerBound).startDateError == nil)
        #expect(validate("1", start: calendar.date(2025, 9, 28)).startDateError != nil)
        // At exactly midnight Flutter's first day is valid and offered.
        let midnight = calendar.date(2026, 9, 28)
        let atMidnight = RecurringForm.startDateRange(now: midnight, calendar: calendar)
        #expect(atMidnight.lowerBound == calendar.date(2025, 9, 28))
        #expect(RecurringForm.startDateError(start: atMidnight.lowerBound, storedStart: nil, now: midnight) == nil)
        // Across a leap day 365 days is not a year.
        let leap = RecurringForm.startDateRange(now: calendar.date(2028, 3, 1, 12), calendar: calendar)
        #expect(leap.lowerBound == calendar.date(2027, 3, 3))
        #expect(leap.upperBound == calendar.date(2029, 3, 1))
    }

    @Test("start: the form-open moment with time of day, a picked day at midnight, the stored value on its own day")
    func resolvedStart() {
        let opened = now
        #expect(RecurringForm.resolvedStart(picked: nil, stored: nil, openedAt: opened, calendar: calendar) == opened)
        let picked = calendar.date(2026, 10, 1)
        #expect(RecurringForm.resolvedStart(picked: picked, stored: nil, openedAt: opened, calendar: calendar) == picked)
        let stored = calendar.date(2026, 3, 5, 14, 32, 11, 123, 456)
        #expect(RecurringForm.resolvedStart(picked: nil, stored: stored, openedAt: opened, calendar: calendar) == stored)
        #expect(RecurringForm.resolvedStart(picked: calendar.date(2026, 3, 5), stored: stored, openedAt: opened, calendar: calendar) == stored)
        #expect(RecurringForm.resolvedStart(picked: picked, stored: stored, openedAt: opened, calendar: calendar) == picked)
    }

    func monthly(start: DartDateTime, day: Int?, pattern: RecurrencePattern = .monthly) -> RecurringTemplate {
        RecurringTemplate.make(
            id: "m", type: .expense, description: "Rent", amount: 900, category: "Housing", pattern: pattern, startDate: start,
            dayOfMonth: day, dayOfWeek: day == nil ? start.weekday : nil)
    }

    @Test("Day of Month: today's day when adding, else the stored day; it follows a picked start only while it is the start's day")
    func initialDayOfMonth() {
        #expect(RecurringForm.initialDayOfMonth(template: nil, openedAt: now) == (28, true))
        #expect(RecurringForm.initialDayOfMonth(template: monthly(start: calendar.date(2026, 1, 15), day: 15), openedAt: now) == (15, true))
        #expect(RecurringForm.initialDayOfMonth(template: monthly(start: calendar.date(2026, 1, 15), day: 20), openedAt: now) == (20, false))
        // A weekly template has no stored day: the start's, following.
        let weekly = monthly(start: calendar.date(2026, 9, 1, 7, 45), day: nil, pattern: .weekly)
        #expect(RecurringForm.initialDayOfMonth(template: weekly, openedAt: now) == (1, true))
    }

    @Test("editing a template that started over a year ago: the picker opens on its day, and OK keeps the start, the day and the cursor")
    func oldTemplateEdit() {
        let stored = calendar.date(2024, 3, 15, 8, 30)
        let template = monthly(start: stored, day: 15).with(nextOccurrence: calendar.date(2026, 10, 15))
        let range = RecurringForm.startDateRange(now: now, calendar: calendar, storedStart: stored)
        #expect(range.lowerBound == calendar.date(2024, 3, 15))
        #expect(range.upperBound == calendar.date(2027, 9, 28))
        // OK on the untouched wheel picks the stored day's midnight.
        let start = RecurringForm.resolvedStart(picked: range.lowerBound, stored: stored, openedAt: now, calendar: calendar)
        #expect(start == stored)
        #expect(RecurringForm.startDateError(start: start, storedStart: stored, now: now) == nil)
        let day = RecurringForm.initialDayOfMonth(template: template, openedAt: now)
        #expect(day == (15, true) && start.day == 15)
        let edit = RecurringForm.edit(
            type: .expense, description: "Rent", amount: 900, category: "Housing", pattern: .monthly, start: start, dayOfMonth: start.day)
        #expect(RecurringTemplate.editedCursor(previous: template, edit: edit, lastGenerated: nil, calendar: calendar) == template.nextOccurrence)
        // The older days in between are offered but fail the rule; a valid
        // day clears the error again.
        let older = calendar.date(2024, 6, 1)
        #expect(range.contains(older))
        let olderStart = RecurringForm.resolvedStart(picked: older, stored: stored, openedAt: now, calendar: calendar)
        #expect(RecurringForm.startDateError(start: olderStart, storedStart: stored, now: now) == RecurringForm.startDateTooOld)
        let valid = RecurringForm.resolvedStart(picked: calendar.date(2026, 1, 10), stored: stored, openedAt: now, calendar: calendar)
        #expect(RecurringForm.startDateError(start: valid, storedStart: stored, now: now) == nil)
        // A stored start past the range stays offered too; one inside it
        // changes nothing.
        let far = RecurringForm.startDateRange(now: now, calendar: calendar, storedStart: calendar.date(2028, 1, 1, 9))
        #expect(far.upperBound == calendar.date(2028, 1, 1) && far.lowerBound == calendar.date(2025, 9, 29))
        #expect(
            RecurringForm.startDateRange(now: now, calendar: calendar, storedStart: calendar.date(2026, 3, 5, 14))
                == RecurringForm.startDateRange(now: now, calendar: calendar))
    }

    @Test("saved fields: day of month for monthly, the start weekday for weekly/biweekly")
    func editFields() {
        let sunday = calendar.date(2026, 9, 27, 18)
        let monthly = RecurringForm.edit(
            type: .expense, description: "Rent", amount: 900, category: "Housing", pattern: .monthly, start: sunday, dayOfMonth: 31)
        #expect(monthly.dayOfMonth == 31 && monthly.dayOfWeek == nil && monthly.startDate == sunday)
        let weekly = RecurringForm.edit(
            type: .income, description: "Pay", amount: 1, category: "Salary", pattern: .biweekly, start: sunday, dayOfMonth: 31)
        #expect(weekly.dayOfMonth == nil && weekly.dayOfWeek == 7)
        #expect(RecurrencePattern.allCases.map(\.displayName) == ["Weekly", "Bi-weekly", "Monthly"])
        #expect(RecurringForm.daysOfMonth == 1...31)
    }

    @Test("preview: start verbatim, then the generator's steps")
    func preview() {
        let start = calendar.date(2026, 1, 31, 14, 32, 11, 123)
        let dates = RecurringGenerator.previewOccurrences(pattern: .monthly, start: start, dayOfMonth: 31, calendar: calendar)
        #expect(dates.map { $0.toIso8601String() } == ["2026-01-31T14:32:11.123", "2026-02-28T00:00:00.000", "2026-03-31T00:00:00.000"])
        #expect(dates.map(DartDateFormat.EEEEMMMddyyyy) == ["Saturday, Jan 31, 2026", "Saturday, Feb 28, 2026", "Tuesday, Mar 31, 2026"])
        let fall = RecurringGenerator.previewOccurrences(pattern: .weekly, start: calendar.date(2026, 10, 25), dayOfMonth: nil, calendar: calendar)
        #expect(fall.map { $0.toIso8601String() } == ["2026-10-25T00:00:00.000", "2026-11-01T00:00:00.000", "2026-11-07T23:00:00.000"])
        #expect(RecurringGenerator.previewOccurrences(pattern: .weekly, start: start, dayOfMonth: nil, count: 0, calendar: calendar) == [])
    }
}

@Suite("Recurring edit cursor (approved divergence Q2)")
struct RecurringEditCursorTests {
    let calendar = DartCalendar(timeZone: newYorkZone)
    var now: DartDateTime { calendar.date(2026, 9, 28, 9, 15, 30, 250, 125) }

    func data() -> FinancialData {
        loadFinancialData(JSONObject(), calendar: calendar, now: now).data
    }

    func edit(_ t: RecurringTemplate, pattern: RecurrencePattern? = nil, start: DartDateTime? = nil, day: Int? = nil,
              description: String? = nil) -> RecurringTemplate.Edit
    {
        let pattern = pattern ?? t.pattern
        return RecurringForm.edit(
            type: t.type, description: description ?? t.description, amount: t.amount, category: t.category, pattern: pattern,
            start: start ?? t.startDate, dayOfMonth: day ?? t.dayOfMonth ?? 1)
    }

    /// A weekly template from Sep 1 (Tuesday, 07:45), generated up to now.
    func generatedWeekly() -> (FinancialData, RecurringTemplate) {
        var data = data()
        let template = RecurringTemplate.make(
            id: "w", type: .expense, description: "Gym", amount: 12.5, category: "Health", pattern: .weekly,
            startDate: calendar.date(2026, 9, 1, 7, 45), dayOfMonth: nil, dayOfWeek: 2)
        data.addTemplate(template)
        let now = self.now
        _ = RecurringGenerator.generateDue(in: &data, now: now, clock: { now }, newID: { UUID().uuidString })
        return (data, data.templates[0])
    }

    @Test("resume skips the occurrences missed while paused; one due today is still generated")
    func resume() {
        var data = data()
        let now = self.now
        // Weekly from Monday Jun 1 07:45, paused with its cursor at Aug 3.
        let weekly = RecurringTemplate.make(
            id: "p", type: .expense, description: "Gym", amount: 12.5, category: "Health", pattern: .weekly,
            startDate: calendar.date(2026, 6, 1, 7, 45), dayOfMonth: nil, dayOfWeek: 1, isActive: false
        ).with(nextOccurrence: calendar.date(2026, 8, 3, 7, 45))
        data.addTemplate(weekly)
        let paused = RecurringGenerator.generateDue(in: &data, now: now, clock: { now }, newID: { "x" })
        #expect(paused.generated.isEmpty)
        let resumed = data.setTemplateActive(id: "p", true, now: now)
        #expect(resumed)
        #expect(data.templates[0].isActive)
        #expect(data.templates[0].nextOccurrence.toIso8601String() == "2026-09-28T07:45:00.000")
        #expect(data.templates[0].raw["nextOccurrence"] == .string("2026-09-28T07:45:00.000"))
        let result = RecurringGenerator.generateDue(in: &data, now: now, clock: { now }, newID: { "x" })
        #expect(result.generated.map { $0.date.toIso8601String() } == ["2026-09-28T07:45:00.000"])
        #expect(data.templates[0].nextOccurrence.toIso8601String() == "2026-10-05T07:45:00.000")
        // A cursor already in the future stays put.
        data.setTemplateActive(id: "p", false, now: now)
        data.setTemplateActive(id: "p", true, now: now)
        #expect(data.templates[0].nextOccurrence.toIso8601String() == "2026-10-05T07:45:00.000")

        // Monthly on the 31st, cursor Jul 31: Aug 31 is past, Sep 30 (clamped) is next.
        let rent = RecurringTemplate.make(
            id: "m", type: .expense, description: "Rent", amount: 900, category: "Housing", pattern: .monthly,
            startDate: calendar.date(2026, 1, 31), dayOfMonth: 31, dayOfWeek: nil, isActive: false
        ).with(nextOccurrence: calendar.date(2026, 7, 31))
        data.addTemplate(rent)
        data.setTemplateActive(id: "m", true, now: now)
        #expect(data.templates[1].nextOccurrence.toIso8601String() == "2026-09-30T00:00:00.000")

        // Resuming a template that is already active never moves its cursor.
        let active = RecurringTemplate.make(
            id: "a", type: .expense, description: "Due", amount: 1, category: "Health", pattern: .weekly,
            startDate: calendar.date(2026, 9, 21), dayOfMonth: nil, dayOfWeek: 1)
        data.addTemplate(active)
        data.setTemplateActive(id: "a", true, now: now)
        #expect(data.templates[2].nextOccurrence == calendar.date(2026, 9, 21))
        let missing = data.setTemplateActive(id: "missing", true, now: now)
        #expect(!missing)
    }

    @Test("last generated date: the latest row of this template only")
    func lastGenerated() {
        var (data, template) = generatedWeekly()
        #expect(data.lastGeneratedDate(forTemplate: template.id)?.toIso8601String() == "2026-09-22T07:45:00.000")
        #expect(data.lastGeneratedDate(forTemplate: "other") == nil)
        _ = data.addTransaction(type: .expense, description: "x", amount: 1, category: "Health", date: calendar.date(2026, 12, 1),
                                recurringTemplateId: "other", id: "o", now: now)
        #expect(data.lastGeneratedDate(forTemplate: template.id)?.toIso8601String() == "2026-09-22T07:45:00.000")
    }

    @Test("an unchanged schedule keeps the cursor and the pause state")
    func unchanged() {
        var (data, template) = generatedWeekly()
        #expect(template.nextOccurrence.toIso8601String() == "2026-09-29T07:45:00.000")
        data.setTemplateActive(id: template.id, false, now: now)
        let e = edit(template, description: "Gym (edited)")
        #expect(RecurringTemplate.editedCursor(previous: template, edit: e, lastGenerated: nil, calendar: calendar) == template.nextOccurrence)
        data.updateTemplate(id: template.id, e)
        #expect(data.templates[0].nextOccurrence == template.nextOccurrence)
        #expect(data.templates[0].description == "Gym (edited)" && !data.templates[0].isActive)
    }

    @Test("a changed schedule restarts at the new start, strictly after the last generated day")
    func changed() {
        var (data, template) = generatedWeekly()
        let last = data.lastGeneratedDate(forTemplate: template.id)
        // Biweekly from Sep 8 steps 8, 22 (same day as the last row, skipped), Oct 6.
        let biweekly = edit(template, pattern: .biweekly, start: calendar.date(2026, 9, 8))
        let cursor = RecurringTemplate.editedCursor(previous: template, edit: biweekly, lastGenerated: last, calendar: calendar)
        #expect(cursor.toIso8601String() == "2026-10-06T00:00:00.000")
        let preview = RecurringGenerator.previewOccurrences(editing: template, biweekly, lastGenerated: last, calendar: calendar)
        #expect(preview.map { $0.toIso8601String() } == ["2026-10-06T00:00:00.000", "2026-10-20T00:00:00.000", "2026-11-02T23:00:00.000"])
        data.updateTemplate(id: template.id, biweekly)
        #expect(data.templates[0].nextOccurrence == cursor)
        #expect(data.templates[0].isActive)

        // Monthly on the 25th from Oct 25 (after every row): the start verbatim.
        let later = edit(data.templates[0], pattern: .monthly, start: calendar.date(2026, 10, 25, 18, 30), day: 25)
        let laterCursor = RecurringTemplate.editedCursor(
            previous: data.templates[0], edit: later, lastGenerated: data.lastGeneratedDate(forTemplate: template.id), calendar: calendar)
        #expect(laterCursor.toIso8601String() == "2026-10-25T18:30:00.000")
        // Only the day of month changing is a schedule change too.
        let monthly = RecurringTemplate.make(
            id: "m", type: .expense, description: "Rent", amount: 900, category: "Housing", pattern: .monthly,
            startDate: calendar.date(2026, 1, 15), dayOfMonth: 15, dayOfWeek: nil).with(nextOccurrence: calendar.date(2026, 10, 15))
        let dayOnly = edit(monthly, day: 20)
        #expect(RecurringTemplate.editedCursor(previous: monthly, edit: dayOnly, lastGenerated: calendar.date(2026, 9, 15), calendar: calendar)
            .toIso8601String() == "2026-09-20T00:00:00.000")
    }

    @Test("without generated rows the new start is the cursor; the step guard ends")
    func noRowsAndGuard() {
        let (_, template) = generatedWeekly()
        let start = calendar.date(2026, 8, 1, 6, 5, 4, 3, 2)
        let e = edit(template, start: start)
        #expect(RecurringTemplate.editedCursor(previous: template, edit: e, lastGenerated: nil, calendar: calendar) == start)
        let ancient = edit(template, start: calendar.date(1800, 1, 1))
        let cursor = RecurringTemplate.editedCursor(previous: template, edit: ancient, lastGenerated: now, calendar: calendar)
        #expect(cursor == calendar.date(1800, 1, 1).adding(days: 7 * 5000))
    }
}
