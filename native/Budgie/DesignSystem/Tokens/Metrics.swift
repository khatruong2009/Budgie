import CoreGraphics

/// Spacing, radii and sizes (`design_system.dart` plus the redesign's
/// literal values, spec 01 section 1.2).
enum Metrics {
    // Spacing scale
    static let spacingXXS: CGFloat = 2
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 16
    static let spacingL: CGFloat = 24
    static let spacingXL: CGFloat = 32

    // Radius scale
    static let radiusM: CGFloat = 12
    static let radiusL: CGFloat = 16

    // Icons and touch targets
    static let iconS: CGFloat = 20
    static let iconXL: CGFloat = 48
    static let touchTarget: CGFloat = 44

    // Borders and opacity
    static let borderThin: CGFloat = 1
    static let borderMedium: CGFloat = 1.5
    static let borderThick: CGFloat = 2
    static let opacityDisabled = 0.38
    static let opacityMuted = 0.60

    // Redesign layout
    static let pageHorizontal: CGFloat = 20
    static let sectionGap: CGFloat = 28
    static let cardPadding: CGFloat = 20
    static let cardRadius: CGFloat = 22
    static let statCardRadius: CGFloat = 22
    static let listCardPadding: CGFloat = 8
    static let hairlineInset: CGFloat = 12
    static let sheetRadius: CGFloat = 30
    static let logoMark: CGFloat = 36
    static let logoMarkRadius: CGFloat = 12
    static let fabSize: CGFloat = 54
    static let micFabSize: CGFloat = 44
    static let fabInset: CGFloat = 20
    static let pillButtonHeight: CGFloat = 52
    static let pillButtonCompactHeight: CGFloat = 44
    static let fieldRadius: CGFloat = 16
    static let formRowHeight: CGFloat = 48
    /// A form row's label column (`FormRow`).
    static let formLabelWidth: CGFloat = 64
    static let maxContentWidth: CGFloat = 600
}
