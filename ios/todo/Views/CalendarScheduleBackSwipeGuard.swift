import SwiftUI
import UIKit

/// Date scrolling owns horizontal pans while this destination is visible.
/// Explicit Back stays available; other navigation destinations keep their prior policy.
@MainActor
struct CalendarScheduleBackSwipeGuard: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.suppressIfVisible() }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.restore() }

    final class Controller: UIViewController {
        private var appeared = false
        private weak var protectedNavigation: UINavigationController?
        private weak var edgeGesture: UIGestureRecognizer?
        private weak var contentGesture: UIGestureRecognizer?
        private var edgeWasEnabled = false
        private var contentWasEnabled = false

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
            // Snapshot after the push transition, not its transient gesture state.
            suppressIfVisible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            appeared = false
            restore()
            super.viewWillDisappear(animated)
        }

        func suppressIfVisible() {
            guard appeared, let navigation = navigationController else { return }
            if protectedNavigation !== navigation {
                restore()
                protectedNavigation = navigation
                edgeGesture = navigation.interactivePopGestureRecognizer
                contentGesture = navigation.interactiveContentPopGestureRecognizer
                edgeWasEnabled = edgeGesture?.isEnabled ?? false
                contentWasEnabled = contentGesture?.isEnabled ?? false
            }
            edgeGesture?.isEnabled = false
            contentGesture?.isEnabled = false
        }

        func restore() {
            if let navigation = protectedNavigation {
                if let gesture = edgeGesture, navigation.interactivePopGestureRecognizer === gesture {
                    gesture.isEnabled = edgeWasEnabled
                }
                if let gesture = contentGesture, navigation.interactiveContentPopGestureRecognizer === gesture {
                    gesture.isEnabled = contentWasEnabled
                }
            }
            protectedNavigation = nil
            edgeGesture = nil
            contentGesture = nil
        }
    }
}
