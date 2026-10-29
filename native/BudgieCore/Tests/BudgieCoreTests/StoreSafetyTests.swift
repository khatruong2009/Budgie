import Foundation
import Testing

@testable import BudgieCore

/// Wraps a file system and fails at a chosen primitive operation, the way a
/// crash, a full disk or a device lock would.
final class FaultyFileSystem: ForwardingStoreFileSystem, @unchecked Sendable {
    enum Fault {
        /// Process dies before the operation has any effect.
        case crashBefore
        /// Process dies halfway through writing the staged file.
        case crashTornWrite
        /// The disk is full: the staged write fails, leaving a partial file.
        case diskFull
    }

    struct Crash: Error {}

    private let lock = NSLock()
    private var operation = 0
    let failAt: Int?
    let fault: Fault
    private(set) var reads = 0

    init(base: InMemoryFileSystem, failAt: Int?, fault: Fault = .crashBefore) {
        self.failAt = failAt
        self.fault = fault
        super.init(base: base)
    }

    private func step() -> Bool {
        lock.withLock {
            defer { operation += 1 }
            return operation == failAt
        }
    }

    override func read(_ name: String) throws -> [UInt8]? {
        lock.withLock { reads += 1 }
        return try super.read(name)
    }

    override func writeStaged(_ name: String, _ bytes: [UInt8]) throws {
        if step() {
            switch fault {
            case .crashBefore: throw Crash()
            case .crashTornWrite, .diskFull:
                base.set(name + ".tmp", Array(bytes.prefix(bytes.count / 2)))
                throw fault == .diskFull ? StoreFileSystemError.posix(operation: "write", name: name, errno: ENOSPC) : Crash()
            }
        }
        try super.writeStaged(name, bytes)
    }

    override func commitStaged(_ name: String) throws {
        if step() { throw Crash() }
        try super.commitStaged(name)
    }

    override func rename(_ name: String, to newName: String) throws {
        if step() { throw Crash() }
        try super.rename(name, to: newName)
    }
}

final class Switch: ProtectedDataAvailability, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isProtectedDataAvailable: Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}

func typicalFiles() throws -> [String: [UInt8]] {
    let input = Fixtures.url("store/typical/input")
    var files: [String: [UInt8]] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: input.path) {
        files[name] = [UInt8](try Data(contentsOf: input.appendingPathComponent(name)))
    }
    return files
}

let testZone = TimeZone(identifier: "America/New_York")!
let fixedNow: @Sendable () -> DartDateTime = { DartDateTime(2026, 9, 28, 12, timeZone: testZone)! }

@Suite("Store safety: crashes, full disk, locked device, concurrency")
struct StoreSafetyTests {
    @Test("a crash or full disk at every step of a commit loses nothing that was saved")
    func crashAtEveryStep() async throws {
        for fault in [FaultyFileSystem.Fault.crashBefore, .crashTornWrite, .diskFull] {
            // Commit = backup stage + rename, primary stage + rename (4 ops).
            for failAt in 0..<4 {
                let base = InMemoryFileSystem(files: try typicalFiles())
                let before = try await FinancialStore(
                    fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow
                ).read()

                let faulty = FaultyFileSystem(base: base, failAt: failAt, fault: fault)
                let store = FinancialStore(fileSystem: faulty, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
                await #expect(throws: FinancialStoreError.self) {
                    try await store.updateSections([("probe", .string("after"))])
                }

                // Relaunch on whatever reached the disk.
                let after = try await FinancialStore(
                    fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow
                ).read()
                if after.revision == before.revision {
                    #expect(after.sections == before.sections, "\(fault) at \(failAt): old state intact")
                } else {
                    #expect(after.revision == before.revision + 1, "\(fault) at \(failAt)")
                    #expect(after.sections["probe"]?.stringValue == "after")
                }
                // The primary always decodes after a crash (rename is atomic).
                #expect(StoreFile.decode(base.snapshot[StoreFile.primaryName]!) != nil, "\(fault) at \(failAt)")
            }
        }
    }

