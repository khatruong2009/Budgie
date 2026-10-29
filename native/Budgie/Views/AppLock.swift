import LocalAuthentication
import SwiftUI
import UIKit

/// Device-owner authentication shared by the lock screen and the Settings
/// toggle. Touches no model state.
enum DeviceAuth {
    enum Outcome: Equatable {
        case success
        case failed
        /// The device has no passcode, so there is nothing to authenticate with.
        case unavailable(String)
    }

    /// The device's biometry; `.none` when it has none.
    static var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType
    }

    static func authenticate(reason: String) async -> Outcome {
        #if DEBUG
        if let outcome = AppLockTestHooks.authenticationOutcome() { return outcome }
        #endif
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error?.localizedDescription ?? "This device can't authenticate.")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? .success : .failed
        } catch {
            return .failed
        }
    }
}

/// The privacy cover and the lock screen, in a second window of the same
/// scene above the app's own (UI_SPEC "App lock"). Presentations (SwiftUI
/// sheets, dialogs, the over-full-screen `AddFormHost`) live inside the app
/// window, so an overlay on the content would sit below them; a window at
/// `.alert + 1` is above all of them. It is hidden (and so takes no touches
/// and no VoiceOver focus) whenever neither applies.
///
/// The cover is raised synchronously from the scene callbacks
/// (`sceneWillResignActive`), before iOS takes the app-switcher snapshot,
/// not from SwiftUI's `scenePhase`, whose render comes a cycle later. The
/// lock screen follows `model.isLocked`. Cosmetic only: bootstrap and saves
/// never depend on it.
@MainActor
final class AppLockWindow {
    /// The scene resigned active (or went to the background) with App Lock on.
    private var showsPrivacyCover = false
    private let model: AppModel
    private let mainWindow: UIWindow
    private let window: UIWindow
    private var backgroundedAt: ContinuousClock.Instant?

    init(windowScene: UIWindowScene, mainWindow: UIWindow, model: AppModel, sceneState: SceneState) {
        self.model = model
        self.mainWindow = mainWindow
        window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1
        let controller = UIHostingController(rootView: AppLockWindowRoot(model: model, sceneState: sceneState))
        window.rootViewController = controller
        // The hosting view is on screen before the first cover needs it.
        controller.loadViewIfNeeded()
        window.isHidden = true
        track()
    }

    /// The app window's interface style (the theme preference) for the lock
    /// screen, which uses the theme tokens.
    func applyInterfaceStyle(_ style: UIUserInterfaceStyle) { window.overrideUserInterfaceStyle = style }

    func sceneWillResignActive() { raiseCover() }

    /// A scene can go to the background without a resign the app saw (and
    /// starts the timeout clock).
    func sceneDidEnterBackground() {
        backgroundedAt = .now
        raiseCover()
    }

    /// Relocks once the app was in the background for the timeout (0 =
    /// immediately), then lowers the cover. A lock screen that takes over
    /// from the cover stays up without a gap.
    func sceneDidBecomeActive() {
        let timeout = model.data?.appSettings.autoLockTimeoutSeconds ?? 0
        if let since = backgroundedAt, since.duration(to: .now) >= .seconds(max(timeout, 0)) {
            model.relock()
        }
        backgroundedAt = nil
        showsPrivacyCover = false
        sync()
    }

    /// Nothing is covered when the lock is off, nor while Settings' enable
    /// prompt (Face ID / passcode, which makes the scene inactive) is up: the
    /// lock is not on yet then, and is not retro-fitted with a cover when it
    /// turns on under the prompt, since the decision is made here, at resign.
    private func raiseCover() {
        guard model.appLockEnabled else { return }
        // A focused field's keyboard and QuickType bar live in windows above
        // this one and can show typed text in the snapshot: end editing first.
        // The fields keep their text; only the focus goes.
        mainWindow.endEditing(true)
        showsPrivacyCover = true
        sync()
    }

