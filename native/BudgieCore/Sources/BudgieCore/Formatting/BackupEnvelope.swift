import Foundation

/// The Flutter app's full backup file (`backup.dart`, settings_page.dart
/// `_exportBackup` / `_importBackup`), byte for byte: a pretty-printed JSON
/// envelope, schema 3.
public enum BackupEnvelope {
    /// `kBackupSchemaVersion`.
    public static let schemaVersion: Int64 = 3

    // MARK: - Export

    /// Dart `encodeBackup` of what `_exportBackup` reads from the models:
    /// every readable row re-serialised from its typed fields (unreadable
    /// rows are absent, as Flutter cannot load them either), rules in
    /// priority-descending order (Dart's `rules` getter sorts with
    /// `List.sort`), `now` as `exportedAt` (local, no zone suffix).
    ///
    /// `themeMode` is the theme preference (`light`, `dark`, `system`; nil
    /// writes null, which the real export never does).
    ///
    /// Throws where Dart's encoder throws: a NaN or infinite amount (only
    /// a hand-edited store can hold one).
    public static func encode(
        data: FinancialData, themeMode: String?, appVersion: String, now: DartDateTime
    ) throws(BackupExportError) -> [UInt8] {
        var transactions: [JSONValue] = []
        transactions.reserveCapacity(data.transactionRows.count)
        for record in data.transactions { transactions.append(.object(try record.canonicalJSON())) }
        var netWorth: [JSONValue] = []
        for record in data.netWorthEntries { netWorth.append(.object(try record.canonicalJSON())) }
        var limits = JSONObject()
        for entry in data.budgetLimitEntries {
            limits.members.append(.init(key: entry.key, value: try Canonical.double(entry.value)))
        }
        var goals: [JSONValue] = []
        for record in data.savingsGoals { goals.append(.object(try record.canonicalJSON())) }
        var templates: [JSONValue] = []
        for record in data.templates { templates.append(.object(try record.canonicalJSON())) }
        let categories = data.categories.map { JSONValue.object($0.canonicalJSON()) }
        let tags = data.tags.map { JSONValue.object($0.canonicalJSON()) }
        var rules: [JSONValue] = []
        for record in rulesByPriority(data.rules) { rules.append(.object(try record.canonicalJSON())) }
        let settings = data.appSettings

        let envelope = JSONObject(ordered: [
            ("schemaVersion", .number(JSONNumber(int: schemaVersion))),
            ("app", .string("budgie")),
            ("appVersion", .string(appVersion)),
            ("exportedAt", .string(now.toIso8601String())),
            ("data", .object(JSONObject(ordered: [
                ("transactions", .array(transactions)),
                ("netWorthEntries", .array(netWorth)),
                ("categoryBudgetLimits", .object(limits)),
                ("savingsGoals", .array(goals)),
                ("recurringTransactions", .array(templates)),
                ("themeMode", themeMode.map { .string($0) } ?? .null),
                ("categories", .array(categories)),
                ("transactionTags", .array(tags)),
                ("categorizationRules", .array(rules)),
                ("baseCurrencyCode", .string(settings.baseCurrencyCode)),
                ("localeOverride", settings.localeOverride.map { .string($0) } ?? .null),
                ("appLockEnabled", .bool(settings.appLockEnabled)),
                ("autoLockTimeoutSeconds", .int(settings.autoLockTimeoutSeconds)),
                ("hideBalances", .bool(settings.hideBalances)),
            ]))),
        ])
        return DartJSON.encodeIndented(.object(envelope))
    }

    /// `budgie_backup_${DateFormat('yyyyMMdd_HHmmss').format(now)}.json`,
    /// from the local fields of `now`.
    public static func fileName(now: DartDateTime) -> String {
        "budgie_backup_\(DartDateFormat.yyyyMMdd_HHmmss(now)).json"
    }

    /// Dart `CategorizationProvider.rules`: a copy sorted by priority,
    /// highest first, with Dart's `List.sort` (tie order included).
    public static func rulesByPriority(_ rules: [CategorizationRuleRecord]) -> [CategorizationRuleRecord] {
        CategorizationEngine.ordered(rules)
    }

