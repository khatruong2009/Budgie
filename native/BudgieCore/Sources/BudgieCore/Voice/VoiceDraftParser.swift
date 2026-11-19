import Foundation

/// A transaction as the model described it, before the confirmation sheet.
/// No id or timestamps: the sheet hands these fields to the add form.
public struct VoiceDraft: Hashable, Sendable {
    public var type: TransactionType
    public var description: String
    public var amount: Double
    public var category: String
    public var date: DartDateTime

    public init(type: TransactionType, description: String, amount: Double, category: String, date: DartDateTime) {
        self.type = type
        self.description = description
        self.amount = amount
        self.category = category
        self.date = date
    }
}

/// `VoiceExpenseService.parseVoiceJson` (voice_expense_service.dart): the
/// model's JSON reply, cleaned up into a draft. Branch for branch the same
/// as Flutter, so a reply that Flutter accepts, clamps or rejects gets the
/// same treatment here (see Fixtures/voice).
public enum VoiceDraftParser {
    /// How far back a spoken date may plausibly reach
    /// (`maxSpokenDateLookbackDays`).
    static let maxSpokenDateLookbackDays = 90

    /// `expenseCategories` / `incomeCategories` are the names the model was
    /// offered (Flutter passes its built-in maps' keys). A category outside
    /// the list becomes "General" (expense) or "Other" (income), even when
    /// that fallback is not itself in the list.
    public static func parse(
        modelOutput: String,
        transcript: String,
        today: DartDateTime,
        expenseCategories: [String],
        incomeCategories: [String]
    ) throws(VoiceEntryError) -> VoiceDraft {
        let raw = stripFence(DartString.trim(modelOutput))

        // `decoded is! Map<String, dynamic>` and any decode failure are the
        // same outcome.
        guard let root = try? JSONParser.parse(raw), let json = root.objectValue else {
            throw .unreadable(transcript: transcript)
        }

        if json.contains("error") {
            throw .notATransaction(transcript: transcript)
        }

        // `json['type'] == 'income'`: a UTF-16 comparison of a String only.
        let type: TransactionType = if case .string(let text)? = json["type"], text.matches("income") { .income } else { .expense }

        let categories = type == .income ? incomeCategories : expenseCategories
        // `Iterable.contains` is `==`, which is code-unit equality.
        let category =
            if case .string(let text)? = json["category"], let match = categories.first(where: text.matches) {
                match
            } else {
                type == .income ? "Other" : "General"
            }

        var amount = 0.0
        switch json["amount"] {
        case .number(let number)?:
            amount = number.doubleValue
        case .string(let text)?:
            amount = DartDouble.tryParse(text.value) ?? 0.0
        default:
            break
        }
        // `-0.0 < 0` is false, so a negative zero survives, as in Dart.
        if amount.isNaN || amount.isInfinite || amount < 0 {
            amount = 0.0
        }

        var description = transcript
        if case .string(let text)? = json["description"] {
            let trimmed = DartString.trim(text.value)
            if !trimmed.isEmpty { description = trimmed }
        }

        var date = today
        if case .string(let text)? = json["date"],
            let parsed = DartDateTime.tryParse(text.value, timeZone: today.timeZone)
        {
            date = parsed
        }
        // Recent spoken dates only: anything older is almost always the model
        // resolving a future event into a previous year. Calendar arithmetic
        // in the zone of `today`, like `DateTime(y, m, d - 90)`.
        let earliestPlausible = DartCalendar(timeZone: today.timeZone).date(
            today.year, today.month, today.day - maxSpokenDateLookbackDays)
        if date.isAfter(today) || date.isBefore(earliestPlausible) {
            date = today
        }

        return VoiceDraft(type: type, description: description, amount: amount, category: category, date: date)
    }

    /// The reply with a Markdown code fence removed:
    /// `replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '')`, then a trailing
    /// "```" dropped and the rest trimmed. `raw` is already trimmed.
    private static func stripFence(_ raw: String) -> String {
        var units = Array(raw.utf16)
        let fence: [UInt16] = [0x60, 0x60, 0x60]
        guard units.starts(with: fence) else { return raw }

        var index = fence.count
        while index < units.count, isASCIILetter(units[index]) { index += 1 }
        if index < units.count, units[index] == 0x0A { index += 1 }
        units.removeFirst(index)

        if units.count >= fence.count, units.suffix(fence.count).elementsEqual(fence) {
            units.removeLast(fence.count)
        }
        return DartString.trim(String(decoding: units, as: UTF16.self))
    }

    private static func isASCIILetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }
}
