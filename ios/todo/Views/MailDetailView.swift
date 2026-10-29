import SwiftUI
import SwiftData
import WebKit


/// Stable presentation identity for a mailbox detail sheet.
///
/// A refresh may collapse duplicate SwiftData rows. Holding an `EmailMessage`
/// in `@State` would retain the deleted duplicate until SwiftUI tears down the
/// sheet, so the sheet instead resolves this key against live query results.
struct MailDetailSelection: Identifiable, Hashable {
    let key: EmailMessageKey

    init(_ email: EmailMessage) {
        key = EmailMessageKey(email)
    }

    var id: String {
        [key.providerRawValue, key.sourceAccountNamespace, key.providerMessageID]
            .joined(separator: "\u{0}")
    }

    static func resolve(
        _ candidates: [EmailMessage],
        matching key: EmailMessageKey
    ) -> EmailMessage? {
        candidates.first { EmailMessageKey($0) == key }
    }

    /// 병합·삭제 후에도 같은 메일을 다시 찾는 라이브 쿼리. 상세·등록 시트가 공유한다.
    var liveQuery: Query<EmailMessage, [EmailMessage]> {
        let providerRawValue = key.providerRawValue
        let sourceAccountNamespace = key.sourceAccountNamespace
        let providerMessageID = key.providerMessageID
        return Query(
            filter: #Predicate<EmailMessage> { email in
                email.providerRawValue == providerRawValue
                    && email.sourceAccountNamespace == sourceAccountNamespace
                    && (email.rawMessageID == providerMessageID || email.id == providerMessageID)
            },
            sort: [SortDescriptor(\EmailMessage.receivedAt, order: .reverse)]
        )
    }
}

struct MailDetailSelectionView: View {
    let selection: MailDetailSelection
    @Environment(\.dismiss) private var dismiss
    @Query private var candidates: [EmailMessage]

    init(selection: MailDetailSelection) {
        self.selection = selection
        _candidates = selection.liveQuery
    }

    var body: some View {
        if let email = MailDetailSelection.resolve(candidates, matching: selection.key) {
            MailDetailView(email: email)
                .id(email.persistentModelID)
        } else {
            Color.clear
                .task(id: selection.id) {
                    dismiss()
                }
        }
    }
}

// MARK: - MailDetailView

struct MailDetailView: View {
    let email: EmailMessage
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @ObservedObject private var openAIConnection = OpenAIConnection.shared
    @AppStorage(SettingsStore.betaOpenAIEnabledKey) private var openAIEnabled = false
    @State private var webViewHeight: CGFloat = 300
    @State private var showRegisterSheet = false
    @State private var isLoadingBody = false
    @State private var isSyncingRead = false
    @State private var isTrashing = false
    @State private var isReanalyzing = false
    @State private var alert: MailDetailAlert?
    @State private var showOpenAIAnalysis = false
    @State private var openAITier: OpenAIAnalysisTier = .basic
    @State private var showAnalysisChoices = false

    private var offersOpenAIAnalysis: Bool {
        openAIEnabled && regionalAvailability.isAvailable && openAIConnection.activeProfile != nil
    }

