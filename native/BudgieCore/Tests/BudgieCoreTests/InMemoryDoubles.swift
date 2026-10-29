import Foundation

@testable import BudgieCore

/// An in-memory store directory for tests.
public final class InMemoryFileSystem: StoreFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: [UInt8]]
    private var directories: Set<String>

    public init(files: [String: [UInt8]] = [:], directories: Set<String> = []) {
        self.files = files
        self.directories = directories
    }

    public var snapshot: [String: [UInt8]] {
        lock.withLock { files }
    }

    public func set(_ name: String, _ bytes: [UInt8]?) {
        lock.withLock { files[name] = bytes }
    }

    public func read(_ name: String) throws -> [UInt8]? {
        try lock.withLock {
            if directories.contains(name) { throw StoreFileSystemError.notAFile(name: name) }
            return files[name]
        }
    }

    public func writeStaged(_ name: String, _ bytes: [UInt8]) throws {
        lock.withLock { files[name + ".tmp"] = bytes }
    }

    public func commitStaged(_ name: String) throws {
        try lock.withLock {
            guard let staged = files.removeValue(forKey: name + ".tmp") else {
                throw StoreFileSystemError.posix(operation: "rename", name: name, errno: ENOENT)
            }
            files[name] = staged
        }
    }

    public func rename(_ name: String, to newName: String) throws {
        try lock.withLock {
            guard let bytes = files.removeValue(forKey: name) else {
                throw StoreFileSystemError.posix(operation: "rename", name: name, errno: ENOENT)
            }
            files[newName] = bytes
        }
    }

    public func list() throws -> [String] {
        lock.withLock { files.keys.sorted() }
    }
}

/// Preferences held in memory, for tests.
public final class InMemoryPreferences: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: PreferenceValue]

    public init(_ values: [String: PreferenceValue] = [:]) {
        self.values = values
    }

    public func value(forKey key: String) -> PreferenceValue? {
        lock.withLock { values[key] }
    }

    public func set(_ value: PreferenceValue?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    public func allKeys() -> [String] {
        lock.withLock { values.keys.sorted() }
    }

    public var all: [String: PreferenceValue] {
        lock.withLock { values }
    }
}
