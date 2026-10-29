import SwiftUI
import UIKit

enum AppTheme {
    // Semantic system colors adapt to appearance, contrast and accessibility.
    #if targetEnvironment(macCatalyst)
    static let accent = Color(uiColor: accessibleSystemColor(.systemBlue))
    #else
    static let accent = Color(uiColor: .systemBlue)
    #endif
    static let accentSoft = accent.opacity(0.10)
    static let accentSubtle = accent.opacity(0.06)
    static let accentStroke = accent.opacity(0.22)
    #if targetEnvironment(macCatalyst)
    static let primaryActionFill = Color(uiColor: accessibleSystemColor(.systemBlue)
        .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)))
    #else
    static let primaryActionFill = accent
    #endif
    static let onAccent = Color.white
    #if targetEnvironment(macCatalyst)
    static let success = Color(uiColor: accessibleSystemColor(.systemGreen))
    static let warning = Color(uiColor: accessibleSystemColor(.systemOrange))
    static let destructive = Color(uiColor: accessibleSystemColor(.systemRed))
    static let secondaryText = Color(uiColor: UIColor { traits in
        UIColor.label.resolvedColor(with: traits).withAlphaComponent(traits.accessibilityContrast == .high ? 0.9 : 0.72)
    })
    #else
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let destructive = Color(uiColor: .systemRed)
    static let secondaryText = Color.secondary
    #endif
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let insetSurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let neutralFill = Color(uiColor: .tertiarySystemFill)
    static let neutralStroke = Color(uiColor: .separator).opacity(0.35)
    // Workspace wells remain distinct from elevated task cards in either appearance.
    static let workspaceWell = Color(uiColor: UIColor { traits in
        (traits.userInterfaceStyle == .dark ? UIColor.secondarySystemBackground : .systemGray5)
            .resolvedColor(with: traits)
    })
    static let elevatedSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.tertiarySystemBackground.resolvedColor(with: traits.modifyingTraits { $0.accessibilityContrast = .normal })
            : UIColor.systemBackground.resolvedColor(with: traits)
    })
    static let workspaceStroke = Color(uiColor: UIColor { traits in
        UIColor.separator.resolvedColor(with: traits)
            .withAlphaComponent(traits.accessibilityContrast == .high ? 0.8 : 0.25)
    })
    static let cornerRadius: CGFloat = 18
    static let controlRadius: CGFloat = 10

    enum Spacing {
        static let compact: CGFloat = 8
        static let item: CGFloat = 12
        static let section: CGFloat = 24
        static let page: CGFloat = 32
    }

    static func motion(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1)
    }

    #if targetEnvironment(macCatalyst)
    private static func accessibleSystemColor(_ color: UIColor) -> UIColor {
        UIColor { traits in
            let resolved = color.resolvedColor(with: traits.modifyingTraits { $0.accessibilityContrast = .high })
            guard traits.userInterfaceStyle != .dark else { return resolved }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return resolved }
            // Colored metadata also sits on gray cards; retain its semantic hue
            // while deepening light variants instead of reducing text opacity.
            return UIColor(red: red * 0.85, green: green * 0.85, blue: blue * 0.85, alpha: alpha)
        }
    }
    #endif
}

private struct AppGroupedContentStyle: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let isForm: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isForm {
            content
                .formStyle(.grouped)
                .modifier(AppContentSpacing(horizontalInset: horizontalInset))
        } else {
            content
                .listStyle(.insetGrouped)
                .modifier(AppContentSpacing(horizontalInset: horizontalInset))
        }
    }

    private var horizontalInset: CGFloat {
        horizontalSizeClass == .compact ? 16 : AppTheme.Spacing.section
    }
}

private struct AppContentSpacing: ViewModifier {
    let horizontalInset: CGFloat

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
            .listSectionSpacing(AppTheme.Spacing.section)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 52)
            .background(AppTheme.canvas)
    }
}

private struct AppScreenStyle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .font(.body)
            .environment(\.defaultMinListRowHeight, 52)
            .background(AppTheme.canvas)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

extension View {
    func appScreenStyle() -> some View {
        modifier(AppScreenStyle())
    }

