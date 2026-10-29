import BudgieCore
import Foundation
import UIKit

extension AppModel {
    // MARK: - Routing

    func setEnablingAppLock(_ enabling: Bool) { isEnablingAppLock = enabling }

    /// The App Lock setting is on (this session may already be unlocked).
    var appLockEnabled: Bool { data?.appSettings.appLockEnabled == true }

    /// App Lock is on and this session has not authenticated.
    var isLocked: Bool { appLockEnabled && !sessionUnlocked }

    func markUnlocked() { sessionUnlocked = true }

    /// After the lock timeout in the background.
    func relock() { sessionUnlocked = false }

    /// Routes open only over unlocked, onboarded data: a quick action or
    /// deep link on a locked launch waits for the unlock (it used to open
    /// the form above the lock screen). One arriving during a restore waits
    /// for it to end (the form would edit data the restore is replacing);
    /// `MainView` opens it when this turns true.
    var canOpenRoutes: Bool { phase == .ready && !isLocked && !showsOnboarding && !isRestoring }

    /// The pending add route, cleared, when it may open now; otherwise nil
    /// and the route stays queued.
    func takePendingAdd() -> AddRoute? {
        guard canOpenRoutes, let route = pendingAdd else { return nil }
        pendingAdd = nil
        return route
    }

    /// The add route a deep link action names; `-` and `_` are the same.
    private static func route(forName name: String) -> AddRoute? {
        switch name.replacingOccurrences(of: "-", with: "_") {
        case "add_income": .income
        case "add_expense": .expense
        case "voice_add": .voice
        default: nil
        }
    }

    func open(_ url: URL) {
        let action = url.host?.isEmpty == false ? url.host! : (url.pathComponents.dropFirst().first ?? "")
        if let route = Self.route(forName: action) { pendingAdd = route }
    }

    /// Quick action types are `action_` plus the underscore form of a route.
    func handleShortcut(_ type: String) {
        guard type.hasPrefix("action_"), !type.contains("-"),
            let route = Self.route(forName: String(type.dropFirst("action_".count)))
        else { return }
        pendingAdd = route
    }

    static func registerShortcuts() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: "action_add_expense", localizedTitle: "Add Expense", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "minus.circle.fill")),
            UIApplicationShortcutItem(
                type: "action_add_income", localizedTitle: "Add Income", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "plus.circle.fill")),
            UIApplicationShortcutItem(
                type: "action_voice_add", localizedTitle: "Add by Voice", localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "mic.circle.fill")),
        ]
    }
}
