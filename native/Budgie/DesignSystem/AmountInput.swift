import BudgieCore

/// The amount fields' helpers: the parse itself lives in BudgieCore
/// (`AmountParser`); the symbols below are for the field prefix glyph.
enum AmountInput {
    /// The amount typed into a field (see `AmountParser.parse`).
    nonisolated static func parse(_ text: String, formatter: MoneyFormatter) -> Double? {
        AmountParser.parse(text, formatter: formatter)
    }

    /// The SF Symbol for an amount field's prefix glyph in the base
    /// currency (Flutter always shows `$`): the transaction form and the
    /// Worth editor.
    nonisolated static func currencySymbolName(_ formatter: MoneyFormatter) -> String {
        switch formatter.currencyCode {
        case "USD", "CAD", "AUD", "MXN": "dollarsign"
        case "EUR": "eurosign"
        case "GBP": "sterlingsign"
        case "JPY", "CNY": "yensign"
        case "INR": "indianrupeesign"
        case "KRW": "wonsign"
        case "BRL": "brazilianrealsign"
        default: "banknote"
        }
    }

    /// The base currency's symbol for a field prefix (Flutter hard-codes
    /// "$"): the currency format of 0 without its digits and spaces.
    nonisolated static func currencySymbol(_ formatter: MoneyFormatter) -> String {
        var visible = formatter
        visible.hideBalances = false
        let symbol = visible.format(0, decimalDigits: 0).filter { !("0"..."9").contains($0) && !$0.isWhitespace }
        return symbol.isEmpty ? "$" : symbol
    }
}
