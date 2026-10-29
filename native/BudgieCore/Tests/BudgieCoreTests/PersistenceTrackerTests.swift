import Foundation
import Testing

@testable import BudgieCore

/// Fails every write while `broken` is set.
final class FlakyFileSystem: ForwardingStoreFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var _broken = false
    var broken: Bool {
        get { lock.withLock { _broken } }
        set { lock.withLock { _broken = newValue } }
    }
    init() { super.init(base: InMemoryFileSystem()) }
    override func writeStaged(_ name: String, _ bytes: [UInt8]) throws {
        if broken { throw StoreFileSystemError.posix(operation: "write", name: name, errno: ENOSPC) }
        try super.writeStaged(name, bytes)
    }
}

@Suite("Unsaved-changes tracking (PersistenceStatus)")
@MainActor
struct PersistenceTrackerTests {
    @Test("a failed save is flagged, carried by the next save, and cleared by it")
    func failureAndHealing() async throws {
        let fs = FlakyFileSystem()
        let store = FinancialStore(fileSystem: fs, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        let tracker = PersistenceTracker(store: store)
        var memory: [String: JSONValue] = ["transactions": .array([]), "recurringTransactions": .array([])]
        let serialize: (String) -> JSONValue = { memory[$0] ?? .null }

        fs.broken = true
        memory["transactions"] = .array([.string("t1")])
        #expect(await tracker.persist([("transactions", memory["transactions"]!)], serialize: serialize) == false)
        #expect(tracker.hasUnsavedChanges)
        #expect(tracker.unsavedSections == ["transactions"])
        #expect(tracker.lastError != nil)

        fs.broken = false
        memory["recurringTransactions"] = .array([.string("r1")])
        #expect(await tracker.persist([("recurringTransactions", memory["recurringTransactions"]!)], serialize: serialize))
        #expect(!tracker.hasUnsavedChanges)
        #expect(tracker.lastError == nil)

        let reloaded = try await FinancialStore(fileSystem: fs, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow).read()
        #expect(reloaded.sections["transactions"] == .array([.string("t1")]), "the flagged section was healed by the later save")
        #expect(reloaded.sections["recurringTransactions"] == .array([.string("r1")]))
    }

    @Test("retry writes the current in-memory value of every flagged section")
    func retry() async throws {
        let fs = FlakyFileSystem()
        let store = FinancialStore(fileSystem: fs, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        let tracker = PersistenceTracker(store: store)
        var memory: [String: JSONValue] = [:]
        fs.broken = true
        memory["transactions"] = .int(1)
        _ = await tracker.persist([("transactions", .int(1))], serialize: { memory[$0] ?? .null })
        memory["transactions"] = .int(2)  // edited again while unsaved
        #expect(await tracker.retry(serialize: { memory[$0] ?? .null }) == false)
        fs.broken = false
        #expect(await tracker.retry(serialize: { memory[$0] ?? .null }))
        let reloaded = try await FinancialStore(fileSystem: fs, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow).read()
        #expect(reloaded.sections["transactions"] == .int(2))
    }

    @Test("flag marks sections unsaved without writing; the next retry writes them")
    func flagWithoutWriting() async throws {
        let fs = FlakyFileSystem()
        let store = FinancialStore(fileSystem: fs, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        let tracker = PersistenceTracker(store: store)
        let memory: [String: JSONValue] = ["transactions": .int(7)]
        tracker.flag(["transactions"], because: .writeFailed(name: "transactions", reason: "held"))
        #expect(tracker.unsavedSections == ["transactions"])
        #expect(tracker.lastError == .writeFailed(name: "transactions", reason: "held"))
        #expect(try fs.list().isEmpty, "nothing written")
        #expect(await tracker.retry(serialize: { memory[$0] ?? .null }))
        #expect(!tracker.hasUnsavedChanges)
        #expect(tracker.lastError == nil)
        let reloaded = try await FinancialStore(fileSystem: fs, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow).read()
        #expect(reloaded.sections["transactions"] == .int(7))
    }
}
