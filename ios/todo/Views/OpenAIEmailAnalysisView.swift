import SwiftUI
import SwiftData

struct OpenAIEmailAnalysisView: View {
    let selection: MailDetailSelection
    let initialTier: OpenAIAnalysisTier
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @Query private var candidates: [EmailMessage]
    @State private var result: RemoteEmailAnalysis?
    @State private var requestTask: Task<Void, Never>?
    @State private var isRequesting = false
    @State private var errorMessage: String?
    @State private var confirmAdvanced = false

    init(selection: MailDetailSelection, tier: OpenAIAnalysisTier) {
        self.selection = selection
        initialTier = tier
        _candidates = selection.liveQuery
    }

    private var email: EmailMessage? { MailDetailSelection.resolve(candidates, matching: selection.key) }

    var body: some View {
        NavigationStack {
            Group {
                if regionalAvailability.isAvailable {
                    availableContent
                } else {
                    RegionalAnalysisUnavailableView()
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(AppLanguage.localized("action.close", defaultValue: "Close", language: .current)) { dismiss() } } }
        }
        .onChange(of: regionalAvailability.isAvailable) { _, available in
            guard !available else { return }
            confirmAdvanced = false
            requestTask?.cancel()
            result = nil
            errorMessage = nil
        }
        .onDisappear { requestTask?.cancel() }
    }

    private var availableContent: some View {
        Form {
            Section {
                if let email {
                    Text(email.subject).font(.headline)
                    Text(AppLanguage.localized("mail.openai.sharingNotice", defaultValue: "Sends only this email's subject and locally stored plain-text body to OpenAI. The inbox, attachments, and meeting content are not sent. The original and local summary remain unchanged.", language: .current))
                        .font(.caption).foregroundStyle(.secondary)
                    if email.body.isEmpty {
                        Text(AppLanguage.localized("mail.openai.noBody", defaultValue: "No plain-text body is available. Finish loading the body in email detail before requesting analysis.", language: .current))
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text(AppLanguage.localized("mail.openai.unavailable", defaultValue: "The email was deleted or is no longer available.", language: .current))
                }
            }
            OpenAIConsentSection(scope: .email)
            Section(AppLanguage.localized("mail.openai.explicitRequest", defaultValue: "Explicit request", language: .current)) {
                Text(initialTier.modelID).font(.caption.monospaced())
                Button(AppLanguage.localized("mail.openai.sendRequest", defaultValue: "Send and analyze with this model", language: .current)) { request(initialTier) }
                    .disabled(email?.body.isEmpty != false || isRequesting)
                    .accessibilityIdentifier("mail.openai.request")
                if result != nil, initialTier == .basic {
                    Button(AppLanguage.localized("mail.openai.advancedRequest", defaultValue: "Re-request important content · gpt-6.1-sol", language: .current)) { confirmAdvanced = true }
                        .disabled(isRequesting)
                        .accessibilityIdentifier("mail.openai.advancedRequest")
                }
                if isRequesting {
                    ProgressView()
                    Button(AppLanguage.localized("memory.analysis.cancelRequest", defaultValue: "Cancel request", language: .current), role: .cancel) { requestTask?.cancel() }
                }
            }
            if let result {
                Section(AppLanguage.localized("mail.openai.preview.title", defaultValue: "Remote analysis · unsaved review preview", language: .current)) {
                    Text(result.modelID).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(result.summary)
                    ForEach(result.keyPoints, id: \.self) { Text($0).font(.subheadline) }
                    if !result.actionItems.isEmpty {
                        Text(AppLanguage.localized("mail.openai.preview.actions", defaultValue: "Requested actions to verify against the original", language: .current)).font(.subheadline.weight(.semibold))
                        ForEach(result.actionItems, id: \.self) { Text($0).font(.subheadline) }
                    }
                    Text(AppLanguage.localized("mail.openai.preview.notice", defaultValue: "No tasks or events are created from this output. Verify deadlines in the original and use the existing save flow explicitly.", language: .current))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
        }
        .appFormStyle()
        .navigationTitle(AppLanguage.localized("mail.openai.title", defaultValue: "OpenAI email analysis", language: .current))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(AppLanguage.localized("mail.openai.advancedConfirmation", defaultValue: "Send this email again using gpt-6.1-sol?", language: .current), isPresented: $confirmAdvanced, titleVisibility: .visible) {
            Button(AppLanguage.localized("mail.openai.advancedConfirm", defaultValue: "Advanced re-request", language: .current)) { request(.advanced) }
            Button(AppLanguage.localized("action.cancel", defaultValue: "Cancel", language: .current), role: .cancel) {}
        }
    }

    private func request(_ tier: OpenAIAnalysisTier) {
        guard regionalAvailability.isAvailable, !isRequesting, let email, !email.body.isEmpty else { return }
        let subject = email.subject
        let body = email.body
        requestTask?.cancel()
        requestTask = Task {
            isRequesting = true
            defer { isRequesting = false }
            do {
                let response = try await OpenAIAnalysisService().email(subject: subject, body: body, tier: tier)
                try Task.checkCancellation()
                guard regionalAvailability.isAvailable,
                      let current = self.email, current.subject == subject, current.body == body else { return }
                result = response
                errorMessage = nil
            } catch is CancellationError { }
            catch { if !Task.isCancelled, regionalAvailability.isAvailable { errorMessage = error.localizedDescription } }
        }
    }
}
