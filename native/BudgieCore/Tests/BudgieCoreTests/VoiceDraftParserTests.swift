import Foundation
import Testing

@testable import BudgieCore

/// budget_app/lib/common.dart `expenseCategories` / `incomeCategories` keys,
/// in order: what Flutter passes to `parseVoiceJson`.
let flutterExpenseNames = [
    "General", "Eating Out", "Groceries", "Housing", "Transportation", "Travel", "Clothing", "Gift", "Health",
    "Entertainment", "Pets", "Family", "Loan Payment",
]
let flutterIncomeNames = ["Salary", "Investment", "Gift", "Other"]

/// A JSON string value; string literals in `jsonOutput` calls become these.
func js(_ text: String) -> JSONValue { .string(JSONString(text)) }

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(JSONString(value)) }
}

let newYork = DartCalendar(timeZone: TimeZone(identifier: "America/New_York")!)

/// The Dart tests' fixed "today": includes a time component so future-date
/// clamping can be exercised against same-day dates that parse to midnight.
let voiceToday = newYork.date(2026, 7, 7, 12, 0, 0)

/// The Dart tests' `jsonOutput`: a model reply with only the given fields.
func jsonOutput(
    type: JSONValue? = nil, description: JSONValue? = nil, amount: JSONValue? = nil, category: JSONValue? = nil,
    date: JSONValue? = nil, extra: [(String, JSONValue)] = []
) -> String {
    var fields: [(String, JSONValue)] = []
    if let type { fields.append(("type", type)) }
    if let description { fields.append(("description", description)) }
    if let amount { fields.append(("amount", amount)) }
    if let category { fields.append(("category", category)) }
    if let date { fields.append(("date", date)) }
    fields.append(contentsOf: extra)
    return DartJSON.encodeString(.object(JSONObject(ordered: fields)))
}

func parse(
    _ output: String, _ transcript: String, expense: [String] = flutterExpenseNames,
    income: [String] = flutterIncomeNames, today: DartDateTime = voiceToday
) throws(VoiceEntryError) -> VoiceDraft {
    try VoiceDraftParser.parse(
        modelOutput: output, transcript: transcript, today: today, expenseCategories: expense, incomeCategories: income)
}

@Suite("VoiceDraftParser: port of VoiceExpenseService.parseVoiceJson")
struct VoiceDraftParserTests {
    // MARK: type (voice_expense_service_test.dart group 'type')

    @Test("defaults to expense when type is missing")
    func typeMissing() throws {
        let draft = try parse(
            jsonOutput(description: "coffee", amount: .int(4), category: "Eating Out"), "coffee for four dollars")
        #expect(draft.type == .expense)
    }

    @Test("honors income when JSON says income")
    func typeIncome() throws {
        let draft = try parse(
            jsonOutput(type: "income", description: "paycheck", amount: .int(3000), category: "Salary"),
            "got paid three thousand")
        #expect(draft.type == .income)
    }

    @Test("clamps a garbage type value to expense")
    func typeGarbage() throws {
        let draft = try parse(
            jsonOutput(type: "refund-or-something", description: "stuff", amount: .int(10), category: "General"),
            "bought stuff")
        #expect(draft.type == .expense)
    }

    @Test("a non-string type value falls back to expense")
    func typeNonString() throws {
        let draft = try parse(
            jsonOutput(type: .int(42), description: "stuff", amount: .int(10), category: "General"), "bought stuff")
        #expect(draft.type == .expense)
    }

    // MARK: category (group 'category exact-match clamp and fallback')

    @Test("valid expense category passes through")
    func categoryValidExpense() throws {
        let draft = try parse(
            jsonOutput(type: "expense", description: "chipotle", amount: .double(12.5), category: "Eating Out"),
            "twelve fifty for lunch at chipotle")
        #expect(draft.category == "Eating Out")
    }

    @Test("unknown expense category falls back to General")
    func categoryUnknownExpense() throws {
        let draft = try parse(
            jsonOutput(type: "expense", description: "mystery", amount: .int(5), category: "Not A Real Category"),
            "spent five on a mystery")
        #expect(draft.category == "General")
    }

    @Test("valid income category passes through")
    func categoryValidIncome() throws {
        let draft = try parse(
            jsonOutput(type: "income", description: "dividends", amount: .int(100), category: "Investment"),
            "got a hundred in dividends")
        #expect(draft.category == "Investment")
    }

    @Test("unknown income category falls back to Other")
    func categoryUnknownIncome() throws {
        let draft = try parse(
            jsonOutput(type: "income", description: "windfall", amount: .int(500), category: "Bonus"),
            "received five hundred bonus")
        #expect(draft.category == "Other")
    }

    @Test("an expense category is not honored for an income type")
    func categoryExpenseNameForIncome() throws {
        // "Groceries" is an expense category, invalid for income -> Other.
        let draft = try parse(
            jsonOutput(type: "income", description: "thing", amount: .int(20), category: "Groceries"), "income thing")
        #expect(draft.category == "Other")
    }

    @Test("missing category falls back per type (expense -> General)")
    func categoryMissingExpense() throws {
        let draft = try parse(jsonOutput(type: "expense", description: "thing", amount: .int(7)), "spent seven")
        #expect(draft.category == "General")
    }

