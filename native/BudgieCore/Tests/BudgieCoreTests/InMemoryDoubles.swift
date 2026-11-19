import Foundation

@testable import BudgieCore

/// An in-memory store directory for tests.
final class InMemoryFileSystem: StoreFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: [UInt8]]
    private var directories: Set<String>

    init(files: [String: [UInt8]] = [:], directories: Set<String> = []) {
        self.files = files
        self.directories = directories
    }

    var snapshot: [String: [UInt8]] {
        lock.withLock { files }
    }

    func set(_ name: String, _ bytes: [UInt8]?) {
        lock.withLock { files[name] = bytes }
    }

    func read(_ name: String) throws -> [UInt8]? {
        try lock.withLock {
            if directories.contains(name) { throw StoreFileSystemError.notAFile(name: name) }
            return files[name]
        }
    }

    func writeStaged(_ name: String, _ bytes: [UInt8]) throws {
        lock.withLock { files[name + ".tmp"] = bytes }
    }

    func commitStaged(_ name: String) throws {
        try lock.withLock {
            guard let staged = files.removeValue(forKey: name + ".tmp") else {
                throw StoreFileSystemError.posix(operation: "rename", name: name, errno: ENOENT)
            }
            files[name] = staged
        }
    }

    func rename(_ name: String, to newName: String) throws {
        try lock.withLock {
            guard let bytes = files.removeValue(forKey: name) else {
                throw StoreFileSystemError.posix(operation: "rename", name: name, errno: ENOENT)
            }
            files[newName] = bytes
        }
    }

    func list() throws -> [String] {
        lock.withLock { files.keys.sorted() }
    }
}

/// Preferences held in memory, for tests.
final class InMemoryPreferences: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PreferenceValue]

    init(_ values: [String: PreferenceValue] = [:]) {
        self.values = values
    }

    func value(forKey key: String) -> PreferenceValue? {
        lock.withLock { values[key] }
    }

    func set(_ value: PreferenceValue?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    func allKeys() -> [String] {
        lock.withLock { values.keys.sorted() }
    }

    var all: [String: PreferenceValue] {
        lock.withLock { values }
    }
}
