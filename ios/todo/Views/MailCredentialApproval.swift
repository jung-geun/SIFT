import Combine
import CryptoKit
import SwiftUI
import UserNotifications
import UIKit

/// App approval is separate from OS authentication. Only registered recovery
/// operations can be retried; an original mail command is never replayed.
@MainActor
final class MailCredentialApprovalCenter: ObservableObject {
    static let shared = MailCredentialApprovalCenter(defaults: .standard, notificationsEnabled: true)
    nonisolated static let notificationIdentifier = "pieroot.todo.credentialApproval"
    private static let pendingKey = "pieroot.todo.credentialApproval.pendingMail"

    struct Request: Identifiable {
        let id: String
        let account: String
        let purpose: String
        let retry: @MainActor () async throws -> Void
    }

    @Published private(set) var requests: [Request] = []
    @Published var isPresented = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var failed = false
    private var deferredIDs: Set<String> = []
    private var notifiedIDs: Set<String> = []
    private let defaults: UserDefaults
    private let notificationsEnabled: Bool

    /// Isolated centers persist only to their supplied store and never publish or
    /// remove production notifications. The singleton retains live app behavior.
    convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, notificationsEnabled: false)
    }

    private init(defaults: UserDefaults, notificationsEnabled: Bool) {
        self.defaults = defaults
        self.notificationsEnabled = notificationsEnabled
        restorePendingMail()
    }

    /// Other authentication types must supply a purpose, account description and
    /// a provenance-checked retry. Unknown Keychain service events are not replayed.
    func requestApproval(
        id: String, account: String, purpose: String, notify: Bool = true,
        retry: @escaping @MainActor () async throws -> Void
    ) {
        guard !requests.contains(where: { $0.id == id }) else { return }
        requests.append(Request(id: id, account: account, purpose: purpose, retry: retry))
        if UIApplication.shared.applicationState == .active, !deferredIDs.contains(id) {
            isPresented = true
        }
        if notificationsEnabled, notify, notifiedIDs.insert(id).inserted {
            Task { await postNotificationIfAuthorized() }
        }
    }

    func requireMailApproval(provider: MailProvider, namespace: String, restoring: Bool = false) {
        guard selectedNamespace(for: provider) == namespace,
              restoring || UIApplication.shared.isProtectedDataAvailable else { return }
        let id = mailID(provider: provider, namespace: namespace)
        var pending = defaults.stringArray(forKey: Self.pendingKey) ?? []
        if !pending.contains(id) {
            pending.append(id)
            defaults.set(pending, forKey: Self.pendingKey)
        }
        requestApproval(
            id: id,
            account: namespace,
            purpose: Self.localized("credentialApproval.mailPurpose", "저장된 메일 앱 비밀번호를 키체인에서 읽어 이 계정의 메일 연결을 복구합니다. 비밀번호는 화면이나 알림에 표시하지 않습니다."),
            notify: !restoring
        ) { [weak self] in
            guard let self, self.selectedNamespace(for: provider) == namespace else {
                throw CancellationError()
            }
            // Read only the originally reviewed account. The registry checks the
            // selected identity again after suspension, before publishing readiness.
            try await MailboxProviderRegistry.ensureReady(for: provider, namespace: namespace)
            guard self.selectedNamespace(for: provider) == namespace else { throw CancellationError() }
            let name = provider == .gmail ? Notification.Name.gmailAuthChanged
                : Notification.Name("pieroot.todo.outlookAuthChanged")
            if self.notificationsEnabled {
                NotificationCenter.default.post(name: name, object: true)
            }
        }
    }

    func resolveMailApproval(provider: MailProvider, namespace: String) {
        removeRequest(id: mailID(provider: provider, namespace: namespace))
    }

    func enterForeground() {
        pruneChangedMailAccounts()
        if requests.contains(where: { !deferredIDs.contains($0.id) }) { isPresented = true }
    }

    func openFromNotification() {
        pruneChangedMailAccounts()
        if !requests.isEmpty {
            failed = false
            isPresented = true
        }
    }

    func present() {
        pruneChangedMailAccounts()
        failed = false
        isPresented = !requests.isEmpty
    }

    func deferApproval() {
        deferredIDs.formUnion(requests.map(\.id))
        isPresented = false
        failed = false
    }

    func approve() async {
        guard !isAuthenticating else { return }
        pruneChangedMailAccounts()
        guard let request = requests.first else { isPresented = false; return }
        isAuthenticating = true
        failed = false
        defer { isAuthenticating = false }
        do {
            try await KeychainStore.withApprovedAuthentication(purpose: request.purpose) {
                try await request.retry()
            }
            removeRequest(id: request.id)
            isPresented = !requests.isEmpty
        } catch is CancellationError {
            pruneChangedMailAccounts()
            if requests.contains(where: { $0.id == request.id }) { failed = true }
        } catch {
            // OS cancellation/denial and network failures never loop or reveal
            // provider diagnostics. The user may retry or choose Later.
            failed = true
        }
    }

    private func restorePendingMail() {
        let pending = Set(defaults.stringArray(forKey: Self.pendingKey) ?? [])
        for provider in [MailProvider.gmail, .outlook] {
            guard let namespace = selectedNamespace(for: provider),
                  pending.contains(mailID(provider: provider, namespace: namespace)) else { continue }
            requireMailApproval(provider: provider, namespace: namespace, restoring: true)
        }
        pruneChangedMailAccounts()
    }

    private func selectedNamespace(for provider: MailProvider) -> String? {
        switch provider {
        case .gmail:
            return IMAPCredentialStore.canonicalAccount(defaults.string(forKey: "pieroot.todo.imap.account") ?? "")
        case .outlook:
            return OutlookIMAPCredentialStore.canonicalAccount(defaults.string(forKey: "pieroot.todo.outlook.account") ?? "")
        }
    }

    private func mailID(provider: MailProvider, namespace: String) -> String {
        let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
        return "mail.\(provider.rawValue).\(digest)"
    }

    private func pruneChangedMailAccounts() {
        let current = Set([MailProvider.gmail, .outlook].compactMap { provider in
            selectedNamespace(for: provider).map { mailID(provider: provider, namespace: $0) }
        })
        requests.removeAll { $0.id.hasPrefix("mail.") && !current.contains($0.id) }
        let saved = defaults.stringArray(forKey: Self.pendingKey) ?? []
        defaults.set(saved.filter { current.contains($0) }, forKey: Self.pendingKey)
        if requests.isEmpty {
            isPresented = false
            if notificationsEnabled {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationIdentifier])
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationIdentifier])
            }
        }
    }

    private func removeRequest(id: String) {
        requests.removeAll { $0.id == id }
        let saved = defaults.stringArray(forKey: Self.pendingKey) ?? []
        defaults.set(saved.filter { $0 != id }, forKey: Self.pendingKey)
        pruneChangedMailAccounts()
    }

    private func postNotificationIfAuthorized() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard UIApplication.shared.applicationState != .active, !requests.isEmpty,
              settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else { return }
        let content = UNMutableNotificationContent()
        content.title = Self.localized("credentialApproval.notification.title", "인증 전에 확인이 필요합니다")
        content.body = Self.localized("credentialApproval.notification.body", "앱에서 계정과 사용 목적을 확인한 뒤 승인해 주세요. 승인 전에는 시스템 인증을 시작하지 않습니다.")
        // No account, credential, service identifier or original command leaves
        // the app in lock-screen content or notification metadata.
        let request = UNNotificationRequest(identifier: Self.notificationIdentifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    static func localized(_ key: String, _ fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "App approval before system credential authentication.")
    }
}

