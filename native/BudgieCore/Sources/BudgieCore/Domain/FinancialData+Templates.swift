import Foundation

extension FinancialData {
    public mutating func addTemplate(_ template: RecurringTemplate) {
        templateRows.append(.record(template))
    }

    /// Edit (approved divergence Q2): Dart resets `nextOccurrence` and
    /// `isActive`, which duplicates already generated transactions. Here the
    /// cursor and pause state are kept; if the schedule changed, the cursor
    /// restarts from the new start date but never lands on or before the
    /// last occurrence already generated for this template.
    @discardableResult
    public mutating func updateTemplate(id: String, _ edit: RecurringTemplate.Edit) -> Bool {
        guard let index = templateRows.firstIndex(where: { $0.record.map { DartString.equal($0.id, id) } ?? false }), let template = templateRows[index].record else {
            return false
        }
        var next = template.applying(edit)
        if next.scheduleKey != template.scheduleKey {
            next = next.with(nextOccurrence: RecurringTemplate.editedCursor(
                previous: template, edit: edit, lastGenerated: lastGeneratedDate(forTemplate: id), calendar: calendar))
        }
        templateRows[index] = .record(next)
        return true
    }

    /// The latest date among readable transactions generated from this
    /// template (`recurringTemplateId`), or nil when there are none.
    public func lastGeneratedDate(forTemplate id: String) -> DartDateTime? {
        transactions.filter { $0.recurringTemplateId.map { DartString.equal($0, id) } ?? false }.map(\.date).max()
    }

    /// Pause or resume (Swift only; Flutter has no pause). Resuming a paused
    /// template moves its cursor to the first occurrence on or after `now`'s
    /// day (`RecurringGenerator.resumedCursor`), so the occurrences missed
    /// while it was paused are skipped rather than back-filled; one due
    /// today stays due. Pausing, or resuming an active template, keeps the
    /// cursor.
    @discardableResult
    public mutating func setTemplateActive(id: String, _ active: Bool, now: DartDateTime) -> Bool {
        guard let index = templateRows.firstIndex(where: { $0.record.map { DartString.equal($0.id, id) } ?? false }), let template = templateRows[index].record else {
            return false
        }
        var next = template.with(isActive: active)
        if active && !template.isActive {
            let cursor = RecurringGenerator.resumedCursor(of: template, now: now, calendar: calendar)
            if cursor != template.nextOccurrence { next = next.with(nextOccurrence: cursor) }
        }
        templateRows[index] = .record(next)
        return true
    }

    @discardableResult
    public mutating func deleteTemplate(id: String) -> Bool {
        let before = templateRows.count
        templateRows.removeAll { $0.record.map { DartString.equal($0.id, id) } ?? false }
        return templateRows.count != before
    }

    mutating func replaceTemplate(_ template: RecurringTemplate) {
        if let index = templateRows.firstIndex(where: { $0.record.map { DartString.equal($0.id, template.id) } ?? false }) {
            templateRows[index] = .record(template)
        }
    }
}
