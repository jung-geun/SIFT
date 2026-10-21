import SwiftUI

struct SettingsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AppTheme.Spacing.item) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - View Extension (Shared Helpers)
extension View {
    @ViewBuilder
    func disableNavigationBarMinimization() -> some View {
        if #available(iOS 27.0, *) {
            self.toolbarMinimizationBehavior(.never, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func disableTabBarMinimization() -> some View {
        if #available(iOS 27.0, *) {
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }
}
