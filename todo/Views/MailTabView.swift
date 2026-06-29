import SwiftUI
import SwiftData
import WebKit
import EventKit
import MSAL

// MARK: - MailTabView

struct MailTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTutorialState) private var tutorial
    @Query(sort: \EmailMessage.receivedAt, order: .reverse)
    private var emails: [EmailMessage]

    @State private var isRefreshing = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var alertTitle = "메일 연결 오류"
    @State private var selectedEmail: EmailMessage?
    @State private var isGmailAuthenticated = false
    @State private var isOutlookAuthenticated = false
    @State private var isAnalyzing = false
    @State private var autoRegisteringEmailID: String?

    private var isAnyMailAuthenticated: Bool {
        isGmailAuthenticated || isOutlookAuthenticated
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isAnyMailAuthenticated {
                    notConnectedView
                } else if emails.isEmpty && !isRefreshing {
                    emptyView
                } else {
                    mailList
                }
            }
            .navigationTitle("메일")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isRefreshing || isAnalyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await fullSync() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(!isAnyMailAuthenticated)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if isAnyMailAuthenticated && (isRefreshing || isAnalyzing) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(isAnalyzing ? "메일 분석 및 태스크 등록 중..." : "메일을 불러오는 중...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                        Divider()
                    }
                }
            }
            .refreshable {
                await syncEmails()
            }
            .sheet(item: $selectedEmail) { email in
                MailDetailView(email: email)
                    .modelContainer(modelContext.container)
            }
            .alert(alertTitle, isPresented: $showError) {
                Button("확인") {}
            } message: {
                if let msg = errorMessage { Text(msg) }
            }
            .task {
                await refreshAuthenticationState()
                if emails.isEmpty && isAnyMailAuthenticated {
                    await syncEmails()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gmailAuthChanged)) { note in
            isGmailAuthenticated = note.object as? Bool ?? EmailService.shared.isAuthenticated
            if isGmailAuthenticated {
                Task { await syncEmails() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .outlookAuthChanged)) { note in
            guard OutlookMailService.shared.isConfigured else {
                isOutlookAuthenticated = false
                return
            }
            if note.object as? Bool == false {
                isOutlookAuthenticated = false
                return
            }
            Task {
                isOutlookAuthenticated = await OutlookMailService.shared.canAccessMailSilently()
                if isOutlookAuthenticated {
                    await syncEmails()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .mailTab) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .onAppear {
            tutorial?.handleMailTabAppeared()
        }
    }

    // MARK: - Placeholder Views

    private var notConnectedView: some View {
        ContentUnavailableView {
            Label("메일 계정 미연결", systemImage: "envelope.badge.shield.half.filled")
        } description: {
            Text("Gmail 계정을 연결하면\n최근 메일을 이 앱에서 바로 읽고 할 일로 등록할 수 있습니다.\n베타/개발 중에는 Google이 “확인하지 않은 앱” 경고를 표시할 수 있습니다. 테스트 사용자로 등록된 계정은 고급/Advanced를 눌러 계속 진행할 수 있고, 일반 사용자 경고 제거는 Google OAuth 검증 완료 후 가능합니다.")
        } actions: {
            VStack(spacing: 12) {
                Button {
                    Task { await connectGmail() }
                } label: {
                    if isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Gmail 연결", systemImage: "plus.circle.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("메일 없음", systemImage: "envelope.open")
        } description: {
            Text("당겨서 새로고침하면 최근 메일을 불러옵니다.")
        }
    }

    // MARK: - Mail List

    private var mailList: some View {
        List {
            ForEach(emails, id: \.localListID) { email in
                Button {
                    selectedEmail = email
                } label: {
                    MailMessageRow(email: email)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if autoRegisteringEmailID == email.localListID {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            Task { await autoRegisterTodo(from: email) }
                        } label: {
                            Label("할일 등록", systemImage: "checkmark.circle.fill")
                        }
                        .tint(.green)
                    }
                }
            }
            .onDelete(perform: deleteEmails)
        }
        .listStyle(.plain)
    }

    private func connectGmail() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await EmailService.shared.authenticate()
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1 {
                alertTitle = "알림"
                errorMessage = "로그인이 취소되었습니다."
            } else {
                alertTitle = "Gmail 연결 오류"
                errorMessage = error.localizedDescription
            }
            showError = true
        }
    }

    private func connectOutlook() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await OutlookMailService.shared.authenticate()
        } catch OutlookMailError.missingClientID {
            alertTitle = "Outlook 연결 오류"
            errorMessage = OutlookMailError.missingClientID.localizedDescription
            showError = true
        } catch {
            let nsError = error as NSError
            if nsError.domain == MSALErrorDomain && nsError.code == MSALError.userCanceled.rawValue {
                alertTitle = "알림"
                errorMessage = "로그인이 취소되었습니다."
            } else {
                alertTitle = "Outlook 연결 오류"
                errorMessage = error.localizedDescription
            }
            showError = true
        }
    }

    @MainActor
    private func syncEmails() async {
        guard !isRefreshing else { return }
        await refreshAuthenticationState()
        guard isAnyMailAuthenticated else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let appContext = ModelContext(AppDataContainer.shared.container)
        var failures: [String] = []

        if isGmailAuthenticated {
            do {
                _ = try await EmailService.shared.syncRecentMessageCache(
                    emailContext: modelContext,
                    todoContext: appContext
                )
            } catch EmailError.notAuthenticated {
                isGmailAuthenticated = false
            } catch {
                failures.append("Gmail: \(error.localizedDescription)")
            }
        }

        if isOutlookAuthenticated {
            do {
                _ = try await OutlookMailService.shared.syncRecentMessageCache(
                    emailContext: modelContext,
                    todoContext: appContext
                )
            } catch OutlookMailError.notAuthenticated {
                isOutlookAuthenticated = false
            } catch {
                failures.append("Outlook: \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            alertTitle = "메일 동기화 오류"
            errorMessage = failures.joined(separator: "\n")
            showError = true
        }
    }

    @MainActor
    private func fullSync() async {
        await syncEmails()
        guard !isAnalyzing else { return }
        guard isAnyMailAuthenticated else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let appContext = ModelContext(AppDataContainer.shared.container)
        var failures: [String] = []
        var didChange = false

        if isGmailAuthenticated {
            do {
                _ = try await EmailService.shared.fetchAndStoreExtractedItems(context: appContext)
                didChange = true
            } catch EmailError.notAuthenticated {
                isGmailAuthenticated = false
            } catch {
                failures.append("Gmail: \(error.localizedDescription)")
            }
        }

        if isOutlookAuthenticated {
            do {
                _ = try await OutlookMailService.shared.fetchAndStoreExtractedItems(context: appContext)
                didChange = true
            } catch OutlookMailError.notAuthenticated {
                isOutlookAuthenticated = false
            } catch {
                failures.append("Outlook: \(error.localizedDescription)")
            }
        }

        if didChange {
            try? appContext.save()
        }

        if !failures.isEmpty {
            alertTitle = "메일 분석 오류"
            errorMessage = failures.joined(separator: "\n")
            showError = true
        }
    }

    @MainActor
    private func autoRegisterTodo(from email: EmailMessage) async {
        guard autoRegisteringEmailID == nil else { return }
        autoRegisteringEmailID = email.localListID
        defer { autoRegisteringEmailID = nil }

        let appContext = ModelContext(AppDataContainer.shared.container)
        let targetSourceRef = email.todoSourceRef
        let existingPredicate = #Predicate { (todo: Todo) in
            todo.sourceRef == targetSourceRef
        }
        let existing = (try? appContext.fetch(FetchDescriptor<Todo>(predicate: existingPredicate))) ?? []
        guard existing.isEmpty else {
            alertTitle = "이미 등록됨"
            errorMessage = "이 메일은 이미 할 일로 등록되어 있습니다."
            showError = true
            return
        }

        var syntheticThreadID = email.threadID
        var syntheticMessageID = ""
        if email.body.isEmpty && email.htmlBody == nil {
            if let full = try? await fetchFullMessage(for: email) {
                email.body = full.body
                if !full.threadID.isEmpty { email.threadID = full.threadID }
                if !full.threadID.isEmpty { syntheticThreadID = full.threadID }
                if !full.messageID.isEmpty { syntheticMessageID = full.messageID }
                if let html = full.htmlBody { email.htmlBody = html }
                try? modelContext.save()
            }
        }

        let synthetic = GmailMessage(
            id: email.todoSourceRef,
            threadID: syntheticThreadID,
            messageID: syntheticMessageID,
            subject: email.subject,
            from: email.from,
            snippet: email.snippet,
            body: email.body,
            htmlBody: email.htmlBody,
            receivedAt: email.receivedAt,
            labelIds: [],
            isBulk: false
        )

        let todo = await EmailService.shared.makeManualTodo(from: synthetic)

        do {
            appContext.insert(todo)
            try appContext.save()
            _ = CalendarService.shared.applyAutoRegistration(for: todo)
            try appContext.save()
            EmailLearningStore.shared.recordAnalyzed(messageIDs: [email.todoSourceRef])
            alertTitle = "할 일 등록됨"
            errorMessage = "메일 요약을 바탕으로 할 일을 등록했습니다."
            showError = true
        } catch {
            alertTitle = "할 일 등록 실패"
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteEmails(at offsets: IndexSet) {
        let targets = offsets.compactMap { emails.indices.contains($0) ? emails[$0] : nil }
        Task { await trashEmails(targets) }
    }

    @MainActor
    private func trashEmails(_ targets: [EmailMessage]) async {
        for email in targets {
            do {
                try await trashRemote(email)
                modelContext.delete(email)
                try modelContext.save()
            } catch {
                alertTitle = "메일 삭제 오류"
                errorMessage = error.localizedDescription
                showError = true
                return
            }
        }
    }

    private func refreshAuthenticationState() async {
        isGmailAuthenticated = EmailService.shared.isAuthenticated
        isOutlookAuthenticated = await OutlookMailService.shared.canAccessMailSilently()
    }

    private func fetchFullMessage(for email: EmailMessage) async throws -> GmailMessage {
        try await providerFetchFullMessage(for: email)
    }

    private func trashRemote(_ email: EmailMessage) async throws {
        try await providerTrashRemote(email)
    }
}

private func providerFetchFullMessage(for email: EmailMessage) async throws -> GmailMessage {
    switch email.provider {
    case .gmail:
        guard let message = try await EmailService.shared.fetchFullMessage(id: email.providerMessageID) else {
            throw EmailError.apiFailed
        }
        return message
    case .outlook:
        return try await OutlookMailService.shared.fetchFullMessage(id: email.providerMessageID)
    }
}

private func providerMarkAsRead(_ email: EmailMessage) async throws {
    switch email.provider {
    case .gmail:
        try await EmailService.shared.markAsRead(messageID: email.providerMessageID)
    case .outlook:
        try await OutlookMailService.shared.markAsRead(messageID: email.providerMessageID)
    }
}

private func providerTrashRemote(_ email: EmailMessage) async throws {
    switch email.provider {
    case .gmail:
        try await EmailService.shared.trashMessage(messageID: email.providerMessageID)
    case .outlook:
        try await OutlookMailService.shared.trashMessage(messageID: email.providerMessageID)
    }
}

// MARK: - MailMessageRow

struct MailMessageRow: View {
    let email: EmailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(senderName)
                    .font(.subheadline)
                    .fontWeight(email.isRead ? .regular : .semibold)
                    .lineLimit(1)
                Text(email.provider == .gmail ? "Gmail" : "Outlook")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Text(email.receivedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(email.subject.isEmpty ? "(제목 없음)" : email.subject)
                .font(.body)
                .fontWeight(email.isRead ? .regular : .medium)
                .lineLimit(1)
            Text(email.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .foregroundStyle(email.isRead ? .secondary : .primary)
    }

    private var senderName: String {
        let from = email.from
        if let nameEnd = from.firstIndex(of: "<") {
            return String(from[from.startIndex..<nameEnd])
                .trimmingCharacters(in: .whitespaces)
        }
        return from.isEmpty ? "(발신자 없음)" : from
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
    @State private var isTrashing = false
    @State private var errorMessage: String?
    @State private var showError = false

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
                            Text(email.receivedAt.formatted(
                                .dateTime.month(.abbreviated).day().hour().minute()
                            ))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding()

                    Divider()

                    if let html = email.htmlBody, !html.isEmpty {
                        EmailWebView(htmlBody: html, contentHeight: $webViewHeight)
                            .frame(height: webViewHeight)
                    } else {
                        let bodyText = email.body.isEmpty ? email.snippet : email.body
                        if bodyText.isEmpty {
                            HStack { Spacer(); ProgressView(); Spacer() }.padding()
                        } else {
                            Text(bodyText)
                                .font(.body)
                                .textSelection(.enabled)
                                .padding()
                        }
                        if isLoadingBody {
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
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .sheet(isPresented: $showRegisterSheet) {
                MailRegisterSheet(email: email)
            }
            .onAppear {
                if !email.isRead {
                    email.isRead = true
                    try? modelContext.save()
                    Task { try? await providerMarkAsRead(email) }
                }
            }
            .task {
                guard email.body.isEmpty && email.htmlBody == nil && !isLoadingBody else { return }
                isLoadingBody = true
                defer { isLoadingBody = false }
                if let full = try? await providerFetchFullMessage(for: email) {
                    email.body = full.body
                    if let html = full.htmlBody { email.htmlBody = html }
                    try? modelContext.save()
                }
            }
        }
        .alert("메일 삭제 오류", isPresented: $showError) {
            Button("확인", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @MainActor
    private func trashCurrentEmail() async {
        guard !isTrashing else { return }
        isTrashing = true
        defer { isTrashing = false }

        do {
            try await providerTrashRemote(email)
            modelContext.delete(email)
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
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
        webView.loadHTMLString(sanitizedHTML, baseURL: nil)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
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

        if html.range(of: "<head", options: .caseInsensitive) != nil {
            // 기존 <head> 안에 삽입
            html = html.replacingOccurrences(
                of: "</head>", with: "\(viewport)\(css)</head>",
                options: .caseInsensitive
            )
        } else {
            html = """
            <!DOCTYPE html>
            <html><head>\(viewport)\(css)</head>
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

        // 외부 링크 → Safari, 나머지는 허용 (이미지·CSS 로드 포함)
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
            } else {
                decisionHandler(.allow, preferences)
            }
        }
    }
}

// MARK: - MailRegisterSheet

/// 메일에서 할일 + 캘린더 일정을 동시 등록하는 프리필 확인 시트.
///
/// ⚠️ 프라이버시 보장:
/// - Gmail 본문은 온디바이스에서만 분석.
/// - Todo는 AppDataContainer.shared.container(main)에 저장, 절대 CloudKit emailContainer에 넣지 않음.
/// - 자동 추출은 `EmailService.makeManualTodo(from:)` 기반으로 동일한 메타데이터 경로 사용.
struct MailRegisterSheet: View {
    let email: EmailMessage

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var dueDate: Date = Date()
    @State private var isAllDay: Bool = false
    @State private var notes: String = ""
    @State private var calendarID: String = ""
    @State private var sourceRef: String = ""
    @State private var sourceMessageID: String = ""
    @State private var sourceThreadID: String = ""
    @State private var sourceSender: String = ""
    @State private var sourceSenderEmail: String = ""
    @State private var calendarSources: [CalendarService.CalendarSourceGroup] = []
    @State private var isAnalyzing = true
    @State private var errorMessage: String?

    private let cal = Calendar.current

    var body: some View {
        NavigationStack {
            Form {
                if isAnalyzing {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("메일 내용 분석 중…")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                }

                Section("제목") {
                    TextField("제목", text: $title)
                }

                Section("완료 기한") {
                    Toggle("종일", isOn: $isAllDay)
                    DatePicker(
                        "날짜",
                        selection: $dueDate,
                        displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                }

                Section("메모") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                        .font(.footnote)
                }

                if !calendarSources.isEmpty {
                    Section("캘린더") {
                        Picker("캘린더 선택", selection: $calendarID) {
                            ForEach(calendarSources) { source in
                                ForEach(source.calendars) { info in
                                    calendarLabel(info).tag(info.id)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                if let err = errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("할일 & 일정 등록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("등록") { register() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isAnalyzing)
                }
            }
        }
        .task {
            await analyzeAndPrefill()
            calendarSources = CalendarService.shared.availableCalendars()
            let defaultID = CalendarService.shared.defaultCalendarID
            calendarID = defaultID.isEmpty
                ? (calendarSources.first?.calendars.first?.id ?? "")
                : defaultID
        }
    }

    @MainActor
    private func analyzeAndPrefill() async {
        var syntheticThreadID = email.threadID
        var syntheticMessageID = ""
        if email.body.isEmpty || email.htmlBody == nil || syntheticMessageID.isEmpty {
            if let full = try? await providerFetchFullMessage(for: email) {
                email.body = full.body
                if let html = full.htmlBody { email.htmlBody = html }
                if !full.messageID.isEmpty {
                    syntheticMessageID = full.messageID
                }
                if !full.threadID.isEmpty {
                    syntheticThreadID = full.threadID
                }
            }
        }

        let synthetic = GmailMessage(
            id: email.todoSourceRef,
            threadID: syntheticThreadID,
            messageID: syntheticMessageID,
            subject: email.subject,
            from: email.from,
            snippet: email.snippet,
            body: email.body,
            htmlBody: email.htmlBody,
            receivedAt: email.receivedAt,
            labelIds: [],
            isBulk: false
        )

        let draftTodo = await EmailService.shared.makeManualTodo(from: synthetic, allowFoundationModels: false)
        let analyzed = EmailContentAnalyzer().analyze(synthetic, now: Date())

        title = draftTodo.title
        notes = draftTodo.notes
        sourceRef = draftTodo.sourceRef
        sourceMessageID = draftTodo.sourceMessageID
        sourceThreadID = draftTodo.sourceThreadID
        sourceSender = draftTodo.sourceSender
        sourceSenderEmail = draftTodo.sourceSenderEmail

        if let parsedDueDate = draftTodo.dueDate {
            dueDate = parsedDueDate
            isAllDay = isManualTodoAllDay(parsedDueDate)
        } else if let extracted = analyzed {
            dueDate = extracted.dueDate
            isAllDay = extracted.isAllDay
        } else {
            dueDate = email.receivedAt.addingTimeInterval(86_400)
            isAllDay = true
        }

        isAnalyzing = false
    }

    private func register() {
        let cleanTitle = title.trimmingCharacters(in: .whitespaces)
        guard !cleanTitle.isEmpty else { return }

        let appContext = ModelContext(AppDataContainer.shared.container)
        let ref = sourceRef.isEmpty ? email.todoSourceRef : sourceRef
        let existingDescriptor = FetchDescriptor<Todo>(
            predicate: #Predicate { $0.sourceRef == ref }
        )
        let existing = (try? appContext.fetch(existingDescriptor)) ?? []

        guard existing.isEmpty else {
            errorMessage = "이미 등록된 메일입니다."
            return
        }

        let eventStart: Date
        let eventEnd: Date
        if isAllDay {
            eventStart = cal.startOfDay(for: dueDate)
            eventEnd   = cal.date(byAdding: .day, value: 1, to: eventStart) ?? eventStart.addingTimeInterval(86_400)
        } else {
            eventStart = dueDate
            eventEnd   = dueDate.addingTimeInterval(3_600)
        }

        do {
            let eventID = try CalendarService.shared.createEventFromEmail(
                title: cleanTitle,
                start: eventStart,
                end: eventEnd,
                isAllDay: isAllDay,
                location: "",
                notes: notes,
                sourceRef: ref,
                calendarID: calendarID.isEmpty ? nil : calendarID
            )

            let todo = Todo(
                title: cleanTitle,
                notes: notes,
                dueDate: dueDate,
                source: .email,
                sourceRef: ref
            )
            todo.sourceSender = sourceSender.isEmpty ? EmailContentAnalyzer().parseSender(from: email.from) : sourceSender
            todo.sourceSenderEmail = sourceSenderEmail.isEmpty ? EmailContentAnalyzer().parseSenderEmail(from: email.from) : sourceSenderEmail
            todo.sourceMessageID = sourceMessageID
            todo.sourceThreadID = sourceThreadID
            if !eventID.isEmpty { todo.calendarEventID = eventID }
            appContext.insert(todo)
            try appContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
    }

    private func isManualTodoAllDay(_ date: Date) -> Bool {
        let components = cal.dateComponents([.hour, .minute, .second], from: date)
        return components.hour == 23 && components.minute == 59 && (components.second ?? 0) == 0
    }

    @ViewBuilder
    private func calendarLabel(_ info: CalendarService.CalendarInfo) -> some View {
        let color: Color = {
            if let ek = CalendarService.shared.ekCalendar(withIdentifier: info.id) {
                return Color(cgColor: ek.cgColor)
            }
            return .accentColor
        }()
        Label {
            Text(info.title)
        } icon: {
            Circle().fill(color).frame(width: 10, height: 10)
        }
    }
}
