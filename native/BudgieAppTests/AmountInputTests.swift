import BudgieCore
import XCTest

@testable import Runner

/// The decimal fields' locale-aware parse (D6), shared by the budget limit
/// sheet (a limit above 0) and the Flow SEE ALL Min / Max amounts (0 and
/// up). Flutter's limit strips `[^0-9.]` ("1.500,00" is 1.5) and its filter
/// drops ',' ("12,5" is 125).
final class AmountInputTests: XCTestCase {
    private let english = MoneyFormatter(currencyCode: "USD")
    private let german = MoneyFormatter(currencyCode: "EUR", locale: "de_DE")
    private let french = MoneyFormatter(currencyCode: "EUR", locale: "fr_FR")

    /// The budget limit: an edited field (no stored limit), above 0.
    private func parse(_ text: String, _ formatter: MoneyFormatter) -> Double? {
        BudgetLimitSheet.limit(text: text, prefill: "", currentLimit: nil, formatter: formatter)
    }

    func testGroupedAmountsInTheirOwnLocale() {
        XCTAssertEqual(parse("1,500.00", english), 1500)
        XCTAssertEqual(parse("1.500,00", german), 1500)
        XCTAssertEqual(parse("1\u{202F}500,00", french), 1500)
        XCTAssertEqual(parse("1,234,567.89", english), 1_234_567.89)
        XCTAssertEqual(parse("100", english), 100)
        XCTAssertEqual(parse("5.", english), 5)
        XCTAssertEqual(parse(".5", english), 0.5)
        XCTAssertEqual(parse(" 42.50 ", english), 42.5)
    }

    /// The prefill round-trips through the parse.
    func testPrefillRoundTrips() {
        for formatter in [english, german, french] {
            XCTAssertEqual(parse(formatter.formatNumber(1500, decimalDigits: 2), formatter), 1500)
            XCTAssertEqual(parse(formatter.formatNumber(0.25, decimalDigits: 2), formatter), 0.25)
        }
    }

    /// A keyboard from another locale types the other decimal key.
    func testLoneGroupingSeparatorIsADecimalUnlessThreeDigitsFollow() {
        XCTAssertEqual(parse("12,5", english), 12.5)
        XCTAssertEqual(parse("1,500", english), 1500)
        XCTAssertEqual(parse("12.5", german), 12.5)
        XCTAssertEqual(parse("1.500", german), 1500)
        XCTAssertEqual(parse("12.5", french), 12.5)
        XCTAssertNil(parse("1,5,0", english))
    }

    func testLimitRejectsEmptyZeroNegativeAndNonNumericText() {
        XCTAssertNil(parse("", english))
        XCTAssertNil(parse(".", english))
        XCTAssertNil(parse("0", english))
        XCTAssertNil(parse("0.00", english))
        XCTAssertNil(parse("-5", english))
        XCTAssertNil(parse("abc", english))
        XCTAssertNil(parse("1.2.3", english))
        XCTAssertNil(parse("1.2.3", german))
    }

    /// Dart `tryParse` accepts exponents and "Infinity"; the field does not
    /// (Flutter's strip turned "1e3" into 13).
    func testRejectsExponentsAndNonFiniteValues() {
        XCTAssertNil(parse("1e3", english))
        XCTAssertNil(parse("Infinity", english))
        XCTAssertNil(parse("NaN", english))
        XCTAssertNil(parse(String(repeating: "9", count: 400), english))
    }

    func testSeparatorsAndCurrencySymbolFollowTheFormat() {
        XCTAssertTrue(AmountParser.separators(english) == (",", "."))
        XCTAssertTrue(AmountParser.separators(german) == (".", ","))
        XCTAssertEqual(AmountInput.currencySymbol(english), "$")
        XCTAssertEqual(AmountInput.currencySymbol(german), "\u{20AC}")
        XCTAssertEqual(AmountInput.currencySymbol(MoneyFormatter(currencyCode: "BRL")), "R$")
        XCTAssertEqual(
            AmountInput.currencySymbol(MoneyFormatter(currencyCode: "GBP", hideBalances: true)), "\u{00A3}")
    }

    /// Filter bounds take 0 and up; blank or unreadable text is no bound.
    func testFilterBoundsAcceptZeroAndFollowTheFormat() {
        func bound(_ text: String, _ formatter: MoneyFormatter) -> Double? { AmountInput.parse(text, formatter: formatter) }
        XCTAssertEqual(bound("0", english), 0)
        XCTAssertEqual(bound("0,00", german), 0)
        XCTAssertEqual(bound("12,5", english), 12.5, "Flutter drops the comma: 125")
        XCTAssertEqual(bound("12,5", german), 12.5)
        XCTAssertEqual(bound("1.234,56", german), 1234.56, "Flutter reads 1.23456")
        XCTAssertEqual(bound("1,234.56", english), 1234.56)
        XCTAssertEqual(bound("1\u{202F}234,5", french), 1234.5)
        XCTAssertNil(bound("", english))
        XCTAssertNil(bound("   ", english))
        XCTAssertNil(bound("-5", english))
        XCTAssertNil(bound("+5", english))
        XCTAssertNil(bound("1e3", english))
        XCTAssertNil(bound("NaN", english))
        XCTAssertNil(bound("Infinity", english))
        XCTAssertNil(bound("0x10", english))
    }

    /// An untouched prefill saves the stored limit exactly; any edit parses.
    func testUnchangedPrefillKeepsTheStoredLimit() {
        func limit(_ text: String, stored: Double?) -> Double? {
            let prefill = stored.map { english.formatNumber($0, decimalDigits: 2) } ?? ""
            return BudgetLimitSheet.limit(text: text, prefill: prefill, currentLimit: stored, formatter: english)
        }
        XCTAssertEqual(english.formatNumber(99.999, decimalDigits: 2), "100.00")
        XCTAssertEqual(limit("100.00", stored: 99.999), 99.999)
        XCTAssertEqual(limit("0.00", stored: 0.001), 0.001, "a tiny stored limit stays saveable")
        XCTAssertEqual(limit("100.0", stored: 99.999), 100, "an edit parses")
        XCTAssertNil(limit("", stored: 99.999))
        XCTAssertNil(limit("", stored: nil))
        XCTAssertEqual(limit("12.5", stored: nil), 12.5)
    }
}

/// `_BudgetRow._formatCurrency`: whole units from 100 up, else cents,
/// decided on the unrounded value.
final class BudgetAmountFormatTests: XCTestCase {
    private let english = MoneyFormatter(currencyCode: "USD")

    func testWholeUnitsFromOneHundredElseCents() {
        XCTAssertEqual(HomeSummary.budgetAmount(99.999, formatter: english), "$100.00")
        XCTAssertEqual(HomeSummary.budgetAmount(99.99, formatter: english), "$99.99")
        XCTAssertEqual(HomeSummary.budgetAmount(100, formatter: english), "$100")
        XCTAssertEqual(HomeSummary.budgetAmount(150, formatter: english), "$150")
        XCTAssertEqual(HomeSummary.budgetAmount(1500, formatter: english), "$1,500")
        XCTAssertEqual(HomeSummary.budgetAmount(42.5, formatter: english), "$42.50")
        XCTAssertEqual(HomeSummary.budgetAmount(0, formatter: english), "$0.00")
    }
}
