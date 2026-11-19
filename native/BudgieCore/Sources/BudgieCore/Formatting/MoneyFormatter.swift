import Foundation

/// Display formatting for money, ported from `lib/money_formatter.dart` and the parts of
/// `package:intl` 0.20.2 (`NumberFormat.simpleCurrency`, `compactSimpleCurrency`,
/// `decimalPatternDigits`) that it uses.
///
/// Foundation's `NumberFormatter` is deliberately not used: ICU rounds the exact decimal
/// expansion (half-even by default) while intl rounds `fraction * 10^digits` as a `double`
/// (half away from zero), so ties such as 0.015 or 0.995 differ. Only the locales and
/// currencies the app offers are supported; any other locale string resolves to `en_US`
/// (intl's default), and any other currency code prints as its own code (intl's fallback).
public struct MoneyFormatter: Sendable {
    /// ISO 4217 code, e.g. "USD".
    public var currencyCode: String
    /// Underscore locale (e.g. "de_DE"); nil is "Match device", which intl resolves to en_US.
    public var locale: String?
    public var hideBalances: Bool

    public init(currencyCode: String = "USD", locale: String? = nil, hideBalances: Bool = false) {
        self.currencyCode = currencyCode
        self.locale = locale
        self.hideBalances = hideBalances
    }

    private static let hiddenText = "\u{2022}\u{2022}\u{2022}\u{2022}"

    /// `NumberFormat.simpleCurrency` (or `compactSimpleCurrency`) `.format(value)`.
    public func format(_ value: Double, decimalDigits: Int = 2, compact: Bool = false) -> String {
        if hideBalances { return Self.hiddenText }
        let data = IntlLocaleData.resolve(locale)
        let symbol = IntlLocaleData.simpleCurrencySymbol(currencyCode)
        let spec = IntlNumberSpec.currency(data: data, symbol: symbol, decimalDigits: decimalDigits)
        if compact {
            return spec.formatCompact(value, styles: data.compactCurrencyStyles, currencySymbol: symbol)
        }
        return spec.format(value)
    }

    /// Sign first (ASCII hyphen or plus), then the unsigned currency string of `abs(value)`.
    public func formatSigned(_ value: Double, decimalDigits: Int = 2, plusForPositive: Bool = false) -> String {
        if hideBalances { return Self.hiddenText }
        let sign = value < 0 ? "-" : (plusForPositive && value > 0 ? "+" : "")
        return sign + format(abs(value), decimalDigits: decimalDigits)
    }

    /// `NumberFormat.decimalPatternDigits`: grouped number with exactly `decimalDigits` decimals,
    /// no currency symbol. Not affected by `hideBalances`.
    public func formatNumber(_ value: Double, decimalDigits: Int = 2) -> String {
        let data = IntlLocaleData.resolve(locale)
        return IntlNumberSpec.decimal(data: data, decimalDigits: decimalDigits).format(value)
    }
}

// MARK: - Locale data (from intl 0.20.2 number_symbols_data.dart / constants.dart)

struct IntlLocaleData: Sendable {
    let decimalSeparator: String
    let groupSeparator: String
    /// CURRENCY_PATTERN split around the digits trunk; U+00A4 marks the currency symbol.
    let currencyPrefixPattern: String
    let currencySuffixPattern: String
    /// COMPACT_DECIMAL_SHORT_CURRENCY_PATTERN, ascending by exponent. Every entry has only
    /// an `other` plural form for the locales the app offers.
    let compactCurrencyPatterns: [(exponent: Int, pattern: String)]

    var compactCurrencyStyles: [CompactStyle] {
        compactCurrencyPatterns.map { CompactStyle(pattern: $0.pattern, exponent: $0.exponent) }
    }

    private static let english = IntlLocaleData(
        decimalSeparator: ".", groupSeparator: ",",
        currencyPrefixPattern: "\u{00A4}", currencySuffixPattern: "",
        compactCurrencyPatterns: [(3, "\u{00A4}0K"), (6, "\u{00A4}0M"), (9, "\u{00A4}0B"), (12, "\u{00A4}0T")])

