import BudgieCore
import Foundation

/// A scratch preferences suite named `budgie.tests.<name>.<uuid>`, never the
/// host app's defaults.
struct ScratchPreferences {
    let suite: String
    let defaults: UserDefaults
    let preferences: UserDefaultsPreferences

    /// `onboardingCompleted` writes the onboarding flag right after the suite
    /// is created.
    init(_ name: String, onboardingCompleted: Bool) {
        suite = "budgie.tests.\(name).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        preferences = UserDefaultsPreferences(defaults: defaults, domainName: suite)
        if onboardingCompleted { OnboardingFlag.markCompleted(preferences) }
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
    }
}

/// A store over `storeDirectory`, as a fresh process would open it.
func scratchStore(storeDirectory: URL, preferences: UserDefaultsPreferences) -> FinancialStore {
    FinancialStore(fileSystem: DirectoryFileSystem(directory: storeDirectory), preferences: preferences, protectedData: AlwaysAvailable())
}

/// What is on disk now in `storeDirectory`, read by a fresh store.
func scratchStored(storeDirectory: URL, preferences: UserDefaultsPreferences) async throws -> FinancialSnapshot {
    try await scratchStore(storeDirectory: storeDirectory, preferences: preferences).read()
}
