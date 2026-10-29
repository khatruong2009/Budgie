import Foundation

/// Dart number helpers.
enum DartNumbers {
    /// `double.tryParse` (accepts what Dart accepts for plain decimals; the
    /// app only ever stores `toString()` output here).
    static func tryParseDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "NaN" { return .nan }
        if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
        if trimmed == "-Infinity" { return -.infinity }
        return Double(trimmed)
    }

    /// `num.toInt()`: truncation toward zero; out-of-range doubles clamp
    /// to the int64 bounds, as the Dart VM does.
    static func toInt(_ value: Double, lexeme: JSONNumber) -> Int64 {
        if let int = lexeme.intValue { return int }
        let truncated = value.rounded(.towardZero)
        if truncated >= 9_223_372_036_854_775_807.0 { return .max }
        if truncated <= -9_223_372_036_854_775_808.0 { return .min }
        return Int64(truncated)
    }
}
