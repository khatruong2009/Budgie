import Foundation

/// A category definition (`BudgetCategory`, `category_definition.dart`).
/// Keeps the row it was read from so edits patch it in place.
public struct CategoryInfo: Hashable, Sendable, Identifiable {
    public let id: String
    public let type: TransactionType
    public let name: String
    public let iconIdentifier: String
    public let colorToken: String
    public let sortOrder: Int
    public let isArchived: Bool
    public let isBuiltIn: Bool
    public let raw: JSONObject

    /// Dart `BudgetCategory.fromJson`. nil where its casts would throw.
    static func parse(_ value: JSONValue) -> CategoryInfo? {
        guard case .object(let object) = value,
            let id = Read.requiredString(object, "id"),
            let name = Read.requiredString(object, "name"),
            case .some(let icon) = Read.optionalString(object, "iconIdentifier"),
            case .some(let color) = Read.optionalString(object, "colorToken")
        else { return nil }
        guard case .some(let storedSortOrder) = Read.optionalNumber(object, "sortOrder") else { return nil }
        let sortOrder = storedSortOrder ?? 0
        guard case .some(let archived) = Read.optionalBool(object, "isArchived"),
            case .some(let builtIn) = Read.optionalBool(object, "isBuiltIn")
        else {
            return nil
        }
        return CategoryInfo(
            id: id, type: object["type"]?.stringValue == "income" ? .income : .expense, name: name,
            iconIdentifier: icon ?? "square_grid_2x2", colorToken: color ?? "accent", sortOrder: sortOrder,
            isArchived: archived ?? false, isBuiltIn: builtIn ?? false, raw: object)
    }

    func with(sortOrder: Int) -> CategoryInfo {
        var raw = self.raw
        raw["sortOrder"] = .int(sortOrder)
        return CategoryInfo(
            id: id, type: type, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, sortOrder: sortOrder,
            isArchived: isArchived, isBuiltIn: isBuiltIn, raw: raw)
    }

    /// Dart `copyWith(name:, iconIdentifier:, colorToken:)`. Only keys whose
    /// value changes (names compared as UTF-16) are rewritten.
    func with(name: String, iconIdentifier: String, colorToken: String) -> CategoryInfo {
        var raw = self.raw
        if !DartString.equal(name, self.name) { raw["name"] = .string(name) }
        if !DartString.equal(iconIdentifier, self.iconIdentifier) { raw["iconIdentifier"] = .string(iconIdentifier) }
        if !DartString.equal(colorToken, self.colorToken) { raw["colorToken"] = .string(colorToken) }
        return CategoryInfo(
            id: id, type: type, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, sortOrder: sortOrder,
            isArchived: isArchived, isBuiltIn: isBuiltIn, raw: raw)
    }

    /// Dart `copyWith(isArchived:)`.
    func with(isArchived: Bool) -> CategoryInfo {
        var raw = self.raw
        raw["isArchived"] = .bool(isArchived)
        return CategoryInfo(
            id: id, type: type, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, sortOrder: sortOrder,
            isArchived: isArchived, isBuiltIn: isBuiltIn, raw: raw)
    }

    /// A new definition as Dart `BudgetCategory(...).toJson()` writes it.
    public static func make(
        id: String, type: TransactionType, name: String, iconIdentifier: String, colorToken: String, sortOrder: Int,
        isArchived: Bool = false, isBuiltIn: Bool
    ) -> CategoryInfo {
        let raw = JSONObject(ordered: [
            ("id", .string(id)),
            ("type", .string(type.rawValue)),
            ("name", .string(name)),
            ("iconIdentifier", .string(iconIdentifier)),
            ("colorToken", .string(colorToken)),
            ("sortOrder", .int(sortOrder)),
            ("isArchived", .bool(isArchived)),
            ("isBuiltIn", .bool(isBuiltIn)),
        ])
        return CategoryInfo(
            id: id, type: type, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken, sortOrder: sortOrder,
            isArchived: isArchived, isBuiltIn: isBuiltIn, raw: raw)
    }
}