    // MARK: - Copy (settings_page.dart, verbatim)

    public static let shareSubject = "Budgie Backup"
    public static let exportedMessage = "Backup exported"
    public static let restoredMessage = "Backup restored"

    /// "Could not export backup: <reason>".
    public static func exportFailedMessage(_ reason: String) -> String { "Could not export backup: \(reason)" }

    /// "Could not import backup: <reason>" (for a `BackupError`, its `message`).
    public static func importFailedMessage(_ reason: String) -> String { "Could not import backup: \(reason)" }

    // MARK: - Import

    /// Dart `decodeBackup(utf8.decode(bytes, allowMalformed: true))`, with
    /// its checks in its order (the first failure decides the message), and
    /// what the restore needs: every row read by its Dart `fromJson` and
    /// re-serialised canonically, as Flutter's restore writes them.
    ///
    /// Bytes: one leading UTF-8 BOM is dropped by the decoder and one more
    /// U+FEFF by `decodeBackup` (so one or two BOMs are accepted, three are
    /// not); malformed UTF-8 becomes U+FFFD, as with `allowMalformed`.
    ///
    /// D10: a `data` key that is absent or null means "not provided", and
    /// that section (or setting) is left unchanged by the restore; Flutter
    /// resets it. `localeOverride` is the exception: present and null means
    /// "Match device". `themeMode` behaves as in Flutter (anything but
    /// light/dark/system leaves the theme alone).
    ///
    /// Two Flutter failures that are not `FormatException`s become
    /// `.corrupt` here: `autoLockTimeoutSeconds` of `1e999` (Flutter:
    /// "Unsupported operation: Infinity or NaN toInt") and a rule amount
    /// bound of `1e999` (Flutter accepts it, then fails its first store
    /// write). Nothing changes in either app.
    ///
    /// `calendar` parses dates as the Dart models do; `now` fills a goal or
    /// snapshot date the file lacks (Dart's `DateTime.now()`); `newID` gives
    /// ids to rows without one.
    public static func decode(
        bytes: [UInt8], calendar: DartCalendar, now: DartDateTime, newID: () -> String
    ) throws(BackupError) -> RestorePlan {
        // utf8.decode(allowMalformed: true): drops one BOM, replaces
        // malformed sequences like Swift's decoder does.
        var input = bytes[...]
        if input.starts(with: [0xEF, 0xBB, 0xBF]) { input = input.dropFirst(3) }
        var text = String(decoding: input, as: UTF8.self)
        // decodeBackup: one more U+FEFF.
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }

        guard case .object(let root)? = try? JSONParser.parse(Array(text.utf8)) else { throw .notABackup }
        guard let schemaVersion = root["schemaVersion"]?.numberValue?.intValue else { throw .notABackup }
        guard schemaVersion <= BackupEnvelope.schemaVersion else { throw .newerVersion }
        guard case .object(let data)? = root["data"] else { throw .missingData }

        /// `_decodeList`: null or absent is nil ("not provided"); anything
        /// but a list of objects each `fromJson` accepts is corrupt.
        func rows<Record>(_ key: String, _ parse: (JSONValue) -> Record?) throws(BackupError) -> [Record]? {
            switch data[key] {
            case nil, .null?: return nil
            case .array(let items)?:
                var records: [Record] = []
                records.reserveCapacity(items.count)
                for item in items {
                    guard case .object(_) = item, let record = parse(item) else { throw .corrupt }
                    records.append(record)
                }
                return records
            default: throw .corrupt
            }
        }
        func require(_ condition: Bool) throws(BackupError) {
            if !condition { throw .corrupt }
        }
        /// `(x as num?)?.toInt()` throws for an infinite number.
        func finiteIfNumber(_ value: JSONValue?) -> Bool {
            guard case .number(let number)? = value else { return true }
            return number.doubleValue.isFinite
        }
        func units(_ value: JSONValue?) -> [UInt16] {
            if case .string(let s)? = value { return s.codeUnits }
            return []
        }

