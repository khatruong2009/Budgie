import Foundation
import os

/// Signposts for Instruments ("os_signpost" track) and the performance UI
/// tests (`XCTOSSignpostMetric`); see docs/PERFORMANCE.md. Free when nothing
/// records them, so they stay in every configuration. Names are
/// `StaticString`s and an interval ends under the name it began with.
enum Signpost {
    static let launch = OSSignposter(subsystem: AppIdentifiers.bundleID, category: "Launch")
    static let ledger = OSSignposter(subsystem: AppIdentifiers.bundleID, category: "Ledger")
    static let ui = OSSignposter(subsystem: AppIdentifiers.bundleID, category: "UI")
}

/// The persisted launch log (`.notice`) that docs/REAL_DEVICE_CHECKLISTS.md
/// greps: `launch prewarm=`, `protected data available after`,
/// `store loaded` and `pre-native snapshot`. Only public, non-financial
/// values: flags, seconds, a revision number and an outcome word.
enum LaunchLog {
    private static let logger = Logger(subsystem: AppIdentifiers.bundleID, category: "launch")

    /// At the top of every process launch. iOS sets `ActivePrewarm=1` in the
    /// environment of a prewarmed launch.
    static func processLaunched(protectedDataAvailable: Bool) {
        let prewarm = ProcessInfo.processInfo.environment["ActivePrewarm"] == "1" ? 1 : 0
        let protected = protectedDataAvailable ? "available" : "unavailable"
        logger.notice("launch prewarm=\(prewarm, privacy: .public) protectedData=\(protected, privacy: .public)")
    }

    static func protectedDataAvailable(after seconds: Double) {
        logger.notice("protected data available after \(seconds, format: .fixed(precision: 1), privacy: .public)s")
    }

    static func storeLoaded(revision: Int) {
        logger.notice("store loaded revision=\(revision, privacy: .public)")
    }

    static func storeLoadFailed(_ kind: String) {
        logger.notice("store load failed \(kind, privacy: .public)")
    }

    /// `created`, `exists` or `failed`.
    static func preNativeSnapshot(_ outcome: String) {
        logger.notice("pre-native snapshot \(outcome, privacy: .public)")
    }
}
