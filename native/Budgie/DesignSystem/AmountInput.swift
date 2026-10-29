import BudgieCore

/// Reading amounts typed into the app's decimal fields (D6): the budget
/// limit sheet and the Flow SEE ALL page's Min / Max amounts. Flutter uses
/// en-US-only parsing there (the limit strips `[^0-9.]`, reading "1.500,00"
/// as 1.5; the filters drop ',' and `tryParse`, reading "12,5" as 125), so a
/// comma-decimal keyboard cannot type a fraction. These follow the money
/// format's separators instead.
enum AmountInput {
    /// The amount typed into a field, or nil unless it is a finite amount of
    /// 0 or more; callers that need more (a limit above 0) check it. Grouping
    /// separators are dropped and the decimal separator becomes ".".
    /// Without a decimal separator, a lone grouping separator that is not
    /// followed by exactly three digits is the decimal key of a keyboard whose
    /// locale differs from the app's format ("12,5" under en_US is 12.5;
    /// "1,500" is 1500). Only digits and separators are accepted, so Dart
    /// `tryParse`'s signs, exponents, "Infinity" and "NaN" are rejected
    /// ("-5", "1e3").
    nonisolated static func parse(_ text: String, formatter: MoneyFormatter) -> Double? {
        let (grouping, decimal) = separators(formatter)
        // Spaces never matter, including the no-break spaces some locales group with.
        var normalized = text.filter { !$0.isWhitespace }
        let group = grouping.filter { !$0.isWhitespace }
        if normalized.contains(decimal) {
            if !group.isEmpty { normalized = normalized.replacingOccurrences(of: group, with: "") }
            normalized = normalized.replacingOccurrences(of: decimal, with: ".")
        } else if !group.isEmpty, normalized.contains(group) {
            let parts = normalized.components(separatedBy: group)
            if !parts[0].isEmpty, parts.dropFirst().allSatisfy({ $0.count == 3 }) {
                normalized = parts.joined()
            } else if parts.count == 2 {
                normalized = parts.joined(separator: ".")
            } else {
                return nil
            }
        }
        guard !normalized.isEmpty, normalized.allSatisfy({ $0 == "." || ("0"..."9").contains($0) }),
            let value = DartDouble.tryParse(normalized), value.isFinite
        else { return nil }
        return value
    }

    /// The number format's grouping and decimal separators, read off
    /// `formatNumber(1234.5)` ("1,234.5", "1.234,5", "1 234,5").
    nonisolated static func separators(_ formatter: MoneyFormatter) -> (grouping: String, decimal: String) {
        var runs: [String] = []
        var current = ""
        for character in formatter.formatNumber(1234.5, decimalDigits: 1) {
            if ("0"..."9").contains(character) {
                if !current.isEmpty { runs.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.count == 2 ? (runs[0], runs[1]) : (",", ".")
    }

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
