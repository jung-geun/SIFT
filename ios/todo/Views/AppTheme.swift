import SwiftUI
import UIKit

enum AppTheme {
    // Semantic system colors adapt to appearance, contrast and accessibility.
    static let accent = Color(uiColor: .systemBlue)
    static let accentSoft = accent.opacity(0.10)
    static let accentSubtle = accent.opacity(0.06)
    static let accentStroke = accent.opacity(0.22)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let destructive = Color(uiColor: .systemRed)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let insetSurface = Color(uiColor: .tertiarySystemGroupedBackground)
    static let neutralFill = Color(uiColor: .tertiarySystemFill)
    static let neutralStroke = Color(uiColor: .separator).opacity(0.35)
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
}

#if targetEnvironment(macCatalyst)
struct CatalystToolbarButton: UIViewRepresentable {
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let action: () -> Void

    final class Coordinator {
        var action: () -> Void
        var systemImage: String?
        init(action: @escaping () -> Void) { self.action = action }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .custom)
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
