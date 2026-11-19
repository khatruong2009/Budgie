import UIKit
import XCTest

@testable import Runner

@MainActor
final class RoutingTests: XCTestCase {
    func testDeepLinksAndShortcutsMapLikeTheFlutterApp() {
        let model = AppModel()
        for (link, route) in [
            ("budgetapp://add-income", AddRoute.income), ("budgetapp://add_income", .income),
            ("budgetapp://add-expense", .expense), ("budgetapp://add_expense", .expense),
            ("budgetapp://voice-add", .voice), ("budgetapp://voice_add", .voice),
            ("budgetapp:///voice-add", .voice), ("budgetapp:///voice_add", .voice), ("budgetapp:///add-income", .income),
        ] {
            model.pendingAdd = nil
            model.open(URL(string: link)!)
            XCTAssertEqual(model.pendingAdd, route, link)
        }
        model.pendingAdd = nil
        model.open(URL(string: "budgetapp://unknown")!)
        XCTAssertNil(model.pendingAdd)
        for (type, route) in [("action_add_expense", AddRoute.expense), ("action_add_income", .income), ("action_voice_add", .voice)] {
            model.pendingAdd = nil
            model.handleShortcut(type)
            XCTAssertEqual(model.pendingAdd, route, type)
        }
    }
}

@MainActor
final class RouteGateTests: XCTestCase {
    /// Before the data is ready (and, in the app, while locked or during
    /// onboarding) a route stays queued instead of opening.
    func testRoutesWaitUntilTheyMayOpen() {
        let model = AppModel()
        XCTAssertFalse(model.canOpenRoutes)
        model.open(URL(string: "budgetapp://add-income")!)
        XCTAssertNil(model.takePendingAdd())
        XCTAssertEqual(model.pendingAdd, .income, "the route is kept for later")
        XCTAssertFalse(model.isLocked, "no data, no lock")
        model.sessionUnlocked = true
        model.sessionUnlocked = false
        XCTAssertEqual(model.pendingAdd, .income)
    }

    /// A voice link or quick action waits like any other route: no recording
    /// sheet before the app is unlocked and past the tour.
    func testVoiceRoutesWaitUntilTheyMayOpen() {
        let model = AppModel()
        XCTAssertFalse(model.canOpenRoutes)
        model.open(URL(string: "budgetapp://voice-add")!)
        XCTAssertNil(model.takePendingAdd())
        XCTAssertEqual(model.pendingAdd, .voice, "the route is kept for later")
        model.handleShortcut("action_voice_add")
        XCTAssertNil(model.takePendingAdd())
        XCTAssertEqual(model.pendingAdd, .voice)
    }
}

/// `AddFormPresenter`: a route opens on top of whatever is presented, is
/// taken only when it can be presented, and never blocks later routes.
@MainActor
final class AddFormPresenterTests: XCTestCase {
    private var window: UIWindow!