struct MailCredentialApprovalPresentation: ViewModifier {
    @ObservedObject private var center = MailCredentialApprovalCenter.shared
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if !center.requests.isEmpty {
                    Button {
                        center.present()
                    } label: {
                        Label(MailCredentialApprovalCenter.localized("credentialApproval.open", "인증 요청 확인"), systemImage: "lock.shield")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    .accessibilityIdentifier("credentialApproval.open")
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 90)
                }
            }
            .sheet(isPresented: $center.isPresented, onDismiss: { center.deferApproval() }) {
                NavigationStack {
                    Form {
                        if let request = center.requests.first {
                            Section {
                                Text(request.account).textSelection(.enabled)
                                Text(request.purpose)
                                Text(MailCredentialApprovalCenter.localized("credentialApproval.explanation", "허용을 누른 경우에만 Touch ID, Face ID 또는 시스템 암호 확인이 표시될 수 있습니다. 나중에 선택하면 시스템 인증을 시작하지 않으며 앱에서 다시 확인할 수 있습니다."))
                            }
                            if center.failed {
                                Text(MailCredentialApprovalCenter.localized("credentialApproval.failed", "인증 또는 연결을 완료하지 못했습니다. 시스템 인증을 자동으로 다시 시도하지 않습니다. 다시 허용하거나 나중에 확인해 주세요."))
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("credentialApproval.failed")
                            }
                            Section {
                                Button(MailCredentialApprovalCenter.localized("credentialApproval.allow", "허용하고 계속")) {
                                    Task { await center.approve() }
                                }
                                .disabled(center.isAuthenticating)
                                .accessibilityIdentifier("credentialApproval.allow")
                                Button(MailCredentialApprovalCenter.localized("credentialApproval.later", "나중에"), role: .cancel) {
                                    center.deferApproval()
                                }
                                .disabled(center.isAuthenticating)
                                .accessibilityIdentifier("credentialApproval.later")
                                if center.isAuthenticating { ProgressView() }
                            }
                        }
                    }
                    .navigationTitle(MailCredentialApprovalCenter.localized("credentialApproval.title", "인증 사용 승인"))
                    .interactiveDismissDisabled(center.isAuthenticating)
                }
            }
            .onAppear { center.enterForeground() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { center.enterForeground() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .gmailAuthChanged)) { _ in center.presentIfAccountChanged() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("pieroot.todo.outlookAuthChanged"))) { _ in center.presentIfAccountChanged() }
    }
}

extension MailCredentialApprovalCenter {
    func presentIfAccountChanged() { pruneChangedMailAccounts() }
}