public enum CategoryCatalog {
    /// `CategoryProvider._builtInCategories()` (research C section 3).
    public static let builtIn: [CategoryInfo] = {
        let expenses: [(String, String, String)] = [
            ("General", "square_grid_2x2", "accent"), ("Eating Out", "asterisk_circle", "orange"),
            ("Groceries", "cart", "green"), ("Housing", "house", "blue"), ("Transportation", "car", "purple"),
            ("Travel", "airplane", "cyan"), ("Clothing", "bag", "pink"), ("Gift", "gift", "purple"),
            ("Health", "heart", "red"), ("Entertainment", "film", "orange"), ("Pets", "paw", "green"),
            ("Family", "people", "blue"), ("Loan Payment", "money", "red"),
        ]
        let incomes: [(String, String, String)] = [
            ("Salary", "money", "green"), ("Investment", "chart", "blue"), ("Gift", "gift", "purple"),
            ("Other", "square_grid_2x2", "accent"),
        ]
        func slug(_ name: String) -> String { name.lowercased().replacingOccurrences(of: " ", with: "-") }
        return expenses.enumerated().map { i, c in
            CategoryInfo.make(
                id: "expense-\(slug(c.0))", type: .expense, name: c.0, iconIdentifier: c.1, colorToken: c.2, sortOrder: i,
                isBuiltIn: true)
        } + incomes.enumerated().map { i, c in
            CategoryInfo.make(
                id: "income-\(slug(c.0))", type: .income, name: c.0, iconIdentifier: c.1, colorToken: c.2, sortOrder: i,
                isBuiltIn: true)
        }
    }()

    /// The stored rows of the `categories` section: each readable (Dart
    /// `fromJson` rules) or kept verbatim. Empty when the section is absent
    /// or not a list. Dart falls back to the seeds for the whole list when
    /// any row is malformed; Swift keeps the readable rows (PARITY_GAPS).
    public static func rows(_ section: JSONValue?) -> [StoredRow<CategoryInfo>] {
        guard case .array(let rows)? = section else { return [] }
        return rows.map { row in CategoryInfo.parse(row).map { .record($0) } ?? .unreadable(row) }
    }

    /// The definitions the app uses: the readable rows, or the built-in
    /// seeds when there are none (Dart `_decodeOrSeed`).
    public static func effective(_ rows: [StoredRow<CategoryInfo>]) -> [CategoryInfo] {
        let records = rows.compactMap(\.record)
        return records.isEmpty ? builtIn : records
    }

