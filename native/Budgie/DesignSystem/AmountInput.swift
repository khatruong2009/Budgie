import BudgieCore

/// The amount fields' prefix glyphs (parsing is `AmountParser` in BudgieCore).
enum AmountInput {
    /// The SF Symbol for an amount field's prefix glyph in the base
    /// currency (Flutter always shows `$`): the goal, allocation and rule
    /// forms.
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
