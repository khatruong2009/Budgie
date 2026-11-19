import Foundation

/// Typed, lossless views over stored rows.
///
/// Each record keeps the raw JSON object it was read from. Reading follows
/// the Dart `fromJson` of the same model (what is required, defaults for
/// missing keys, type tolerance). Editing changes only the keys it touches,
/// so unknown keys and every untouched lexeme survive. A new record is built
/// with exactly the keys, order and JSON types Dart's `toJson` writes.
///
/// Where Dart would throw on a malformed row (and, for some sections, abort
/// the whole load), the Swift side treats that single row as unreadable:
/// hidden from the UI and written back unchanged.

enum Read {
    /// `x as T?`: `.some(nil)` for missing/null, the converted value, nil
    /// (failure) when `convert` rejects the JSON type.
    private static func optional<T>(_ object: JSONObject, _ key: String, _ convert: (JSONValue) -> T?) -> T?? {
        switch object[key] {
        case nil, .null?: return .some(nil)
        case let value?: return convert(value).map { Optional($0) }
        }
    }

    /// `x as String?`: nil for missing/null, failure for another type.
    static func optionalString(_ object: JSONObject, _ key: String) -> String?? {
        optional(object, key, \.stringValue)
    }

    /// `(x as num).toDouble()`.
    static func num(_ object: JSONObject, _ key: String) -> Double? {
        object[key]?.numberValue?.doubleValue
    }

    /// `x as bool?`: .some(nil) for missing/null, nil (failure) for another type.
    static func optionalBool(_ object: JSONObject, _ key: String) -> Bool?? {
        optional(object, key, \.boolValue)
    }

    /// `x as int?` (strict: a number with a fractional lexeme fails).
    static func optionalInt(_ object: JSONObject, _ key: String) -> Int?? {
        switch object[key] {
        case nil, .null?: return .some(nil)
        case .number(let n)? where n.isDartInt: return .some(n.intValue.map { Int($0) })
        default: return nil
        }
    }

    /// `(x as num?)?.toInt()`: any number, converted as Dart's `toInt`.
    static func optionalNumber(_ object: JSONObject, _ key: String) -> Int?? {
        optional(object, key) { $0.numberValue.map { Int(DartNumbers.toInt($0)) } }
    }

    /// `(x as num?)?.toDouble()`.
    static func optionalDouble(_ object: JSONObject, _ key: String) -> Double?? {
        optional(object, key) { $0.numberValue?.doubleValue }
    }

    /// A lenient date: nil for a missing, non-string, empty or unparseable value.
    static func optionalDate(_ object: JSONObject, _ key: String, _ calendar: DartCalendar) -> DartDateTime? {
        guard let text = object[key]?.stringValue, !text.isEmpty else { return nil }
        return calendar.tryParse(text)
    }

    /// A list of strings (non-strings dropped): [] for missing/null, nil
    /// (failure) for another type.
    static func stringArray(_ object: JSONObject, _ key: String) -> [String]? {
        switch object[key] {
        case nil, .null?: return []
        case .array(let items)?: return items.compactMap(\.stringValue)
        default: return nil
        }
    }

    /// Dart `DateTime.parse(x)` where x must be a String.
    static func parsedDate(_ object: JSONObject, _ key: String, _ calendar: DartCalendar) -> DartDateTime? {
        guard let text = object[key]?.stringValue else { return nil }
        return calendar.tryParse(text)
    }
}
