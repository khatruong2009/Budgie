#if DEBUG
import SwiftUI

private enum GalleryScreen: String, Identifiable {
    case opening, lock, cover
    var id: Self { self }
}

/// Every design-system component on one scrolling page, for screenshot
/// comparison with `docs/research/screenshots` in light and dark. Opened
/// with `BUDGIE_DESIGN_GALLERY=1` (launch environment) or from Settings in
/// DEBUG builds. Sample values only; nothing reads or writes the store.
struct DesignGalleryView: View {
    @Environment(AppModel.self) private var model
    @State private var segment = 2
    @State private var range = 1
    @State private var text = ""
    @State private var amount = "12.5"
    @State private var sheet = false
    @State private var dialog = false
    @State private var deleted = 0
    @State private var fullScreen: GalleryScreen?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                BudgieHeader(showLogo: true, centerTrailing: true) {
                    MonthPill(label: "September 2026") {}
                } accessory: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(BudgieColor.textSecondary)
                }
                .padding(.horizontal, -Metrics.pageHorizontal)

                hero
                colours
                typography
                cards
                feature
                pills
                progress
                fields
                misc
            }
            .padding(.horizontal, Metrics.pageHorizontal)
            .padding(.bottom, 120)
        }
        .background(BudgieColor.background)
        .toastHost()
        .overlay(alignment: .bottomTrailing) {
            GlowFab(label: "Add transaction") {}
                .padding(Metrics.fabInset)
        }
        .sheet(isPresented: $sheet) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Safe to spend").textStyle(.sheetTitle).foregroundStyle(BudgieColor.textPrimary)
                Text("A forward-looking estimate for the rest of this month.").textStyle(.bodySmall)
                    .foregroundStyle(BudgieColor.textSecondary)
                PillButton(title: "Done", filled: true, height: Metrics.pillButtonHeight) { sheet = false }
                    .padding(.top, 12)
                PillButton(title: "Cancel", color: BudgieColor.textPrimary) { sheet = false }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .presentationDetents([.medium])
            .budgieSheetChrome()
        }
        .fullScreenCover(item: $fullScreen) { screen in
            ZStack(alignment: .topTrailing) {
                switch screen {
                case .opening: OpeningView()
                case .lock: LockScreen(onUnlock: {})
                case .cover: PrivacyCover()
                }
                Button("Close") { fullScreen = nil }.padding(.top, 60).padding(.trailing, 20)
            }
        }
        .budgieDialog(isPresented: $dialog) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New savings goal").textStyle(.sheetTitle).foregroundStyle(BudgieColor.textPrimary)
                BudgieField(title: "Goal name", text: $text, prompt: "Emergency fund", symbol: "flag")
                DateTile(label: "Target date", value: "Mar 28, 2027") {}
                HStack(spacing: 12) {
                    PillButton(title: "Cancel", color: BudgieColor.textSecondary, height: 44) { dialog = false }
                    PillButton(title: "Add", symbol: "plus", filled: true) { dialog = false }
                }
            }
        }
    }

    private var feature: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Safe to spend").textStyle(.captionStrong).foregroundStyle(BudgieColor.featureSecondary)
            Text("$239.00").textStyle(.heroSmall).foregroundStyle(BudgieColor.featureAmount)
            Text("$8/day for 29 days left").textStyle(.caption).foregroundStyle(BudgieColor.featureSecondary)
        }
        .featureCard()
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Text("CASH FLOW").textStyle(.eyebrow).foregroundStyle(BudgieColor.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("$3,157").textStyle(.hero).foregroundStyle(BudgieColor.textPrimary)
                Text(".50").textStyle(.heroDecimals).foregroundStyle(BudgieColor.textSecondary)
            }
            Text("$3,200 in  ·  $43 out").textStyle(.rowSubtitle).foregroundStyle(BudgieColor.textSecondary)
            Text("SAVED THIS MONTH").textStyle(.monoLink).foregroundStyle(BudgieColor.accent)
            GlowProgressBar(
                value: 0.013, height: 14, color: BudgieColor.accent, showThumb: true,
                trackBorder: Color.primary.opacity(0.06), fillInset: 2)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private var colours: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Colours")
            let swatches: [(String, Color)] = [
                ("accent", BudgieColor.accent), ("income", BudgieColor.income), ("danger", BudgieColor.danger),
                ("warning", BudgieColor.warning), ("info", BudgieColor.info), ("pink", BudgieColor.pink),
                ("cyan", BudgieColor.cyan), ("card", BudgieColor.card), ("chip", BudgieColor.chipSurface),
                ("track", BudgieColor.track), ("track2", BudgieColor.trackSecondary),
            ]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(swatches, id: \.0) { name, color in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 10).fill(color).frame(height: 36)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BudgieColor.cardBorder))
                        Text(name).textStyle(.monoAxis).foregroundStyle(BudgieColor.textSecondary)
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(BudgieColor.chartPalette.indices, id: \.self) { BudgieColor.chartPalette[$0].frame(height: 18) }
            }
            .clipShape(Capsule())
        }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Type", link: "See all") {}
            let samples: [(String, TextSpec)] = [
                ("Net worth", .pageTitle), ("$48,210", .heroMedium), ("$1,284", .heroSmall), ("Budgets", .sectionHeader),
                ("Growth", .cardTitle), ("Emergency fund", .goalTitle), ("General", .rowTitle), ("$42.50 of $100", .rowSubtitle),
                ("-$12.30", .amount), ("$3,200", .metricAmount), ("$57.50 left", .badge), ("Appearance", .eyebrow),
                ("SPENT", .monoLabel), ("6M  1Y  ALL", .monoMetricLabel), ("Budgie is locked", .headingLarge),
                ("Some changes are not saved to this device yet.", .bodyMedium),
            ]
            ForEach(samples, id: \.0) { text, spec in
                Text(text).textStyle(spec).foregroundStyle(BudgieColor.textPrimary)
            }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Budgets", link: "Edit") {}
            HStack(spacing: 12) {
                statCard(title: "Income", dot: BudgieColor.income, value: "$3,200", delta: "+100.0% vs August")
                statCard(title: "Expenses", dot: BudgieColor.danger, value: "$43", delta: "+100.0% vs August")
            }
            GlowCard(onTap: {}) {
                HStack(spacing: 14) {
                    IconTile(symbol: "exclamationmark.triangle", color: BudgieColor.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Projected shortfall").textStyle(.rowTitle).foregroundStyle(BudgieColor.textPrimary)
                        Text("Add income or reduce planned spending").textStyle(.rowSubtitle).foregroundStyle(BudgieColor.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("$100").textStyle(.metricAmount).foregroundStyle(BudgieColor.danger)
                        Text("DETAILS ›").textStyle(.monoLabel).foregroundStyle(BudgieColor.textSecondary)
                    }
                }
            }
            GlowListCard(rows: [
                AnyView(budgetRow),
                AnyView(listRow(symbol: "plus", color: BudgieColor.accent, title: "Add a budget", subtitle: "Set a limit for another category")),
            ])
            GlowCard(onTap: {}, onLongPress: {}) {
                Text("Tap or long-press card").textStyle(.rowTitle).foregroundStyle(BudgieColor.textPrimary)
            }
        }
    }

    private var budgetRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: "square.grid.2x2", color: BudgieColor.income)
                VStack(alignment: .leading, spacing: 2) {
                    Text("General").textStyle(.rowTitle).foregroundStyle(BudgieColor.textPrimary)
                    Text("$42.50 of $100").textStyle(.rowSubtitle).foregroundStyle(BudgieColor.textSecondary)
                }
                Spacer()
                PillChip(label: "$57.50 left", color: BudgieColor.income)
            }
            GlowProgressBar(value: 0.425, color: BudgieColor.income)
        }
        .padding(12)
    }

    private func statCard(title: String, dot: Color, value: String, delta: String) -> some View {
        GlowCard(padding: 16, radius: Metrics.statCardRadius) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text(title).textStyle(.rowTitle).foregroundStyle(BudgieColor.textSecondary)
                }
                Text(value).textStyle(.chipAmount).foregroundStyle(BudgieColor.textPrimary)
                Text(delta).textStyle(.rowSubtitle).foregroundStyle(dot)
            }
        }
    }

    private func listRow(symbol: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textStyle(.rowTitle).foregroundStyle(color == BudgieColor.accent ? BudgieColor.accent : BudgieColor.textPrimary)
                Text(subtitle).textStyle(.rowSubtitle).foregroundStyle(BudgieColor.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(BudgieColor.textTertiary)
        }
        .padding(12)
    }

    private var pills: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Pills")
            HStack(spacing: 8) {
                PillChip(label: "$61 over", color: BudgieColor.danger)
                PillChip(label: "Set limit", color: BudgieColor.accent, outlined: true)
                PillChip(label: "+4.2%", color: BudgieColor.income, symbol: "arrow.up.right")
                PillChip(label: "ON TRACK", color: BudgieColor.income, style: .badgeSmall)
            }
            HStack(spacing: 12) {
                PillButton(title: "Expense", symbol: "minus", color: BudgieColor.danger) {}
                PillButton(title: "Income", symbol: "plus", color: BudgieColor.income) {}
            }
            HStack {
                SegmentedPills(items: ["Light", "Dark", "Auto"], selection: $segment)
                Spacer()
                SegmentedPills(items: ["6M", "1Y", "ALL"], selection: $range, mono: true)
            }
            HStack {
                PillButton(title: "Add money", symbol: "plus", filled: true) {}.frame(width: 160)
                Spacer()
                MonthPill(label: "Last 12 months") {}
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Progress")
            GlowProgressBar(value: 0.92, color: BudgieColor.warning)
            GlowProgressBar(value: 1.3, height: 6, color: BudgieColor.danger)
            SplitGlowBar(assetsFraction: 0.72)
            HStack(spacing: 20) {
                ProgressRing(value: 0.64, size: 72, thickness: 8) {
                    Text("64%").textStyle(.badge).foregroundStyle(BudgieColor.textPrimary)
                }
                ProgressRing(value: 1, color: BudgieColor.income) {
                    Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(BudgieColor.income)
                }
                RecurrenceGlyph()
                RecurrenceGlyph(size: 24, color: BudgieColor.accent)
            }
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Fields")
            BudgieField(title: "Goal name", text: $text, prompt: "Emergency fund", symbol: "flag")
            BudgieField(title: "Amount", text: $amount, prompt: "0.00", keyboard: .decimalPad, style: .amount, prefix: "$")
            BudgieField(title: "Amount", text: $amount, prompt: "0.00", keyboard: .decimalPad,
                        error: "Enter an amount greater than zero", style: .amount, prefix: "$")
            BudgieField(title: "Description", text: $text, prompt: "What was this for?", symbol: "text.alignleft", style: .inline)
            FormRow(label: "Category", trailingSymbol: "chevron.down", action: {}) {
                HStack(spacing: 12) {
                    IconTile(symbol: "cart", color: BudgieColor.income, size: 28, radius: 9, iconSize: 15)
                    Text("Groceries").textStyle(.rowTitle).foregroundStyle(BudgieColor.textPrimary)
                }
            }
            DateTile(label: "Date", value: "Sep 05, 2026") {}
            DateTile(label: "Start Date", value: "Sep 05, 2026", error: true) {}
            FormRow(label: "Tags", note: "Optional") {
                HStack(spacing: 8) {
                    PillChip(label: "Work", color: BudgieColor.accent, horizontalPadding: 14, verticalPadding: 9)
                    PillChip(label: "Vacation", color: BudgieColor.textSecondary, outlined: true, horizontalPadding: 14, verticalPadding: 9)
                }
            }
        }
    }

    private var misc: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Rows, sheets, dialogs")
            SwipeToDeleteRow(onDelete: { deleted += 1 }) {
                GlowCard(padding: 12, radius: Metrics.radiusL) {
                    Text("Swipe me left (deleted \(deleted))").textStyle(.rowTitle).foregroundStyle(BudgieColor.textPrimary)
                }
            }
            HStack(spacing: 12) {
                PillButton(title: "Sheet") { sheet = true }
                PillButton(title: "Dialog") { dialog = true }
            }
            HStack(spacing: 12) {
                PillButton(title: "Toast", color: BudgieColor.income) { model.showToast(.addedTo(month: model.selectedMonth, now: model.now)) }
                PillButton(title: "Error toast", color: BudgieColor.danger) { model.showToast(.saveFailed) }
            }
            HStack(spacing: 12) {
                PillButton(title: "Opening") { fullScreen = .opening }
                PillButton(title: "Lock") { fullScreen = .lock }
                PillButton(title: "Cover") { fullScreen = .cover }
            }
            EmptyStateView(
                symbol: "flag", title: "No savings goals yet",
                message: "Create a goal, set a target date, and track progress as you set money aside.",
                actionTitle: "Add goal", horizontalInset: 0
            ) {}
            EmptyStateView(kind: .error, horizontalInset: 0)
        }
    }
}
#endif
