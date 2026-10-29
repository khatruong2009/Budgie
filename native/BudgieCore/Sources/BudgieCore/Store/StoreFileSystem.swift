import Foundation

/// The few file primitives the store needs, split finely enough that tests
/// can crash the commit protocol between any two of them.
///
/// Names are plain file names inside the store directory.
public protocol StoreFileSystem: Sendable {
    /// Bytes of the file, or nil only when it does not exist. Any other
    /// failure (a directory in its place, permissions, protected data,
    /// I/O) throws: a read error must never look like an empty store.
    func read(_ name: String) throws -> [UInt8]?

    /// Writes `<name>.tmp` completely (truncating) and flushes it to stable
    /// storage.
    func writeStaged(_ name: String, _ bytes: [UInt8]) throws

    /// Atomically renames `<name>.tmp` over `<name>` and makes the rename
    /// durable.
    func commitStaged(_ name: String) throws

    /// Renames a file (used to set damaged files aside).
    func rename(_ name: String, to newName: String) throws

    /// Names of the regular files in the store directory.
    func list() throws -> [String]
}

public enum StoreFileSystemError: Error, Equatable, Sendable {
    case posix(operation: String, name: String, errno: Int32)
    case notAFile(name: String)
}

/// The real store directory: `<Application Support>/financial_store/`.
public final class DirectoryFileSystem: StoreFileSystem, @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    public func read(_ name: String) throws -> [UInt8]? {
        let path = path(name)
        var info = stat()
        if stat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw StoreFileSystemError.posix(operation: "stat", name: name, errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw StoreFileSystemError.notAFile(name: name) }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw StoreFileSystemError.posix(operation: "open", name: name, errno: errno) }
        defer { close(fd) }
        var result: [UInt8] = []
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw StoreFileSystemError.posix(operation: "read", name: name, errno: errno)
            }
            if count == 0 { break }
            result.append(contentsOf: buffer[0..<count])
        }
        return result
    }

    public func writeStaged(_ name: String, _ bytes: [UInt8]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staged = path(name + ".tmp")
        let fd = open(staged, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw StoreFileSystemError.posix(operation: "open", name: name + ".tmp", errno: errno) }
        var closed = false
        defer { if !closed { close(fd) } }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw StoreFileSystemError.posix(operation: "write", name: name + ".tmp", errno: errno)
            }
            offset += written
        }
        // F_FULLFSYNC asks the drive to flush its cache too; fall back to
        // fsync where it is unsupported.
        if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 {
            throw StoreFileSystemError.posix(operation: "fsync", name: name + ".tmp", errno: errno)
        }
        closed = true
        if close(fd) != 0 {
            throw StoreFileSystemError.posix(operation: "close", name: name + ".tmp", errno: errno)
        }
        #if os(iOS)
        // What the Flutter app's files get by default; stated explicitly.
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: staged)
        #endif
    }

    public func commitStaged(_ name: String) throws {
        if Darwin.rename(path(name + ".tmp"), path(name)) != 0 {
            throw StoreFileSystemError.posix(operation: "rename", name: name, errno: errno)
        }
        syncDirectory()
    }

    public func rename(_ name: String, to newName: String) throws {
        if Darwin.rename(path(name), path(newName)) != 0 {
            throw StoreFileSystemError.posix(operation: "rename", name: name, errno: errno)
        }
        syncDirectory()
    }

    public func list() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path(name), isDirectory: &isDirectory) && !isDirectory.boolValue
        }.sorted()
    }

    /// Makes a rename durable. Best effort: failure here does not undo the
    /// rename, and the store verifies the result by reading it back.
    private func syncDirectory() {
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
