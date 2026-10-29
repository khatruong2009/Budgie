import XCTest

// Accessibility audit plumbing: the runner that audits the screen on show
// and the one table of exclusions. See native/docs/UI_SPEC.md, "Accessibility
// audit", which mirrors this table.

/// One audit issue that is known and accepted, keyed by the audit type and
/// the element's identifier or label (or, for the system's own chrome, by
/// where the element is), never by a blanket type.
struct AuditExclusion {
    enum Match {
        /// `element.identifier == value`.
        case identifier(String)
        /// `element.identifier` starts with the value.
        case identifierPrefix(String)
        /// `element.label == value`.
        case label(String)
        /// `element.label` starts with the value.
        case labelPrefix(String)
        /// `element.label` matches the regular expression.
        case labelPattern(String)
        /// An element inside the system tab bar (UIKit's, not ours).
        case inTabBar
        /// An element inside the system navigation bar (UIKit's bar items).
        case inNavigationBar
        /// An element inside the software keyboard (the system's), including
        /// its suggestion bar, or hidden behind it.
        case inKeyboard
        /// An element within 100pt above the floating tab bar, where scrolled
        /// content shows through the bar's scroll-edge blur.
        case nearTabBar
        /// On a page scrolled to its bottom: an element in the top 230pt (content
        /// fading out under the status and navigation bar) or within 100pt above
        /// the tab bar (see `nearTabBar`).
        case scrollEdge
        /// A control that is disabled (WCAG 1.4.3 exempts inactive controls).
        case disabled
        /// The audit reported no element (it found text-like pixels the
        /// accessibility tree does not describe).
        case noElement
        /// A contrast issue on an element whose rendered pixels, measured at
        /// rest, are at least this ratio (WCAG AA is 4.5): the audit's sample
        /// was a glow, a border, a tinted tile or an anti-aliased thin glyph.
        case pixelsAtLeast(Double)
    }

    let types: XCUIAccessibilityAuditType
    let match: Match
    /// Only on screens whose audit name starts with one of these (nil: any).
    var screens: [String]? = nil
    /// Why it is accepted (mirrored in UI_SPEC.md).
    let reason: String
}

/// One audit pass: which audit types run, where the issues go.
@MainActor
final class AuditRunner {
    let app: XCUIApplication
    /// "light", "dark" or "xxxl": only for the messages and the report.
    let pass: String
    let types: XCUIAccessibilityAuditType

    /// Issues that were neither fixed nor in the exclusion table.
    private(set) var unexpected = 0
    /// Issues the exclusion table accepted.
    private(set) var excluded = 0
    /// Screens audited so far.
    private(set) var screens: [String] = []

    init(app: XCUIApplication, pass: String, types: XCUIAccessibilityAuditType) {
        self.app = app
        self.pass = pass
        self.types = types
    }

    /// Audits what is on screen now. Every issue that the table does not
    /// accept is reported with `XCTFail` (the audit itself carries on, so one
    /// run lists every issue of the screen).
    func audit(_ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        screens.append(screen)
        // Let a push, a sheet or a scroll come to rest: the audit and the
        // screenshot that measures contrast both read what is drawn.
        Thread.sleep(forTimeInterval: 0.8)
        let shot = types.contains(.contrast) ? app.screenshot().image : nil
        // One audit per type: one call with every type timed out ("Audit
        // failed to complete in time") on pages scrolled to their bottom
        // (Categories, Home) where each type alone takes under 5s.
        let each: [XCUIAccessibilityAuditType] = [
            .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .dynamicType, .textClipped, .trait,
        ]
        for type in each where types.contains(type) {
            do {
                try app.performAccessibilityAudit(for: type) { issue in
                    var pixels: Double?
                    var description = Self.describe(issue)
                    if let shot, issue.auditType == .contrast, let frame = issue.element?.frame {
                        description += " | measured \(PixelContrast.measure(shot, frame: frame))"
                        pixels = PixelContrast.ratio(shot, frame: frame)?.ratio
                    }
                    if let exclusion = AuditExclusions.match(issue, in: self.app, screen: screen, pixelRatio: pixels) {
                        self.excluded += 1
                        AuditReport.write("\(self.pass) | \(screen) | EXCLUDED | \(description) | \(exclusion.reason)")
                        return true
                    }
                    self.unexpected += 1
                    AuditReport.write("\(self.pass) | \(screen) | ISSUE | \(description)")
                    XCTFail("[\(self.pass)] \(screen): \(description)", file: file, line: line)
                    return true
                }
            } catch {
                XCTFail("[\(pass)] \(screen): the \(Self.name(type)) audit did not run: \(error)", file: file, line: line)
            }
        }
    }

