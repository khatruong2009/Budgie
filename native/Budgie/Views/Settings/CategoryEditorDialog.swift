import BudgieCore
import SwiftUI

/// What the Categories page asks the editor for: a new category of `type`
/// (the selected segment), or an edit of `category`.
struct CategoryEditorRequest: Identifiable {
    let id = UUID()
    let type: TransactionType
    let category: CategoryInfo?
}

/// The add / edit category dialog (`_showCategoryEditor`,
/// category_settings_page.dart:183-332), in the redesign's centred card
/// (`budgieDialog`, as the Goals form): "New category" / "Edit category",
/// the autofocused Name field (words capitalised), the 18 icons and 8
/// colours as 44pt choice buttons 8 apart, then Cancel and Add / Save.
///
/// Save validates here and keeps the dialog open on an error, shown under
/// the field with Flutter's copy: "Enter a category name" (the form's
/// validator) for an empty name, else the provider's messages ("A category
/// with this name already exists"), which Flutter shows in a SnackBar
/// after closing the dialog. Once shown, the error follows the text. The
/// edit is then awaited with the dialog open and inert (scrim included);
/// it closes when the edit was written or changed nothing, and also when
/// the write failed (the change is in memory behind the unsaved banner),
/// with the save-failed toast. A rename's cascade reaches every screen
/// through the model (one commit, the ledger rebuilt).
struct CategoryEditorDialog: View {
    let request: CategoryEditorRequest
    let onClose: () -> Void

    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var iconIdentifier: String
    @State private var colorToken: String
    @State private var error: String?
    /// Save was tapped once: from then on the error follows the text.
    @State private var validating = false
    @State private var busy = false

    init(request: CategoryEditorRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        // The stored values (a padded legacy name stays padded; an icon
        // outside the registry shows none selected and saves as the grid).
        _name = State(initialValue: request.category?.name ?? "")
        _iconIdentifier = State(initialValue: request.category?.iconIdentifier ?? "square_grid_2x2")
        _colorToken = State(initialValue: request.category?.colorToken ?? "accent")
    }

