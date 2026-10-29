import Foundation
import Testing

@testable import BudgieCore

/// Fixture text (a JSON string value) as the UTF-8 bytes it stands for.
func fixtureBytes(_ value: J) -> [UInt8] {
    guard case .string(let string)? = value.value else { return [] }
    return Array(String(decoding: string.codeUnits, as: UTF16.self).utf8)
}

/// The zones the backup fixtures are generated in.
let backupZones = ["America/New_York", "Australia/Lord_Howe", "UTC", "America/Santiago"]

func backupFixture(_ zone: String, _ file: String) throws -> J {
    try Fixtures.json("\(Fixtures.zonePath("backup", zone))/\(file)")
}

/// Typed preferences (the harness `typedPrefs` form) as a fixture value.
func typedPreferences(_ value: J) -> [String: PreferenceValue] {
    var result: [String: PreferenceValue] = [:]
    for key in value.keys {
        let entry = value[key]
        switch entry["type"].string {
        case "string": result[key] = .string(entry["value"].string!)
        case "stringList": result[key] = .stringList(entry["value"].array.map { $0.string! })
        case "int": result[key] = .int(Int64(entry["value"].int!))
        case "double": result[key] = .double(entry["value"].double!)
        case "bool": result[key] = .bool(entry["value"].bool!)
        default: Issue.record("pref type \(key)")
        }
    }
    return result
}

/// Every string value in a JSON tree (keys included).
func allStrings(_ value: JSONValue, into set: inout Set<[UInt16]>) {
    switch value {
    case .string(let s): set.insert(s.codeUnits)
    case .array(let items): for item in items { allStrings(item, into: &set) }
    case .object(let object):
        for member in object.members {
            set.insert(member.key.codeUnits)
            allStrings(member.value, into: &set)
        }
    default: break
    }
}

/// Row ids (objects in arrays) not in `known`, in document order: the
/// harness `generatedIds`.
func generatedIDs(_ value: JSONValue, known: Set<[UInt16]>) -> [String] {
    var found: [String] = []
    func walk(_ value: JSONValue) {
        switch value {
        case .array(let items):
            for item in items {
                if case .object(let row) = item, case .string(let id)? = row["id"], !known.contains(id.codeUnits) {
                    found.append(id.value)
                }
                walk(item)
            }
        case .object(let object):
            for member in object.members { walk(member.value) }
        default:
            break
        }
    }
    walk(value)
    return found
}

/// Swift's output with the ids it generated replaced, in order, by the ones
/// Dart generated (both sides draw them at random).
func substitutingGeneratedIDs(_ bytes: [UInt8], dart: [String], known: Set<[UInt16]>) throws -> [UInt8] {
    let swift = generatedIDs(try JSONParser.parse(bytes), known: known)
    guard swift.count == dart.count else {
        Issue.record("generated ids: swift \(swift.count) dart \(dart.count)")
        return bytes
    }
    var text = String(decoding: bytes, as: UTF8.self)
    for (mine, theirs) in zip(swift, dart) {
        text = text.replacingOccurrences(of: "\"\(mine)\"", with: "\"\(theirs)\"")
    }
    return Array(text.utf8)
}

/// Base64 fixture bytes.
func base64Bytes(_ value: J) -> [UInt8] {
    [UInt8](Data(base64Encoded: value.string ?? "") ?? Data())
}
