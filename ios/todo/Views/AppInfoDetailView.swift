import SwiftUI
import SwiftData
import UIKit

// 8. 앱 정보
struct AppInfoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appUpdate: AppUpdateService
    
    var body: some View {
        Form {
            Section {
                LabeledContent("버전") {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
                    Text("\(version) (\(build))")
                }
                if let updateInfo = appUpdate.updateInfo {
                    LabeledContent("업데이트") {
                        Text("최신 \(updateInfo.latestVersion)")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        appUpdate.openAppStore()
                    } label: {
                        Label("App Store에서 업데이트", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                }
                NavigationLink(destination: LaunchScreenDetailView()) {
                    Label("시작 화면", systemImage: "rectangle.on.rectangle")
                }
                NavigationLink(destination: FeedbackView()) {
                    Label(
                        AppLanguage.localized("feedback.title", defaultValue: "의견 보내기", language: .current),
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
                .accessibilityIdentifier("appInfo.feedback")
                NavigationLink(destination: DiagnosticReportView()) {
                    Label(
                        AppLanguage.localized(
                            "diagnostics.settings.link",
                            defaultValue: AppLanguage.current == .english ? "Error Reports" : "오류 보고",
                            language: .current,
                            comment: "Link to user-consented diagnostic reporting settings."
                        ),
                        systemImage: "exclamationmark.bubble"
                    )
                }
                .accessibilityIdentifier("appInfo.diagnosticReports")

                Button {
                    UserDefaults.standard.set(false, forKey: "pieroot.todo.hasCompletedTutorial")
                    NotificationCenter.default.post(name: .settingsDismissRequested, object: nil)
                    dismiss()
                } label: {
                    Label(replayTutorialTitle, systemImage: "questionmark.circle")
                }
                .accessibilityIdentifier("appInfo.replayTutorial")
                .buttonStyle(.borderless)

            }

            Section(header: Text("약관 및 정책")) {
                NavigationLink(destination: LegalDocumentView(document: .privacy)) {
                    Label("개인정보 처리방침", systemImage: "hand.raised.fill")
                }
                NavigationLink(destination: LegalDocumentView(document: .terms)) {
                    Label("서비스 약관", systemImage: "doc.text")
                }
                NavigationLink(destination: ThirdPartyNoticesView()) {
                    Label(
                        AppLanguage.localized("appInfo.licenses.title", defaultValue: "오픈소스 라이선스", language: .current),
                        systemImage: "doc.plaintext"
                    )
                }
                .accessibilityIdentifier("appInfo.licenses")
            }
        }
        .appFormStyle()
        .navigationTitle("앱 정보")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var replayTutorialTitle: String {
        AppLanguage.localized("튜토리얼 다시 보기", defaultValue: "Replay Tutorial", language: .current, comment: "Replay the app tutorial.")
    }

}

private struct ThirdPartyNoticesView: View {
    @State private var notices: [LicenseNotice]?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let notices {
                List(notices) { notice in
                    NavigationLink {
                        LicenseNoticesTextView(notice: notice)
                            .appScreenStyle()
                            .navigationTitle(notice.title)
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Text(notice.title)
                    }
                }
                .appListStyle()
            } else if loadFailed {
                Text(AppLanguage.localized(
                    "appInfo.licenses.loadError",
                    defaultValue: "앱에 포함된 라이선스 문서를 읽을 수 없습니다.",
                    language: .current
                ))
                .padding()
            } else {
                ProgressView().padding()
            }
        }
        .appScreenStyle()
        .navigationTitle(AppLanguage.localized(
            "appInfo.licenses.title", defaultValue: "오픈소스 라이선스", language: .current
        ))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard notices == nil, !loadFailed else { return }
            do {
                guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                notices = try await Task.detached(priority: .utility) {
                    try LicenseNotice.load(from: url)
                }.value
            } catch {
                loadFailed = true
            }
        }
    }
}

private struct LicenseNotice: Identifiable, Sendable {
    let id: Int
    let title: String
    let text: Substring

    nonisolated static func load(from url: URL) throws -> [LicenseNotice] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let separator = "\n\n===== SIFT-LICENSE-SECTION =====\n"
        var notices: [LicenseNotice] = []
        var start = text.startIndex

        func append(_ body: Substring) throws {
            guard !body.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            let titleEnd = body.firstIndex(of: "\n") ?? body.endIndex
            let title = String(body[..<titleEnd])
            guard !title.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            notices.append(LicenseNotice(id: notices.count, title: title, text: body))
        }

        while let range = text.range(of: separator, range: start..<text.endIndex) {
            try append(text[start..<range.lowerBound])
            start = range.upperBound
        }
        try append(text[start..<text.endIndex])
        return notices
    }
}

private struct LicenseNoticesTextView: UIViewRepresentable {
    let notice: LicenseNotice

    final class Coordinator {
        var noticeID: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .monospacedSystemFont(ofSize: 13, weight: .regular)
        )
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.accessibilityIdentifier = "appInfo.licenseText"
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if context.coordinator.noticeID != notice.id {
            uiView.text = String(notice.text)
            context.coordinator.noticeID = notice.id
        }
        uiView.accessibilityLabel = notice.title
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView()
            .environmentObject(AppUpdateService())
            .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
    }
}
