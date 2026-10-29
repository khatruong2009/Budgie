import BudgieCore
import UIKit
import XCTest

@testable import Runner

@MainActor
final class CategoryModelTests: XCTestCase {
    /// The editor's 18 icons all have an SF Symbol on the iOS 17 floor.
    func testEveryRegisteredIconHasASymbol() {
        XCTAssertEqual(CategoryCatalog.iconIdentifiers.count, 18)
        for identifier in CategoryCatalog.iconIdentifiers {
            let symbol = CategoryCatalog.symbol(for: identifier)
            XCTAssertNotNil(UIImage(systemName: symbol), "\(identifier) -> \(symbol)")
        }
        XCTAssertEqual(CategoryCatalog.colorTokens, ["accent", "green", "blue", "orange", "red", "purple", "pink", "cyan"])
    }

    /// Before the store is loaded nothing can change and nothing is written.
    func testEditsBeforeLoadDoNothing() async {
        let model = AppModel()
        let added = await model.addCategory(type: .expense, name: "Coffee", iconIdentifier: "cart", colorToken: "green")
        XCTAssertEqual(added, .unchanged)
        let updated = await model.updateCategory(id: "expense-general", name: "X", iconIdentifier: "cart", colorToken: "green")
        XCTAssertEqual(updated, .unchanged)
        let archived = await model.setCategoryArchived(id: "expense-general", true)
        XCTAssertEqual(archived, .unchanged)
        let moved = await model.moveCategory(id: "expense-general", offset: 1)
        XCTAssertEqual(moved, .unchanged)
        XCTAssertEqual(model.categoryDefinitions(type: .expense, includeArchived: true), [])
        XCTAssertNil(model.validateCategoryName("", type: .expense, excluding: nil))
        XCTAssertNil(model.categoryMoveOffset(id: "expense-general", direction: 1, includeArchived: false))
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    /// The outcome carries Flutter's copy for the caller's message.
    func testRejectedOutcomeCarriesFlutterCopy() {
        let outcome = AppModel.EditOutcome<CategoryEditError>.rejected(.lastActive)
        guard case .rejected(let error) = outcome else { return XCTFail() }
        XCTAssertEqual(error.message, "At least one category must remain active")
    }
}
