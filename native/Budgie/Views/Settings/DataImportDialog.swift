import BudgieCore
import SwiftUI

/// The confirmation before an import writes anything, in the redesign's
/// centred card: "Import 3 transactions?" with the skipped counts
/// (`_confirmImport`, settings_page.dart:217-286) or "Replace all data?"
/// with the counts the backup brings (`_confirmRestore`, :525-577), then
/// Cancel and the action. The action is awaited with the dialog modal and
/// inert (no Cancel, no scrim dismiss) while the action pill shows a
/// spinner, read and announced as `busyLabel` ("Restoring", "Importing");
/// `onConfirm` closes it.
struct DataImportDialog: View {
    let title: String
    /// The body; nil shows none (Flutter's `content: null`).
    let message: String?
    let confirmTitle: String
    /// "Replace" is drawn in the danger colour (Flutter `AppColors.expense`).
    let destructive: Bool
    /// What VoiceOver hears while the action runs.
    let busyLabel: String
    /// Prefix of the accessibility identifiers (`<prefix>.title`, `.message`,
    /// `.cancel`, `.confirm`).
    let identifier: String
    let onCancel: () -> Void
    let onConfirm: @MainActor () async -> Void

    @State private var busy = false

    private var actionColor: Color { destructive ? BudgieColor.danger : BudgieColor.accent }

    var body: some View {
        VStack(spacing: 0) {
            DialogTitle(text: title)
                .accessibilityIdentifier("\(identifier).title")
            if let message {
                DialogScroll {
                    Text(message)
                        .textStyle(.bodyMedium)
                        .foregroundStyle(BudgieColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("\(identifier).message")
                }
                .padding(.top, 12)
            }
            HStack(spacing: 12) {
                PillButton(title: CSVImport.cancelButtonTitle, color: BudgieColor.textPrimary, height: 44, action: onCancel)
                    .disabled(busy)
                    .opacity(busy ? 0.4 : 1)
                    .accessibilityIdentifier("\(identifier).cancel")
                if busy {
                    busyPill
                } else {
                    PillButton(title: confirmTitle, color: actionColor, filled: true, height: 44, action: confirm)
                        .accessibilityIdentifier("\(identifier).confirm")
                }
            }
            .padding(.top, Metrics.spacingL)
        }
        .budgieDialogDismissDisabled(busy)
    }

    /// The action pill while it runs: its fill with the spinner in place of
    /// the title (the app's other busy buttons do the same).
    private var busyPill: some View {
        ProgressView()
            .tint(BudgieColor.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(actionColor, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(busyLabel)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("\(identifier).busy")
    }

    private func confirm() {
        guard !busy else { return }
        busy = true
        AccessibilityNotification.Announcement(busyLabel).post()
        Task { await onConfirm() }
    }
}
