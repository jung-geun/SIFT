import UIKit
import Testing
@testable import todo

@MainActor
@Suite("Calendar date-scroll navigation ownership", .serialized)
struct CalendarScheduleBackSwipeGuardTests {
    @Test("Calendar suppresses edge and full-content Back, then restores each prior policy",
          arguments: [true, false], [true, false])
    func restoresPriorGesturePolicies(edgeEnabled: Bool, contentEnabled: Bool) throws {
        let root = UIViewController()
        let destination = CalendarScheduleBackSwipeGuard.Controller()
        let navigation = UINavigationController(rootViewController: root)
        navigation.setViewControllers([root, destination], animated: false)
        navigation.loadViewIfNeeded()
        let edge = try #require(navigation.interactivePopGestureRecognizer)
        let content = try #require(navigation.interactiveContentPopGestureRecognizer)
        edge.isEnabled = edgeEnabled
        content.isEnabled = contentEnabled

        destination.beginAppearanceTransition(true, animated: false)
        destination.endAppearanceTransition()
        #expect(!edge.isEnabled)
        #expect(!content.isEnabled)
        destination.suppressIfVisible()
        #expect(!edge.isEnabled && !content.isEnabled)

        destination.beginAppearanceTransition(false, animated: false)
        destination.endAppearanceTransition()
        #expect(edge.isEnabled == edgeEnabled)
        #expect(content.isEnabled == contentEnabled)
        destination.restore()
        #expect(edge.isEnabled == edgeEnabled && content.isEnabled == contentEnabled)
    }
}