    @Test("a crash after the primary rename but before verification still yields the new revision")
    func crashAfterRename() async throws {
        let base = InMemoryFileSystem(files: try typicalFiles())
        let store = FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        let start = try await store.read().revision
        try await store.updateSections([("probe", .int(1))])
        let reloaded = try await FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow).read()
        #expect(reloaded.revision == start + 1)
        // Backup holds the previous revision.
        #expect(StoreFile.verify(base.snapshot[StoreFile.backupName]!)!.revision == start)
    }

    @Test("locked device: nothing is read or written, and an empty view is never saved")
    func lockedDevice() async throws {
        let gate = Switch(false)
        let base = InMemoryFileSystem(files: try typicalFiles())
        let spy = FaultyFileSystem(base: base, failAt: nil)
        let prefs = InMemoryPreferences([PreferenceKey.transactions: .string("[]")])
        let store = FinancialStore(fileSystem: spy, preferences: prefs, protectedData: gate, clock: fixedNow)
        let original = base.snapshot

        await #expect(throws: FinancialStoreError.protectedDataUnavailable) { try await store.read() }
        await #expect(throws: FinancialStoreError.protectedDataUnavailable) {
            try await store.updateSections([("x", .null)])
        }
        #expect(spy.reads == 0)
        #expect(base.snapshot == original)
        #expect(prefs.contains(PreferenceKey.transactions), "legacy keys untouched while locked")

        gate.set(true)
        let loaded = try await store.read()
        #expect(loaded.revision > 0)
        #expect(base.snapshot == original, "loading a healthy store writes nothing")
    }

    @Test("the device locking mid-commit fails the commit without damage")
    func lockDuringCommit() async throws {
        let gate = Switch(true)
        let base = InMemoryFileSystem(files: try typicalFiles())
        let store = FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: gate, clock: fixedNow)
        let before = try await store.read()
        gate.set(false)
        await #expect(throws: FinancialStoreError.protectedDataUnavailable) {
            try await store.updateSections([("probe", .null)])
        }
        gate.set(true)
        let after = try await FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: gate, clock: fixedNow).read()
        #expect(after == before)
    }

    @Test("concurrent edits are serialized: every one lands, revisions are sequential")
    func concurrency() async throws {
        let base = InMemoryFileSystem()
        let store = FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { _ = try? await store.updateSections([("k\(i)", .int(i))]) }
            }
        }
        let final = try await FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow).read()
        #expect(final.revision == 50)
        for i in 0..<50 { #expect(final.sections["k\(i)"]?.numberValue?.intValue == Int64(i)) }
    }

    @Test("random edit sequences: save -> load is identical every time (seeded)")
    func property() async throws {
        var rng = SeededGenerator(seed: 20_260_928)
        for round in 0..<60 {
            let base = InMemoryFileSystem(files: round % 2 == 0 ? try typicalFiles() : [:])
            var expected = try await FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow).read()
            let store = FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                let key = ["transactions", "futureFeature", "appSettings", "x\(Int.random(in: 0...5, using: &rng))"].randomElement(using: &rng)!
                let value = randomJSON(depth: 3, using: &rng)
                expected = expected.applying([(key, value)])
                let written = try await store.updateSections([(key, value)])
                #expect(written == expected)
            }
            let reloaded = try await FinancialStore(fileSystem: base, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow).read()
            #expect(reloaded == expected, "round \(round)")
        }
    }

    @Test("both files unreadable: Swift stops (approved divergence) until acknowledged")
    func unreadableStops() async throws {
        var files = try typicalFiles()
        for name in [StoreFile.primaryName, StoreFile.backupName] { files[name] = Array(files[name]!.dropLast()) }
        let base = InMemoryFileSystem(files: files)
        let prefs = InMemoryPreferences()
        let store = FinancialStore(fileSystem: base, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        var corrupt: [String] = []
        do {
            _ = try await store.read()
            Issue.record("expected dataUnreadable")
        } catch .dataUnreadable(let names) {
            corrupt = names
        }
        #expect(corrupt.count == 2)
        // A relaunch still stops: the files are set aside, not forgotten.
        let relaunch = FinancialStore(fileSystem: base, preferences: prefs, protectedData: AlwaysAvailable(), clock: fixedNow)
        await #expect(throws: FinancialStoreError.dataUnreadable(corruptFiles: corrupt)) { try await relaunch.read() }
        try await relaunch.acknowledgeUnreadableData(corrupt)
        #expect(try await relaunch.read() == .empty)
        #expect(base.snapshot.keys.filter { $0.contains(".corrupt-") }.count == 2, "set-aside files are kept")
    }

    @Test("the real directory backend: commit, reload, and a directory in place of the primary")
    func directoryBackend() async throws {
        let dir = TestDirectory.make("budgie-store").appendingPathComponent("financial_store")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let fs = DirectoryFileSystem(directory: dir)
        let store = FinancialStore(fileSystem: fs, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        #expect(try await store.read() == .empty)
        #expect(try fs.list().isEmpty, "a fresh install writes nothing on load")
        try await store.updateSections([("a", .double(1200.0))])
        try await store.updateSections([("b", .string("😀"))])
        let reloaded = try await FinancialStore(fileSystem: fs, preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow).read()
        #expect(reloaded.revision == 2)
        #expect(reloaded.sections["a"]?.numberValue?.lexeme == "1200.0")
        #expect(try fs.list() == [StoreFile.backupName, StoreFile.primaryName])

        let broken = TestDirectory.make("budgie-store")
        defer { try? FileManager.default.removeItem(at: broken) }
        try FileManager.default.createDirectory(at: broken.appendingPathComponent(StoreFile.primaryName), withIntermediateDirectories: true)
        let failing = FinancialStore(fileSystem: DirectoryFileSystem(directory: broken), preferences: InMemoryPreferences(), protectedData: AlwaysAvailable(), clock: fixedNow)
        do {
            _ = try await failing.read()
            Issue.record("a directory must be a read error, never an empty store")
        } catch .readFailed {
        }
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomJSON(depth: Int, using rng: inout SeededGenerator) -> JSONValue {
    let choice = Int.random(in: 0...(depth > 0 ? 7 : 4), using: &rng)
    switch choice {
    case 0: return .null
    case 1: return .bool(Bool.random(using: &rng))
    case 2: return .int(Int.random(in: -1_000_000...1_000_000, using: &rng))
    case 3:
        let bits = UInt64.random(in: 0...UInt64.max, using: &rng)
        let value = Double(bitPattern: bits)
        return value.isFinite ? .double(value) : .double(Double(Int.random(in: -99...99, using: &rng)) / 100)
    case 4:
        let pool = ["", "Café", "😀", "\"q\"", "a/b", "line\nbreak", "\u{7}", "\u{2028}", "Große"]
        return .string((0..<Int.random(in: 0...3, using: &rng)).map { _ in pool.randomElement(using: &rng)! }.joined())
    case 5, 6:
        return .array((0..<Int.random(in: 0...4, using: &rng)).map { _ in randomJSON(depth: depth - 1, using: &rng) })
    default:
        return .object(JSONObject(ordered: (0..<Int.random(in: 0...4, using: &rng)).map { i in
            ("k\(i)", randomJSON(depth: depth - 1, using: &rng))
        }))
    }
}
