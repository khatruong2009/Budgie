import Foundation

/// Rule 1 of the migration: before the Swift app reads or writes any
/// financial data, it copies everything the Flutter app left behind into
/// `Application Support/pre-native-migration/<stamp>/`. Never deleted
/// automatically. MIGRATION_SPEC section 10.
public struct PreNativeMigrationBackup: Sendable {
    public static let folderName = "pre-native-migration"
    public static let completeMarker = "COMPLETE"
    public static let manifestName = "manifest.json"

    public struct Sources: Sendable {
        /// `<Application Support>/financial_store`
        public var storeDirectory: URL
        /// The app's `NSUserDefaults` persistent domain as a plist.
        public var exportPreferences: @Sendable () throws -> Data
        /// The App Group suite's persistent domain as a plist.
        public var exportAppGroupPreferences: @Sendable () throws -> Data

        public init(
            storeDirectory: URL, exportPreferences: @escaping @Sendable () throws -> Data,
            exportAppGroupPreferences: @escaping @Sendable () throws -> Data
        ) {
            self.storeDirectory = storeDirectory
            self.exportPreferences = exportPreferences
            self.exportAppGroupPreferences = exportAppGroupPreferences
        }
    }

    public let root: URL
    public let sources: Sources
    public let clock: @Sendable () -> Date
    public let appVersion: String

    public init(applicationSupport: URL, sources: Sources, appVersion: String, clock: @escaping @Sendable () -> Date = { Date() }) {
        root = applicationSupport.appendingPathComponent(PreNativeMigrationBackup.folderName, isDirectory: true)
        self.sources = sources
        self.appVersion = appVersion
        self.clock = clock
    }

    public enum Outcome: Equatable, Sendable {
        case created(URL)
        case alreadyCurrent(URL)
    }

    /// Takes a snapshot unless a complete one already covers the current
    /// primary file (the one recorded in the newest manifest, or the one this
    /// Swift install last committed). Throws if the copy cannot be made; the
    /// caller must not touch the store then.
    public func ensure(lastCommittedChecksum: String?) throws -> Outcome {
        let current = try currentPrimaryChecksum()
        if let latest = try latestComplete() {
            let recorded = try recordedPrimaryChecksum(latest)
            // A matching primary says nothing about a backup-only recovery
            // or legacy preferences written since the previous snapshot.
            // Also verify the safety copy itself before relying on it.
            if try isIntact(latest),
                try (current != nil && current == lastCommittedChecksum
                    || current == recorded && matchesSources(latest))
            {
                return .alreadyCurrent(latest)
            }
        }
        return .created(try create())
    }

    /// Complete snapshots, oldest first.
    public func completeSnapshots() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(PreNativeMigrationBackup.completeMarker).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func latestComplete() throws -> URL? {
        try completeSnapshots().last
    }

    private func currentPrimaryChecksum() throws -> String? {
        let primary = sources.storeDirectory.appendingPathComponent(StoreFile.primaryName)
        guard FileManager.default.fileExists(atPath: primary.path) else { return nil }
        let bytes = [UInt8](try Data(contentsOf: primary))
        return StoreFile.verify(bytes)?.payloadChecksum ?? "unverified:" + sha256Hex(Data(bytes))
    }

    private func recordedPrimaryChecksum(_ snapshot: URL) throws -> String? {
        let data = try Data(contentsOf: snapshot.appendingPathComponent(PreNativeMigrationBackup.manifestName))
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return manifest?["primaryChecksum"] as? String
    }