    private static let german = IntlLocaleData(
        decimalSeparator: ",", groupSeparator: ".",
        currencyPrefixPattern: "", currencySuffixPattern: "\u{00A0}\u{00A4}",
        compactCurrencyPatterns: [
            (3, "0"), (4, "0"), (5, "0"),
            (6, "0\u{00A0}Mio.\u{00A0}\u{00A4}"),
            (9, "0\u{00A0}Mrd.\u{00A0}\u{00A4}"),
            (12, "0\u{00A0}Bio.\u{00A0}\u{00A4}"),
        ])

    private static let spanish = IntlLocaleData(
        decimalSeparator: ",", groupSeparator: ".",
        currencyPrefixPattern: "", currencySuffixPattern: "\u{00A0}\u{00A4}",
        compactCurrencyPatterns: [
            (3, "0\u{00A0}mil\u{00A0}\u{00A4}"),
            (6, "0\u{00A0}M\u{00A4}"),
            (10, "00\u{00A0}mil\u{00A0}M\u{00A4}"),
            (12, "0\u{00A0}B\u{00A4}"),
        ])

    private static let french = IntlLocaleData(
        decimalSeparator: ",", groupSeparator: "\u{202F}",
        currencyPrefixPattern: "", currencySuffixPattern: "\u{00A0}\u{00A4}",
        compactCurrencyPatterns: [
            (3, "0\u{00A0}k\u{00A0}\u{00A4}"),
            (6, "0\u{00A0}M\u{00A0}\u{00A4}"),
            (9, "0\u{00A0}Md\u{00A0}\u{00A4}"),
            (12, "0\u{00A0}Bn\u{00A0}\u{00A4}"),
        ])

    private static let japanese = IntlLocaleData(
        decimalSeparator: ".", groupSeparator: ",",
        currencyPrefixPattern: "\u{00A4}", currencySuffixPattern: "",
        compactCurrencyPatterns: [
            (3, "0"),
            (4, "\u{00A4}0\u{4E07}"),
            (8, "\u{00A4}0\u{5104}"),
            (12, "\u{00A4}0\u{5146}"),
            (16, "\u{00A4}0\u{4EAC}"),
        ])

    /// intl's locale fallback for the offered locales: en_US/en_CA/en_GB/en_AU share the `en`
    /// number data, de_DE -> de, fr_FR -> fr, es_ES -> es_ES (identical to es), ja_JP -> ja.
    /// nil and anything unknown resolve to en_US, like `Intl.defaultLocale ?? 'en_US'`.
    static func resolve(_ locale: String?) -> IntlLocaleData {
        guard let locale else { return english }
        switch locale.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased() {
        case "de": return german
        case "es": return spanish
        case "fr": return french
        case "ja": return japanese
        default: return english
        }
    }

    /// `constants.simpleCurrencySymbols[code] ?? code` for the currencies the app offers.
    static func simpleCurrencySymbol(_ code: String) -> String {
        switch code {
        case "USD", "CAD", "AUD", "MXN": return "$"
        case "EUR": return "\u{20AC}"
        case "GBP": return "\u{00A3}"
        case "JPY", "CNY": return "\u{00A5}"
        case "INR": return "\u{20B9}"
        case "KRW": return "\u{20A9}"
        case "BRL": return "R$"
        default: return code
        }
    }
}

// MARK: - Compact styles (compact_number_format.dart `_CompactStyle`)

struct CompactStyle: Sendable {
    let pattern: String
    let prefix: String
    let suffix: String
    let divisor: Int
    let exponent: Int

    /// `_CompactStyle.createStyle` for a pattern without a `;` negative part.
    init(pattern: String, exponent: Int) {
        self.pattern = pattern
        self.exponent = exponent
        // Regex `([^0]*)(0+)(.*)`: prefix, a run of zeros, suffix.
        let scalars = pattern.unicodeScalars
        let leading = scalars.prefix { $0 != "0" }
        let zeroRun = scalars[leading.endIndex...].prefix { $0 == "0" }
        self.prefix = String(leading)
        self.suffix = String(scalars[zeroRun.endIndex...])
        let onlyZeros = scalars.allSatisfy { $0 == "0" }
        self.divisor = (!zeroRun.isEmpty && !onlyZeros) ? intPow10(exponent - zeroRun.count + 1) : 1
    }

