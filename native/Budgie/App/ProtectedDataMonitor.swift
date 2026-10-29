import BudgieCore
import UIKit

/// Tracks `UIApplication.isProtectedDataAvailable` in a thread-safe flag the
/// store can read synchronously (MIGRATION_SPEC section 6).
///
/// iOS can prewarm the app before the first unlock after a reboot; files are
/// then unreadable and `UserDefaults` reads back empty. Nothing may touch
/// financial data or preferences until this reports available, and there is
/// deliberately no timeout.
final class ProtectedDataMonitor: ProtectedDataAvailability, @unchecked Sendable {
    private let lock = NSLock()
    private var available: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []

    @MainActor
    init() {
        available = UIApplication.shared.isProtectedDataAvailable
        #if DEBUG
        // Rehearsal hook (UPGRADE_VERIFICATION.md): simulate a prewarmed,
        // locked launch for N seconds. Debug builds only.
        if let seconds = ProcessInfo.processInfo.environment["BUDGIE_SIMULATE_LOCKED_SECONDS"].flatMap(Double.init) {
            available = false
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.set(true) }
        }
        #endif
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.set(true) })
        observers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.set(false) })
    }

    var isProtectedDataAvailable: Bool {
        lock.withLock { available }
    }

    private func set(_ value: Bool) {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            available = value
            guard value else { return [] }
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume() }
    }

    /// Returns once protected data is readable.
    func waitUntilAvailable() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if available { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
