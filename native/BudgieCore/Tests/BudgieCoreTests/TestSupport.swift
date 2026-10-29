import Foundation
import Testing

@testable import BudgieCore

/// Navigation over expected.json parsed with the lossless parser, so doubles
/// compare bit for bit with what Dart printed.
struct J {
    let value: JSONValue?
    init(_ value: JSONValue?) { self.value = value }
    subscript(_ key: String) -> J { J(value?.objectValue?[key]) }
    subscript(_ index: Int) -> J { J(value?.arrayValue.flatMap { index < $0.count ? $0[index] : nil }) }
    var double: Double? { value?.numberValue?.doubleValue }
    var int: Int? { value?.numberValue?.intValue.map { Int($0) } }
    var string: String? { value?.stringValue }
    var bool: Bool? { value?.boolValue }
    var array: [J] { value?.arrayValue?.map { J($0) } ?? [] }
    var keys: [String] { value?.objectValue?.keys ?? [] }
    var isNull: Bool { value == nil || value!.isNull }
}

func loadExpected(_ url: URL) throws -> J {
    J(try JSONParser.parse([UInt8](Data(contentsOf: url.appendingPathComponent("expected.json")))))
}

/// Runs the Swift launch sequence (load, pending writes, generator, one
/// commit) the way the app does.
func launch(_ scenario: Scenario, zone: TimeZone = Scenario.zone) async throws -> FinancialData? {
    try await launchWithSnapshot(scenario, zone: zone)?.data
}

/// `launch`, plus the store's snapshot after the launch commits.
func launchWithSnapshot(
    _ scenario: Scenario, zone: TimeZone = Scenario.zone, matchesPaddedCategoryNames: Bool = false
) async throws -> (data: FinancialData, snapshot: FinancialSnapshot)? {
    let calendar = DartCalendar(timeZone: zone)
    let now = scenario.launchNow(in: zone)
    let store = scenario.makeStore(zone: zone)
    var snapshot: FinancialSnapshot
    do {
        snapshot = try await store.read()
    } catch .dataUnreadable(let names) {
        try await store.acknowledgeUnreadableData(names)
        snapshot = try await store.read()
    } catch {
        return nil
    }
    var loaded = FinancialData.load(
        snapshot, preferences: scenario.preferences, calendar: calendar, now: { now }, newID: { UUID().uuidString.lowercased() },
        matchesPaddedCategoryNames: matchesPaddedCategoryNames)
    if !loaded.pendingWrites.isEmpty { snapshot = try await store.updateSections(loaded.pendingWrites) }
    let result = RecurringGenerator.generateDue(in: &loaded.data, now: now, clock: { now }, newID: { UUID().uuidString.lowercased() })
    if result.changed {
        snapshot = try await store.updateSections([
            (Section.transactions, loaded.data.transactionsSection()),
            (Section.recurringTransactions, loaded.data.templatesSection()),
        ])
    }
    return (loaded.data, snapshot)
}

/// A Dart double printed as its 64-bit pattern in hex.
func bits(_ value: J) -> Double? {
    value.string.flatMap { UInt64($0, radix: 16) }.map { Double(bitPattern: $0) }
}

func strings(_ j: J) -> [String] { j.array.map { $0.string! } }

/// UTF-16 comparison, as Dart compares strings.
func same(_ actual: String, _ expected: String, _ label: String) {
    #expect(Array(actual.utf16) == Array(expected.utf16), "\(label): \(actual) | \(expected)")
}

func same(_ actual: [String], _ expected: [String], _ label: String) {
    #expect(actual.map { Array($0.utf16) } == expected.map { Array($0.utf16) }, "\(label): \(actual) | \(expected)")
}

enum TestDirectory {
    /// A fresh, not yet created path `<tmp>/<prefix>-<UUID>`. Callers create it
    /// and remove it in a `defer`, as before.
    static func make(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }
}

/// A `StoreFileSystem` that forwards every operation to an in-memory base.
/// Fault decorators subclass it and override only the operations they change
/// (calling `super` to perform the real one).
class ForwardingStoreFileSystem: StoreFileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    init(base: InMemoryFileSystem) { self.base = base }
    func read(_ name: String) throws -> [UInt8]? { try base.read(name) }
    func writeStaged(_ name: String, _ bytes: [UInt8]) throws { try base.writeStaged(name, bytes) }
    func commitStaged(_ name: String) throws { try base.commitStaged(name) }
    func rename(_ name: String, to newName: String) throws { try base.rename(name, to: newName) }
    func list() throws -> [String] { try base.list() }
}
