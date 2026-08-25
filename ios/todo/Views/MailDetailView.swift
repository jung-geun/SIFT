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
}

struct MailDetailSelectionView: View {
    let selection: MailDetailSelection
    @Environment(\.dismiss) private var dismiss
    @Query private var candidates: [EmailMessage]

    init(selection: MailDetailSelection) {
        self.selection = selection
        let providerRawValue = selection.key.providerRawValue
        let sourceAccountNamespace = selection.key.sourceAccountNamespace
        let providerMessageID = selection.key.providerMessageID
        _candidates = Query(
            filter: #Predicate<EmailMessage> { email in
                email.providerRawValue == providerRawValue
                    && email.sourceAccountNamespace == sourceAccountNamespace
                    && (email.rawMessageID == providerMessageID || email.id == providerMessageID)
            },
            sort: [SortDescriptor(\EmailMessage.receivedAt, order: .reverse)]
        )
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
    @State private var webViewHeight: CGFloat = 300
    @State private var showRegisterSheet = false
    @State private var isLoadingBody = false
    @State private var isSyncingRead = false
    @State private var isTrashing = false
    @State private var isReanalyzing = false
    @State private var alert: MailDetailAlert?

    private var analysisCardTitle: String {
        guard email.analysisFailureReasonRaw != nil else { return "AI 정리" }
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(email.subject.isEmpty ? "(제목 없음)" : email.subject)
                            .font(.title3)
                            .fontWeight(.semibold)

                        HStack(alignment: .top) {
                            Text(email.from)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            Text(
                                email.receivedAt.formatted(
                                    .dateTime.month(.abbreviated).day().hour().minute()
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding()

                    Divider()

                    if email.analysisState == .analyzed,
                       !email.analysisSummary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(analysisCardTitle, systemImage: "sparkles")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AppTheme.accent)
                                Spacer()
                                Button {
                                    Task { await reanalyzeCurrentEmail() }
                                } label: {
                                    if isReanalyzing || email.analysisState == .analyzing {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Label("다시 요약", systemImage: "arrow.triangle.2.circlepath")
                                            .labelStyle(.titleAndIcon)
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isReanalyzing || isLoadingBody || email.analysisState == .analyzing)
                                .accessibilityIdentifier("mail.detail.reanalyze")
                            }
                            Text(email.analysisSummary)
                                .font(.subheadline)
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
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !email.analysisKeyPoints.isEmpty {
                                ForEach(email.analysisKeyPoints, id: \.self) { point in
                                    Label(point, systemImage: "circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !email.analysisActionItems.isEmpty {
                                Divider()
                                Text("확인/처리 필요")
                                    .font(.caption.weight(.semibold))
                                ForEach(email.analysisActionItems, id: \.self) { item in
                                    Label(item, systemImage: "square")
                                        .font(.caption)
                                }
                            }
                        }
                        .padding()
                        .background(
                            AppTheme.accentSubtle,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .padding(.horizontal)
                        .padding(.top, 12)
                    } else if email.analysisState == .failed {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("AI 정리 실패", systemImage: "exclamationmark.triangle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.warning)
                            if !email.analysisError.isEmpty {
                                Text(email.analysisError)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                Task { await reanalyzeCurrentEmail() }
                            } label: {
                                if isReanalyzing {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Label("다시 요약", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isReanalyzing || isLoadingBody)
                            .accessibilityIdentifier("mail.detail.reanalyze")
                        }
                        .padding()
                        .background(
                            AppTheme.warning.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .padding(.horizontal)
                        .padding(.top, 12)
                    } else if isReanalyzing || email.analysisState == .analyzing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("AI 정리 중...")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            AppTheme.accentSubtle,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .padding(.horizontal)
                        .padding(.top, 12)
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
                                .padding()
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
            }
            .navigationTitle("메일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showRegisterSheet = true
                    } label: {
                        Label("일정 등록하기", systemImage: "calendar.badge.plus")
                    }
                }
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

    @MainActor
    private func synchronizeReadLoadContentAndAnalyze() async {
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
                title: "AI 정리 오류",
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
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.scrollView.removeObserver(coordinator, forKeyPath: "contentSize")
    }

    private var sanitizedHTML: String {
        var html = htmlBody

        // <script> 태그 전체 제거
        if let re = try? NSRegularExpression(pattern: "<script[\\s\\S]*?</script>", options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            html = re.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }
        // on* 이벤트 핸들러 제거 (onclick=, onerror= 등)
        if let re = try? NSRegularExpression(pattern: #"\s+on\w+\s*=\s*(?:"[^"]*"|'[^']*')"#, options: .caseInsensitive) {
            let range = NSRange(html.startIndex..., in: html)
            html = re.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        }

        let viewport = #"<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">"#
        let contentSecurityPolicy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: cid: blob:; style-src 'unsafe-inline'; font-src data:; connect-src 'none'; media-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">"#
        let css = """
        <style>
        body{font-family:-apple-system,Helvetica,sans-serif;font-size:15px;
             color:#1c1c1e;max-width:100%;word-wrap:break-word;
             padding:12px;margin:0;background:#fff;}
        img{max-width:100%!important;height:auto!important;}
        table{max-width:100%!important;}
        a{color:#007AFF;}
        *{box-sizing:border-box;}
        </style>
        """
        let injectedHead = "\(viewport)\(contentSecurityPolicy)\(css)"

        if html.range(of: "<head", options: .caseInsensitive) != nil {
            // 기존 <head> 안에 삽입
            html = html.replacingOccurrences(
                of: "</head>", with: "\(injectedHead)</head>",
                options: .caseInsensitive
            )
        } else {
            html = """
            <!DOCTYPE html>
            <html><head>\(injectedHead)</head>
            <body>\(html)</body></html>
            """
        }
        return html
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

        // 외부 링크는 Safari로 열고, 메일 HTML 내부의 원격 리소스 요청은 차단한다.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            preferences.allowsContentJavaScript = false
            if action.navigationType == .linkActivated,
               let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel, preferences)
                return
            }

            if let url = action.request.url,
               !Self.isAllowedEmbeddedResourceURL(url) {
                decisionHandler(.cancel, preferences)
                return
            }

            decisionHandler(.allow, preferences)
        }

        private static func isAllowedEmbeddedResourceURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return true }
            return ["about", "data", "blob", "cid"].contains(scheme)
        }
    }
}
