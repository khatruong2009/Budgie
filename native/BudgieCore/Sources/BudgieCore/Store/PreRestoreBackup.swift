import Foundation

/// The safety copy taken before a backup is restored (D10): every file of
/// the store directory and the preferences, in
/// `Application Support/pre-restore/<stamp>/`, outside `financial_store/`
/// so neither app ever reads it.
///
/// Unlike `PreNativeMigrationBackup.ensure` this always copies (a restore
/// replaces a store the Swift app itself wrote). The restore must not run
/// when `create()` throws. After a successful restore, `prune()` keeps the
/// newest `retained` complete copies and always the one that restore
/// made; nothing else deletes them.
///
/// "Newest" is creation order, not the clock: each folder name starts with
/// a sequence number one above the highest already there
/// (`s000004-20260930-...`), so a device clock set back cannot make the
/// copy just taken sort first and be pruned. Folders from before the
/// sequence (a bare stamp) count as older than every numbered one.
public struct PreRestoreBackup: Sendable {
    public static let folderName = "pre-restore"
    public static let retained = 3
    public static let completeMarker = "COMPLETE"
    public static let manifestName = "manifest.json"
    public static let preferencesName = "preferences.plist"

    /// `<Application Support>/pre-restore`.
    public let root: URL
    /// The store directory (read only).
    public let store: StoreFileSystem
    /// The app's `NSUserDefaults` persistent domain as a plist.
    public let exportPreferences: @Sendable () throws -> Data
    public let appVersion: String
    public let clock: @Sendable () -> DartDateTime

    public init(
        applicationSupport: URL, store: StoreFileSystem, exportPreferences: @escaping @Sendable () throws -> Data,
        appVersion: String, clock: @escaping @Sendable () -> DartDateTime
    ) {
        root = applicationSupport.appendingPathComponent(PreRestoreBackup.folderName, isDirectory: true)
        self.store = store
        self.exportPreferences = exportPreferences
        self.appVersion = appVersion
        self.clock = clock
    }

    public enum Failure: Error, Equatable {
        /// A copied file did not read back identical.
        case copyMismatch(String)
    }

    /// Copies the store files (byte for byte, each verified) and the
    /// preferences into a new folder, then writes `manifest.json` and, last,
    /// `COMPLETE`; every file is flushed to stable storage. Throws if any
    /// step fails, after removing the partial folder.
    @discardableResult
    public func create() throws -> URL {
        let sequence = (try folders().last.map { Self.sequence(of: $0) } ?? 0) + 1
        let folder = root.appendingPathComponent(folderName(sequence: sequence), isDirectory: true)
        let copy = DirectoryFileSystem(directory: folder.appendingPathComponent(StoreFile.directoryName, isDirectory: true))
        let meta = DirectoryFileSystem(directory: folder)
        do {
            // The folder exists even for an empty store.
            try FileManager.default.createDirectory(at: copy.directory, withIntermediateDirectories: true)
            var files: [[String: Any]] = []
            var primaryChecksum: String? = nil
            for name in try store.list() {
                guard let bytes = try store.read(name) else { continue }  // gone since the listing
                try copy.writeStaged(name, bytes)
                try copy.commitStaged(name)
                guard try copy.read(name) == bytes else { throw Failure.copyMismatch(name) }
                files.append(["name": name, "size": bytes.count, "sha256": sha256Hex(bytes)])
                if name == StoreFile.primaryName { primaryChecksum = StoreFile.verify(bytes)?.payloadChecksum }
            }
            let preferences = [UInt8](try exportPreferences())
            try write(meta, PreRestoreBackup.preferencesName, preferences)

            let now = clock()
            let manifest: [String: Any] = [
                "reason": "restore",
                "createdAt": DartDateTime(microsecondsSinceEpoch: now.microsecondsSinceEpoch, isUtc: true, timeZone: now.timeZone)
                    .toIso8601String(),
                "appVersion": appVersion,
                "primaryChecksum": primaryChecksum ?? NSNull(),
                "files": files,
                "preferencesSha256": sha256Hex(preferences),
            ]
            let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try write(meta, PreRestoreBackup.manifestName, [UInt8](manifestData))
            // Written last: a folder without it is incomplete and ignored.
            try write(meta, PreRestoreBackup.completeMarker, Array("ok\n".utf8))
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Complete copies, oldest first (creation order).
    public func completeSnapshots() throws -> [URL] {
        try folders().filter(isComplete)
    }

    /// Removes all but the newest `keeping` complete copies, and any
    /// incomplete folder (a copy that failed part way). `protecting` (the
    /// copy the restore just made, `create()`'s result) is never removed.
    /// Call only after a successful restore. Returns the removed folders.
    @discardableResult
    public func prune(keeping: Int = PreRestoreBackup.retained, protecting newest: URL? = nil) throws -> [URL] {
        let all = try folders()
        let complete = all.filter(isComplete)
        var keep = Set(complete.suffix(max(keeping, 0)).map(\.lastPathComponent))
        if let newest { keep.insert(newest.lastPathComponent) }
        let doomed = all.filter { !keep.contains($0.lastPathComponent) }
        for folder in doomed { try FileManager.default.removeItem(at: folder) }
        return doomed
    }

    // MARK: - Helpers

    private func folders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { (Self.sequence(of: $0), $0.lastPathComponent) < (Self.sequence(of: $1), $1.lastPathComponent) }
    }

    /// The creation sequence in a folder's name (`s<digits>-...`); 0 for a
    /// folder without one (made before the sequence existed).
    static func sequence(of folder: URL) -> Int {
        let name = folder.lastPathComponent
        guard name.hasPrefix("s") else { return 0 }
        return Int(name.dropFirst().prefix { $0 != "-" }) ?? 0
    }

    private func isComplete(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(PreRestoreBackup.completeMarker).path)
    }

    /// `s<sequence, 6+ digits>-yyyyMMdd-HHmmss-uuuuuu-<8 hex>`, the stamp in
    /// UTC: ordered by the sequence, readable by the stamp, unique.
    private func folderName(sequence: Int) -> String {
        let now = clock()
        let f = DartDateTime(microsecondsSinceEpoch: now.microsecondsSinceEpoch, isUtc: true, timeZone: now.timeZone).fields
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        let micros = f.millisecond * 1_000 + f.microsecond
        return "s\(pad(sequence, 6))-"
            + "\(pad(f.year, 4))\(pad(f.month, 2))\(pad(f.day, 2))-\(pad(f.hour, 2))\(pad(f.minute, 2))\(pad(f.second, 2))-"
            + "\(pad(micros, 6))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private func write(_ directory: DirectoryFileSystem, _ name: String, _ bytes: [UInt8]) throws {
        try directory.writeStaged(name, bytes)
        try directory.commitStaged(name)
    }
}