        // Categories, tags and rules first (backup.dart:123-141).
        let categories = try rows("categories") { item -> CategoryInfo? in
            guard finiteIfNumber(item.objectValue?["sortOrder"]) else { return nil }
            return CategoryInfo.parse(item)?.canonicalized()
        }
        let tags = try rows("transactionTags") { TransactionTagRecord.parse($0, newID: newID)?.canonicalized() }
        let rules = try rows("categorizationRules") { item -> CategorizationRuleRecord? in
            guard finiteIfNumber(item.objectValue?["priority"]) else { return nil }
            return CategorizationRuleRecord.parse(item, newID: newID)
        }
        let categoryIDs = (categories ?? []).map { units($0.raw["id"]) }
        let tagIDs = Set((tags ?? []).map { units($0.raw["id"]) })
        let ruleIDs = Set((rules ?? []).map { units($0.raw["id"]) })
        try require(Set(categoryIDs).count == categoryIDs.count)
        try require(tagIDs.count == (tags ?? []).count && ruleIDs.count == (rules ?? []).count)
        for rule in rules ?? [] {
            for tagID in rule.raw["tagIds"]?.arrayValue ?? [] {
                if case .string(let id) = tagID { try require(tagIDs.contains(id.codeUnits)) }
            }
        }
        if let categories, !categories.isEmpty {
            for type in [TransactionType.expense, .income] {
                try require(categories.contains { $0.type == type && !$0.isArchived })
            }
        }

        // Settings types (backup.dart:142-151).
        let localeValue = data["localeOverride"]
        try require(localeValue == nil || localeValue!.isNull || localeValue!.stringValue != nil)
        let lockValue = data["appLockEnabled"], hideValue = data["hideBalances"]
        try require(lockValue == nil || lockValue!.isNull || lockValue!.boolValue != nil)
        try require(hideValue == nil || hideValue!.isNull || hideValue!.boolValue != nil)
        let timeoutValue = data["autoLockTimeoutSeconds"]
        var timeout: Int? = nil
        switch timeoutValue {
        case nil, .null?: break
        case .number(let number)?:
            // Flutter: UnsupportedError for an infinite value (see above).
            try require(number.doubleValue.isFinite)
            timeout = Int(DartNumbers.toInt(number.doubleValue, lexeme: number))
            try require(timeout! >= 0)
        default: throw .corrupt
        }

        // BackupData arguments, in order (backup.dart:153-169).
        let transactions = try rows("transactions") { item -> TransactionRecord? in
            let type = item.objectValue?["type"]?.stringValue
            guard type == "expense" || type == "income",
                let record = TransactionRecord.parse(item, calendar: calendar, newID: newID),
                record.amount.isFinite
            else { return nil }
            return try? record.canonicalized()
        }
        let netWorthEntries = try rows("netWorthEntries") { item -> NetWorthEntryRecord? in
            let type = item.objectValue?["type"]?.stringValue
            guard type == "asset" || type == "liability",
                let record = NetWorthEntryRecord.parse(item, calendar: calendar, now: { now }),
                record.snapshots.allSatisfy({ $0.amount.isFinite })
            else { return nil }
            return try? record.canonicalized()
        }
        let budgetLimits: [RestorePlan.BudgetLimit]?
        switch data["categoryBudgetLimits"] {
        case nil, .null?: budgetLimits = nil
        case .object(let object)?:
            // Dart map semantics: first position, last value, keys as UTF-16.
            var order: [[UInt16]] = []
            var latest: [[UInt16]: JSONValue] = [:]
            for member in object.members {
                let key = member.key.codeUnits
                if latest[key] == nil { order.append(key) }
                latest[key] = member.value
            }
            var limits: [RestorePlan.BudgetLimit] = []
            for key in order {
                guard let value = latest[key]!.numberValue?.doubleValue, value.isFinite else { throw .corrupt }
                limits.append(RestorePlan.BudgetLimit(key: JSONString(lexeme: DartJSON.escape(codeUnits: key)), value: value))
            }
            budgetLimits = limits
        default: throw .corrupt
        }
        var goalCounter = 0
        let savingsGoals = try rows("savingsGoals") { item -> SavingsGoalRecord? in
            guard let record = SavingsGoalRecord.parse(item, calendar: calendar, now: now, newID: {
                defer { goalCounter += 1 }
                return SavingsGoalRecord.makeID(now: now, counter: goalCounter)
            }), record.targetAmount.isFinite, record.currentAmount.isFinite
            else { return nil }
            return try? record.canonicalized()
        }
        let templates = try rows("recurringTransactions") { item -> RecurringTemplate? in
            let type = item.objectValue?["type"]?.stringValue
            guard type == "expense" || type == "income",
                let record = RecurringTemplate.parse(item, calendar: calendar, newID: newID),
                record.amount.isFinite
            else { return nil }
            if record.pattern == .monthly {
                guard let day = record.dayOfMonth, (1...31).contains(day) else { return nil }
            }
            return try? record.canonicalized()
        }
        let themeMode = data["themeMode"]?.stringValue.flatMap { ["light", "dark", "system"].contains($0) ? $0 : nil }