    var isFallback: Bool { pattern == "0" }
}

// MARK: - Number format engine (number_format.dart)

private let lnTen = log(10.0)

func intPow10(_ n: Int) -> Int {
    var result = 1
    var i = 0
    while i < n {
        result = result &* 10
        i += 1
    }
    return result
}

/// Dart `double.toInt()` / `round()` / `floor()` results, saturating instead of trapping.
private func saturatingInt(_ d: Double) -> Int {
    if d.isNaN { return 0 }
    if d >= 9.223372036854775807e18 { return Int.max }
    if d <= -9.223372036854775808e18 { return Int.min }
    return Int(d)
}

private func dartRound(_ d: Double) -> Int {
    saturatingInt(d.rounded(.toNearestOrAwayFromZero))
}

/// `NumberFormat.numberOfIntegerDigits` (threshold table, 19 at most).
func numberOfIntegerDigits(_ number: Double) -> Int {
    let a = abs(number)
    var threshold = 10.0
    var digits = 1
    while digits < 19 {
        if a < threshold { return digits }
        threshold *= 10
        digits += 1
    }
    return 19
}

struct IntlNumberSpec: Sendable {
    let decimalSeparator: String
    let groupSeparator: String
    let positivePrefix: String
    let positiveSuffix: String
    let negativePrefix: String
    let negativeSuffix: String
    let groupingSize = 3
    let finalGroupingSize = 3
    let minimumFractionDigits: Int
    let maximumFractionDigits: Int
    let isForCurrency: Bool
    let decimalDigits: Int

    /// `NumberFormat.simpleCurrency(locale, name:, decimalDigits:)`.
    static func currency(data: IntlLocaleData, symbol: String, decimalDigits: Int) -> IntlNumberSpec {
        let prefix = data.currencyPrefixPattern.replacingOccurrences(of: "\u{00A4}", with: symbol)
        let suffix = data.currencySuffixPattern.replacingOccurrences(of: "\u{00A4}", with: symbol)
        return IntlNumberSpec(
            decimalSeparator: data.decimalSeparator, groupSeparator: data.groupSeparator,
            positivePrefix: prefix, positiveSuffix: suffix,
            negativePrefix: "-" + prefix, negativeSuffix: suffix,
            minimumFractionDigits: decimalDigits, maximumFractionDigits: decimalDigits,
            isForCurrency: true, decimalDigits: decimalDigits)
    }

    /// `NumberFormat.decimalPatternDigits(locale, decimalDigits:)` with pattern `#,##0.###`.
    static func decimal(data: IntlLocaleData, decimalDigits: Int) -> IntlNumberSpec {
        IntlNumberSpec(
            decimalSeparator: data.decimalSeparator, groupSeparator: data.groupSeparator,
            positivePrefix: "", positiveSuffix: "",
            negativePrefix: "-", negativeSuffix: "",
            minimumFractionDigits: decimalDigits, maximumFractionDigits: decimalDigits,
            isForCurrency: false, decimalDigits: decimalDigits)
    }

    // MARK: Plain format

    func format(_ number: Double) -> String {
        formatAffixed(
            number, positivePrefix: positivePrefix, negativePrefix: negativePrefix,
            positiveSuffix: positiveSuffix, negativeSuffix: negativeSuffix,
            digits: FixedDigits(
                significantDigitsInUse: false, useDefaultSignificantDigits: true,
                minimumFractionDigits: minimumFractionDigits, groupingEnabled: true))
    }

    // MARK: Compact format (`_CompactNumberFormat.format`)

