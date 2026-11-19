import SwiftUI
import XCTest

@testable import Runner

/// Flutter lays out each line of app text at `round(size * height)` with the
/// extra leading split evenly (Material `Typography` sets
/// `leadingDistribution: even`); values measured with the real fonts in a
/// Flutter widget test. Guards `TextStyleModifier`.
@MainActor
final class TextLineHeightTests: XCTestCase {
    private func height(_ text: String, _ spec: TextSpec) -> CGFloat {
        let host = UIHostingController(rootView: Text(text).textStyle(spec).fixedSize())
        return host.sizeThatFits(in: CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude)).height
    }

    func testSingleLinesMatchFlutter() {
        let expected: [(String, TextSpec, CGFloat)] = [
            ("hero", .hero, 58), ("heroSmall", .heroSmall, 37), ("chipAmount", .chipAmount, 28),
            ("rowTitle", .rowTitle, 19), ("rowSubtitle", .rowSubtitle, 15), ("bodyMedium", .bodyMedium, 23),
            ("caption", .caption, 18), ("eyebrow", .eyebrow, 13), ("headingLarge", .headingLarge, 34),
            ("numericMedium", .numericMedium, 29),
        ]
        for (name, spec, lineHeight) in expected {
            XCTAssertEqual(height("Ag", spec), lineHeight, accuracy: 0.01, name)
            XCTAssertEqual(spec.lineHeight(scaledSize: spec.size), lineHeight, accuracy: 0.01, "\(name) helper")
        }
    }

    func testWrappedLinesAreWholeLineBoxes() {
        XCTAssertEqual(height("Ag\nAg", .bodyMedium), 46, accuracy: 0.01)
        XCTAssertEqual(height("Ag\nAg", .rowTitle), 38, accuracy: 0.01)
    }
}