    var body: some View {
        let isNew = request.category == nil
        VStack(spacing: 0) {
            DialogTitle(text: isNew ? "New category" : "Edit category")
            DialogScroll { fields }
                .padding(.top, 20)
            DialogButtons(
                cancelId: "categories.editor.cancel", submitTitle: isNew ? "Add" : "Save",
                submitId: "categories.editor.submit", cancel: onClose, submit: submit)
        }
        .disabled(busy)
        // The scrim (and its VoiceOver Dismiss) is inert while saving.
        .budgieDialogDismissDisabled(busy)
        .onChange(of: name) {
            if validating { error = validationMessage() }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Flutter's single-line field shows Done on iOS and only
            // dismisses the keyboard (no onFieldSubmitted): SwiftUI's
            // default on return.
            BudgieField(title: "Name", text: $name, capitalization: .words, error: error, autofocus: true)
                .submitLabel(.done)
                .accessibilityIdentifier("categories.editor.name")
            caption("Icon")
                .padding(.top, Metrics.spacingM)
            FlowLayout(spacing: Metrics.spacingS) {
                ForEach(CategoryCatalog.iconIdentifiers, id: \.self) { identifier in
                    ChoiceButton(
                        selected: iconIdentifier == identifier, label: Self.iconName(identifier),
                        identifier: "categories.editor.icon.\(identifier)"
                    ) {
                        iconIdentifier = identifier
                    } content: {
                        // Flutter's plain `Icon`: the Cupertino glyphs' weight.
                        Image(systemName: CategoryCatalog.symbol(for: identifier))
                            .font(.system(size: Metrics.categoryGlyph, weight: .regular))
                            .foregroundStyle(BudgieColor.textPrimary)
                    }
                }
            }
            .frame(maxWidth: Self.gridWidth, alignment: .leading)
            .padding(.top, Metrics.spacingS)
            caption("Color")
                .padding(.top, Metrics.spacingM)
            // Flutter's colour Wrap has no run spacing (the rows touch);
            // 8 like the icons (PARITY_GAPS).
            FlowLayout(spacing: Metrics.spacingS) {
                ForEach(CategoryCatalog.colorTokens, id: \.self) { token in
                    ChoiceButton(
                        selected: colorToken == token, label: Self.colorName(token),
                        identifier: "categories.editor.color.\(token)"
                    ) {
                        colorToken = token
                    } content: {
                        Circle()
                            .fill(BudgieColor.category(token))
                            .frame(width: Metrics.iconS, height: Metrics.iconS)
                    }
                }
            }
            .frame(maxWidth: Self.gridWidth, alignment: .leading)
            .padding(.top, Metrics.spacingS)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Five choice buttons a row, as Flutter's narrower `AlertDialog`
    /// wraps them (icons 5/5/5/3, colours 5+3): the redesign card would
    /// fit six.
    private static let gridWidth = Metrics.touchTarget * 5 + Metrics.spacingS * 4

    /// "Icon" / "Color", as the field's label (caption w600, secondary,
    /// inset 4).
    private func caption(_ text: String) -> some View {
        FieldCaption(text, isHeader: true)
    }

    // MARK: - Save

    /// The first error saving would give: the form's empty-name message,
    /// else the provider's.
    private func validationMessage() -> String? {
        if DartString.trim(name).isEmpty { return "Enter a category name" }
        return model.validateCategoryName(name, type: request.type, excluding: request.category?.id)?.message
    }

    private func submit() {
        guard !busy else { return }
        validating = true
        if let message = validationMessage() {
            show(message)
            return
        }
        error = nil
        busy = true
        Task {
            let outcome: AppModel.EditOutcome<CategoryEditError>
            if let category = request.category {
                outcome = await model.updateCategory(
                    id: category.id, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken)
            } else {
                outcome = await model.addCategory(
                    type: request.type, name: name, iconIdentifier: iconIdentifier, colorToken: colorToken)
            }
            busy = false
            outcome.handle(on: model, message: { $0.message }, close: onClose, rejected: show)
        }
    }

    private func show(_ message: String) {
        error = message
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: - VoiceOver names

    private static func iconName(_ identifier: String) -> String {
        switch identifier {
        case "square_grid_2x2": "Grid"
        case "asterisk_circle": "Asterisk"
        case "cart": "Cart"
        case "house": "House"
        case "car": "Car"
        case "airplane": "Airplane"
        case "bag": "Bag"
        case "gift": "Gift"
        case "heart": "Heart"
        case "film": "Film"
        case "paw": "Paw print"
        case "people": "People"
        case "money": "Money"
        case "chart": "Chart"
        case "book": "Book"
        case "phone": "Phone"
        case "wrench": "Tools"
        case "leaf": "Leaf"
        default: identifier
        }
    }

    private static func colorName(_ token: String) -> String {
        switch token {
        case "accent": "Indigo"
        case "green": "Green"
        case "blue": "Blue"
        case "orange": "Orange"
        case "red": "Red"
        case "purple": "Purple"
        case "pink": "Pink"
        case "cyan": "Cyan"
        default: token
        }
    }
}

/// `_ChoiceButton` (:341-379): 44pt, radius 12; selected: accent at 18%
/// with a 1pt accent border, else the field fill with the card border. No
/// press animation (Flutter's ink ripple has no SwiftUI counterpart here).
private struct ChoiceButton<Content: View>: View {
    let selected: Bool
    let label: String
    let identifier: String
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous)
        Button(action: action) {
            content()
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                .background(selected ? BudgieColor.accent.opacity(0.18) : BudgieColor.fieldFill, in: shape)
                .overlay(shape.strokeBorder(selected ? BudgieColor.accent : BudgieColor.cardBorder, lineWidth: Metrics.borderThin))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}