    /// Picker list for a type: active definitions by sort order (Dart
    /// normalises sort order per type, stable in list order), then any of
    /// `usedNames` without a definition. Loaded data passes none (see
    /// `categoryPicker(for:)`). A used name is skipped as Dart
    /// `_containsName` skips it: some definition of the type (archived ones
    /// and names added earlier in this pass included) whose `toLowerCase()`
    /// equals the name's `trim().toLowerCase()` as UTF-16 code units.
    public static func pickerList(_ categories: [CategoryInfo], type: TransactionType, usedNames: [String]) -> [CategoryInfo] {
        let defined = categories.enumerated()
            .filter { $0.element.type == type }
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)
        var result = defined.filter { !$0.isArchived }
        var known = Set(defined.map { Array(DartString.lowercase($0.name).utf16) })
        for name in usedNames where !known.contains(Array(DartString.lowercase(DartString.trim(name)).utf16)) {
            known.insert(Array(DartString.lowercase(name).utf16))
            result.append(CategoryInfo.make(
                id: "\(type.rawValue)-legacy-\(name)", type: type, name: name, iconIdentifier: "square_grid_2x2",
                colorToken: "accent", sortOrder: Int.max, isBuiltIn: false))
        }
        return result
    }

    /// The keys of Dart's `categoryIconRegistry` in insertion order
    /// (common.dart:4-23): the editor's icon grid. Any other identifier is
    /// stored as `square_grid_2x2` by add and update.
    public static let iconIdentifiers = [
        "square_grid_2x2", "asterisk_circle", "cart", "house", "car", "airplane", "bag", "gift", "heart", "film", "paw",
        "people", "money", "chart", "book", "phone", "wrench", "leaf",
    ]

    /// The editor's colour choices (`_colorTokens`,
    /// category_settings_page.dart:381-390). Add and update store any token
    /// verbatim; an unknown one renders as accent.
    public static let colorTokens = ["accent", "green", "blue", "orange", "red", "purple", "pink", "cyan"]

    /// SF Symbol for a Flutter icon identifier (CupertinoIcons registry,
    /// common.dart; the Cupertino glyph's SF counterpart where one exists,
    /// filled where the Cupertino glyph is: `car_detailed` and `paw`).
    /// Unknown identifiers fall back like Flutter does.
    public static func symbol(for iconIdentifier: String) -> String {
        switch iconIdentifier {
        case "square_grid_2x2": "square.grid.2x2"
        case "asterisk_circle": "asterisk.circle"
        case "cart": "cart"
        case "house": "house"
        case "car": "car.fill"
        case "airplane": "airplane"
        case "bag": "bag"
        case "gift": "gift"
        case "heart": "heart"
        case "film": "film"
        case "paw": "pawprint.fill"
        case "people": "person.2"
        case "money": "dollarsign"
        case "chart": "chart.bar"
        case "book": "book"
        case "phone": "iphone"
        case "wrench": "hammer"
        case "leaf": "leaf.arrow.circlepath"
        default: "square.grid.2x2"
        }
    }
}

extension FinancialData {
    /// The launch pass of the Flutter app (`main.dart` `_initializeApp`):
    /// `CategoryProvider.load` (seeds when nothing is readable, sort orders
    /// normalised), then `ensureLegacyCategories(transactions)` and
    /// `ensureLegacyCategoryNames(template categories + expense budget
    /// keys)`: every (type, name) in use without a definition gets one.
    /// Returns whether the `categories` section now differs from what was
    /// stored (the caller writes it only then, as Flutter does).
    mutating func ensureLegacyCategories(stored: JSONValue?, newID: () -> String) -> Bool {
        if categoryRows.allSatisfy({ $0.record == nil }) {
            categoryRows += CategoryCatalog.builtIn.map { .record($0) }
        }
        normalizeCategorySortOrders()

        materializeCategories(
            transactions.map { ($0.type, $0.category) }
                + templates.map { ($0.type, $0.category) }
                + budgetLimits.map { (TransactionType.expense, $0.0) },
            newID: newID)

        guard case .array? = stored else { return true }
        return DartJSON.encode(categoriesSection()) != DartJSON.encode(stored!)
    }

    /// The naming step of the launch pass (`ensureLegacyCategories` /
    /// `ensureLegacyCategoryNames`): each (type, name) without a definition
    /// gets one at the end of its type, then sort orders are renumbered.
    /// Returns whether any was added.
    ///
    /// Dart adds the name as given (padding kept) but compares the trimmed
    /// candidate with the stored, untrimmed names, so a padded name never
    /// matches the definition it created and every launch adds another
    /// (PARITY_GAPS, "padded-name"). Swift adds exactly what Dart adds, but
    /// also treats a definition stored before this pass as matching when its
    /// trimmed name matches: the second launch finds the first one's (unless
    /// `matchesPaddedCategoryNames` is off).
    /// Definitions added during this pass are compared as Dart does, so the
    /// first launch writes the same rows as Flutter's.
    @discardableResult
    mutating func materializeCategories(_ names: [(TransactionType, String)], newID: () -> String) -> Bool {
        var added = false
        let stored = matchesPaddedCategoryNames ? categoryRows.count : 0
        for (type, name) in names where !containsCategory(type: type, name: name, trimmingStoredBefore: stored) {
            let count = categoryRows.filter { $0.record?.type == type }.count
            categoryRows.append(.record(CategoryInfo.make(
                id: uniqueCategoryID(type: type, name: name, newID: newID), type: type, name: name,
                iconIdentifier: "square_grid_2x2", colorToken: "accent", sortOrder: count, isBuiltIn: false)))
            added = true
        }
        if added { normalizeCategorySortOrders() }
        return added
    }

