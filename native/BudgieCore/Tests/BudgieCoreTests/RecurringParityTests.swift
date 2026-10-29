import Foundation
import Testing

@testable import BudgieCore

/// Zones of Fixtures/recurring: the harness zones (America/Santiago is the
/// one whose DST change happens at midnight).
let recurringZones = fixtureZones

private func recurringFixture(_ zone: String, _ file: String) throws -> J {
    try Fixtures.json("\(Fixtures.zonePath("recurring", zone))/\(file)")
}

/// A fixture instant, from its microseconds (an ambiguous local time
/// cannot be re-derived from its ISO text).
private func instant(_ j: J, _ tz: TimeZone) -> DartDateTime {
    DartDateTime(microsecondsSinceEpoch: Int64(j["us"].int!), timeZone: tz)
}

@Suite("Recurring: form preview and generation against Dart in five time zones")
struct RecurringParityTests {
    @Test("Next 3 Occurrences preview", arguments: recurringZones)
    func preview(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let fixture = try recurringFixture(zone, "preview.json")
        #expect(fixture["tz"].string == zone)
        #expect(fixture["cases"].array.count >= 25)
        for c in fixture["cases"].array {
            let start = instant(c["start"], tz)
            let label = "\(zone) \(c["label"].string!)"
            #expect(start.toIso8601String() == c["start"]["iso"].string, "\(label) start")
            let pattern = RecurrencePattern(rawValue: c["pattern"].string!)!
            let dates = RecurringGenerator.previewOccurrences(
                pattern: pattern, start: start, dayOfMonth: c["dayOfMonth"].int, calendar: calendar)
            let expected = c["dates"].array
            #expect(dates.map { $0.toIso8601String() } == expected.map { $0["iso"].string! }, "\(label) iso")
            #expect(dates.map(\.microsecondsSinceEpoch) == expected.map { Int64($0["us"].int!) }, "\(label) us")
            #expect(dates.map(\.weekday) == expected.map { $0["weekday"].int! }, "\(label) weekday")
            #expect(dates.map(DartDateFormat.EEEEMMMddyyyy).count == 3)
        }
    }

    private func load(_ template: RecurringTemplate, _ calendar: DartCalendar) -> FinancialData {
        FinancialData.load(
            FinancialSnapshot(revision: 0, sections: JSONObject(ordered: [(Section.recurringTransactions, .array([.object(template.raw)]))])),
            preferences: InMemoryPreferences(), calendar: calendar, now: { calendar.date(2026, 1, 1, 12) }, newID: { "id" }
        ).data
    }

    /// Every case, the old-cursor one included: an active template whose
    /// cursor fell behind (the app was not opened for weeks) back-fills
    /// within the 90-day lookback exactly as Dart does.
    @Test("generate due on form-written templates", arguments: recurringZones)
    func generate(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let fixture = try recurringFixture(zone, "generate.json")
        for c in fixture["cases"].array {
            let template = RecurringTemplate.parse(c["template"].value!, calendar: calendar, newID: { "x" })!
            var data = load(template, calendar)
            let now = instant(c["now"], tz)
            _ = RecurringGenerator.generateDue(in: &data, now: now, clock: { now }, newID: { UUID().uuidString })
            let label = "\(zone) \(c["label"].string!)"
            let generated = c["generated"].array
            #expect(data.transactions.map { $0.date.toIso8601String() } == generated.map { $0["date"]["iso"].string! }, "\(label) dates")
            #expect(data.transactions.map(\.date.microsecondsSinceEpoch) == generated.map { Int64($0["date"]["us"].int!) }, "\(label) us")
            #expect(data.transactions.map { $0.createdAt.toIso8601String() } == generated.map { $0["createdAt"].string! }, "\(label) createdAt")
            #expect(data.transactions.allSatisfy { $0.recurringTemplateId == template.id }, "\(label) link")
            #expect(data.templates[0].nextOccurrence.toIso8601String() == c["nextOccurrence"]["iso"].string, "\(label) cursor")
            #expect(data.templates[0].nextOccurrence.microsecondsSinceEpoch == Int64(c["nextOccurrence"]["us"].int!), "\(label) cursor us")
            #expect(data.templates[0].isActive == c["isActive"].bool, "\(label) active")
        }
    }

    /// Deliberate difference (PARITY_GAPS; Flutter has no pause): the
    /// oracle's "resumed weekly with an old cursor" records Flutter's
    /// generator on that cursor, every missed occurrence in the lookback.
    /// Resuming the paused template in Swift at the same clock skips the
    /// ones before that day, so only Dart's rows on or after it are
    /// generated, and the cursor ends where Dart's does.
    @Test("resume: the old-cursor case paused, then resumed, generates only from that day on", arguments: recurringZones)
    func resumed(zone: String) throws {
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let fixture = try recurringFixture(zone, "generate.json")
        let c = try #require(fixture["cases"].array.first { $0["label"].string == "resumed weekly with an old cursor" })
        let template = RecurringTemplate.parse(c["template"].value!, calendar: calendar, newID: { "x" })!
        var data = load(template, calendar)
        let now = instant(c["now"], tz)
        let paused = data.setTemplateActive(id: template.id, false, now: now)
        let resumed = data.setTemplateActive(id: template.id, true, now: now)
        #expect(paused && resumed)
        _ = RecurringGenerator.generateDue(in: &data, now: now, clock: { now }, newID: { UUID().uuidString })

        let dart = c["generated"].array.map { instant($0["date"], tz) }
        let expected = dart.filter { !$0.isBefore(now) || calendar.isSameDay($0, now) }
        #expect(!expected.isEmpty && expected.count < dart.count, "\(zone): the case must have paused and due rows")
        #expect(data.transactions.map(\.date.microsecondsSinceEpoch) == expected.map(\.microsecondsSinceEpoch), "\(zone) rows")
        #expect(data.templates[0].nextOccurrence.microsecondsSinceEpoch == Int64(c["nextOccurrence"]["us"].int!), "\(zone) cursor")
        #expect(data.templates[0].isActive)
    }
}