    func formatCompact(_ number: Double, styles: [CompactStyle], currencySymbol: String) -> String {
        if number.isNaN || number.isInfinite {
            // Dart would throw on rounding infinity; mirror the plain path instead of trapping.
            return format(number)
        }
        let style = compactStyle(for: number, styles: styles)
        let isFallback = style?.isFallback ?? true
        let divisor = isFallback ? 1 : style!.divisor
        let divided = number / Double(divisor)
        let formatted: String
        if let style, !isFallback {
            formatted = formatAffixed(
                divided, positivePrefix: style.prefix, negativePrefix: "-" + style.prefix,
                positiveSuffix: style.suffix, negativeSuffix: style.suffix,
                digits: FixedDigits(
                    significantDigitsInUse: true,
                    useDefaultSignificantDigits: true,
                    minimumFractionDigits: 0,  // overridden getter for non-fallback styles
                    groupingEnabled: false))
        } else {
            formatted = formatAffixed(
                divided, positivePrefix: positivePrefix, negativePrefix: negativePrefix,
                positiveSuffix: positiveSuffix, negativeSuffix: negativeSuffix,
                digits: FixedDigits(
                    significantDigitsInUse: true,
                    useDefaultSignificantDigits: !isForCurrency,
                    minimumFractionDigits: minimumFractionDigits,
                    groupingEnabled: false))
        }
        if isForCurrency, !isFallback, let range = formatted.range(of: "\u{00A4}") {
            return formatted.replacingCharacters(in: range, with: currencySymbol)
        }
        return formatted
    }

    /// `_CompactNumberFormat._styleFor`. nil means `_defaultCompactStyle`.
    private func compactStyle(for number: Double, styles: [CompactStyle]) -> CompactStyle? {
        if abs(number) < 10 { return nil }
        var rounded = number
        var digitLength = numberOfIntegerDigits(number)
        var divisor = 1

        func updateRounding() {
            let divisorLength = numberOfIntegerDigits(Double(divisor))
            // significant digits are always in use (minimum 3, no maximum): keep all integer digits.
            let fractionDigits = max(0, 3 - digitLength + divisorLength - 1)
            let fractionMultiplier = Double(intPow10(fractionDigits))
            let scaled = dartRound(rounded * fractionMultiplier / Double(divisor))
            rounded = Double(scaled &* divisor) / fractionMultiplier
            digitLength = numberOfIntegerDigits(rounded)
        }

        updateRounding()
        var chosen: CompactStyle?
        for style in styles {
            if style.exponent + 1 > digitLength { break }
            chosen = style
            divisor = style.divisor
            updateRounding()
        }
        return chosen
    }

    // MARK: NumberFormat.format / _formatFixed

    struct FixedDigits {
        var significantDigitsInUse: Bool
        var useDefaultSignificantDigits: Bool
        var minimumFractionDigits: Int
        var groupingEnabled: Bool
    }

    private func formatAffixed(
        _ number: Double, positivePrefix: String, negativePrefix: String,
        positiveSuffix: String, negativeSuffix: String, digits: FixedDigits
    ) -> String {
        if number.isNaN { return "NaN" }
        let negative = number.sign == .minus
        let prefix = negative ? negativePrefix : positivePrefix
        let suffix = negative ? negativeSuffix : positiveSuffix
        if number.isInfinite { return prefix + "\u{221E}" }
        return prefix + formatFixed(abs(number), digits) + suffix
    }