    private func isIntact(_ snapshot: URL) throws -> Bool {
        let manifestData = try Data(contentsOf: snapshot.appendingPathComponent(Self.manifestName))
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
            let files = manifest["files"] as? [[String: Any]],
            let preferencesHash = manifest["preferencesSha256"] as? String,
            let appGroupHash = manifest["appGroupSha256"] as? String
        else { return false }
        for file in files {
            guard let name = file["name"] as? String, let hash = file["sha256"] as? String,
                let data = try? Data(contentsOf: snapshot.appendingPathComponent(StoreFile.directoryName).appendingPathComponent(name)),
                sha256Hex(data) == hash
            else { return false }
        }
        guard let prefs = try? Data(contentsOf: snapshot.appendingPathComponent("preferences.plist")),
            let group = try? Data(contentsOf: snapshot.appendingPathComponent("app-group.plist"))
        else { return false }
        return sha256Hex(prefs) == preferencesHash && sha256Hex(group) == appGroupHash
    }

    private func matchesSources(_ snapshot: URL) throws -> Bool {
        let fm = FileManager.default
        let copy = snapshot.appendingPathComponent(StoreFile.directoryName)
        let names = fm.fileExists(atPath: sources.storeDirectory.path)
            ? try fm.contentsOfDirectory(atPath: sources.storeDirectory.path).sorted() : []
        guard names == (try fm.contentsOfDirectory(atPath: copy.path).sorted()) else { return false }
        for name in names {
            guard try Data(contentsOf: sources.storeDirectory.appendingPathComponent(name))
                == Data(contentsOf: copy.appendingPathComponent(name))
            else { return false }
        }
        return try sources.exportPreferences() == Data(contentsOf: snapshot.appendingPathComponent("preferences.plist"))
            && sources.exportAppGroupPreferences() == Data(contentsOf: snapshot.appendingPathComponent("app-group.plist"))
    }

    private func create() throws -> URL {
        let fm = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(formatter.string(from: clock()))-\(UUID().uuidString.prefix(8).lowercased())"
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let storeCopy = folder.appendingPathComponent(StoreFile.directoryName, isDirectory: true)
        try fm.createDirectory(at: storeCopy, withIntermediateDirectories: true)

        var files: [[String: Any]] = []
        if fm.fileExists(atPath: sources.storeDirectory.path) {
            for item in try fm.contentsOfDirectory(at: sources.storeDirectory, includingPropertiesForKeys: nil)
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                let destination = storeCopy.appendingPathComponent(item.lastPathComponent)
                try fm.copyItem(at: item, to: destination)
                let original = try Data(contentsOf: item)
                let copy = try Data(contentsOf: destination)
                guard original == copy else { throw CopyError.copyMismatch(item.lastPathComponent) }
                try flush(destination)
                files.append(["name": item.lastPathComponent, "size": original.count, "sha256": sha256Hex(original)])
            }
        }
        let preferences = try sources.exportPreferences()
        try write(preferences, to: folder.appendingPathComponent("preferences.plist"))
        let appGroup = try sources.exportAppGroupPreferences()
        try write(appGroup, to: folder.appendingPathComponent("app-group.plist"))

        let manifest: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: clock()),
            "appVersion": appVersion,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "primaryChecksum": try currentPrimaryChecksum() ?? NSNull(),
            "files": files,
            "preferencesSha256": sha256Hex(preferences),
            "appGroupSha256": sha256Hex(appGroup),
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try write(manifestData, to: folder.appendingPathComponent(PreNativeMigrationBackup.manifestName))
        // Written last: a snapshot without it is incomplete and ignored.
        try write(Data("ok\n".utf8), to: folder.appendingPathComponent(PreNativeMigrationBackup.completeMarker))
        return folder
    }

    /// A staged copy that does not read back identical (not the backup-file
    /// `BackupError` of the Data export/import).
    public enum CopyError: Error, Equatable {
        case copyMismatch(String)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        guard try Data(contentsOf: url) == data else { throw CopyError.copyMismatch(url.lastPathComponent) }
        try flush(url)
    }

    private func flush(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw StoreFileSystemError.posix(operation: "open", name: url.lastPathComponent, errno: errno)
        }
        defer { close(fd) }
        if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 {
            throw StoreFileSystemError.posix(operation: "fsync", name: url.lastPathComponent, errno: errno)
        }
    }
}
