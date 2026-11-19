import BudgieCore
import XCTest

@testable import Runner

@MainActor
final class ToastTests: XCTestCase {
    func testShowReplaceAndDismissOnlyTheCurrentToast() {
        let model = AppModel()
        let first = Toast.transactionDeleted
        model.showToast(first)
        let second = Toast.saveFailed
        model.showToast(second)
        model.dismissToast(first.id)
        XCTAssertEqual(model.toast, second, "a stale timer must not dismiss a newer toast")
        model.dismissToast(second.id)
        XCTAssertNil(model.toast)
    }

    /// A preset shown twice is two toasts: the second gets its own timer
    /// instead of inheriting the first one's.
    func testPresetsAreFreshToastsEveryTime() {
        XCTAssertNotEqual(Toast.goalAdded.id, Toast.goalAdded.id)
        XCTAssertNotEqual(Toast.saveFailed.id, Toast.saveFailed.id)
        let model = AppModel()
        let first = Toast.allocationAdded
        model.showToast(first)
        model.showToast(.allocationAdded)
        model.dismissToast(first.id)
        XCTAssertNotNil(model.toast, "the first showing's timer must not dismiss the second")
    }

    func testAddedToCopyNamesTheYearOnlyWhenItDiffers() {
        let calendar = DartCalendar(timeZone: .current)
        let now = calendar.date(2026, 9, 28)
        XCTAssertEqual(Toast.addedTo(month: calendar.date(2026, 3), now: now).message, "Added to March")
        XCTAssertEqual(Toast.addedTo(month: calendar.date(2025, 12), now: now).message, "Added to December 2025")
        XCTAssertEqual(Toast.saveFailed.duration, 8)
    }
}
