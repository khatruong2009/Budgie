import SwiftUI

/// Settings > About > Licences: the SIL OFL texts the bundled fonts require
/// to travel with them, one section per font (REDESIGN_PLAN 4.7: a
/// `SectionHeader` over a card holding the text).
struct LicencesView: View {
    private let licences: [(title: String, file: String)] = [
        ("Gabarito", "OFL-Gabarito"),
        ("Spline Sans Mono", "OFL-SplineSansMono"),
    ]

    private static let licenceText = TextSpec(face: .monoRegular, size: 12, height: 1.45, relativeTo: .footnote)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                ForEach(licences, id: \.file) { licence in
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: licence.title)
                        GlowCard(padding: Metrics.spacingM) {
                            Text(Self.text(licence.file))
                                .textStyle(Self.licenceText)
                                .foregroundStyle(BudgieColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: Metrics.spacingM, leading: Metrics.pageHorizontal, bottom: Metrics.spacingXL, trailing: Metrics.pageHorizontal))
            .frame(maxWidth: Metrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BudgieColor.background)
        .budgiePushedTitle("Licences", singleLine: true)
    }

    static func text(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}
