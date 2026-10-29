import Foundation
import Testing

@testable import BudgieCore

/// Zones of Fixtures/transactions: a DST change at 02:00 (New York), at
/// midnight (Santiago) and of 30 minutes (Lord Howe).
private let transactionZones = ["America/New_York", "America/Santiago", "Australia/Lord_Howe"]

private func fixture(_ zone: String, _ file: String) throws -> J {
    try Fixtures.json("\(Fixtures.zonePath("transactions", zone))/\(file)")
}

private func hex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}

/// A fixture instant from its microseconds: an ambiguous wall time cannot be
/// re-derived from its ISO text.
private func instant(_ j: J, _ tz: TimeZone) -> DartDateTime {
    DartDateTime(microsecondsSinceEpoch: Int64(j["us"].int!), timeZone: tz)
}

/// Every field of a row, strings as UTF-16 (Dart compares code units).
private func fields(
    _ t: TransactionRecord, idMap: [String: String] = [:], instants: Bool = true
) -> [[UInt16]] {
    let id = idMap[t.id] ?? t.id
    let parts: [String] = [
        id, t.type.rawValue, t.description, hex(t.amount), t.category, t.date.toIso8601String(),
        String(t.date.microsecondsSinceEpoch), t.recurringTemplateId ?? "\u{0}null", t.tagIds.joined(separator: "\u{1}"),
        t.createdAt.toIso8601String(), String(t.createdAt.microsecondsSinceEpoch), t.updatedAt.toIso8601String(),
        String(t.updatedAt.microsecondsSinceEpoch),
    ]
    // A stored ISO string cannot say which of two equal wall times in a
    // repeated hour it means, so a reload compares the text only.
    return parts.enumerated().filter { instants || ![6, 10, 12].contains($0.offset) }.map { Array($0.element.utf16) }
}

private func fields(_ j: J) -> [[UInt16]] {
    let parts: [String] = [
        j["id"].string!, j["type"].string!, j["description"].string!, j["amount"].string!, j["category"].string!,
        j["date"]["iso"].string!, String(j["date"]["us"].int!), j["recurringTemplateId"].string ?? "\u{0}null",
        j["tagIds"].array.map { $0.string! }.joined(separator: "\u{1}"), j["createdAt"]["iso"].string!,
        String(j["createdAt"]["us"].int!), j["updatedAt"]["iso"].string!, String(j["updatedAt"]["us"].int!),
    ]
    return parts.map { Array($0.utf16) }
}

private func fields(_ t: RecurringTemplate, instants: Bool = true) -> [[UInt16]] {
    let parts: [String] = [
        t.id, t.type.rawValue, t.description, hex(t.amount), t.category, t.pattern.rawValue, t.startDate.toIso8601String(),
        String(t.startDate.microsecondsSinceEpoch), t.nextOccurrence.toIso8601String(),
        String(t.nextOccurrence.microsecondsSinceEpoch), t.dayOfMonth.map(String.init) ?? "null",
        t.dayOfWeek.map(String.init) ?? "null", String(t.isActive),
    ]
    return parts.enumerated().filter { instants || ![7, 9].contains($0.offset) }.map { Array($0.element.utf16) }
}

private func templateFields(_ j: J) -> [[UInt16]] {
    let parts: [String] = [
        j["id"].string!, j["type"].string!, j["description"].string!, j["amount"].string!, j["category"].string!,
        j["pattern"].string!, j["startDate"]["iso"].string!, String(j["startDate"]["us"].int!),
        j["nextOccurrence"]["iso"].string!, String(j["nextOccurrence"]["us"].int!), j["dayOfMonth"].int.map(String.init) ?? "null",
        j["dayOfWeek"].int.map(String.init) ?? "null", String(j["isActive"].bool!),
    ]
    return parts.map { Array($0.utf16) }
}

private func load(_ sections: JSONObject, calendar: DartCalendar, now: DartDateTime) -> FinancialData {
    FinancialData.load(
        FinancialSnapshot(revision: 1, sections: sections), preferences: InMemoryPreferences([:]), calendar: calendar,
        now: { now }, newID: { UUID().uuidString.lowercased() }
    ).data
}

private func initialSections(_ scenario: J) throws -> JSONObject {
    try scenario["initial"].string.map { try JSONParser.parse($0).objectValue! } ?? JSONObject()
}

/// The stored local date strings Dart rewrites (a gap time moves forward):
/// mapped to Dart's text in Swift's section, only those and only quoted.
private func normalised(_ text: String, _ gapTexts: [J]) -> String {
    var out = text
    for pair in gapTexts {
        out = out.replacingOccurrences(of: "\"\(pair[0].string!)\"", with: "\"\(pair[1].string!)\"")
    }
    return out
}

