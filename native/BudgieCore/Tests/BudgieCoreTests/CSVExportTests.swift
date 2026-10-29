import Foundation
import Testing

@testable import BudgieCore

@Suite("Formatting: DartFixed and CSV export match the Dart app")
struct CSVExportTests {
    private static let utc = TimeZone(identifier: "UTC")!

    private func fixture() throws -> [String: Any] {
        try Fixtures.jsonObject("logic/csv_export.json") as! [String: Any]
    }

    private func rows(_ fixture: [String: Any]) throws -> [CSVExport.Row] {
        try (fixture["transactions"] as! [[String: Any]]).map { transaction in
            CSVExport.Row(
                date: try DartDateTime.parse(transaction["date"] as! String, timeZone: Self.utc),
                isIncome: (transaction["type"] as! String) == "income",
                category: transaction["category"] as! String,
                description: transaction["description"] as! String,
                amount: (transaction["amount"] as! NSNumber).doubleValue)
        }
    }

    @Test("toStringAsFixed(2) matches every numbers.json vector")
    func fixedVectors() throws {
        let numbers = try Fixtures.jsonObject("logic/numbers.json") as! [String: Any]
        let doubles = numbers["doubles"] as! [[String: Any]]
        var mismatches: [String] = []
        for entry in doubles {
            let bits = entry["bits"] as! String
            let value = Double(bitPattern: UInt64(bits, radix: 16)!)
            let actual = DartFixed.toStringAsFixed(value, 2)
            let expected = entry["fixed2"] as? String ?? DartDouble.format(value)
            if entry["fixed2"] is NSNull || entry["fixed2"] == nil {
                #expect(value.magnitude >= 1e21, "null fixed2 only above 1e21: \(bits)")
            }
            if actual != expected { mismatches.append("\(bits): expected \(expected), got \(actual)") }
        }
        #expect(doubles.count > 1000)
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, first 20: \(mismatches.prefix(20))")
    }

    @Test("toStringAsFixed rounds exact ties away from zero and keeps signs")
    func fixedSpotChecks() {
        #expect(DartFixed.toStringAsFixed(0.125, 2) == "0.13")
        #expect(DartFixed.toStringAsFixed(-0.125, 2) == "-0.13")
        #expect(DartFixed.toStringAsFixed(2.5, 0) == "3")
        #expect(DartFixed.toStringAsFixed(1.005, 2) == "1.00")
        #expect(DartFixed.toStringAsFixed(0.005, 2) == "0.01")
        #expect(DartFixed.toStringAsFixed(0.015, 2) == "0.01")
        #expect(DartFixed.toStringAsFixed(-0.001, 2) == "-0.00")
        #expect(DartFixed.toStringAsFixed(-0.0, 2) == "-0.00")
        #expect(DartFixed.toStringAsFixed(999.999, 2) == "1000.00")
        #expect(DartFixed.toStringAsFixed(9.5, 0) == "10")
        #expect(DartFixed.toStringAsFixed(1e21, 2) == "1e+21")
    }

    @Test("export of the fixture transactions equals the Dart bytes")
    func exportBytes() throws {
        let fixture = try fixture()
        let bytes = CSVExport.export(try rows(fixture))
        let expected = [UInt8](Data(base64Encoded: fixture["base64"] as! String)!)
        #expect(bytes == expected)
        #expect(String(decoding: bytes, as: UTF8.self) == fixture["text"] as! String)
    }

    @Test("empty ledger is only the header")
    func emptyLedger() throws {
        let fixture = try fixture()
        #expect(String(decoding: CSVExport.export([]), as: UTF8.self) == fixture["emptyLedgerText"] as! String)
    }

    @Test("file name comes from the local fields of now")
    func fileName() throws {
        let fixture = try fixture()
        let now = DartDateTime(2026, 2, 3, 4, 5, 6, timeZone: Self.utc)!
        #expect(CSVExport.fileName(now: now) == fixture["fileName"] as! String)
    }
}
