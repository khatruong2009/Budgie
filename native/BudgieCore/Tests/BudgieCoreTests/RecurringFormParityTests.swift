import Foundation
import Testing

@testable import BudgieCore

/// Zones of Fixtures/recurring_form: a DST change at 02:00 (New York), at
/// midnight (Santiago) and of 30 minutes (Lord Howe).
private let formZones = ["America/New_York", "America/Santiago", "Australia/Lord_Howe"]

private func fixture(_ zone: String) throws -> J {
    try Fixtures.json("\(Fixtures.zonePath("recurring_form", zone))/validation.json")
}

private func bits(_ value: J) -> Double? {
    value.string.flatMap { UInt64($0, radix: 16) }.map { Double(bitPattern: $0) }
}

private func instant(_ j: J, _ tz: TimeZone) -> DartDateTime {
    DartDateTime(microsecondsSinceEpoch: Int64(j["us"].int!), timeZone: tz)
}

@Suite("Recurring form: validation copy, the start-date rule and what Save stores match the Flutter form (Fixtures/recurring_form)")
struct RecurringFormParityTests {
    /// The real form driven through Save, case by case. Swift's
    /// `RecurringForm.validate` gives the same three messages and the same
    /// verdict, except where a documented difference applies:
    /// - an amount that parses to NaN or an infinity passes Flutter's checks
    ///   (`NaN <= 0` is false); Swift rejects it (fixed, like the
    ///   transaction form);
    /// - Flutter stores the text of the amount field, so an untouched
    ///   prefill (`toStringAsFixed(2)`) rounds the stored amount; Swift keeps
    ///   the stored amount while the field still shows its prefill;
    /// - Flutter re-validates an edited template's untouched start date, so
    ///   a template that started over a year ago cannot be saved; Swift
    ///   accepts its own stored start (`storedStart`).
    @Test("validation, start-date rule and stored row", arguments: formZones)
    func validation(zone: String) throws {
        let f = try fixture(zone)
        #expect(f["tz"].string == zone)
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let en = Locale(identifier: "en_US")
        let cases = f["cases"].array
        #expect(cases.count >= 120)

        var nonFinite = 0, prefillRounded = 0, oldStartAccepted = 0, startErrors = 0, startOK = 0, saves = 0, generatedRows = 0
        var weekdayWheel = 0
        for c in cases {
            let label = "\(zone) \(c["label"].string!)"
            let edit = c["mode"].string == "edit"
            let now = instant(c["now"], tz)
            let start = edit ? instant(c["templateStart"], tz) : now
            let storedAmount = edit ? c["template"]["amount"].double : nil
            let amountText = c["amountText"].string!
            let dartClosed = c["closed"].bool!

            let v = RecurringForm.validate(
                amountText: amountText, description: c["descriptionText"].string!, start: start, storedStart: nil,
                storedAmount: storedAmount, now: now, locale: en)

            // Amount: the same message, except non-finite numbers.
            let parsed = DartDouble.tryParse(amountText)
            let isNonFinite = parsed.map { !$0.isFinite } ?? false
            if isNonFinite {
                nonFinite += 1
                #expect(v.amountError == RecurringForm.amountInvalid, "\(label) Swift rejects a non-finite amount")
                #expect(
                    c["amountError"].string == nil || c["amountError"].string == RecurringForm.amountNotPositive,
                    "\(label) Flutter lets it through or calls it not positive")
            } else {
                #expect(v.amountError == c["amountError"].string, "\(label) amount error")
            }
            #expect(v.descriptionError == c["descriptionError"].string, "\(label) description error")
            #expect(v.startDateError == c["startError"].string, "\(label) start error")
            if v.startDateError == nil { startOK += 1 } else { startErrors += 1 }
            // Flutter's second check of the same rule (`!isBefore(oneYearAgo)`
            // after a pick): the start-date error clears exactly when valid.
            #expect(RecurringForm.startDateError(start: start, storedStart: nil, now: now) == c["startError"].string, "\(label) rule")
            if edit, c["startError"].string != nil {
                // Approved difference: an untouched stored start is accepted.
                #expect(RecurringForm.startDateError(start: start, storedStart: start, now: now) == nil, "\(label) stored start")
                oldStartAccepted += 1
            }

            if !isNonFinite {
                #expect(v.isValid == dartClosed, "\(label) closes")
            }
            guard dartClosed, !isNonFinite else { continue }
            saves += 1

            // What Save stored.
            let row = c["stored"]
            #expect(row["description"].string == v.description, "\(label) stored description")
            let dartAmount = bits(c["storedAmount"])!
            guard let swiftAmount = v.amount else {
                Issue.record("\(label) Swift reports no amount")
                continue
            }
            if swiftAmount.bitPattern != dartAmount.bitPattern {
                // Only the untouched prefill differs: Swift keeps the stored
                // amount, Flutter the rounded text.
                #expect(edit && swiftAmount == storedAmount, "\(label) Swift keeps the stored amount")
                #expect(dartAmount.bitPattern == DartDouble.tryParse(amountText)!.bitPattern, "\(label) Flutter stores the text")
                prefillRounded += 1
            }
            #expect(instant(c["storedStart"], tz) == start, "\(label) stored start instant")

            // The wheel the form opened with.
            let opened = RecurringForm.initialDayOfMonth(template: nil, openedAt: now)
            let pattern = row["pattern"].string!
            if !edit {
                #expect(pattern == "monthly" && c["wheel"]["kind"].string == "dayOfMonth", "\(label) default pattern")
                #expect(c["wheel"]["value"].int == opened.day && row["dayOfMonth"].int == opened.day, "\(label) day of month")
                #expect(row["dayOfWeek"].isNull, "\(label) no weekday for monthly")
                // The generator logs today's occurrence right away.
                let template = RecurringTemplate.make(
                    id: "new", type: TransactionType(rawValue: c["type"].string!)!, description: v.description, amount: swiftAmount,
                    category: "General", pattern: .monthly, startDate: start, dayOfMonth: opened.day, dayOfWeek: nil)
                var data = FinancialData.load(
                    FinancialSnapshot(revision: 0, sections: JSONObject()), preferences: InMemoryPreferences(), calendar: calendar,
                    now: { now }, newID: { "x" }
                ).data
                data.addTemplate(template)
                _ = RecurringGenerator.generateDue(in: &data, now: now, clock: { now }, newID: { "generated" })
                let dart = c["generated"].array
                #expect(data.transactions.map(\.date.microsecondsSinceEpoch) == dart.map { Int64($0["date"]["us"].int!) }, "\(label) generated")
                #expect(data.transactions.map { $0.date.toIso8601String() } == dart.map { $0["date"]["iso"].string! }, "\(label) generated iso")
                #expect(dart.count == 1, "\(label) today's occurrence")
                generatedRows += dart.count
            } else {
                let template = RecurringTemplate.parse(c["template"].value!, calendar: calendar, newID: { "x" })!
                let initial = RecurringForm.initialDayOfMonth(template: template, openedAt: now)
                let swiftEdit = RecurringForm.edit(
                    type: TransactionType(rawValue: c["type"].string!)!, description: v.description, amount: swiftAmount,
                    category: template.category, pattern: template.pattern, start: start, dayOfMonth: initial.day)
                if pattern == "monthly" {
                    #expect(c["wheel"]["kind"].string == "dayOfMonth" && c["wheel"]["value"].int == initial.day, "\(label) wheel day")
                    #expect(row["dayOfMonth"].int == swiftEdit.dayOfMonth && row["dayOfWeek"].isNull && swiftEdit.dayOfWeek == nil, "\(label) monthly day")
                } else {
                    // Flutter stores its Day of Week wheel (the stored weekday);
                    // Swift the start date's weekday. Nothing reads either.
                    #expect(c["wheel"]["kind"].string == "dayOfWeek" && c["wheel"]["value"].int == template.dayOfWeek, "\(label) wheel weekday")
                    #expect(row["dayOfWeek"].int == template.dayOfWeek && swiftEdit.dayOfWeek == start.weekday, "\(label) weekday")
                    #expect(row["dayOfMonth"].isNull && swiftEdit.dayOfMonth == nil, "\(label) no day of month")
                    if template.dayOfWeek != start.weekday { weekdayWheel += 1 }
                }
            }
        }
        #expect(nonFinite >= 3 && prefillRounded >= 2 && oldStartAccepted >= 10 && startErrors >= 20 && startOK >= 40, "the fixtures exercise the rules")
        #expect(saves >= 40 && generatedRows >= 10 && weekdayWheel >= 1, "the fixtures exercise Save")
    }

    /// The days the picker offers. Flutter offers every local day from the
    /// one holding `now - 365 days` (elapsed time) but a picked day is its
    /// midnight, which the rule rejects for the first day unless the floor
    /// is exactly midnight; Swift leaves that partial day out. Checked
    /// against the oracle's verdicts for the two midnights around the floor.
    @Test("picker range starts at the first day Flutter accepts", arguments: formZones)
    func range(zone: String) throws {
        let f = try fixture(zone)
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let cases = f["cases"].array
        var checked = 0
        for c in cases {
            let label = c["label"].string!
            guard label.hasPrefix("start midnight of the floor day @ ") else { continue }
            let name = label.components(separatedBy: " @ ")[1]
            let now = instant(c["now"], tz)
            let after = try #require(cases.first { $0["label"].string == "start midnight after the floor day @ \(name)" })
            let floor = now.adding(days: -365)
            let expected = c["startError"].string == nil
                ? calendar.date(floor.year, floor.month, floor.day) : calendar.date(floor.year, floor.month, floor.day + 1)
            // Flutter accepts the later midnight whenever it accepts the earlier one.
            #expect(after["startError"].string == nil, "\(zone) \(name) the day after")
            let range = RecurringForm.startDateRange(now: now, calendar: calendar)
            #expect(range.lowerBound == expected, "\(zone) \(name) first offered day")
            #expect(RecurringForm.startDateError(start: range.lowerBound, storedStart: nil, now: now) == nil, "\(zone) \(name) accepted")
            // The day before it would fail the rule.
            let before = calendar.date(range.lowerBound.year, range.lowerBound.month, range.lowerBound.day - 1)
            #expect(RecurringForm.startDateError(start: before, storedStart: nil, now: now) != nil, "\(zone) \(name) the day before")
            checked += 1
        }
        #expect(checked == 9, "\(zone): one per clock")
    }
}
