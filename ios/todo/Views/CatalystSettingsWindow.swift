#if targetEnvironment(macCatalyst)
import SwiftUI

enum CatalystSettingsWindowID: String, Codable, Hashable {
    case settings
    static let sceneID = "settings"
}

struct CatalystSettingsPresenter: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .settingsRequested)) { _ in
            openWindow(id: CatalystSettingsWindowID.sceneID, value: CatalystSettingsWindowID.settings)
        }
    }
}

struct CatalystSettingsWindowContent: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var language = AppLanguage.current
    @State private var replayTutorialAfterClose = false

    var body: some View {
        NavigationStack {
            PersonaSettingsView(onClose: { dismissWindow() })
        }
        .frame(minWidth: 480, idealWidth: 620, minHeight: 420, idealHeight: 740)
        .environment(\.locale, language.locale)
        .modifier(CatalystSettingsPresenter())
        .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
            language = AppLanguage.current
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsDismissRequested)) { _ in
            replayTutorialAfterClose = true
            dismissWindow()
        }
        .onDisappear {
            guard replayTutorialAfterClose else { return }
            replayTutorialAfterClose = false
            NotificationCenter.default.post(name: .appTutorialRequested, object: nil)
        }
    }
}
#endif