    @Test("missing category falls back per type (income -> Other)")
    func categoryMissingIncome() throws {
        let draft = try parse(jsonOutput(type: "income", description: "thing", amount: .int(7)), "earned seven")
        #expect(draft.category == "Other")
    }

    @Test("a non-string category falls back")
    func categoryNonString() throws {
        let draft = try parse(
            jsonOutput(type: "expense", description: "thing", amount: .int(7), category: .int(99)), "spent seven")
        #expect(draft.category == "General")
    }

    // MARK: amount (group 'amount')

    @Test("numeric double is honored")
    func amountDouble() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out"), "twelve fifty lunch")
        #expect(draft.amount == 12.5)
    }

    @Test("numeric integer is coerced to double")
    func amountInteger() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .int(3000), category: "Eating Out"), "three thousand")
        #expect(draft.amount == 3000.0)
    }

    @Test("string amount like \"12.50\" is parsed to double")
    func amountString() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: "12.50", category: "Eating Out"), "twelve fifty lunch")
        #expect(draft.amount == 12.5)
    }

    @Test("unparseable string amount becomes 0.0 sentinel")
    func amountUnparseableString() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: "a lot", category: "Eating Out"), "a lot for lunch")
        #expect(draft.amount == 0.0)
    }

    @Test("missing amount becomes 0.0 sentinel")
    func amountMissing() throws {
        let draft = try parse(jsonOutput(description: "lunch", category: "Eating Out"), "lunch")
        #expect(draft.amount == 0.0)
    }

    @Test("negative amount is clamped to 0.0")
    func amountNegative() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .int(-5), category: "Eating Out"), "negative five")
        #expect(draft.amount == 0.0)
        #expect(draft.amount.sign == .plus)
    }

    @Test("a boolean amount becomes 0.0 sentinel")
    func amountBoolean() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .bool(true), category: "Eating Out"), "lunch")
        #expect(draft.amount == 0.0)
    }

    // MARK: description (group 'description')

    @Test("valid description passes through (trimmed)")
    func descriptionTrimmed() throws {
        let draft = try parse(
            jsonOutput(description: "  Chipotle  ", amount: .double(12.5), category: "Eating Out"),
            "twelve fifty at chipotle")
        #expect(draft.description == "Chipotle")
    }

    @Test("missing description falls back to the raw transcript")
    func descriptionMissing() throws {
        let draft = try parse(
            jsonOutput(amount: .double(12.5), category: "Eating Out"), "twelve fifty at chipotle")
        #expect(draft.description == "twelve fifty at chipotle")
    }

    @Test("empty/whitespace description falls back to the raw transcript")
    func descriptionWhitespace() throws {
        let draft = try parse(
            jsonOutput(description: "   ", amount: .double(12.5), category: "Eating Out"), "twelve fifty at chipotle")
        #expect(draft.description == "twelve fifty at chipotle")
    }

    @Test("a non-string description falls back to the raw transcript")
    func descriptionNonString() throws {
        let draft = try parse(
            jsonOutput(description: .int(123), amount: .double(12.5), category: "Eating Out"),
            "twelve fifty at chipotle")
        #expect(draft.description == "twelve fifty at chipotle")
    }

    // MARK: date (group 'date')

    @Test("recent explicit past date passes through")
    func dateRecentPast() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out", date: "2026-06-20"),
            "lunch on june 20")
        #expect(draft.date == newYork.date(2026, 6, 20))
    }

    @Test("missing date defaults to today")
    func dateMissing() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out"), "lunch")
        #expect(draft.date == voiceToday)
    }

    @Test("invalid date string defaults to today")
    func dateInvalid() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out", date: "not-a-date"),
            "lunch")
        #expect(draft.date == voiceToday)
    }

    @Test("a non-string date defaults to today")
    func dateNonString() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out", date: .int(20_260_315)),
            "lunch")
        #expect(draft.date == voiceToday)
    }

    @Test("future date is clamped to today")
    func dateFuture() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out", date: "2030-01-01"),
            "lunch next decade")
        #expect(draft.date == voiceToday)
    }

    @Test("date at the 90-day lookback boundary passes through")
    func dateLookbackBoundary() throws {
        // today is 2026-07-07, so 2026-04-08 is exactly 90 days back.
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out", date: "2026-04-08"),
            "that lunch back in april")
        #expect(draft.date == newYork.date(2026, 4, 8))
    }

    @Test("date older than the 90-day lookback falls back to today")
    func dateBeyondLookback() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out", date: "2026-04-07"),
            "lunch")
        #expect(draft.date == voiceToday)
    }

    @Test("a future trip mis-resolved into last year falls back to today")
    func dateFutureTripLastYear() throws {
        // Regression: "hotel for our trip in September" spoken in July 2026.
        let draft = try parse(
            jsonOutput(description: "Hotel", amount: .int(280), category: "Travel", date: "2025-09-12"),
            "two eighty for the hotel for our trip in september")
        #expect(draft.date == voiceToday)
    }

    @Test("an ancient date falls back to today")
    func dateAncient() throws {
        let draft = try parse(
            jsonOutput(description: "lunch", amount: .double(12.5), category: "Eating Out", date: "1985-06-01"),
            "lunch in the eighties")
        #expect(draft.date == voiceToday)
    }
}
