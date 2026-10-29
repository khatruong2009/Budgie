import BudgieCore
import SwiftUI

/// Category management (`CategorySettingsPage`,
/// category_settings_page.dart:26-181), pushed from Settings >
/// PERSONALIZATION > Categories: the Expenses | Income pills, "Show
/// archived", then one card per definition of the selected type in sort
/// order (archived ones interleaved, only while the switch is on), as rows
/// in one card with hairlines between them (REDESIGN_PLAN 4.7). The bar's
/// "+" opens the editor for the selected type; each row's menu offers Edit,
/// Move up, Move down and Archive / Restore.
///
/// Differences from Flutter (PARITY_GAPS): no duplicate FAB; Move up / Move
/// down step over hidden archived rows (`categoryMoveOffset`); the editor is
/// the redesign's centred card with inline errors; the row menu is the
/// system menu. Refused row actions (archiving the last active category)
/// show Flutter's copy in the neutral toast (its default SnackBar), a
/// failed write the save-failed toast. Neither the type nor the switch is
/// persisted (as Flutter).
struct CategoriesView: View {
    @Environment(AppModel.self) private var model

    /// 0 Expenses, 1 Income (`_selectedType`, default expense).
    @State private var typeIndex = 0
    @State private var showArchived = false
    @State private var editor: CategoryEditorRequest?

    private var type: TransactionType { typeIndex == 0 ? .expense : .income }

