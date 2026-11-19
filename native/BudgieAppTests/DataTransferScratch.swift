import BudgieCore
import XCTest

@testable import Runner

/// A full `AppModel` bootstrap against a scratch Application Support
/// directory and a scratch preferences suite (never the host app's data).
@MainActor
final class Scratch {
    let directory: URL
    private let scratchPreferences: ScratchPreferences
    var suite: String { scratchPreferences.suite }
    var defaults: UserDefaults { scratchPreferences.defaults }
    var preferences: UserDefaultsPreferences { scratchPreferences.preferences }

    init(onboardingCompleted: Bool = true) throws {
        directory = TestDirectory.make("budgie-data")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scratchPreferences = ScratchPreferences("data", onboardingCompleted: onboardingCompleted)
    }

    func makeModel() -> AppModel { AppModel(applicationSupport: directory, preferences: preferences) }

    /// A started model.
    func start() async -> AppModel {
        let model = makeModel()
        await model.start()
        return model
    }

    var storeDirectory: URL { directory.appendingPathComponent(StoreFile.directoryName, isDirectory: true) }
    var preRestore: URL { directory.appendingPathComponent(PreRestoreBackup.folderName, isDirectory: true) }

    /// Writes `sections` as an existing store (before the model starts).
    func seed(_ sections: JSONObject) async throws {
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        _ = try await scratchStore(storeDirectory: storeDirectory, preferences: preferences).replace(sections: sections)
    }

    /// What is on disk now, read by a fresh store.
    func stored() async throws -> FinancialSnapshot {
        try await scratchStored(storeDirectory: storeDirectory, preferences: preferences)
    }

    func completeSafetyCopies() throws -> [URL] {
        try PreRestoreBackup(
            applicationSupport: directory, store: DirectoryFileSystem(directory: storeDirectory),
            exportPreferences: { Data() }, appVersion: "test", clock: { DartDateTime.now(timeZone: .current) }
        ).completeSnapshots()
    }

    /// The store directory refuses writes until the returned closure runs.
    func lockStoreDirectory() throws -> () -> Void {
        let path = storeDirectory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        return { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    }

    func remove() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: storeDirectory.path)
        scratchPreferences.remove()
        try? FileManager.default.removeItem(at: directory)
    }
}
