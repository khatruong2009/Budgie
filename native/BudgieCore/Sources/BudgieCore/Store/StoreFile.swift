import CryptoKit
import Foundation

/// All financial state: the sections of `financial_store_v2.json`.
public struct FinancialSnapshot: Hashable, Sendable {
    public var schemaVersion: Int
    public var revision: Int64
    /// Section name -> raw JSON, in file order. Unknown sections live here too.
    public var sections: JSONObject

    public init(schemaVersion: Int = StoreFile.schemaVersion, revision: Int64, sections: JSONObject) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.sections = sections
    }

    public static let empty = FinancialSnapshot(revision: 0, sections: JSONObject())

    /// Dart `copyWithSections`: `Map.from(sections)..addAll(updates)` with the
    /// revision advanced. Existing keys keep their position, new ones append.
    public func applying(_ updates: [(String, JSONValue)]) -> FinancialSnapshot {
        var next = sections
        for (key, value) in updates { next[key] = value }
        return FinancialSnapshot(schemaVersion: schemaVersion, revision: revision + 1, sections: next)
    }
}

/// Section names inside the envelope (`FinancialSections`).
public enum Section {
    public static let transactions = "transactions"
    public static let netWorthEntries = "netWorthEntries"
    public static let selectedNetWorthMonth = "selectedNetWorthMonth"
    public static let categoryBudgetLimits = "categoryBudgetLimits"
    public static let savingsGoals = "savingsGoals"
    public static let recurringTransactions = "recurringTransactions"
    public static let categories = "categories"
    public static let transactionTags = "transactionTags"
    public static let categorizationRules = "categorizationRules"
    public static let appSettings = "appSettings"

    /// Every section the Flutter app writes, in `FinancialSections` order.
    public static let all = [
        transactions, netWorthEntries, selectedNetWorthMonth, categoryBudgetLimits, savingsGoals,
        recurringTransactions, categories, transactionTags, categorizationRules, appSettings,
    ]
}

/// The byte format of `financial_store_v2.json` (MIGRATION_SPEC section 4):
/// one JSON header line, LF, then the payload `jsonEncode(sections)`.
public enum StoreFile {
    public static let schemaVersion = 2
    public static let formatTag = "budgie-financial-store"
    public static let directoryName = "financial_store"
    public static let primaryName = "financial_store_v2.json"
    public static let backupName = "financial_store_v2.backup.json"

    /// FNV-1a 64 over `bytes`, formatted exactly like Dart's
    /// `hash.toRadixString(16).padLeft(16, '0')` on a signed 64-bit int:
    /// negative hashes get a leading `-`, and padding zeros go before it.
    public static func checksum<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let text = String(Int64(bitPattern: hash), radix: 16)
        return String(repeating: "0", count: max(0, 16 - text.count)) + text
    }

    public struct Header: Hashable, Sendable {
        public var schemaVersion: Int
        public var revision: Int64
        public var payloadChecksum: String
        public var payloadRange: Range<Int>
    }

    /// Dart `_encode`. `writtenAt` is informational (never read by either app).
    public static func encode(_ snapshot: FinancialSnapshot, writtenAt: DartDateTime) -> [UInt8] {
        let payload = DartJSON.encode(.object(snapshot.sections))
        let header = JSONObject(ordered: [
            ("format", .string(formatTag)),
            ("schemaVersion", .int(snapshot.schemaVersion)),
            ("revision", .number(JSONNumber(int: snapshot.revision))),
            ("payloadLength", .int(payload.count)),
            ("payloadChecksum", .string(checksum(payload))),
            ("writtenAt", .string(writtenAt.toIso8601String())),
        ])
        var bytes = DartJSON.encode(.object(header))
        bytes.append(0x0A)
        bytes.append(contentsOf: payload)
        return bytes
    }

    /// Dart `_verifyBytes`: header and checksum valid, payload not decoded.
    /// Passing this does not establish that the JSON payload is readable.
    /// Backup replacement requires `decode`, so a usable backup survives.
    public static func verify(_ bytes: [UInt8]) -> Header? {
        guard let newline = bytes.firstIndex(of: 0x0A), newline > 0 else { return nil }
        guard case .object(let header)? = try? JSONParser.parse(Array(bytes[..<newline])) else { return nil }
        guard
            header["format"]?.stringValue == formatTag,
            let version = header["schemaVersion"]?.numberValue?.intValue, version <= Int64(schemaVersion),
            let revision = header["revision"]?.numberValue?.intValue,
            let length = header["payloadLength"]?.numberValue?.intValue,
            case .string(let checksumValue)? = header["payloadChecksum"]
        else { return nil }
        let payloadRange = (newline + 1)..<bytes.count
        guard Int64(payloadRange.count) == length else { return nil }
        let expected = checksumValue.value
        guard checksum(bytes[payloadRange]) == expected else { return nil }
        return Header(schemaVersion: Int(version), revision: revision, payloadChecksum: expected, payloadRange: payloadRange)
    }

    /// Dart `_decodeBytes`: verified, and the payload is valid UTF-8 JSON
    /// whose top level is an object.
    public static func decode(_ bytes: [UInt8]) -> FinancialSnapshot? {
        guard let header = verify(bytes) else { return nil }
        guard case .object(let sections)? = try? JSONParser.parse(Array(bytes[header.payloadRange])) else {
            return nil
        }
        return FinancialSnapshot(schemaVersion: header.schemaVersion, revision: header.revision, sections: sections)
    }
}

/// Lowercase hex SHA-256, as written into the backup manifests.
func sha256Hex<D: DataProtocol>(_ data: D) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