        let currency: String?
        switch data["baseCurrencyCode"] {
        case nil, .null?: currency = nil
        case .string(let raw)?:
            let trimmed = DartString.trim(raw.value)
            guard trimmed.utf16.count == 3 else { throw .invalidCurrency }
            currency = DartString.uppercase(trimmed)
        default: throw .invalidCurrency
        }

        // Flutter fails the first store write on a non-finite rule bound.
        var canonicalRules: [CategorizationRuleRecord]? = nil
        if let rules {
            canonicalRules = []
            for rule in rules {
                guard let canonical = try? rule.canonicalized() else { throw .corrupt }
                canonicalRules!.append(canonical)
            }
        }

        let locale: RestorePlan.LocaleChange
        switch localeValue {
        case nil: locale = .keep
        case .string(let s)?: locale = .set(s.value)
        default: locale = .set(nil)
        }
        return RestorePlan(
            schemaVersion: schemaVersion, transactions: transactions, netWorthEntries: netWorthEntries,
            budgetLimits: budgetLimits, savingsGoals: savingsGoals, templates: templates, themeMode: themeMode,
            categories: categories, tags: tags, rules: canonicalRules, baseCurrencyCode: currency, localeOverride: locale,
            appLockEnabled: lockValue?.boolValue, autoLockTimeoutSeconds: timeout, hideBalances: hideValue?.boolValue)
    }
}

/// `decodeBackup`'s `FormatException`s.
public enum BackupError: Error, Equatable, Sendable {
    case notABackup, newerVersion, missingData, corrupt, invalidCurrency

    /// Flutter's message, verbatim (shown after "Could not import backup: ").
    public var message: String {
        switch self {
        case .notABackup: "This is not a valid Budgie backup file"
        case .newerVersion: "This backup was made by a newer version of Budgie. Update the app and try again."
        case .missingData: "This backup file is missing its data."
        case .corrupt: "This backup file is corrupt or incomplete."
        case .invalidCurrency: "This backup has an invalid currency."
        }
    }
}

extension FinancialData {
    /// `categoryBudgetLimits` as Dart's model holds it (values > 0, first
    /// position and last value per key, keys as UTF-16), with each key's
    /// exact code units (a Swift `String` cannot hold a lone surrogate).
    var budgetLimitEntries: [(key: JSONString, value: Double)] {
        var order: [[UInt16]] = []
        var entries: [[UInt16]: JSONValue] = [:]
        for member in budgetLimitsObject.members {
            let units = member.key.codeUnits
            if entries[units] == nil { order.append(units) }
            entries[units] = member.value
        }
        return order.compactMap { units in
            guard let value = entries[units]!.numberValue?.doubleValue, value > 0 else { return nil }
            return (JSONString(lexeme: DartJSON.escape(codeUnits: units)), value)
        }
    }
}
