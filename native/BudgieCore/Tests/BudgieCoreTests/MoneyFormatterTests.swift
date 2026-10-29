import Foundation
import Testing

@testable import BudgieCore

@Suite("Money formatting matches Dart intl")
struct MoneyFormatterTests {
    @Test("every vector, every field")
    func vectors() throws {
        let fixture = try Fixtures.jsonObject("logic/money_format.json") as! [String: Any]
        let vectors = fixture["vectors"] as! [[String: Any]]
        #expect(!vectors.isEmpty)

        var mismatches: [String] = []
        var checked = 0
        for vector in vectors {
            let currency = vector["currency"] as! String
            let locale = vector["locale"] as? String
            let value = (vector["value"] as! NSNumber).doubleValue
            let formatter = MoneyFormatter(currencyCode: currency, locale: locale)

            let cases: [(String, String)] = [
                ("format2", formatter.format(value)),
                ("format0", formatter.format(value, decimalDigits: 0)),
                ("compact1", formatter.format(value, decimalDigits: 1, compact: true)),
                ("signed2", formatter.formatSigned(value)),
                ("signedPlus2", formatter.formatSigned(value, plusForPositive: true)),
                ("number2", formatter.formatNumber(value)),
            ]
            for (field, actual) in cases {
                let expected = vector[field] as! String
                checked += 1
                if actual != expected {
                    mismatches.append(
                        "\(currency) \(locale ?? "nil") value=\(value) (sign \(value.sign)) \(field): "
                            + "expected \(escaped(expected)) actual \(escaped(actual))")
                }
            }
        }
        let report = "\(mismatches.count) of \(checked) fields mismatched; first 30:\n"
            + mismatches.prefix(30).joined(separator: "\n")
        #expect(mismatches.isEmpty, Comment(rawValue: report))
    }

    @Test("hideBalances masks format and formatSigned")
    func hidden() throws {
        let fixture = try Fixtures.jsonObject("logic/money_format.json") as! [String: Any]
        let hidden = fixture["hidden"] as! [String: String]
        let formatter = MoneyFormatter(currencyCode: "EUR", locale: "de_DE", hideBalances: true)
        #expect(formatter.format(1234.56) == hidden["format"])
        #expect(formatter.format(1234.56, decimalDigits: 1, compact: true) == hidden["format"])
        #expect(formatter.formatSigned(-1234.56) == hidden["signed"])
        #expect(formatter.formatSigned(1234.56, plusForPositive: true) == hidden["signed"])
    }

    private func escaped(_ s: String) -> String {
        "\"" + s.unicodeScalars.map { scalar in
            scalar.value < 0x80 && scalar.value >= 0x20 ? String(scalar) : "\\u{" + String(scalar.value, radix: 16) + "}"
        }.joined() + "\""
    }
}