    /// Dart `_containsName`: same type, names equal after lowercasing (the
    /// candidate is trimmed, the stored name is not). The first
    /// `trimmingStoredBefore` rows are compared trimmed too (see
    /// `materializeCategories`); 0 is Dart's rule exactly.
    func containsCategory(type: TransactionType, name: String, trimmingStoredBefore: Int = 0) -> Bool {
        let wanted = DartString.lowercase(DartString.trim(name))
        return categoryRows.enumerated().contains { index, row in
            guard let record = row.record, record.type == type else { return false }
            let stored = index < trimmingStoredBefore ? DartString.trim(record.name) : record.name
            return DartString.equal(DartString.lowercase(stored), wanted)
        }
    }

    /// Dart `_uniqueId`: `type-slug`, or `type-uuid` when that id is taken.
    /// The slug is the trimmed, lowercased name with each run of characters
    /// outside [a-z0-9] replaced by "-", and leading/trailing "-" removed.
    func uniqueCategoryID(type: TransactionType, name: String, newID: () -> String) -> String {
        var slug = ""
        var inRun = false
        for unit in DartString.lowercase(DartString.trim(name)).utf16 {
            if (0x61...0x7A).contains(unit) || (0x30...0x39).contains(unit) {
                slug.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
                inRun = false
            } else if !inRun {
                slug.append("-")
                inRun = true
            }
        }
        while slug.hasPrefix("-") { slug.removeFirst() }
        while slug.hasSuffix("-") { slug.removeLast() }
        let candidate = "\(type.rawValue)-\(slug.isEmpty ? "category" : slug)"
        if categoryRows.contains(where: { $0.record?.id == candidate }) { return "\(type.rawValue)-\(newID())" }
        return candidate
    }

    /// Dart `_normalizeSortOrders`: per type, every definition (archived
    /// included) ordered by sortOrder, stable, renumbered 0..n-1. Only rows
    /// whose number changes are patched.
    mutating func normalizeCategorySortOrders() {
        for type in TransactionType.allCases {
            let ordered = categoryRows.indices
                .filter { categoryRows[$0].record?.type == type }
                .enumerated()
                .sorted { a, b in
                    let x = categoryRows[a.element].record!.sortOrder, y = categoryRows[b.element].record!.sortOrder
                    return x != y ? x < y : a.offset < b.offset
                }
                .map(\.element)
            for (position, index) in ordered.enumerated() {
                guard let record = categoryRows[index].record, record.sortOrder != position else { continue }
                categoryRows[index] = .record(record.with(sortOrder: position))
            }
        }
    }

    /// Dart's runtime `expenseCategories` / `incomeCategories` keys
    /// (`_syncCompatibilityMaps`): the active definitions of `type` by sort
    /// order, nothing else. No transaction scan: the launch pass
    /// (`ensureLegacyCategories`, run by `load`) has already defined every
    /// (type, name) in use, and a name matching an archived definition gets
    /// none (Dart `_containsName` sees archived ones), so Flutter's list has
    /// no entry for it either.
    public func categoryPicker(for type: TransactionType) -> [CategoryInfo] {
        CategoryCatalog.pickerList(categories, type: type, usedNames: [])
    }

    /// A case-insensitive match compared as UTF-16, as Dart's
    /// `name.toLowerCase() == other.toLowerCase()` (category_provider.dart
    /// `_containsName`), so NFC and NFD spellings are different categories.
    public func categoryInfo(named name: String, type: TransactionType) -> CategoryInfo? {
        let wanted = DartString.lowercase(name)
        return categories.first { $0.type == type && DartString.equal(DartString.lowercase($0.name), wanted) }
    }
}
