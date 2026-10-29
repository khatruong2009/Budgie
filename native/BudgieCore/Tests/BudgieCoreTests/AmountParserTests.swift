import Foundation
import Testing

@testable import BudgieCore

/// The decimal fields' locale-aware parse (D6), copied from the app's
/// AmountInputTests. The limit sheet's "above 0" rule stays in the app.
@Suite("AmountParser: typed amounts follow the money format's separators")
struct AmountParserTests {
    private let english = MoneyFormatter(currencyCode: "USD")
    private let german = MoneyFormatter(currencyCode: "EUR", locale: "de_DE")
    private let french = MoneyFormatter(currencyCode: "EUR", locale: "fr_FR")

    private func parse(_ text: String, _ formatter: MoneyFormatter) -> Double? {
        AmountParser.parse(text, formatter: formatter)
    }

    @Test("grouped amounts in their own locale")
    func grouped() {
        #expect(parse("1,500.00", english) == 1500)
        #expect(parse("1.500,00", german) == 1500)
        #expect(parse("1\u{202F}500,00", french) == 1500)
        #expect(parse("1,234,567.89", english) == 1_234_567.89)
        #expect(parse("100", english) == 100)
        #expect(parse("5.", english) == 5)
        #expect(parse(".5", english) == 0.5)
        #expect(parse(" 42.50 ", english) == 42.5)
    }

    @Test("a prefill round-trips through the parse")
    func prefillRoundTrips() {
        for formatter in [english, german, french] {
            #expect(parse(formatter.formatNumber(1500, decimalDigits: 2), formatter) == 1500)
            #expect(parse(formatter.formatNumber(0.25, decimalDigits: 2), formatter) == 0.25)
        }
    }

    @Test("a lone grouping separator is a decimal unless three digits follow")
    func loneGroupingSeparator() {
        #expect(parse("12,5", english) == 12.5)
        #expect(parse("1,500", english) == 1500)
        #expect(parse("12.5", german) == 12.5)
        #expect(parse("1.500", german) == 1500)
        #expect(parse("12.5", french) == 12.5)
        #expect(parse("1,5,0", english) == nil)
    }

    @Test("empty, signs, malformed, exponent and non-finite text is rejected; zero is accepted")
    func rejects() {
        for text in ["", "   ", ".", "-5", "+5", "abc", "1.2.3", "1e3", "NaN", "Infinity", "0x10", String(repeating: "9", count: 400)] {
            #expect(parse(text, english) == nil, "\(text.prefix(12))")
        }
        #expect(parse("1.2.3", german) == nil)
        #expect(parse("0", english) == 0)
        #expect(parse("0,00", german) == 0)
    }

    @Test("filter bounds follow the format")
    func filterBounds() {
        #expect(parse("12,5", english) == 12.5)
        #expect(parse("12,5", german) == 12.5)
        #expect(parse("1.234,56", german) == 1234.56)
        #expect(parse("1,234.56", english) == 1234.56)
        #expect(parse("1\u{202F}234,5", french) == 1234.5)
    }

    @Test("separators are read off the number format")
    func separators() {
        #expect(AmountParser.separators(english) == (",", "."))
        #expect(AmountParser.separators(german) == (".", ","))
    }
}