    private func sync() {
        let locked = model.isLocked
        // While locked, VoiceOver reaches only the lock screen: the whole
        // app window (tabs, tour, any sheet or over-full-screen host) is out.
        mainWindow.accessibilityElementsHidden = locked
        window.rootViewController?.view.backgroundColor = UIColor(BudgieColor.background)
        window.isHidden = !(locked || showsPrivacyCover)
        guard !window.isHidden else { return }
        // Committed before the callback returns, so the snapshot has it.
        window.layoutIfNeeded()
        CATransaction.flush()
    }

    /// Follows `model.isLocked` (the launch lock, unlocking) for the cases
    /// the scene callbacks do not cover.
    private func track() {
        withObservationTracking {
            _ = model.isLocked
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.track()
            }
        }
    }
}

/// The window's root: the lock screen while locked, else the privacy cover.
/// Environment as `AppRoot` gives the app (the model; the scene phase the
/// lock screen waits on before it authenticates).
private struct AppLockWindowRoot: View {
    let model: AppModel
    let sceneState: SceneState

    var body: some View {
        Group {
            if model.isLocked {
                LockScreen { model.markUnlocked() }
            } else {
                PrivacyCover()
            }
        }
        .font(TextSpec.bodyLarge.font())
        .environment(model)
        .environment(\.scenePhase, sceneState.phase)
    }
}

/// The app-switcher cover (`_AppSwitcherPrivacyCover`): opaque, on the page
/// background of the current palette, 72pt mark, "Budgie", "App preview
/// hidden".
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            BudgieColor.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Image("logo").resizable().scaledToFit().frame(width: 72, height: 72)
                Text("Budgie")
                    .textStyle(.pageTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .padding(.top, Metrics.spacingM)
                Text("App preview hidden")
                    .textStyle(.bodyMedium)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .padding(.top, Metrics.spacingXS)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The lock screen (`_LockScreen`), in the redesign tokens: the mark,
/// "Budgie is locked", the reason or the last error, and a filled accent
/// Unlock pill.
struct LockScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    let onUnlock: () -> Void
    @State private var attempted = false
    @State private var authenticating = false
    @State private var error: String?
    @State private var biometry = DeviceAuth.biometryType

    var body: some View {
        ZStack {
            BudgieColor.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Image("logo").resizable().scaledToFit().frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                Text("Budgie is locked")
                    .textStyle(.pageTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                    .padding(.top, Metrics.spacingL)
                    .accessibilityAddTraits(.isHeader)
                Text(error ?? "Authenticate to view your financial data.")
                    .textStyle(.bodyMedium)
                    .foregroundStyle(error == nil ? BudgieColor.textSecondary : BudgieColor.danger)
                    .multilineTextAlignment(.center)
                    .padding(.top, Metrics.spacingS)
                PillButton(
                    title: authenticating ? "Authenticating…" : "Unlock",
                    symbol: biometry == .faceID ? "faceid" : biometry == .touchID ? "touchid" : "lock.open",
                    filled: true, height: 52
                ) {
                    unlock()
                }
                .disabled(authenticating)
                .padding(.top, Metrics.spacingL)
            }
            .frame(maxWidth: 360)
            .padding(Metrics.spacingXL)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("applock.lock")
        // Evaluating while the scene is inactive fails, so wait for active.
        // Auto-attempt once; the Unlock button retries.
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, !attempted else { return }
            attempted = true
            unlock()
        }
    }

    private func unlock() {
        guard !authenticating else { return }
        authenticating = true
        error = nil
        Task {
            let outcome = await DeviceAuth.authenticate(reason: "Unlock Budgie to view your financial data")
            authenticating = false
            switch outcome {
            case .success:
                onUnlock()
            case .failed:
                error = "Authentication was not completed."
            case .unavailable:
                // No passcode: there is nothing to lock against, and keeping
                // the data hidden forever would lock the owner out.
                onUnlock()
            }
        }
    }
}