    private var analysisCardTitle: String {
        if email.analysisVersion != EmailAnalysisContract.summaryContractVersion {
            return AppLanguage.localized(
                "mail.summaryHeader",
                defaultValue: AppLanguage.current == .english ? "Email Summary" : "메일 요약",
                language: .current,
                comment: "Neutral title for an older cached email summary."
            )
        }
        guard email.analysisFailureReasonRaw != nil else {
            return AppLanguage.localized(
                "mail.analysis.afmTitle",
                defaultValue: "Apple Intelligence 요약",
                language: .current,
                comment: "Email detail heading for an Apple Intelligence-generated summary."
            )
        }
        return AppLanguage.localized(
            "mail.analysis.ruleBasedTitle",
            defaultValue: AppLanguage.current == .english ? "Rule-based summary" : "규칙 기반 요약",
            language: .current,
            comment: "Email detail title when a provider did not produce the summary."
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                        Text(email.subject.isEmpty ? AppLanguage.localized("todo.noTitle", defaultValue: "(No Title)", language: .current) : email.subject)
                            .font(.title2)
                            .fontWeight(.semibold)

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                            Text(email.from)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(
                                email.receivedAt.formatted(
                                    .dateTime.month(.abbreviated).day().hour().minute()
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(AppTheme.Spacing.section)
                    if let candidate = email.analysisTodoCandidate {
                        Label(
                            AppLanguage.localized(
                                candidate ? "mail.analysis.layaCandidate" : "mail.analysis.layaNotCandidate",
                                defaultValue: candidate
                                    ? "할 일 후보 · Laya"
                                    : "Laya: 할 일 후보 아님 · 직접 저장 가능",
                                language: .current,
                                comment: "Laya email-to-do suggestion; user may override."
                            ),
                            systemImage: candidate ? "checkmark.circle" : "info.circle"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(candidate ? AppTheme.success : Color.secondary)
                        .padding(.horizontal, AppTheme.Spacing.section)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("mail.detail.layaDecision")
                    }

                    Divider()

                    if email.analysisState == .analyzed,
                       !email.analysisSummary.isEmpty {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                            HStack {
                                Label(analysisCardTitle, systemImage: "sparkles")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                reanalyzeButton
                            }
                            Text(email.analysisSummary)
                                .font(.body)
                            if let rawReason = email.analysisFailureReasonRaw,
                               let reason = RuleFallbackReason(rawValue: rawReason) {
                                let language = AppLanguage.current
                                let label = AppLanguage.localized(
                                    "mail.analysis.ruleBased",
                                    defaultValue: language == .english ? "Rule-based · %@" : "규칙 기반 · %@",
                                    language: language,
                                    comment: "Email analysis rules fallback label."
                                )
                                Text(String(format: label, locale: language.locale, reason.localizedDescription(language: language)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !email.analysisKeyPoints.isEmpty {
                                ForEach(email.analysisKeyPoints, id: \.self) { point in
                                    Label(point, systemImage: "circle.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !email.analysisActionItems.isEmpty {
                                Divider()
                                Text("확인/처리 필요")
                                    .font(.subheadline.weight(.semibold))
                                ForEach(email.analysisActionItems, id: \.self) { item in
                                    Label(item, systemImage: "square")
                                        .font(.subheadline)
                                }
                            }
                        }
                        .padding(AppTheme.Spacing.section)
                        .background(
                            AppTheme.insetSurface,
                            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        )
                        .padding(.horizontal, AppTheme.Spacing.section)
                        .padding(.top, AppTheme.Spacing.section)
                    } else if email.analysisState == .failed {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                            Label("AI 정리 실패", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                                .foregroundStyle(AppTheme.warning)
                            if !email.analysisError.isEmpty {
                                Text(email.analysisError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            reanalyzeButton
                        }
                        .padding(AppTheme.Spacing.section)
                        .background(
                            AppTheme.insetSurface,
                            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        )
                        .padding(.horizontal, AppTheme.Spacing.section)
                        .padding(.top, AppTheme.Spacing.section)
                    } else if isReanalyzing || email.analysisState == .analyzing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("AI 정리 중...")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(AppTheme.Spacing.section)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            AppTheme.insetSurface,
                            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        )
                        .padding(.horizontal, AppTheme.Spacing.section)
                        .padding(.top, AppTheme.Spacing.section)
                    } else {
                        reanalyzeButton
                            .padding(AppTheme.Spacing.section)
                    }
                    if let html = email.htmlBody, !html.isEmpty {
                        EmailWebView(htmlBody: html, contentHeight: $webViewHeight)
                            .frame(height: webViewHeight)
                    } else {
                        let bodyText = email.body.isEmpty ? email.snippet : email.body
                        if bodyText.isEmpty {
                            if isLoadingBody {
                                HStack(spacing: 8) {
                                    Spacer()
                                    ProgressView().controlSize(.regular)
                                    Text("메일 본문 로딩 중…")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 32)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "envelope.badge")
                                        .font(.largeTitle)
                                        .foregroundStyle(.tertiary)
                                    Text("메일 본문을 불러올 수 없습니다.")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                            }
                        } else {
                            Text(bodyText)
                                .font(.body)
                                .textSelection(.enabled)
                                .padding(AppTheme.Spacing.section)
                        }
                        if isLoadingBody && !bodyText.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("전체 본문 로딩 중…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                    }
                }
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.surface)
            .navigationTitle("메일")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    showRegisterSheet = true
                } label: {
                    Label(MailRegisterSheet.saveActionTitle, systemImage: "checkmark.circle")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
                .tint(AppTheme.accent)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
                .accessibilityIdentifier("mail.detail.saveTodo")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        Task { await trashCurrentEmail() }
                    } label: {
                        Label("휴지통", systemImage: "trash")
                    }
                    .disabled(isTrashing)
                    .accessibilityIdentifier("mail.detail.trash")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .sheet(isPresented: $showRegisterSheet) {
                MailRegisterSheet(email: email)
            }
            .sheet(isPresented: $showOpenAIAnalysis) {
                OpenAIEmailAnalysisView(selection: MailDetailSelection(email), tier: openAITier)
            }
            .confirmationDialog(
                AppLanguage.localized("mail.analysis.chooseMethod", defaultValue: "Summarize again", language: .current),
                isPresented: $showAnalysisChoices,
                titleVisibility: .visible
            ) {
                Button(AppLanguage.localized("mail.analysis.onDeviceRequest", defaultValue: "On-device summary", language: .current)) {
                    Task { await reanalyzeCurrentEmail() }
                }
                .accessibilityIdentifier("mail.detail.reanalyzeLocal")
                if offersOpenAIAnalysis {
                    Button(AppLanguage.localized("mail.openai.basicRequest", defaultValue: "OpenAI basic analysis · gpt-6-luna", language: .current)) {
                        presentOpenAIAnalysis(.basic)
                    }
                    .accessibilityIdentifier("mail.detail.openAIBasic")
                    Button(AppLanguage.localized("mail.openai.advancedRequest", defaultValue: "Re-request important content · gpt-6.1-sol", language: .current)) {
                        presentOpenAIAnalysis(.advanced)
                    }
                    .accessibilityIdentifier("mail.detail.openAIAdvanced")
                }
                Button(AppLanguage.localized("action.cancel", defaultValue: "Cancel", language: .current), role: .cancel) {}
            } message: {
                if offersOpenAIAnalysis {
                    Text(AppLanguage.localized(
                        "mail.openai.explanation",
                        defaultValue: "Optional external analysis needs separate sharing consent. Automatic email analysis stays on device.",
                        language: .current
                    ))
                }
            }
            .onChange(of: offersOpenAIAnalysis) { _, available in
                if !available {
                    showAnalysisChoices = false
                    showOpenAIAnalysis = false
                }
            }
            .task {
                await synchronizeReadLoadContentAndAnalyze()
            }
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .cancel(Text("확인"))
            )
        }
    }

    private var reanalyzeButton: some View {
        Button {
            if offersOpenAIAnalysis {
                showAnalysisChoices = true
            } else {
                Task { await reanalyzeCurrentEmail() }
            }
        } label: {
            if isReanalyzing || email.analysisState == .analyzing {
                ProgressView().controlSize(.mini)
            } else {
                Label("다시 요약", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isReanalyzing || isLoadingBody || email.analysisState == .analyzing)
        .accessibilityIdentifier("mail.detail.reanalyze")
    }

    private func presentOpenAIAnalysis(_ tier: OpenAIAnalysisTier) {
        guard offersOpenAIAnalysis else { return }
        openAITier = tier
        showOpenAIAnalysis = true
    }

    @MainActor
    private func synchronizeReadLoadContentAndAnalyze() async {
        do {
            try MailboxLocalStore.live.markViewedInApp(email, in: modelContext)
        } catch {
            alert = MailDetailAlert(
                title: AppLanguage.localized("mail.alert.statusSaveError", defaultValue: "메일 상태 저장 오류", language: .current),
                message: error.localizedDescription
            )
        }
        let key = EmailMessageKey(email)
        let provider = MailboxProviderRegistry.provider(for: email.provider)
        if !email.isRead {
            let messageID = email.providerMessageID
            let expectedGlobalMessageID = mutationIdentity(for: email)
            isSyncingRead = true
            defer { isSyncingRead = false }
            do {
                try await MailboxLocalStore.live.markAsRead(
                    email,
                    in: modelContext,
                    remote: {
                        try await provider.markAsRead(
                            messageID: messageID,
                            expectedGlobalMessageID: expectedGlobalMessageID
                        )
                    }
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                alert = mailDetailAlert(action: .markAsRead, error: error)
            }
        }

        guard !Task.isCancelled, let currentEmail = resolvedEmail(matching: key) else {
            return
        }
        guard currentEmail.body.isEmpty, (currentEmail.htmlBody ?? "").isEmpty else {
            try? await EmailMessageAnalysisService.shared.analyze(
                currentEmail,
                context: modelContext
            )
            return
        }

        let messageID = currentEmail.providerMessageID
        isLoadingBody = true
        defer { isLoadingBody = false }
        do {
            let content = try await provider.fetchMessageContent(messageID: messageID)
            guard !Task.isCancelled, let currentEmail = resolvedEmail(matching: key) else {
                return
            }
            try MailboxLocalStore.live.updateContent(
                content,
                for: currentEmail,
                in: modelContext
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if alert == nil {
                alert = MailDetailAlert(
                    title: AppLanguage.localized(
                        "mail.alert.bodyLoadError",
                        defaultValue: "메일 본문 로드 오류",
                        language: .current,
                        comment: "Mail body load alert title."
                    ),
                    message: mailErrorMessage(error)
                )
            }
            return
        }

        guard !Task.isCancelled, let currentEmail = resolvedEmail(matching: key) else {
            return
        }
        try? await EmailMessageAnalysisService.shared.analyze(
            currentEmail,
            context: modelContext
        )
    }

    @MainActor
    private func reanalyzeCurrentEmail() async {
        guard !isReanalyzing, !isLoadingBody else { return }
        let key = EmailMessageKey(email)
        guard let currentEmail = resolvedEmail(matching: key) else { return }

        isReanalyzing = true
        defer { isReanalyzing = false }

        if currentEmail.body.isEmpty && currentEmail.htmlBody == nil {
            let provider = MailboxProviderRegistry.provider(for: currentEmail.provider)
            let messageID = currentEmail.providerMessageID
            isLoadingBody = true
            defer { isLoadingBody = false }
            do {
                let content = try await provider.fetchMessageContent(messageID: messageID)
                guard !Task.isCancelled, let currentEmail = resolvedEmail(matching: key) else {
                    return
                }
                try MailboxLocalStore.live.updateContent(
                    content,
                    for: currentEmail,
                    in: modelContext
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                alert = MailDetailAlert(
                    title: AppLanguage.localized(
                        "mail.alert.bodyLoadError",
                        defaultValue: "메일 본문 로드 오류",
                        language: .current,
                        comment: "Mail body load alert title."
                    ),
                    message: mailErrorMessage(error)
                )
                return
            }
        }

        guard !Task.isCancelled, let currentEmail = resolvedEmail(matching: key) else {
            return
        }
        EmailAnalysisContract.resetAnalysis(currentEmail)
        do {
            try modelContext.save()
        } catch {
            alert = MailDetailAlert(
                title: AppLanguage.localized("mail.alert.analysisError", defaultValue: "AI 정리 오류", language: .current, comment: "Mail analysis failure title."),
                message: error.localizedDescription
            )
            return
        }

        guard !Task.isCancelled, let currentEmail = resolvedEmail(matching: key) else {
            return
        }
        try? await EmailMessageAnalysisService.shared.analyze(
            currentEmail,
            context: modelContext
        )
    }

    private func resolvedEmail(matching key: EmailMessageKey) -> EmailMessage? {
        let providerRawValue = key.providerRawValue
        let sourceAccountNamespace = key.sourceAccountNamespace
        let descriptor = FetchDescriptor<EmailMessage>(
            predicate: #Predicate<EmailMessage> { email in
                email.providerRawValue == providerRawValue
                    && email.sourceAccountNamespace == sourceAccountNamespace
            },
            sortBy: [SortDescriptor(\EmailMessage.receivedAt, order: .reverse)]
        )
        guard let candidates = try? modelContext.fetch(descriptor) else {
            return nil
        }
        return MailDetailSelection.resolve(candidates, matching: key)
    }

    private func mutationIdentity(for email: EmailMessage) -> String? {
        switch email.provider {
        case .gmail:
            return GmailIMAPService.globalMessageID(from: email.id)
        case .outlook:
            return email.providerGlobalMessageID.isEmpty
                ? nil
                : email.providerGlobalMessageID
        }
    }

    @MainActor
    private func trashCurrentEmail() async {
        guard !isTrashing else { return }
        guard let currentEmail = resolvedEmail(matching: EmailMessageKey(email)) else {
            dismiss()
            return
        }

        isTrashing = true
        defer { isTrashing = false }

        do {
            let mutations = try MailboxLocalStore.live.stageTrash(
                [currentEmail],
                in: modelContext
            )
            let provider = MailboxProviderRegistry.provider(for: currentEmail.provider)
            dismiss()
            Task { @MainActor in
                _ = await MailboxLocalStore.live.flushStagedTrash(
                    mutations,
                    now: .distantFuture
                ) { mutation in
                    try await provider.trashMessage(
                        messageID: mutation.providerMessageID,
                        expectedGlobalMessageID: mutation.expectedGlobalMessageID
                    )
                }
            }
        } catch {
            alert = mailDetailAlert(action: .trash, error: error)
        }
    }
}

// MARK: - EmailWebView

/// WKWebView 래퍼: HTML 이메일 렌더링 + 보안 세니타이징.
/// - JavaScript 비활성화 (XSS / 추적 스크립트 차단)
/// - 외부 링크 → Safari 오픈
/// - KVO로 콘텐츠 높이 측정 → SwiftUI ScrollView와 협조
struct EmailWebView: UIViewRepresentable {
    let htmlBody: String
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .systemBackground
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        webView.scrollView.addObserver(
            context.coordinator,
            forKeyPath: "contentSize",
            options: .new,
            context: nil
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = sanitizedHTML
        guard context.coordinator.lastLoadedHTML != html else { return }
        context.coordinator.lastLoadedHTML = html
        context.coordinator.prepareForDocumentLoad()
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.scrollView.removeObserver(coordinator, forKeyPath: "contentSize")
    }

    private var sanitizedHTML: String {
        EmailHTMLSanitizer.sanitize(htmlBody)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EmailWebView
        init(_ parent: EmailWebView) { self.parent = parent }

        // KVO: contentSize 변경 시 SwiftUI 프레임 갱신
        override func observeValue(
            forKeyPath keyPath: String?, of object: Any?,
            change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?
        ) {
            guard keyPath == "contentSize",
                  let scrollView = object as? UIScrollView,
                  scrollView.contentSize.height > 0 else { return }
            let h = scrollView.contentSize.height
            DispatchQueue.main.async { self.parent.contentHeight = h }
        }

        var lastLoadedHTML: String?
        private var mainFrameNavigationGate = EmailHTMLMainFrameNavigationGate()

        func prepareForDocumentLoad() {
            mainFrameNavigationGate.reset()
        }

        // Only user-activated web/mail/phone links may leave the isolated document.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            preferences.allowsContentJavaScript = false
            if action.navigationType == .linkActivated,
               let url = action.request.url {
                if EmailHTMLSanitizer.isAllowedExternalLinkURL(url) {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel, preferences)
                return
            }

            if action.targetFrame?.isMainFrame == true {
                decisionHandler(
                    mainFrameNavigationGate.allows(action.request.url) ? .allow : .cancel,
                    preferences
                )
                return
            }

            if let url = action.request.url,
               !EmailHTMLSanitizer.isAllowedEmbeddedResourceURL(url) {
                decisionHandler(.cancel, preferences)
                return
            }

            decisionHandler(.allow, preferences)
        }
    }
}

// MARK: - EmailHTMLMainFrameNavigationGate

/// Ensures the email document never navigates away after its initial local load.
struct EmailHTMLMainFrameNavigationGate {
    private var hasAdmittedInitialDocument = false

    mutating func reset() {
        hasAdmittedInitialDocument = false
    }

    mutating func allows(_ url: URL?) -> Bool {
        guard !hasAdmittedInitialDocument, url?.scheme?.lowercased() == "about" else {
            return false
        }
        hasAdmittedInitialDocument = true
        return true
    }
}

// MARK: - EmailHTMLSanitizer


/// HTML 이메일 보안 세니타이징 및 임베디드 리소스 허용 여부 판별 헬퍼.
enum EmailHTMLSanitizer {
    /// HTML 본문을 세니타이징하고 보안 CSP / Viewport / CSS 스타일을 주입한다.
    static func sanitize(_ htmlBody: String) -> String {
        var html = htmlBody

        // <script> 태그 및 내용 제거
        if let re = try? NSRegularExpression(pattern: "(?i)<script[\\s\\S]*?</script>|<script[^>]*/>", options: []) {
            let range = NSRange(html.startIndex..., in: html)
            html = re.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }

        // <base> 태그 제거
        if let re = try? NSRegularExpression(pattern: "(?i)<base\\b[^>]*>(?:</base>)?", options: []) {
            let range = NSRange(html.startIndex..., in: html)
            html = re.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }

        // on* 이벤트 핸들러 제거 (quoted & unquoted: onclick=, onerror=, onload= 등)
        if let re = try? NSRegularExpression(pattern: "(?i)\\s+on\\w+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>/]+)", options: []) {
            let range = NSRange(html.startIndex..., in: html)
            html = re.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }

        let viewport = #"<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">"#
        let contentSecurityPolicy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid: blob: https:; style-src 'unsafe-inline' https:; font-src data: https:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';">"#
        let css = """
        <meta name="color-scheme" content="light dark">
        <style>
        :root{color-scheme:light dark;}
        body{font-family:-apple-system,Helvetica,sans-serif;font-size:17px;
             font:-apple-system-body;line-height:1.5;
             color:CanvasText;max-width:100%;word-wrap:break-word;
             padding:24px;margin:0;background:Canvas;}
        img{max-width:100%!important;height:auto!important;}
        table{max-width:100%!important;}
        a{color:LinkText;}
        *{box-sizing:border-box;}
        </style>
        """
        let injectedHead = "\(viewport)\(contentSecurityPolicy)\(css)"

        // The policy must precede all untrusted markup, even with a missing or
        // malformed <head>. Appending to a sender's head applies the CSP too late.
        return """
        <!DOCTYPE html>
        <html><head>\(injectedHead)</head>
        <body>\(html)</body></html>
        """
    }


    /// 내장 리소스 요청에 허용되는 URL 스킴인지 확인한다. (HTTPS visual resources 포함, HTTP 차단)
    static func isAllowedEmbeddedResourceURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return ["about", "data", "blob", "cid", "https"].contains(scheme)
    }

    static func isAllowedExternalLinkURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return !(url.host ?? "").isEmpty
        case "mailto", "tel":
            return !url.path.isEmpty
        default:
            return false
        }
    }
}