    /// Port of `_formatFixed` for a non-negative finite `number`, multiplier 1, minimum
    /// significant digits 3 and no maximum when `significantDigitsInUse`.
    private func formatFixed(_ number: Double, _ mode: FixedDigits) -> String {
        var fractionDigits = maximumFractionDigits
        let minFractionDigits = mode.minimumFractionDigits

        // integerPart is an Int, or (for numbers beyond the Int range) the original double.
        var integerPart = saturatingInt(number.rounded(.down))
        var bigIntegerPart: Double?
        var fraction = number - Double(integerPart)
        if saturatingInt(fraction) != 0 {
            bigIntegerPart = number
            fraction = 0
        }
        func integerPartIsZero() -> Bool { bigIntegerPart == nil && integerPart == 0 }
        func integerPartAsDouble() -> Double { bigIntegerPart ?? Double(integerPart) }

        func adjustFractionDigits(_ digits: Int, _ expectedSignificantDigits: Int) -> Int {
            if mode.useDefaultSignificantDigits { return digits }
            if expectedSignificantDigits > 0 { return decimalDigits }
            return min(digits, decimalDigits)
        }

        func computeFractionDigits() {
            guard mode.significantDigitsInUse else { return }
            let integerLength: Int
            if number == 0 {
                integerLength = 1
            } else if !integerPartIsZero() {
                integerLength = numberOfIntegerDigits(integerPartAsDouble())
            } else {
                integerLength = saturatingInt((log(fraction) / lnTen).rounded(.up))
            }
            let remainingSignificantDigits = 3 - integerLength
            fractionDigits = max(0, remainingSignificantDigits)
            fractionDigits = adjustFractionDigits(fractionDigits, remainingSignificantDigits)
        }

        computeFractionDigits()

        let power = intPow10(fractionDigits)
        var remainingDigits = dartRound(fraction * Double(power))

        var hasRounding = false
        if remainingDigits >= power {
            if bigIntegerPart != nil { bigIntegerPart! += 1 } else { integerPart &+= 1 }
            remainingDigits -= power
            hasRounding = true
        } else if numberOfIntegerDigits(Double(remainingDigits))
            > numberOfIntegerDigits(Double(saturatingInt((fraction * Double(power)).rounded(.down))))
        {
            fraction = Double(remainingDigits) / Double(power)
            hasRounding = true
        }
        if hasRounding && mode.significantDigitsInUse {
            computeFractionDigits()
        }

        let extraIntegerDigits = power == 0 ? 0 : remainingDigits / power
        let fractionPart = power == 0 ? 0 : remainingDigits % power

        var integerDigits = self.integerDigits(
            integerPart: integerPart, big: bigIntegerPart, extraIntegerDigits: extraIntegerDigits)
        let fractionPresent = fractionDigits > 0 && (minFractionDigits > 0 || fractionPart > 0)

        var out = ""
        // A zero integer part still prints "0".
        if integerDigits.isEmpty { integerDigits = "0" }
        let digitChars = Array(integerDigits)
        let digitLength = digitChars.count
        let grouping = mode.groupingEnabled ? groupingSize : 0
        let finalGrouping = mode.groupingEnabled ? finalGroupingSize : 0
        for (i, ch) in digitChars.enumerated() {
            out.append(ch)
            let distanceFromEnd = digitLength - i
            if distanceFromEnd <= 1 || grouping <= 0 { continue }
            if distanceFromEnd == finalGrouping + 1 {
                out += groupSeparator
            } else if distanceFromEnd > finalGrouping && (distanceFromEnd - finalGrouping) % grouping == 1 {
                out += groupSeparator
            }
        }

        if fractionPresent {
            out += decimalSeparator
            let fractionText = Array(String(fractionPart &+ power))
            var length = fractionText.count
            while fractionText[length - 1] == "0" && length > minFractionDigits + 1 {
                length -= 1
            }
            if length > 1 {
                out += String(fractionText[1..<length])
            }
        }
        return out
    }

    /// `_integerDigits`: integer digits, zero-padded past the Int range like intl.
    private func integerDigits(integerPart: Int, big: Double?, extraIntegerDigits: Int) -> String {
        var padding = ""
        let main: String
        if let big {
            let tooBig = saturatingInt((log(big) / lnTen).rounded(.up)) - 19
            let divisor: Double = tooBig < 19 ? Double(intPow10(tooBig)) : pow(10.0, Double(tooBig))
            padding = String(repeating: "0", count: max(0, tooBig))
            main = String(saturatingInt((big / divisor).rounded(.towardZero)))
        } else {
            main = integerPart == 0 ? "" : String(integerPart)
        }
        let extra = extraIntegerDigits == 0 ? "" : String(extraIntegerDigits)
        return main + extra + padding
    }
}