    override func setUp() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        window = UIWindow(windowScene: scene)
    }

    override func tearDown() async throws {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
        window = nil
    }

    /// Shows `root` in the test window.
    private func show(_ root: UIViewController) {
        window.rootViewController = root
        window.isHidden = false
    }

    /// Runs the main loop until `condition` holds (UIKit finishes even an
    /// unanimated presentation on a later turn of the loop).
    private func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Stands in for a controller mid-dismissal or mid-presentation.
    private final class Transitioning: UIViewController {
        var dismissing = false
        var presenting = false
        override var isBeingDismissed: Bool { dismissing }
        override var isBeingPresented: Bool { presenting }
    }

    /// Refuses every presentation, as UIKit does from a busy controller.
    private final class Refusing: UIViewController {
        override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {}
    }

    /// Reports `shown` as presented without presenting it.
    private final class Showing: UIViewController {
        var shown: UIViewController?
        override var presentedViewController: UIViewController? { shown }
    }

    func testPresentsFromTheTopmostPresentedController() {
        let root = UIViewController(), sheet = UIViewController(), picker = UIViewController()
        XCTAssertNil(AddFormPresenter.presenter(above: nil))
        XCTAssertNil(AddFormPresenter.presenter(above: root), "not in a window yet")
        show(root)
        XCTAssertIdentical(AddFormPresenter.presenter(above: root), root, "nothing presented")
        root.present(sheet, animated: false)
        settle { AddFormPresenter.presenter(above: root) != nil }
        sheet.present(picker, animated: false)
        settle { AddFormPresenter.presenter(above: root) === picker }
        XCTAssertIdentical(AddFormPresenter.presenter(above: root), picker, "over a sheet over a sheet")
    }

    func testWaitsForATransitionAndKeepsTheRoute() {
        let root = UIViewController(), sheet = Transitioning()
        show(root)
        root.present(sheet, animated: false)
        settle { AddFormPresenter.presenter(above: root) != nil }
        var pending: AddRoute? = .income
        let take = { () -> AddRoute? in
            defer { pending = nil }
            return pending
        }

        sheet.dismissing = true
        XCTAssertNil(AddFormPresenter.presenter(above: root), "the top is being dismissed")
        XCTAssertNil(AddFormPresenter.open(above: root, take: take) { _ in UIViewController() })
        XCTAssertEqual(pending, .income, "not taken while nothing can present it")
        sheet.dismissing = false
        sheet.presenting = true
        XCTAssertNil(AddFormPresenter.open(above: root, take: take) { _ in UIViewController() })
        XCTAssertEqual(pending, .income, "not taken mid-presentation either")

        // Once the transition is over it opens, over the sheet.
        sheet.presenting = false
        let form = UIViewController()
        XCTAssertNil(AddFormPresenter.open(above: root, take: take) { _ in form })
        XCTAssertNil(pending, "taken")
        XCTAssertIdentical(form.presentingViewController, sheet, "presented over the sheet")
    }

    func testEveryLaterRouteOpensToo() {
        let root = UIViewController()
        show(root)
        var opened: [UIViewController] = []
        for route in [AddRoute.expense, .income, .expense] {
            settle { AddFormPresenter.presenter(above: root) != nil }
            let form = UIViewController()
            XCTAssertNil(AddFormPresenter.open(above: root, take: { route }) { _ in form })
            XCTAssertNotNil(form.presentingViewController, "\(route) opened")
            opened.append(form)
        }
        XCTAssertIdentical(opened[1].presentingViewController, opened[0], "stacked over the open form")
        XCTAssertIdentical(opened[2].presentingViewController, opened[1])
    }

    /// The bug: a refused presentation lost the route. It comes back for
    /// the caller to queue again.
    func testARefusedPresentationHandsTheRouteBack() {
        show(Refusing())
        let refused = AddFormPresenter.open(above: window.rootViewController, take: { .income }) { _ in UIViewController() }
        XCTAssertEqual(refused, .income)
    }

    /// A host with no form over it is about to show its form or to dismiss
    /// itself (taking anything presented from it along): wait for it.
    func testWaitsWhileAnAddFormHostHasNoFormUp() {
        let root = Showing()
        show(root)
        root.shown = UIViewController()
        XCTAssertIdentical(AddFormPresenter.presenter(above: root), root.shown)
        root.shown = AddFormHost(route: .income, model: AppModel())
        XCTAssertNil(AddFormPresenter.presenter(above: root))
    }

    /// One voice flow at a time (Flutter's `_voiceFlowActive`): a second
    /// `.voice` route while a voice host is up is taken and dropped, not
    /// queued and not stacked; add and income routes still open over it.
    func testASecondVoiceRouteIsDroppedWhileAVoiceHostIsUp() {
        let root = UIViewController()
        show(root)
        let voice = UIViewController()
        settle { AddFormPresenter.presenter(above: root) != nil }
        XCTAssertNil(AddFormPresenter.open(above: root, take: { .voice }) { _ in voice })
        XCTAssertIdentical(voice.presentingViewController, root, "the first opens")
        settle { AddFormPresenter.presenter(above: root) === voice }

        var pending: AddRoute? = .voice
        let take = { () -> AddRoute? in
            defer { pending = nil }
            return pending
        }
        var built = 0
        XCTAssertNil(AddFormPresenter.open(above: root, take: take) { _ in built += 1; return UIViewController() })
        XCTAssertNil(pending, "taken")
        XCTAssertEqual(built, 0, "and nothing was presented for it")
        XCTAssertNil(voice.presentedViewController, "no second voice flow stacked")

        // Other routes still stack over the voice flow.
        let form = UIViewController()
        XCTAssertNil(AddFormPresenter.open(above: root, take: { .expense }) { _ in form })
        XCTAssertIdentical(form.presentingViewController, voice)

        // Once the voice host is gone a new voice route opens again.
        form.dismiss(animated: false)
        settle { voice.presentedViewController == nil }
        voice.dismiss(animated: false)
        settle { AddFormPresenter.presenter(above: root) === root }
        let again = UIViewController()
        XCTAssertNil(AddFormPresenter.open(above: root, take: { .voice }) { _ in again })
        XCTAssertIdentical(again.presentingViewController, root)
        endVoiceFlow(again)
    }

    /// The presenter remembers the last voice host, so a test that opened
    /// one closes it before it ends.
    private func endVoiceFlow(_ host: UIViewController) {
        settle { host.transitionCoordinator == nil }
        host.dismiss(animated: false)
        settle { host.presentingViewController == nil }
    }

    /// A refused voice presentation leaves nothing behind: the route comes
    /// back and the next voice route is not mistaken for a duplicate.
    func testARefusedVoicePresentationDoesNotBlockTheNextOne() {
        show(Refusing())
        let refused = AddFormPresenter.open(above: window.rootViewController, take: { .voice }) { _ in UIViewController() }
        XCTAssertEqual(refused, .voice)
        let root = UIViewController()
        show(root)
        let host = UIViewController()
        settle { AddFormPresenter.presenter(above: root) != nil }
        XCTAssertNil(AddFormPresenter.open(above: root, take: { .voice }) { _ in host })
        XCTAssertIdentical(host.presentingViewController, root)
        endVoiceFlow(host)
    }
}
