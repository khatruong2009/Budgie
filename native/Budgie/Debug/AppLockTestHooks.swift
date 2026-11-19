#if DEBUG
import Foundation
import os

/// Debug-only launch hooks for App Lock, so UI tests can lock the app on a
/// simulator that has no passcode (where `DeviceAuth` reports the device
/// cannot authenticate and unlocks at once). Read from the launch
/// environment (`XCUIApplication.launchEnvironment`):
///
/// - `BUDGIE_UITEST_APP_LOCK=<seconds>`: App Lock is on, in memory only
///   (nothing is written), with `<seconds>` as the auto-lock timeout.
/// - `BUDGIE_UITEST_AUTH_SUCCESSES=<n>`: the first `n` authentications
///   succeed and every later one fails, so the lock screen stays up after
///   a relock. Without it the real `LAContext` runs.
///
/// Release builds contain none of this.
enum AppLockTestHooks {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var timeoutSeconds: Int? { environment["BUDGIE_UITEST_APP_LOCK"].flatMap(Int.init) }

    private static let authentications = OSAllocatedUnfairLock(initialState: 0)

    static func authenticationOutcome() -> DeviceAuth.Outcome? {
        guard let allowed = environment["BUDGIE_UITEST_AUTH_SUCCESSES"].flatMap(Int.init) else { return nil }
        let count = authentications.withLock { $0 += 1; return $0 }
        return count <= allowed ? .success : .failed
    }
}
#endif
