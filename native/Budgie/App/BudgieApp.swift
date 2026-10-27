import SwiftUI
import UIKit

// UIKit lifecycle on purpose (MIGRATION_SPEC section 11.5).
//
// iOS persists each scene session with the class name of its delegate and
// restores it on the next launch without asking the app again. The SwiftUI
// `App` lifecycle stores `SwiftUI.AppSceneDelegate`, which does not exist in
// the Flutter binary: reinstalling the Flutter build over this app then
// showed a black screen (found in the upgrade rehearsal). The Flutter app
// stores `Runner.SceneDelegate` under "Default Configuration". This app uses
// the same module name (`Runner`), class name and configuration, so sessions
// saved by either app restore in both.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    @MainActor static let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The launch log's first line (REAL_DEVICE_CHECKLISTS, budgie-uia.8).
        LaunchLog.processLaunched(protectedDataAvailable: application.isProtectedDataAvailable)
        Signpost.launch.emitEvent("processLaunch")
        // Replaces the Flutter build's dynamic items (same three, same order).
        AppModel.registerShortcuts()
        return true
    }

    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// Drives SwiftUI's `scenePhase` from the UIKit scene callbacks.
@MainActor
@Observable
final class SceneState {
    var phase: ScenePhase = .inactive
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// The privacy cover and lock screen, above the app window and every
    /// presentation in it (`AppLockWindow`).
    private var lockWindow: AppLockWindow?
    private let sceneState = MainActor.assumeIsolated { SceneState() }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            let model = AppDelegate.model
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIHostingController(
                rootView: AppRoot(model: model, sceneState: sceneState) { [weak self, weak window] style in
                    window?.overrideUserInterfaceStyle = style
                    self?.lockWindow?.applyInterfaceStyle(style)
                })
            window.makeKeyAndVisible()
            self.window = window
            // Created after the app window, which stays the key window.
            lockWindow = AppLockWindow(windowScene: windowScene, mainWindow: window, model: model, sceneState: sceneState)
            if let url = connectionOptions.urlContexts.first?.url { model.open(url) }
            if let shortcut = connectionOptions.shortcutItem { model.handleShortcut(shortcut.type) }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        MainActor.assumeIsolated { AppDelegate.model.open(url) }
    }

    func windowScene(
        _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        MainActor.assumeIsolated { AppDelegate.model.handleShortcut(shortcutItem.type) }
        completionHandler(true)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        MainActor.assumeIsolated {
            sceneState.phase = .active
            lockWindow?.sceneDidBecomeActive()
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // The cover goes up here, before the callback returns and so before
        // iOS takes the app-switcher snapshot.
        MainActor.assumeIsolated {
            lockWindow?.sceneWillResignActive()
            sceneState.phase = .inactive
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        MainActor.assumeIsolated { sceneState.phase = .inactive }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        MainActor.assumeIsolated {
            sceneState.phase = .background
            lockWindow?.sceneDidEnterBackground()
            AppModel.registerShortcuts()
            // Like the Flutter app: retry unsaved changes on backgrounding.
            let model = AppDelegate.model
            if model.hasUnsavedChanges { Task { await model.retrySaves() } }
            // Export files no share sheet is using (they hold financial data).
            model.removeStaleExports()
        }
    }
}

/// Root of the hosting controller: environment, theme, bootstrap.
struct AppRoot: View {
    let model: AppModel
    let sceneState: SceneState
    let applyInterfaceStyle: (UIUserInterfaceStyle) -> Void

    var body: some View {
        RootView()
            .budgieSheetHost()
            // Unstyled text uses Gabarito, as Flutter's ThemeData.fontFamily.
            .font(TextSpec.bodyLarge.font())
            .environment(model)
            .environment(\.scenePhase, sceneState.phase)
            .onChange(of: model.themeMode, initial: true) { _, mode in
                applyInterfaceStyle(mode == .light ? .light : mode == .dark ? .dark : .unspecified)
            }
            .task { await model.start() }
    }
}