    func appFormStyle() -> some View {
        modifier(AppGroupedContentStyle(isForm: true))
    }

    func appListStyle() -> some View {
        modifier(AppGroupedContentStyle(isForm: false))
    }

    /// Only unoccupied canvas participates; foreground content supplies exclusion anchors.
    func todoBlankAreaExcluded() -> some View {
        anchorPreference(key: TodoBlankAreaExclusions.self, value: .bounds) { [$0] }
    }

    func onTodoBlankAreaDoubleTap(enabled: Bool, perform action: @escaping () -> Void) -> some View {
        overlayPreferenceValue(TodoBlankAreaExclusions.self) { anchors in
            GeometryReader { geometry in
                TodoBlankAreaDoubleTap(
                    exclusions: anchors.map { geometry[$0] },
                    enabled: enabled,
                    action: action
                )
                .accessibilityHidden(true)
            }
        }
    }
}

private struct TodoBlankAreaExclusions: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

/// Observe native taps without inserting a hit-testing layer over scroll, swipe or drag targets.
private struct TodoBlankAreaDoubleTap: UIViewRepresentable {
    let exclusions: [CGRect]
    let enabled: Bool
    let action: () -> Void

    final class CanvasObserver: UIView, UIGestureRecognizerDelegate {
        var exclusions: [CGRect] = []
        var action: () -> Void = {}
        private weak var observedWindow: UIWindow?
        private lazy var doubleTap: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(createTodo))
            recognizer.numberOfTapsRequired = 2
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard observedWindow !== window else { return }
            observedWindow?.removeGestureRecognizer(doubleTap)
            observedWindow = window
            window?.addGestureRecognizer(doubleTap)
        }

        func detach() {
            observedWindow?.removeGestureRecognizer(doubleTap)
            observedWindow = nil
        }

        func setEnabled(_ enabled: Bool) { doubleTap.isEnabled = enabled }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let point = touch.location(in: self)
            guard observedWindow?.isKeyWindow == true,
                  observedWindow?.rootViewController?.presentedViewController == nil,
                  bounds.contains(point),
                  !exclusions.contains(where: { $0.contains(point) }) else { return false }
            var ancestor: UIView? = self
            while let view = ancestor {
                guard !view.isHidden, view.alpha > 0 else { return false }
                ancestor = view.superview
            }
            var touchedView = touch.view
            while let view = touchedView {
                // Native list row padding is part of the task, not blank canvas.
                if view is UIControl || view is UITextView || view is UITextField
                    || view is UITableViewCell || view is UICollectionViewCell { return false }
                touchedView = view.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func createTodo() {
            guard doubleTap.state == .ended else { return }
            action()
        }
    }

    func makeUIView(context: Context) -> CanvasObserver { CanvasObserver() }

    func updateUIView(_ view: CanvasObserver, context: Context) {
        view.exclusions = exclusions
        view.action = action
        view.setEnabled(enabled)
    }

    static func dismantleUIView(_ view: CanvasObserver, coordinator: ()) { view.detach() }
}

#if targetEnvironment(macCatalyst)
struct CatalystToolbarButton: UIViewRepresentable {
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let action: () -> Void

    private final class ToolbarButton: UIButton {
        override var intrinsicContentSize: CGSize { CGSize(width: 32, height: 32) }
    }

    final class Coordinator {
        var action: () -> Void
        var systemImage: String?
        init(action: @escaping () -> Void) { self.action = action }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = ToolbarButton(type: .custom)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .vertical)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32)
        ])
        let coordinator = context.coordinator
        button.addAction(UIAction { _ in coordinator.action() }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        if context.coordinator.systemImage != systemImage {
            button.setImage(UIImage(systemName: systemImage), for: .normal)
            context.coordinator.systemImage = systemImage
        }
        button.accessibilityIdentifier = accessibilityIdentifier
        button.accessibilityLabel = title
        button.isEnabled = context.environment.isEnabled
        button.tintColor = context.environment.isEnabled ? UIColor(AppTheme.accent) : .tertiaryLabel
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: 32, height: 32)
    }
}
#endif