    var body: some View {
        let categories = model.categoryDefinitions(type: type, includeArchived: showArchived)
        VStack(spacing: 0) {
            SegmentedPills(items: ["Expenses", "Income"], selection: $typeIndex)
                .fixedSize()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Category type")
                .accessibilityIdentifier("categories.type")
                .padding(EdgeInsets(top: Metrics.spacingS, leading: Metrics.pageHorizontal, bottom: 0, trailing: Metrics.pageHorizontal))
            archivedSwitch
            ScrollView {
                GlowListCard(lazy: true, rows: categories.uniqueKeys(id: \.id).enumerated().map { index, item in
                    CategoryRow(
                        category: item.element,
                        actions: CategoryRowAction.menu(
                            index: index, count: categories.count, isArchived: item.element.isArchived)
                    ) { perform($0, on: item.element) }
                })
                .padding(EdgeInsets(top: 0, leading: Metrics.pageHorizontal, bottom: Metrics.spacingXL, trailing: Metrics.pageHorizontal))
                .frame(maxWidth: Metrics.maxContentWidth)
                .frame(maxWidth: .infinity)
            }
            // A new list per type, starting at the top: the kept offset of a
            // scrolled Expenses list left the shorter Income list above the
            // viewport (Flutter's list shows the other type from the top).
            .id(typeIndex)
            .accessibilityIdentifier("categories.list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BudgieColor.background)
        .budgiePushedTitle("Categories", singleLine: true)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editor = CategoryEditorRequest(type: type, category: nil)
                } label: {
                    Image(systemName: "plus").foregroundStyle(BudgieColor.textPrimary)
                }
                .accessibilityLabel("Add category")
                .accessibilityIdentifier("categories.add")
            }
        }
        .budgieDialog(item: $editor) { request in
            CategoryEditorDialog(request: request) { editor = nil }
        }
    }

    /// `SwitchListTile.adaptive` (56 tall, inset 24 like an eyebrow):
    /// the `switchOn` switch, and the title (rowTitle) also toggles it (the
    /// whole tile is Flutter's tap target). VoiceOver reads the switch by
    /// the title.
    /// The title's tap and the switch do not overlap: a zero-length
    /// synthetic tap (Simulator tooling) misses every system switch in the
    /// app, Settings' included, while a real touch toggles it once.
    private var archivedSwitch: some View {
        HStack(spacing: Metrics.spacingM) {
            Text("Show archived")
                .textStyle(.rowTitle)
                .foregroundStyle(BudgieColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { showArchived.toggle() }
                .accessibilityHidden(true)
            Toggle("Show archived", isOn: $showArchived)
                .labelsHidden()
                .tint(BudgieColor.switchOn)
                .accessibilityIdentifier("categories.showArchived")
        }
        .padding(.horizontal, Metrics.pageHorizontal + Metrics.spacingXS)
        .frame(minHeight: 56)
        .frame(maxWidth: Metrics.maxContentWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Row actions

    private func perform(_ action: CategoryRowAction, on category: CategoryInfo) {
        switch action {
        case .edit:
            editor = CategoryEditorRequest(type: category.type, category: category)
        case .moveUp, .moveDown:
            // Relative to the rows shown (hops over hidden archived rows).
            guard let offset = model.categoryMoveOffset(
                id: category.id, direction: action == .moveUp ? -1 : 1, includeArchived: showArchived)
            else { return }
            run { await model.moveCategory(id: category.id, offset: offset) }
        case .archive:
            run { await model.setCategoryArchived(id: category.id, true) }
        case .restore:
            run { await model.setCategoryArchived(id: category.id, false) }
        }
    }

    /// Awaits the edit; silent when saved or a no-op (as Flutter), the
    /// save-failed toast when only memory changed, Flutter's message in the
    /// neutral toast when refused.
    private func run(_ edit: @escaping () async -> AppModel.EditOutcome<CategoryEditError>) {
        Task {
            switch await edit() {
            case .saved, .unchanged: break
            case .failed: model.showToast(.saveFailed)
            case .rejected(let error): model.showToast(CategoryRowAction.refusedToast(error))
            }
        }
    }
}

/// A row menu item (`PopupMenuItem`s, category_settings_page.dart:113-139).
enum CategoryRowAction: Hashable {
    case edit, moveUp, moveDown, archive, restore

    var title: String {
        switch self {
        case .edit: "Edit"
        case .moveUp: "Move up"
        case .moveDown: "Move down"
        case .archive: "Archive"
        case .restore: "Restore"
        }
    }

    /// Flutter's items for the row at `index` of the `count` rows shown:
    /// Edit; Move up unless archived or first; Move down unless archived or
    /// last; Restore for an archived row, else Archive.
    static func menu(index: Int, count: Int, isArchived: Bool) -> [CategoryRowAction] {
        var items: [CategoryRowAction] = [.edit]
        if !isArchived && index > 0 { items.append(.moveUp) }
        if !isArchived && index < count - 1 { items.append(.moveDown) }
        items.append(isArchived ? .restore : .archive)
        return items
    }

    /// The row's subtitle: "Built in" and "Archived" joined with " · ",
    /// empty for an active custom category.
    static func subtitle(for category: CategoryInfo) -> String {
        [category.isBuiltIn ? "Built in" : nil, category.isArchived ? "Archived" : nil]
            .compactMap { $0 }
            .joined(separator: " \u{00B7} ")
    }

    /// A refused row action: Flutter's message in its default SnackBar
    /// (`_handleAction`'s plain `SnackBar`), the neutral toast.
    static func refusedToast(_ error: CategoryEditError) -> Toast {
        Toast(message: error.message, style: .neutral)
    }
}

extension Metrics {
    /// Categories' glyphs (the editor's icon grid, the row menu): SF
    /// Symbols draw about 18% larger than Flutter's Cupertino and Material
    /// glyphs at the same size, so 17 renders like Flutter's 20 (grid,
    /// measured) and its 24pt `more_horiz`.
    static let categoryGlyph: CGFloat = 17
}

/// One definition, as Home's Recent activity rows: the category's 40pt
/// tile, 12 apart, the name (rowTitle) over the subtitle (rowSubtitle,
/// secondary; "Built in", "Archived", or nothing), then the 44pt "Category
/// actions" menu. No row tap (as Flutter).
///
/// VoiceOver: the text is one element ("Groceries", "Built in") offering
/// the menu's items as actions; the menu button follows it, valued with the
/// category's name.
private struct CategoryRow: View {
    let category: CategoryInfo
    let actions: [CategoryRowAction]
    let onAction: (CategoryRowAction) -> Void

    var body: some View {
        let subtitle = CategoryRowAction.subtitle(for: category)
        HStack(spacing: 12) {
            IconTile(category: category)
            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                Text(category.name)
                    .textStyle(.rowTitle)
                    .foregroundStyle(BudgieColor.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .textStyle(.rowSubtitle)
                        .foregroundStyle(BudgieColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.touchTarget, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(category.name)
            .accessibilityValue(subtitle)
            .accessibilityActions {
                ForEach(actions, id: \.self) { action in
                    Button(action.title) { onAction(action) }
                }
            }
            .accessibilityIdentifier("categories.row.\(category.id)")
            Menu {
                ForEach(actions, id: \.self) { action in
                    Button(action.title) { onAction(action) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: Metrics.categoryGlyph, weight: .bold))
                    .foregroundStyle(BudgieColor.textSecondary)
                    .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                    .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .accessibilityLabel("Category actions")
            .accessibilityValue(category.name)
            .accessibilityIdentifier("categories.row.menu.\(category.id)")
        }
        .padding(.vertical, 12)
        .padding(.leading, 12)
        // The menu's 44pt box already insets its dots.
        .padding(.trailing, Metrics.spacingXXS)
    }
}
