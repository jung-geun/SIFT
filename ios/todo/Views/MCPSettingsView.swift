import SwiftUI
#if targetEnvironment(macCatalyst)
import UIKit
#endif

/// Desktop-only switch for the loopback MCP server that lets local AI agents read and edit to-dos.
struct MCPSettingsView: View {
    @AppStorage("pieroot.todo.mcp.enabled") private var enabled = false
    @ObservedObject private var server = TodoMCPServer.shared
    @State private var token = ""
    @State private var revealed = false
    @State private var errorText: String?
    @State private var confirmRegenerate = false

    private var bridgeCommand: String {
        "SIFT_MCP_TOKEN=\(revealed ? token : "<토큰>") python3 scripts/sift_mcp_bridge.py"
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    AppLanguage.localized("mcp.settings.enable", defaultValue: "MCP 서버 켜기", language: .current, comment: "Enable local MCP server."),
                    isOn: $enabled
                )
                .onChange(of: enabled) { _, isOn in
                    if isOn {
                        server.start(container: AppDataContainer.shared.container)
                    } else {
                        server.stop()
                    }
                    refreshToken()
                }
            } footer: {
                Text(AppLanguage.localized("mcp.settings.footer", defaultValue: "이 Mac의 127.0.0.1에서만 열립니다. 외부 네트워크나 다른 기기에서는 접근할 수 없습니다. 휴대폰에서 추가한 할 일은 iCloud 동기화 후 여기에서 보입니다.", language: .current, comment: "Local MCP server explanation."))
            }

            Section {
                LabeledContent(AppLanguage.localized("mcp.settings.status", defaultValue: "상태", language: .current, comment: "MCP server status label.")) {
                    Text(server.isRunning
                        ? AppLanguage.localized("mcp.settings.running", defaultValue: "실행 중", language: .current, comment: "MCP server running.")
                        : AppLanguage.localized("mcp.settings.stopped", defaultValue: "중지됨", language: .current, comment: "MCP server stopped."))
                }
                LabeledContent(AppLanguage.localized("mcp.settings.endpoint", defaultValue: "엔드포인트", language: .current, comment: "MCP endpoint label.")) {
                    Text(TodoMCPServer.endpointURL)
                        .textSelection(.enabled)
                        .font(.caption.monospaced())
                }
                if let error = server.lastError ?? errorText {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section(AppLanguage.localized("mcp.settings.token", defaultValue: "토큰", language: .current, comment: "MCP bearer token section.")) {
                if enabled, !token.isEmpty {
                    Text(revealed ? token : String(repeating: "•", count: 24))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button(revealed
                        ? AppLanguage.localized("mcp.settings.hide", defaultValue: "숨기기", language: .current, comment: "Hide token.")
                        : AppLanguage.localized("mcp.settings.reveal", defaultValue: "보기", language: .current, comment: "Reveal token.")) {
                        revealed.toggle()
                    }
                    #if targetEnvironment(macCatalyst)
                    Button(AppLanguage.localized("mcp.settings.copy", defaultValue: "토큰 복사", language: .current, comment: "Copy token.")) {
                        UIPasteboard.general.string = token
                    }
                    #endif
                    Button(AppLanguage.localized("mcp.settings.regenerate", defaultValue: "토큰 재발급", language: .current, comment: "Regenerate token."), role: .destructive) {
                        confirmRegenerate = true
                    }
                } else {
                    Text(AppLanguage.localized("mcp.settings.tokenOff", defaultValue: "서버를 켜면 토큰이 만들어집니다.", language: .current, comment: "Token appears when server enabled."))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(AppLanguage.localized("mcp.settings.howto.stdio", defaultValue: "stdio 클라이언트(Claude Code, Codex, omp 등)는 저장소의 브리지 스크립트를 등록합니다.", language: .current, comment: "How to connect stdio clients."))
                    .font(.footnote)
                Text(bridgeCommand)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(AppLanguage.localized("mcp.settings.howto.http", defaultValue: "HTTP MCP를 지원하는 클라이언트는 위 엔드포인트와 Authorization: Bearer 헤더를 사용합니다.", language: .current, comment: "How to connect HTTP clients."))
                    .font(.footnote)
            } header: {
                Text(AppLanguage.localized("mcp.settings.howto", defaultValue: "연결 방법", language: .current, comment: "MCP connection instructions."))
            }
        }
        .navigationTitle(AppLanguage.localized("mcp.settings.title", defaultValue: "MCP 연결", language: .current, comment: "MCP settings title."))
        .onAppear { refreshToken() }
        .confirmationDialog(
            AppLanguage.localized("mcp.settings.regenerateConfirm", defaultValue: "토큰을 재발급할까요? 기존 연결은 즉시 끊깁니다.", language: .current, comment: "Confirm token regeneration."),
            isPresented: $confirmRegenerate,
            titleVisibility: .visible
        ) {
            Button(AppLanguage.localized("mcp.settings.regenerate", defaultValue: "토큰 재발급", language: .current, comment: "Regenerate token."), role: .destructive) {
                regenerate()
            }
            Button(AppLanguage.localized("action.cancel", defaultValue: "취소", language: .current, comment: "Cancel action."), role: .cancel) {}
        }
    }

    private func refreshToken() {
        token = enabled ? (TodoMCPServer.currentToken() ?? "") : ""
    }

    private func regenerate() {
        do {
            try server.regenerateToken(container: AppDataContainer.shared.container)
            errorText = nil
            refreshToken()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