/// Ids that appear as `"id": <string>` in the stored initial sections.
private func storedIds(_ initial: JSONObject) -> Set<String> {
    var ids = Set<String>()
    func walk(_ value: JSONValue) {
        switch value {
        case .array(let items): items.forEach(walk)
        case .object(let object):
            if let id = object["id"]?.stringValue { ids.insert(id) }
            object.members.forEach { walk($0.value) }
        default: break
        }
    }
    initial.members.forEach { walk($0.value) }
    return ids
}

@Suite("Transactions: add, update, delete and recurring templates match the Flutter models (Fixtures/transactions)")
struct TransactionMutationParityTests {
    /// Real `TransactionModel` calls through a real store, replayed on
    /// `FinancialData`: after every call the two agree on the returned value,
    /// on whether a write is due, and on every field of every row (dates as
    /// instants); for data Dart wrote itself the stored section is byte
    /// identical. Whatever Swift wrote loads back to the same memory.
    @Test("mutation scenarios", arguments: transactionZones)
    func mutations(zone: String) throws {
        let f = try fixture(zone, "mutations.json")
        #expect(f["tz"].string == zone)
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let scenarios = f["scenarios"].array
        #expect(scenarios.count == 4)
        var unknownIds = 0, updatedAtBumps = 0, deletesMissing = 0
        for s in scenarios {
            let label = "\(zone) \(s["name"].string!)"
            let byteComparable = s["byteComparable"].bool!
            let gapTexts = s["gapTexts"].array
            var now = instant(s["launch"], tz)
            let initial = try initialSections(s)
            var data = load(initial, calendar: calendar, now: now)
            let loaded = s["loaded"].array
            #expect(data.transactions.count == loaded.count, "\(label) load count")
            // Rows Dart gave a fresh id get their own in Swift: same position.
            var idMap: [String: String] = [:]
            let known = storedIds(initial)
            for (row, dart) in zip(data.transactions, loaded) where row.id != dart["id"].string! {
                #expect(!known.contains(dart["id"].string!), "\(label) only generated ids differ")
                idMap[row.id] = dart["id"].string!
            }
            #expect(data.transactions.map { fields($0, idMap: idMap) } == loaded.map(fields), "\(label) load")
            var dartRewrote = false

            for (index, step) in s["steps"].array.enumerated() {
                let op = step["op"].string!
                if op == "clock" {
                    now = instant(step["now"], tz)
                    continue
                }
                let at = "\(label) step \(index) \(op)"
                #expect(instant(step["now"], tz) == now, "\(at) clock")
                /// The row a step names: its position (rows keep their order)
                /// or its id.
                func target(_ ref: J) -> String {
                    if let position = ref["index"].int { return data.transactions[position].id }
                    return ref["id"].string!
                }
                var swiftResult: Bool?
                switch op {
                case "add":
                    let record = data.addTransaction(
                        type: TransactionType(rawValue: step["type"].string!)!, description: step["description"].string!,
                        amount: bits(step["amount"])!, category: step["category"].string!, date: instant(step["date"], tz),
                        recurringTemplateId: step["template"].string, tagIds: step["tags"].array.map { $0.string! },
                        id: step["newId"].string!, now: now)
                    #expect(record.createdAt == now && record.updatedAt == now, "\(at) stamps")
                    swiftResult = true
                case "addMany":
                    let rows = step["rows"].array, ids = step["newIds"].array
                    #expect(rows.count == ids.count && rows.count >= 34, "\(at) many")
                    for (row, id) in zip(rows, ids) {
                        _ = data.addTransaction(
                            type: TransactionType(rawValue: row["type"].string!)!, description: row["description"].string!,
                            amount: bits(row["amount"])!, category: row["category"].string!, date: instant(row["date"], tz),
                            id: id.string!, now: now)
                    }
                    swiftResult = true
                case "update":
                    let id = target(step["ref"])
                    let dartID = step["ref"]["id"].string!
                    #expect(id == dartID || idMap[id] == dartID, "\(at) ref")
                    let tags: [String]? = step["tags"].string == "keep" ? nil : step["tags"].array.map { $0.string! }
                    let before = data.transactions.first { $0.id == id }
                    swiftResult = data.updateTransaction(
                        id: id,
                        .init(
                            type: TransactionType(rawValue: step["type"].string!)!, description: step["description"].string!,
                            amount: bits(step["amount"])!, category: step["category"].string!, date: instant(step["date"], tz),
                            tagIds: tags),
                        now: now)
                    if before == nil { unknownIds += 1 }
                    if let before, let after = data.transactions.first(where: { $0.id == id }) {
                        // id, createdAt and the template link survive the edit.
                        #expect(after.createdAt == before.createdAt && after.recurringTemplateId == before.recurringTemplateId, "\(at) kept")
                        if !now.isAfter(before.updatedAt) {
                            #expect(after.updatedAt == before.updatedAt.adding(microseconds: 1), "\(at) +1 us")
                            updatedAtBumps += 1
                        } else {
                            #expect(after.updatedAt == now, "\(at) updatedAt")
                        }
                    }
                case "delete":
                    let id = target(step["ref"])
                    let existed = data.transactions.contains { $0.id == id }
                    swiftResult = data.deleteTransaction(id: id)
                    if !existed { deletesMissing += 1 }
                default:
                    Issue.record("unknown op in \(at)")
                    continue
                }
                #expect(swiftResult == step["result"].bool, "\(at) result")
                if op == "update" || op == "delete" {
                    #expect(step["wrote"].bool == step["result"].bool, "\(at) Dart writes exactly when it found the row")
                }
                #expect(step["hasUnsavedChanges"].bool == false, "\(at) Dart save failed")
                if step["wrote"].bool == true { dartRewrote = true }
                #expect(data.transactions.map { fields($0, idMap: idMap) } == step["memory"].array.map(fields), "\(at) memory")
                let swiftSection = DartJSON.encodeString(data.transactionsSection())
                if byteComparable {
                    let dartSection = step["section"].string ?? (dartRewrote ? "[]" : nil)
                    if let dartSection {
                        let text = dartRewrote ? normalised(swiftSection, gapTexts) : swiftSection
                        #expect(Array(text.utf16) == Array(dartSection.utf16), "\(at) section:\n\(text)\n\(dartSection)")
                    }
                }
                // What Swift would write loads back as the same memory.
                var written = JSONObject()
                written[Section.transactions] = data.transactionsSection()
                #expect(
                    load(written, calendar: calendar, now: now).transactions.map { fields($0, instants: false) }
                        == data.transactions.map { fields($0, instants: false) },
                    "\(at) reload")
            }
        }
        #expect(unknownIds >= 1 && updatedAtBumps >= 8 && deletesMissing >= 2, "edge cases \(unknownIds) \(updatedAtBumps) \(deletesMissing)")
    }

    /// Real `RecurringTransactionModel` calls (the form's add and edit, delete)
    /// and `TransactionGenerator.generateDueTransactions` through a real store,
    /// replayed on `FinancialData`/`RecurringGenerator`. Everything agrees
    /// except the approved difference (Q2): Flutter's edit rewrites the
    /// template with its cursor at the start date and active, Swift's keeps
    /// them unless the schedule changed. Each edit step records Flutter's real
    /// row, which is checked against a fresh template, and the row Swift must
    /// write (computed with Dart's arithmetic), which Swift's `updateTemplate`
    /// must produce.
    @Test("recurring template scenarios", arguments: transactionZones)
    func templates(zone: String) throws {
        let f = try fixture(zone, "templates.json")
        #expect(f["tz"].string == zone)
        let tz = TimeZone(identifier: zone)!
        let calendar = DartCalendar(timeZone: tz)
        let scenarios = f["scenarios"].array
        #expect(scenarios.count == 4)
        var differing = 0, same = 0, generatedRows = 0, deleteMissing = 0
        for s in scenarios {
            let label = "\(zone) \(s["name"].string!)"
            let byteComparable = s["byteComparable"].bool!
            let gapTexts = s["gapTexts"].array
            var now = instant(s["launch"], tz)
            var data = load(try initialSections(s), calendar: calendar, now: now)
            #expect(data.templates.map { fields($0) } == s["loaded"]["templates"].array.map(templateFields), "\(label) load templates")
            #expect(data.transactions.map { fields($0) } == s["loaded"]["transactions"].array.map(fields), "\(label) load transactions")
            /// The latest section text Dart stored, by section.
            var dartSections: [String: String] = [:]

            for (index, step) in s["steps"].array.enumerated() {
                let op = step["op"].string!
                if op == "clock" {
                    now = instant(step["now"], tz)
                    continue
                }
                let at = "\(label) step \(index) \(op)"
                #expect(instant(step["now"], tz) == now, "\(at) clock")
                func target(_ ref: J) -> String {
                    if let position = ref["index"].int { return data.templates[position].id }
                    return ref["id"].string!
                }
                /// What the form's Save hands the model.
                func edit() -> RecurringTemplate.Edit {
                    RecurringForm.edit(
                        type: TransactionType(rawValue: step["type"].string!)!, description: step["description"].string!,
                        amount: bits(step["amount"])!, category: step["category"].string!,
                        pattern: RecurrencePattern(rawValue: step["pattern"].string!)!, start: instant(step["start"], tz),
                        dayOfMonth: step["dom"].int ?? 1)
                }
                var swiftWrote: Bool?
                switch op {
                case "addT":
                    let e = edit()
                    data.addTemplate(
                        .make(
                            id: step["newId"].string!, type: e.type, description: e.description, amount: e.amount,
                            category: e.category, pattern: e.pattern, startDate: e.startDate, dayOfMonth: e.dayOfMonth,
                            dayOfWeek: e.dayOfWeek))
                    swiftWrote = true
                case "generate":
                    var ids = step["newTransactionIds"].array.map { $0.string! }
                    let result = RecurringGenerator.generateDue(
                        in: &data, now: now, clock: { now }, newID: { ids.isEmpty ? "exhausted" : ids.removeFirst() })
                    #expect(ids.isEmpty, "\(at) every Dart id used")
                    #expect(result.generated.map(\.id) == step["newTransactionIds"].array.map { $0.string! }, "\(at) ids")
                    #expect(result.changed == (step["wrote"].bool == true), "\(at) writes")
                    generatedRows += result.generated.count
                case "editT":
                    let id = target(step["ref"])
                    let e = edit()
                    let existed = data.templates.contains { $0.id == id }
                    if existed, let dart = step["dartTemplates"].string {
                        // Flutter's real row: a fresh template, cursor at the start, active.
                        let fresh = RecurringTemplate.make(
                            id: id, type: e.type, description: e.description, amount: e.amount, category: e.category,
                            pattern: e.pattern, startDate: e.startDate, dayOfMonth: e.dayOfMonth, dayOfWeek: e.dayOfWeek)
                        let rows = try JSONParser.parse(dart).arrayValue!
                        let row = try #require(rows.first { $0.objectValue?["id"]?.stringValue == id })
                        #expect(
                            Array(DartJSON.encodeString(.object(fresh.raw)).utf16) == Array(DartJSON.encodeString(row).utf16),
                            "\(at) Flutter's edit is a fresh row")
                        if step["differs"].bool == true { differing += 1 } else { same += 1 }
                    }
                    swiftWrote = data.updateTemplate(id: id, e)
                    #expect(swiftWrote == existed, "\(at) found")
                case "deleteT":
                    let id = target(step["ref"])
                    let existed = data.templates.contains { $0.id == id }
                    swiftWrote = data.deleteTemplate(id: id)
                    #expect(swiftWrote == existed, "\(at) found")
                    if !existed {
                        // Flutter saves the unchanged list anyway; nothing changes.
                        deleteMissing += 1
                        #expect(step["wrote"].bool == true && step["sections"].keys.isEmpty, "\(at) Dart rewrites the same list")
                    } else {
                        #expect(step["wrote"].bool == true, "\(at) wrote")
                    }
                default:
                    Issue.record("unknown op in \(at)")
                    continue
                }
                if op == "addT" || op == "editT" {
                    #expect(swiftWrote == step["result"].bool, "\(at) result")
                }
                #expect(step["hasUnsavedChanges"].bool == false, "\(at) Dart save failed")
                #expect(data.templates.map { fields($0) } == step["templates"].array.map(templateFields), "\(at) templates")
                #expect(data.transactions.map { fields($0) } == step["transactions"].array.map(fields), "\(at) transactions")
                for name in step["sections"].keys { dartSections[name] = step["sections"][name].string }
                if byteComparable {
                    let swift: [String: JSONValue] = [
                        Section.recurringTransactions: data.templatesSection(), Section.transactions: data.transactionsSection(),
                    ]
                    for (name, dart) in dartSections {
                        let text = normalised(DartJSON.encodeString(swift[name]!), gapTexts)
                        #expect(Array(text.utf16) == Array(dart.utf16), "\(at) \(name):\n\(text)\n\(dart)")
                    }
                }
                // What Swift would write loads back as the same memory.
                var written = JSONObject()
                written[Section.recurringTransactions] = data.templatesSection()
                written[Section.transactions] = data.transactionsSection()
                let reloaded = load(written, calendar: calendar, now: now)
                #expect(
                    reloaded.templates.map { fields($0, instants: false) } == data.templates.map { fields($0, instants: false) },
                    "\(at) reload templates")
                #expect(
                    reloaded.transactions.map { fields($0, instants: false) } == data.transactions.map { fields($0, instants: false) },
                    "\(at) reload transactions")
            }
        }
        #expect(differing >= 6 && same >= 1 && generatedRows >= 30 && deleteMissing >= 1, "approved difference \(differing) \(same) \(generatedRows) \(deleteMissing)")
    }
}
