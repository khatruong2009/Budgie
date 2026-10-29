import Foundation
import Testing

@testable import BudgieCore

/// Fixtures written by native/ParityHarness/parity/voice_fixtures_test.dart
/// from the real VoiceExpenseService.parseVoiceJson.
private let voiceZones = [
    "America/New_York", "UTC", "Australia/Lord_Howe", "Asia/Kolkata", "America/Santiago", "Asia/Beirut",
]

private func voiceFixture(_ zone: String) throws -> J {
    try Fixtures.json("\(Fixtures.zonePath("voice", zone))/parse.json")
}

private func voiceHex(_ value: Double) -> String {
    let text = String(value.bitPattern, radix: 16)
    return String(repeating: "0", count: 16 - text.count) + text
}

/// Dart string equality (code units; Swift `==` is canonical equivalence).
private func voiceSame(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case (let a?, let b?): DartString.equal(a, b)
    default: false
    }
}

@Suite("Voice: VoiceDraftParser matches VoiceExpenseService.parseVoiceJson (Fixtures/voice)")
struct VoiceParityTests {
    @Test("every recorded model reply, in every zone", arguments: voiceZones)
    func matchesDart(_ zone: String) throws {
        let f = try voiceFixture(zone)
        #expect(f["tz"].string == zone)
        let timeZone = TimeZone(identifier: zone)!
        let defaultExpense = f["expense"].array.map { $0.string! }
        let defaultIncome = f["income"].array.map { $0.string! }
        #expect(defaultExpense.count == 13 && defaultIncome.count == 4)

        let cases = f["cases"].array
        #expect(cases.count >= 60)

        var problems: [String] = []
        var accepted = 0
        var errors = 0
        var utcDates = 0
        var clamped = 0
        for item in cases {
            let name = item["name"].string!
            let expected = item["result"]
            let today = DartDateTime(
                microsecondsSinceEpoch: Int64(item["todayUs"].int!), isUtc: false, timeZone: timeZone)
            let expense = item["expense"].value == nil ? defaultExpense : item["expense"].array.map { $0.string! }
            let income = item["income"].value == nil ? defaultIncome : item["income"].array.map { $0.string! }

            let draft: VoiceDraft
            do {
                draft = try VoiceDraftParser.parse(
                    modelOutput: item["raw"].string!, transcript: item["transcript"].string!, today: today,
                    expenseCategories: expense, incomeCategories: income)
            } catch {
                errors += 1
                let transcript = item["transcript"].string!
                switch (expected["error"].string, error) {
                case ("unreadable", .unreadable(let actual)), ("notATransaction", .notATransaction(let actual)):
                    if !voiceSame(actual, expected["transcript"].string) || !voiceSame(actual, transcript) {
                        problems.append("\(name): transcript \(actual) vs \(expected["transcript"].string ?? "nil")")
                    }
                default:
                    problems.append("\(name): Swift threw \(error), Dart \(expected["error"].string ?? "returned")")
                }
                continue
            }
            guard expected["type"].string != nil else {
                problems.append("\(name): Dart \(expected["error"].string ?? expected["threw"].string ?? "?"), Swift returned")
                continue
            }
            accepted += 1

            if draft.type.rawValue != expected["type"].string {
                problems.append("\(name): type \(draft.type) vs \(expected["type"].string!)")
            }
            if !voiceSame(draft.description, expected["description"].string) {
                problems.append("\(name): description «\(draft.description)» vs «\(expected["description"].string!)»")
            }
            if voiceHex(draft.amount) != expected["amountBits"].string {
                problems.append(
                    "\(name): amount \(draft.amount) (\(voiceHex(draft.amount))) vs \(expected["amount"].string!) (\(expected["amountBits"].string!))"
                )
            }
            if !voiceSame(draft.category, expected["category"].string) {
                problems.append("\(name): category «\(draft.category)» vs «\(expected["category"].string!)»")
            }
            if draft.date.microsecondsSinceEpoch != Int64(expected["dateUs"].int!) || draft.date.isUtc != expected["dateUtc"].bool {
                problems.append(
                    "\(name): date \(draft.date.microsecondsSinceEpoch) utc \(draft.date.isUtc) vs \(expected["dateUs"].int!) utc \(expected["dateUtc"].bool ?? false) (\(expected["dateIso"].string!))"
                )
            }
            if draft.date.isUtc { utcDates += 1 }
            if draft.date == today { clamped += 1 }
        }
        #expect(problems.isEmpty, "\(problems.count) differences in \(zone): \(problems.prefix(25))")

        // The corpus reaches the branches it is meant to.
        #expect(accepted > 1000 && errors > 40)
        #expect(utcDates > 100 && clamped > 300)
    }

    @Test("case names are unique, and the corpus covers each area", arguments: ["UTC"])
    func corpusShape(_ zone: String) throws {
        let cases = try voiceFixture(zone)["cases"].array
        let names = cases.map { $0["name"].string! }
        #expect(Set(names).count == names.count)
        for area in [
            "type ", "category expense ", "category income ", "category near-miss", "category custom list", "amount number",
            "amount string", "description ", "date ", "date rel ",
        ] {
            #expect(names.contains { $0.hasPrefix(area) }, "no case named \(area)…")
        }
        // Every model reply fixture is a string, and none is empty by accident.
        #expect(cases.allSatisfy { $0["raw"].string != nil })
    }
}
