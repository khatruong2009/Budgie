import BudgieCore
import SwiftUI

/// The Recurring page (`RecurringTransactionsPage`,
/// recurring_transactions_page.dart), pushed from Settings > DATA, on the
/// redesign tokens (D1, D15): one `RecurringCard` per template, active ones
/// first, then paused ones, each in stored order; Flutter's empty state; the
/// bar's refresh runs "Generate Due Transactions" and "+" opens the form.
///
/// Differences from Flutter (PARITY_GAPS): the "+" add button, pause /
/// resume and the Paused state (approved MVP behaviours); the empty state
/// also offers "Add Recurring"; the generate and delete writes are awaited
/// and a failed write shows the save-failed toast instead of Flutter's.
struct RecurringView: View {
    @Environment(AppModel.self) private var model

    @State private var sheet: FormSheet?
    @State private var pendingDelete: RecurringTemplate?
    @State private var generating = false
    @State private var generateTaps = 0
    @State private var deleteConfirms = 0

    enum FormSheet: Identifiable {
        case add
        case edit(RecurringTemplate)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let template): "edit-" + template.id
            }
        }

        var template: RecurringTemplate? {
            if case .edit(let template) = self { template } else { nil }
        }
    }

    var body: some View {
        Group {
            if let data = model.data {
                let templates = data.templates.filter(\.isActive) + data.templates.filter { !$0.isActive }
                if templates.isEmpty {
                    emptyState
                } else {
                    list(templates)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BudgieColor.background)
        .budgiePushedTitle("Recurring Transactions", scales: true)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await generateDue() }
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(BudgieColor.textPrimary)
                }
                .disabled(generating || model.data == nil)
                .accessibilityLabel("Generate Due Transactions")
                .accessibilityIdentifier("recurring.generate")
                Button {
                    sheet = .add
                } label: {
                    Image(systemName: "plus").foregroundStyle(BudgieColor.textPrimary)
                }
                .disabled(model.data == nil)
                .accessibilityLabel("Add recurring transaction")
                .accessibilityIdentifier("recurring.add")
            }
        }
        .sheet(item: $sheet) { sheet in
            RecurringFormView(template: sheet.template)
        }
        .alert("Delete Recurring Transaction?", isPresented: Binding(isPresent: $pendingDelete), presenting: pendingDelete) { template in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteConfirms += 1
                Task { await delete(template) }
            }
        } message: { template in
            Text(Self.deleteMessage(template.description))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: generateTaps)
        .sensoryFeedback(.impact(weight: .heavy), trigger: deleteConfirms)
    }

    /// `_deleteRecurring`'s content (recurring_transactions_page.dart:170-176).
    static func deleteMessage(_ description: String) -> String {
        "This will stop generating future transactions for \"\(description)\". "
            + "Previously generated transactions will not be affected."
    }

    // MARK: - Content

    private func list(_ templates: [RecurringTemplate]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(templates) { template in
                    RecurringCard(
                        template: template,
                        onEdit: { sheet = .edit(template) },
                        onToggleActive: { Task { await setActive(template, !template.isActive) } },
                        onDelete: { pendingDelete = template })
                }
            }
            .padding(EdgeInsets(top: Metrics.spacingM, leading: Metrics.pageHorizontal, bottom: Metrics.spacingXL, trailing: Metrics.pageHorizontal))
            .frame(maxWidth: Metrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("recurring.list")
    }

    /// `_buildEmptyState` (:68-108) as the redesign's empty card: the repeat
    /// glyph, the title and the two-line message, centred.
    private var emptyState: some View {
        GeometryReader { proxy in
            ScrollView {
                EmptyStateView(
                    symbol: "repeat", title: "No Recurring Transactions",
                    message: "Create recurring transactions to automatically\ngenerate expenses and income on a schedule",
                    actionTitle: "Add Recurring", actionIdentifier: "recurring.empty.add"
                ) { sheet = .add }
                .frame(maxWidth: Metrics.maxContentWidth)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .accessibilityIdentifier("recurring.empty")
    }

    // MARK: - Actions

    /// `_generateDueTransactions` (:120-146): Flutter's message whether or
    /// not anything was due; the save-failed toast when the write failed.
    private func generateDue() async {
        guard !generating else { return }
        generateTaps += 1
        generating = true
        let result = await model.generateDueNow()
        generating = false
        model.showToast(result.toast)
    }

    private func setActive(_ template: RecurringTemplate, _ active: Bool) async {
        guard hasTemplate(template.id) else { return }
        if !(await model.setTemplateActive(id: template.id, active)) { model.showToast(.saveFailed) }
    }

    private func delete(_ template: RecurringTemplate) async {
        // Already gone (deleted elsewhere): nothing failed.
        guard hasTemplate(template.id) else { return }
        let saved = await model.deleteTemplate(id: template.id)
        model.showToast(saved ? .recurringDeleted : .saveFailed)
    }

    private func hasTemplate(_ id: String) -> Bool {
        model.data?.templates.contains { $0.id == id } ?? false
    }
}
