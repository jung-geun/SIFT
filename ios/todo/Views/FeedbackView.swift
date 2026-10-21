import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Push directly from App Info, or present inside a NavigationStack from a
/// diagnostic preview. The callback acknowledges only a validated durable receipt;
/// its Boolean describes the frozen payload, not the current attachment toggle.
@MainActor struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var composer: FeedbackComposer
    @State private var sendTask: Task<Void, Never>?
    private let showsCloseButton: Bool
    private let onDelivered: (FeedbackReceipt, Bool) -> Void

    init(
        initialKind: FeedbackKind = .bug,
        diagnosticData: Data? = nil,
        showsCloseButton: Bool = false,
        onDelivered: @escaping (FeedbackReceipt, Bool) -> Void = { _, _ in }
    ) {
        _composer = StateObject(wrappedValue: FeedbackComposer(
            initialKind: initialKind, preparedDiagnostics: diagnosticData
        ))
        self.showsCloseButton = showsCloseButton
        self.onDelivered = onDelivered
    }

    var body: some View {
        Form {
            if let receipt = composer.receipt {
                receiptSections(receipt)
            } else if let submission = composer.submission {
                reviewSections(submission)
            } else {
                draftSections
            }
        }
        .appFormStyle()
        .navigationTitle(text("title", "Send feedback"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button(text(composer.receipt == nil ? "cancel" : "done", composer.receipt == nil ? "Cancel" : "Done")) {
                        dismiss()
                    }
                    .disabled(composer.isSending)
                    .accessibilityIdentifier("feedback.close")
                }
            }
        }
        .interactiveDismissDisabled(composer.isSending)
        .onDisappear {
            sendTask?.cancel()
            composer.cancel()
        }
    }

    @ViewBuilder private var draftSections: some View {
        Section {
            Picker(text("kind", "Feedback type"), selection: $composer.kind) {
                Text(text("kind.bug", "Bug report")).tag(FeedbackKind.bug)
                Text(text("kind.feature", "Feature request")).tag(FeedbackKind.feature)
            }
            .pickerStyle(.segmented)
        }
        Section(text("field.title", "Title")) {
            TextField(text("field.title", "Title"), text: $composer.title, axis: .vertical)
                .lineLimit(1...3)
                .accessibilityIdentifier("feedback.titleField")
            characterCount(composer.title, maximum: 120)
        }
        Section(text("field.message", "Message")) {
            TextEditor(text: $composer.message)
                .frame(minHeight: 180)
                .accessibilityLabel(text("field.message", "Message"))
                .accessibilityIdentifier("feedback.messageField")
            characterCount(composer.message, maximum: 8000)
        }
        Section {
            if composer.kind == .bug, composer.preparedDiagnostics != nil {
                Toggle(text("diagnostics.include", "Attach the prepared diagnostic report"), isOn: $composer.includeDiagnostics)
                Text(text("diagnostics.exact", "Only the exact report shown below will be attached. Switching to a feature request excludes diagnostics."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if composer.includeDiagnostics {
                    if let data = composer.preparedDiagnostics, let report = String(data: data, encoding: .utf8) {
                        diagnosticPreview(report)
                    } else {
                        Text(failureText(.invalidDiagnostics)).foregroundStyle(.red)
                    }
                }
            } else {
                Text(text("diagnostics.none", "No diagnostics attached"))
                    .foregroundStyle(.secondary)
            }
            privacyNotice
        }
        if let failure = composer.failure { failureSection(failure) }
        Section {
            Button(text("review", "Review before sending")) { composer.prepareReview() }
                .accessibilityIdentifier("feedback.reviewButton")
        }
    }

    @ViewBuilder private func reviewSections(_ submission: FeedbackSubmission) -> some View {
        Section {
            Text(text("review.detail", "Nothing is sent until you consent and tap Send. Review the exact message, app metadata, and any attached report below."))
        }
        Section(text("kind", "Feedback type")) {
            Text(submission.kind == .bug ? text("kind.bug", "Bug report") : text("kind.feature", "Feature request"))
        }
        Section(text("field.title", "Title")) {
            Text(verbatim: submission.title).textSelection(.enabled)
        }
        Section(text("field.message", "Message")) {
            Text(verbatim: submission.message).textSelection(.enabled)
        }
        Section(text("metadata", "App information")) {
            metadataRow("version", "App version", submission.app.version)
            metadataRow("build", "Build", submission.app.build)
            metadataRow("platform", "Platform", submission.app.platform)
            metadataRow("os", "OS version", submission.app.osVersion)
            metadataRow("language", "App language", submission.app.language)
        }
        Section {
            if let report = submission.diagnostics {
                diagnosticPreview(report)
            } else {
                Text(text("diagnostics.none", "No diagnostics attached"))
            }
            privacyNotice
            Text(text("legal.transmission", "Sending is optional. Your message and app, OS and language information go over HTTPS to the private SIFT inbox hosted by Cloudflare. Only the operator reads it. Exact diagnostics are included only if selected and reviewed. Reports expire after 30 days and are purged daily; provider recovery history may retain deleted data for 7 days. The host processes network metadata; daily HMAC-IP abuse-prevention records are kept for 2 days. No email or account is required and no individual reply is provided."))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle(text("consent", "I have reviewed this content and agree to send it to the private SIFT inbox."), isOn: $composer.consent)
                .disabled(composer.isSending)
                .accessibilityIdentifier("feedback.consentToggle")
        }
        if let failure = composer.failure { failureSection(failure) }
        Section {
            if composer.isSending {
                ProgressView(text("sending", "Sending…"))
                Button(text("cancelSending", "Cancel sending"), role: .cancel) {
                    sendTask?.cancel()
                    composer.cancel()
                }
            } else {
                Button(text(composer.failure == nil ? "send" : "retry", composer.failure == nil ? "Send" : "Retry this submission")) {
                    send()
                }
                .disabled(!composer.consent)
                .accessibilityIdentifier("feedback.sendButton")
                Button(text("edit", "Edit")) { composer.returnToEditing() }
            }
        }
    }

    @ViewBuilder private func receiptSections(_ receipt: FeedbackReceipt) -> some View {
        Section {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                Label(text("receipt.title", "Feedback received"), systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Text(text("receipt.detail", "Your feedback was saved to the private SIFT inbox. Keep this receipt for your records; no individual reply is provided."))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("feedback.receipt")
        }
        Section(text("receipt.ticket", "Ticket ID")) {
            Text(verbatim: receipt.ticketID)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            #if canImport(UIKit)
            Button(text("receipt.copy", "Copy ticket ID"), systemImage: "doc.on.doc") {
                UIPasteboard.general.string = receipt.ticketID
            }
            #endif
        }
        Section(text("receipt.date", "Received at (UTC)")) {
            Text(verbatim: receipt.receivedAt).textSelection(.enabled)
        }
        Section {
            Button(text("done", "Done")) { dismiss() }
        }
    }

    private var privacyNotice: some View {
        Text(text("privacy", "Do not enter passwords, tokens, account details, tasks, or other private content. No account or email is required. This inbox does not provide individual replies."))
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func diagnosticPreview(_ report: String) -> some View {
        DisclosureGroup(text("diagnostics.preview", "Exact diagnostic report")) {
            Text(verbatim: report)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataRow(_ suffix: String, _ fallback: String, _ value: String) -> some View {
        LabeledContent(text("metadata.\(suffix)", fallback)) {
            Text(verbatim: value).textSelection(.enabled)
        }
    }

    private func characterCount(_ value: String, maximum: Int) -> some View {
        let count = value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        let format = text("count", "%lld / %lld Unicode code points")
        return Text(String(format: format, locale: AppLanguage.current.locale, Int64(count), Int64(maximum)))
            .font(.caption)
            .foregroundStyle(count > maximum ? Color.red : Color.secondary)
    }

    private func failureSection(_ failure: FeedbackFailure) -> some View {
        Section(text("failure.title", "Delivery not confirmed")) {
            Text(failureText(failure))
                .foregroundStyle(.red)
            if case let .rateLimited(seconds?) = failure {
                Text(AppLanguage.localizedCount(
                    "feedback.failure.retryAfter", count: seconds,
                    defaultValue: "Wait at least %lld seconds before retrying.", language: .current
                ))
                .font(.footnote)
            }
        }
    }

    private func failureText(_ failure: FeedbackFailure) -> String {
        let fallback: String
        switch failure {
        case .configuration:
            fallback = "The feedback endpoint is not configured securely. Your draft has not been sent."
        case .invalidInput:
            fallback = "Enter a title (1–120 Unicode code points) and message (1–8000). App metadata must also be valid."
        case .invalidDiagnostics:
            fallback = "The prepared report is not a valid UTF-8 JSON object or exceeds 512 KiB. Keep the original report locally, or send without attaching it."
        case .requestTooLarge:
            fallback = "This submission is too large. Edit the message or remove the report before trying again."
        case .transport:
            fallback = "Delivery could not be confirmed. Your draft is kept. Retry sends the same submission so a saved report is not duplicated."
        case .cancelled:
            fallback = "Sending was cancelled. The server may already have saved the submission. Your draft and report are kept; retry uses the same submission."
        case .invalidResponse:
            fallback = "The server did not return a valid saved receipt. Your draft and report are kept. Retry uses the same submission."
        case .conflict:
            fallback = "This submission ID conflicts with saved content. Edit and review the draft to create a new submission."
        case .rateLimited:
            fallback = "Too many submissions. Please wait before retrying; your draft is kept."
        case .unavailable:
            fallback = "The private inbox is temporarily unavailable or full. Your draft is kept. Try again later."
        case .rejected:
            fallback = "The server rejected this submission. Your draft and report are kept. Review the content before trying again."
        }
        return AppLanguage.localized(failure.localizationKey, defaultValue: fallback, language: .current)
    }

    private func text(_ suffix: String, _ fallback: String) -> String {
        AppLanguage.localized("feedback.\(suffix)", defaultValue: fallback, language: .current)
    }

    private func send() {
        guard !composer.isSending, composer.receipt == nil else { return }
        let includesDiagnostics = composer.submission?.includesDiagnostics == true
        sendTask = Task { @MainActor in
            if let receipt = await composer.send(), !Task.isCancelled {
                onDelivered(receipt, includesDiagnostics)
            }
        }
    }
}
