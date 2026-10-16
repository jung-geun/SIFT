import SwiftUI

// MARK: - View Extension (Shared Helpers)
extension View {
    @ViewBuilder
    func scopeBadge(for key: String, iCloudSyncEnabled: Bool) -> some View {
        let isLocal = SettingsStore.shared.isLocal(key: key)
        
        HStack(spacing: 4) {
            if SettingsStore.supportsICloud && iCloudSyncEnabled {
                if isLocal {
                    Text("로컬")
                        .font(.caption2)
                } else {
                    Image(systemName: "icloud")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text("iCloud 동기화")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            } else {
                Text("로컬")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

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