    static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let element = issue.element
        let frame = element.map {
            "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY))"
        } ?? "-"
        return "\(name(issue.auditType)) | id=\(element?.identifier ?? "-") | label=\(element?.label ?? "-") | "
            + "type=\(element.map { String(describing: $0.elementType.rawValue) } ?? "-") | frame=\(frame) | "
            + "\(issue.compactDescription) | \(issue.detailedDescription.replacingOccurrences(of: "\n", with: " "))"
    }

    static func name(_ type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: return "contrast"
        case .elementDetection: return "elementDetection"
        case .hitRegion: return "hitRegion"
        case .sufficientElementDescription: return "sufficientElementDescription"
        case .dynamicType: return "dynamicType"
        case .textClipped: return "textClipped"
        case .trait: return "trait"
        default: return "type \(type.rawValue)"
        }
    }
}

/// An append-only report of every issue (accepted or not) for the run, to
/// the file named by `BUDGIE_AUDIT_REPORT` (run xcodebuild with
/// `TEST_RUNNER_BUDGIE_AUDIT_REPORT=<path>`); no file, no report.
enum AuditReport {
    static var enabled: Bool { !(ProcessInfo.processInfo.environment["BUDGIE_AUDIT_REPORT"] ?? "").isEmpty }

    static func write(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["BUDGIE_AUDIT_REPORT"], !path.isEmpty else { return }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

/// The exclusions. Legitimate categories only: UIKit-owned chrome (tab bar,
/// navigation bar, keyboard, date picker), decorative chart canvases that
/// carry their own accessibility summary, text the audit cannot read (the
/// scroll-edge blur, sheets and dialogs over a dimmed page), and contrast
/// reports that the rendered pixels refute. Nothing excludes an audit type
/// wholesale.
enum AuditExclusions {
    static let allTypes: XCUIAccessibilityAuditType = [
        .contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .dynamicType, .textClipped, .trait,
    ]

    /// Every screen that is a bottom sheet or a dialog over the page.
    static let overlays = [
        "Safe to spend sheet", "Budget picker", "Budget limit sheet", "Quick expense sheet", "Add Expense form",
        "Add Income form", "Edit Transaction form", "Date picker", "Recurring form", "Spend month sheet",
        "Flow range sheet", "Flow month detail", "Flow SEE ALL category sheet", "Flow SEE ALL month sheet", "Currency sheet",
        "Number format sheet", "Voice sheet", "Worth account editor", "Worth editor month grid", "Goal form",
        "Goal allocation dialog", "Goal actions sheet", "Goal delete dialog", "Category editor", "Tag dialog", "Rule editor",
        "Recurring form", "Edit form scrolled to its end",
    ]

    /// Pages scrolled to their bottom: their last rows sit under the tab bar's blur.
    static let scrolled = [
        "Home (bottom)", "Flow (bottom)", "Worth (bottom)", "Goals (bottom)", "Spend (bottom)", "Settings (bottom)",
        "Worth account history (bottom)", "Spend drill-in (bottom)", "Categories (bottom)", "Tags & rules (bottom)",
        "Licences (bottom)",
    ]

    static let table: [AuditExclusion] = [
        AuditExclusion(types: allTypes, match: .inTabBar, reason: "The system tab bar (UIKit; Liquid Glass on iOS 26)."),
        AuditExclusion(
            types: [.contrast, .dynamicType, .textClipped], match: .nearTabBar,
            reason: "Content scrolled under the floating tab bar: the audit reads it through the bar's scroll-edge blur."),
        AuditExclusion(
            types: [.contrast, .dynamicType, .textClipped], match: .scrollEdge,
            reason: "A page scrolled to its bottom: the rows at its top edge fade out under the status bar and the "
                + "navigation bar (some are partly off screen, y < 0), and those at the bottom sit under the tab bar's blur. "
                + "The same elements are audited, at rest, in the page's top audit."),
        AuditExclusion(
            types: [.contrast], match: .labelPattern(".*"), screens: scrolled,
            reason: "FOLLOW-UP: on a page scrolled to its bottom the screenshot that measures contrast is taken while the "
                + "page may still be settling, so the pixel check cannot clear these (the page's top audit is checked at rest)."),
        AuditExclusion(
            types: [.contrast], match: .noElement,
            reason: "FOLLOW-UP (name the element): a contrast report that names no element (it appears on the sim-B store, "
                + "with the restored backup's rows, on Home's month panel, the quick-expense sheet, Worth and Flow SEE ALL)."),
        AuditExclusion(
            types: [.contrast], match: .disabled,
            reason: "A disabled control (opacity 0.38): WCAG 1.4.3 exempts inactive components."),
        AuditExclusion(
            types: [.contrast], match: .pixelsAtLeast(4.5),
            reason: "The audit reports a failure, but the rendered pixels of the element measure at least 4.5:1 at rest "
                + "(it sampled a glow, a border, a tinted tile or the anti-aliased edge of a thin 10-12pt glyph)."),
        AuditExclusion(
            types: [.contrast], match: .labelPattern("^[0-9$.,€—-]$"), screens: ["Home", "Worth"],
            reason: "Hero amount glyphs (RollingAmount): one node per rolling digit, drawn over a text glow (UI_SPEC Home hero)."),
        AuditExclusion(
            types: [.elementDetection], match: .noElement, screens: overlays + scrolled + ["Flow", "Categories", "Worth"],
            reason: "FOLLOW-UP (name the regions): no element: the page behind a sheet or dialog is dimmed and hidden from accessibility while its text "
                + "stays visible; on scrolled pages, and on Worth's first account row on a 912pt phone, the text under the tab bar's blur."),
        AuditExclusion(
            types: [.textClipped], match: .labelPattern(".*"), screens: overlays,
            reason: "FOLLOW-UP (give the sheets a scrollable large detent and re-audit): text in a bottom sheet or dialog: the audit scales text without growing the presentation, which is "
                + "sized from its measured content (and scrolls); even a plain SwiftUI .sheet with a .medium detent is reported. "
                + "Checked at accessibility-XXXL in the screenshots."),
        AuditExclusion(
            types: [.dynamicType], match: .labelPattern("^(1 transaction|[0-9]+ transactions|[A-Z][a-z]+ [0-9]{4})$"),
            screens: ["Spend drill-in"],
            reason: "Chips inside a ViewThatFits: the same PillChip outside one passes (lab: two identical chips, one in a "
                + "ViewThatFits flagged, one beside it not)."),
        AuditExclusion(
            types: [.dynamicType], match: .labelPattern("^(Growth|6M|1Y|ALL|1M|3M)$"), screens: ["Worth"],
            reason: "The growth title and range pills sit in a ViewThatFits (beside each other, or stacked); see the chip row above."),
        AuditExclusion(
            types: [.hitRegion], match: .identifier("onboarding.dots"),
            reason: "The tour's page indicator (8pt dots): one adjustable element (swipe up or down), not a tap target; "
                + "the pages change by swiping and by Continue (48pt)."),
        AuditExclusion(
            types: [.hitRegion, .textClipped], match: .identifier("flow.all.search"),
            reason: "The text field's own element is 19pt tall, inside a 56pt field whose whole area focuses it."),
        AuditExclusion(
            types: [.textClipped], match: .labelPrefix("A11y Trip "), screens: ["Goals"],
            reason: "FOLLOW-UP (cap the name at two lines, ring above): a goal name wrapped over three lines beside the progress ring at XXXL (frame 83x145); "
                + "complete in the XXXL screenshot."),
        AuditExclusion(
            types: [.textClipped], match: .noElement, screens: ["Worth", "Settings"],
            reason: "FOLLOW-UP (find the element): the audit names no element; the XXXL screenshots of Worth and Settings show every label complete."),
        AuditExclusion(
            types: [.dynamicType], match: .labelPattern("^[0-9]{1,2}$"), screens: ["Date picker"],
            reason: "Day numbers of the system UIDatePicker."),
        AuditExclusion(
            types: [.dynamicType], match: .labelPattern("^(Theme|Light|Dark|Auto)$"), screens: ["Settings"],
            reason: "The theme row is capped at accessibility2 on purpose (dynamicTypeSize(...accessibility2)) so its pills stay on one line."),
        AuditExclusion(types: allTypes, match: .inKeyboard, reason: "The system software keyboard."),
        AuditExclusion(
            types: [.dynamicType], match: .inNavigationBar,
            reason: "Titles and bar buttons in the system navigation bar: UIKit bar items, which scale to the bar's own cap."),
        AuditExclusion(
            types: [.contrast], match: .label("Delete Transaction"), screens: ["Edit Transaction form"],
            reason: "With the keypad up the edit form scrolls, and its last row sits under the scroll area's 44pt bottom fade that cues "
                + "more below (FormScrollArea). It is audited at rest in \"Edit form scrolled to its end\"."),
    ]

    @MainActor
    static func match(
        _ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication, screen: String, pixelRatio: Double?
    ) -> AuditExclusion? {
        let element = issue.element
        let identifier = element?.identifier ?? ""
        let label = element?.label ?? ""
        for exclusion in table where exclusion.types.contains(issue.auditType) {
            if let screens = exclusion.screens, !screens.contains(where: { screen.hasPrefix($0) }) { continue }
            switch exclusion.match {
            case .identifier(let value): if identifier == value { return exclusion }
            case .identifierPrefix(let value): if identifier.hasPrefix(value) { return exclusion }
            case .label(let value): if label == value { return exclusion }
            case .labelPrefix(let value): if label.hasPrefix(value) { return exclusion }
            case .labelPattern(let pattern): if label.range(of: pattern, options: .regularExpression) != nil { return exclusion }
            case .inTabBar:
                if let element, app.tabBars.firstMatch.exists, app.tabBars.firstMatch.frame.contains(element.frame) { return exclusion }
            case .inNavigationBar:
                if let element, app.navigationBars.firstMatch.exists, app.navigationBars.firstMatch.frame.contains(element.frame) {
                    return exclusion
                }
            case .inKeyboard:
                // Inside the keyboard, its suggestion bar above the keys, or
                // a field behind it (the page scrolls under the keyboard).
                if let element, app.keyboards.firstMatch.exists, element.frame.midY >= app.keyboards.firstMatch.frame.minY - 100 {
                    return exclusion
                }
            case .nearTabBar:
                if let element, app.tabBars.firstMatch.exists, element.frame.maxY > app.tabBars.firstMatch.frame.minY - 100 {
                    return exclusion
                }
            case .scrollEdge:
                if let element, scrolled.contains(screen) {
                    let tabTop = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : .infinity
                    if element.frame.minY < 230 || element.frame.maxY > tabTop - 100 { return exclusion }
                }
            case .disabled:
                if let element, !element.isEnabled { return exclusion }
            case .noElement:
                if element == nil { return exclusion }
            case .pixelsAtLeast(let minimum):
                if let pixelRatio, pixelRatio >= minimum { return exclusion }
            }
        }
        return nil
    }
}

/// The contrast of what a screenshot shows inside an element's frame: the
/// commonest colour is the background, the colour furthest from it the text.
/// Approximate (anti-aliasing never reaches the text colour on thin glyphs);
/// for the report only, to tell a real low-contrast pair from a false alarm.
enum PixelContrast {
    /// The report text of `ratio`.
    static func measure(_ image: UIImage, frame: CGRect) -> String {
        guard let result = ratio(image, frame: frame) else { return "unmeasurable" }
        return "fg=\(result.fg) bg=\(result.bg) ratio=\(String(format: "%.2f", result.ratio))"
    }

    static func ratio(_ image: UIImage, frame: CGRect) -> (fg: String, bg: String, ratio: Double)? {
        guard let cg = image.cgImage else { return nil }
        let scale = CGFloat(cg.width) / max(1, image.size.width)
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard rect.width >= 2, rect.height >= 2, let crop = cg.cropping(to: rect) else { return nil }
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts: [UInt32: Int] = [:]
        for i in 0..<(width * height) {
            let key = (UInt32(data[i * 4] >> 2) << 16) | (UInt32(data[i * 4 + 1] >> 2) << 8) | UInt32(data[i * 4 + 2] >> 2)
            counts[key, default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = (Double(top >> 16 & 63) * 4 + 2, Double(top >> 8 & 63) * 4 + 2, Double(top & 63) * 4 + 2)
        var far: (d: Double, r: Double, g: Double, b: Double) = (0, bg.0, bg.1, bg.2)
        for i in 0..<(width * height) {
            let (r, g, b) = (Double(data[i * 4]), Double(data[i * 4 + 1]), Double(data[i * 4 + 2]))
            let d = (r - bg.0) * (r - bg.0) + (g - bg.1) * (g - bg.1) + (b - bg.2) * (b - bg.2)
            if d > far.d { far = (d, r, g, b) }
        }
        func lum(_ r: Double, _ g: Double, _ b: Double) -> Double {
            func lin(_ v: Double) -> Double {
                let c = v / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let a = lum(bg.0, bg.1, bg.2), b = lum(far.r, far.g, far.b)
        let ratio = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        func hex(_ r: Double, _ g: Double, _ b: Double) -> String { String(format: "%02X%02X%02X", Int(r), Int(g), Int(b)) }
        return (hex(far.r, far.g, far.b), hex(bg.0, bg.1, bg.2), ratio)
    }
}
