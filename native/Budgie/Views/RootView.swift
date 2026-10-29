import BudgieCore
import SwiftUI

/// Chooses what to show for the bootstrap phase. Financial screens appear
/// only once the store has been read safely.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BUDGIE_DESIGN_GALLERY"] == "1" {
            DesignGalleryView()
        } else {
            phaseView
        }
        #else
        phaseView
        #endif
    }

    /// Phase changes cross-fade over 450ms, as Flutter's AnimatedSwitcher.
    private var phaseKey: Int {
        switch model.phase {
        case .waitingForUnlock: 0
        case .starting: 1
        case .blocked: 2
        case .ready: 3
        }
    }

    private var phaseView: some View {
        ZStack {
            phaseContent
                .id(phaseKey)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BudgieColor.background)
        .motion(.easeOut(duration: 0.45), value: phaseKey)
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .waitingForUnlock:
            EmptyStateView(
                symbol: "lock.fill", title: "Unlock your iPhone",
                message: "Budgie opens your data once your iPhone is unlocked.")
        case .starting:
            OpeningView()
        case .blocked(let blocker):
            BlockedView(blocker: blocker)
        case .ready:
            MainView()
        }
    }
}

/// The phases that stop the app from opening the store: the dashed status
/// card, then a filled "Try Again" pill and, for unreadable data, an
/// outlined danger pill for the empty budget. Scrolls at large text sizes.
struct BlockedView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsEmptyBudget = false
    let blocker: AppModel.Blocker

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                content
                    .padding(.vertical, Metrics.spacingL)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .confirmationDialog("Start with an Empty Budget?", isPresented: $confirmsEmptyBudget, titleVisibility: .visible) {
            Button("Start with an Empty Budget", role: .destructive) {
                if case .dataUnreadable(let files) = blocker {
                    Task { await model.startFresh(acknowledging: files) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will open a budget without recovering your saved data. Your original files and safety copy will remain on this iPhone.")
        }
    }

    @ViewBuilder private var content: some View {
        switch blocker {
        case .backupFailed(let reason):
            VStack(spacing: Metrics.spacingM) {
                EmptyStateView(
                    kind: .error, symbol: "externaldrive.badge.exclamationmark", title: "Couldn't prepare your data",
                    message: "Budgie makes a safety copy of your data before opening it and couldn't this time. Nothing was changed. Free up some storage and try again.")
                reasonText(reason)
                tryAgain
            }
        case .readFailed(let reason):
            VStack(spacing: Metrics.spacingM) {
                EmptyStateView(
                    kind: .error, symbol: "exclamationmark.triangle", title: "Couldn't read your data",
                    message: "Your data is still on this iPhone. Nothing was changed.")
                reasonText(reason)
                tryAgain
            }
        case .dataUnreadable:
            VStack(spacing: Metrics.spacingM) {
                EmptyStateView(
                    kind: .error, symbol: "exclamationmark.octagon", title: "Your data couldn't be read",
                    message: "Your saved budget data could not be read. The original files and a safety copy have been kept on this iPhone.")
                tryAgain
                PillButton(title: "Start with an Empty Budget", color: BudgieColor.danger, minHeight: Metrics.pillButtonHeight) {
                    confirmsEmptyBudget = true
                }
                .padding(.horizontal, Metrics.pageHorizontal)
            }
        }
    }

    private func reasonText(_ reason: String) -> some View {
        Text(reason)
            .textStyle(.rowSubtitle)
            .foregroundStyle(BudgieColor.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Metrics.pageHorizontal)
    }

    private var tryAgain: some View {
        PillButton(title: "Try Again", filled: true, minHeight: Metrics.pillButtonHeight) {
            Task { await model.retryStart() }
        }
        .padding(.horizontal, Metrics.pageHorizontal)
    }
}
