import Foundation

extension DartDouble {
    /// Dart `double.tryParse` (VM): surrounding whitespace (Dart's `trim`
    /// set) is ignored; then an optional sign followed by "Infinity", "NaN",
    /// or a decimal numeral with an optional fraction (".5" and "5." both
    /// count, "." does not) and an optional exponent ("1e3", "1E-3").
    /// Anything else, including "1,5", hex and non-ASCII digits, is nil.
    /// Out-of-range values round to infinity or zero. Verified against Dart,
    /// see Fixtures/home/try_parse.json.
    public static func tryParse(_ text: String) -> Double? {
        let units = DartString.trimUnits(Array(text.utf16))
        let end = units.count
        guard end > 0 else { return nil }

        var i = 0
        var negative = false
        if units[i] == 0x2B || units[i] == 0x2D {  // + -
            negative = units[i] == 0x2D
            i += 1
        }
        let rest = units[i..<end]
        if rest.elementsEqual("Infinity".utf16) { return negative ? -.infinity : .infinity }
        if rest.elementsEqual("NaN".utf16) { return .nan }

        func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }
        func digits() -> String {
            var out = ""
            while i < end && isDigit(units[i]) {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(units[i])))
                i += 1
            }
            return out
        }

        let integer = digits()
        var fraction = ""
        if i < end && units[i] == 0x2E {  // .
            i += 1
            fraction = digits()
        }
        guard !integer.isEmpty || !fraction.isEmpty else { return nil }
        var exponent = ""
        if i < end && (units[i] == 0x65 || units[i] == 0x45) {  // e E
            i += 1
            var sign = ""
            if i < end && (units[i] == 0x2B || units[i] == 0x2D) {
                sign = units[i] == 0x2D ? "-" : ""
                i += 1
            }
            let value = digits()
            guard !value.isEmpty else { return nil }
            exponent = "e" + sign + value
        }
        guard i == end else { return nil }

        // A plain numeral that strtod rounds correctly.
        let numeral = (negative ? "-" : "") + (integer.isEmpty ? "0" : integer) + "." + (fraction.isEmpty ? "0" : fraction) + exponent
        return Double(numeral)
    }
}
