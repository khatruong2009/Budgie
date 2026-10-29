import BudgieCore
import SwiftUI

/// The "New tag" dialog (`_addTag`, categorization_settings_page.dart:83-126)
/// in the redesign's centred card: the autofocused field (hint "Travel
/// planning", words capitalised; Return adds), then Cancel and Add.
///
/// As Flutter, an empty or blank name closes the dialog and adds nothing.
/// A duplicate ("A tag with this name already exists", case-insensitive)
/// shows under the field and keeps the dialog open with the typed name
/// (Flutter closes it, then shows the message in a SnackBar); after the
/// first Add the message follows the text. The add is awaited with the
/// dialog inert; it closes once written, and also when the write failed
/// (the tag is in memory behind the unsaved banner), with the save-failed
/// toast.
struct NewTagDialog: View {
    let onClose: () -> Void

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var error: String?
    @State private var validating = false
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            DialogTitle(text: "New tag")
            BudgieField(
                title: "Tag name", text: $name, prompt: "Travel planning", capitalization: .words, error: error,
                autofocus: true
            )
            .submitLabel(.done)
            .onSubmit(submit)
            .accessibilityIdentifier("tags.editor.name")
            .padding(.top, 20)
            DialogButtons(
                cancelId: "tags.editor.cancel", submitTitle: "Add", submitId: "tags.editor.submit", cancel: onClose,
                submit: submit)
        }
        .disabled(busy)
        .budgieDialogDismissDisabled(busy)
        .onChange(of: name) {
            if validating { error = validationMessage() }
        }
    }

    /// The provider's message for a non-blank name (a blank one closes
    /// silently instead).
    private func validationMessage() -> String? {
        if DartString.trim(name).isEmpty { return nil }
        return model.validateTagName(name)?.message
    }

    private func submit() {
        guard !busy else { return }
        if DartString.trim(name).isEmpty {
            onClose()
            return
        }
        validating = true
        if let message = validationMessage() {
            show(message)
            return
        }
        error = nil
        busy = true
        Task {
            let outcome = await model.addTag(name: name)
            busy = false
            switch outcome {
            case .saved, .unchanged: onClose()
            case .failed:
                onClose()
                model.showToast(.saveFailed)
            case .rejected(let rejection): show(rejection.message)
            }
        }
    }

    private func show(_ message: String) {
        error = message
        AccessibilityNotification.Announcement(message).post()
    }
}

/// Swift-only confirmation before a tag is deleted (Flutter deletes at
/// once): deleting it also removes it from every merchant rule, which
/// cannot be undone. Transactions keep the id (D9) but no longer show it.
/// The delete is awaited with the dialog inert; it closes afterwards, with
/// the save-failed toast if only memory changed.
struct DeleteTagDialog: View {
    let tag: TransactionTagRecord
    let onClose: () -> Void

    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            DialogTitle(text: "Delete tag?")
            DialogScroll {
                Text("This removes \"\(tag.name)\" from your tags and from any merchant rule that uses it.")
                    .textStyle(.bodyMedium)
                    .foregroundStyle(BudgieColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            HStack(spacing: 12) {
                PillButton(title: "Cancel", color: BudgieColor.textPrimary, height: 44, action: onClose)
                    .accessibilityIdentifier("tags.delete.cancel")
                PillButton(title: "Delete", color: BudgieColor.danger, filled: true, height: 44, action: delete)
                    .accessibilityIdentifier("tags.delete.confirm")
            }
            .padding(.top, 24)
        }
        .disabled(busy)
        .budgieDialogDismissDisabled(busy)
    }

    private func delete() {
        guard !busy else { return }
        busy = true
        Task {
            let outcome = await model.deleteTag(id: tag.id)
            busy = false
            onClose()
            if outcome == .failed { model.showToast(.saveFailed) }
        }
    }
}
