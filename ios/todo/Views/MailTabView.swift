import SwiftUI
import SwiftData
import UIKit
import WebKit
import EventKit
import MSAL

// MARK: - MailTabView

struct MailAnalysisProgress: Equatable {
    let currentIndex: Int
    let completedCount: Int
    let totalCount: Int

    var fraction: Double {
        totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0
    }

    var statusText: String {
        statusText(language: .current)
    }

    func statusText(language: AppLanguage) -> String {
        let key = completedCount == totalCount ? "mail.analysis.completed" : "mail.analysis.progress"
        let fallback = completedCount == totalCount
            ? "메일 분석 완료 \(totalCount)/\(totalCount)"
            : "메일 분석 \(currentIndex)/\(totalCount)"
        let template = AppLanguage.localized(key, defaultValue: fallback, language: language, comment: "Mail analysis progress.")
        return String(format: template, currentIndex, totalCount)
    }

    var accessibilityValue: String {
        accessibilityValue(language: .current)
    }

    func accessibilityValue(language: AppLanguage) -> String {
        let key = completedCount == totalCount ? "mail.analysis.accessibility.completed" : "mail.analysis.accessibility.progress"
        let fallback = completedCount == totalCount
            ? "총 \(totalCount)개 메일 처리 완료"
            : "총 \(totalCount)개 중 \(currentIndex)번째 메일 분석 중, \(completedCount)개 처리됨"
        if completedCount == totalCount {
            return AppLanguage.localizedCount(
                "mail.analysis.accessibility.completed",
                count: totalCount,
                defaultValue: language == .english
                    ? (totalCount == 1 ? "Completed %lld mail" : "Completed %lld mails")
                    : "총 %lld개 메일 처리 완료",
                language: language,
                comment: "Mail analysis progress accessibility value."
            )
        }
        let template = AppLanguage.localized(
            key,
            defaultValue: fallback,
            language: language,
            comment: "Mail analysis progress accessibility value."
        )
        return String(format: template, totalCount, currentIndex, completedCount)
    }

    static func processing(index: Int, total: Int) -> MailAnalysisProgress {
        MailAnalysisProgress(
            currentIndex: index,
            completedCount: index - 1,
            totalCount: total
        )
    }

    func completingCurrent() -> MailAnalysisProgress {
        MailAnalysisProgress(
            currentIndex: currentIndex,
            completedCount: currentIndex,
            totalCount: totalCount
        )
    }
}

@MainActor
enum MailAnalysisBatch {
    static func run(
        emails: [EmailMessage],
        process: @MainActor (EmailMessage) async -> Void,
        onProgress: @MainActor (MailAnalysisProgress) -> Void
    ) async {
        for (offset, email) in emails.enumerated() {
            let progress = MailAnalysisProgress.processing(index: offset + 1, total: emails.count)
            onProgress(progress)
            await process(email)
            onProgress(progress.completingCurrent())
        }
    }
}

struct MailAnalysisSyncGate: Equatable {
    private(set) var isAnalyzing = false
    private(set) var syncRequested = false

    mutating func beginAnalysis() -> Bool {
        guard !isAnalyzing else { return false }
        isAnalyzing = true
        return true
    }

    mutating func requestSync() -> Bool {
        guard isAnalyzing else { return true }
        syncRequested = true
        return false
    }

    mutating func finishAnalysis() -> Bool {
        let shouldSync = syncRequested
        isAnalyzing = false
        syncRequested = false
        return shouldSync
    }
}

func mailboxAnalysisCandidates(
    from emails: [EmailMessage],
    lookbackDays: Int,
    now: Date = Date()
) -> [EmailMessage] {
    let cutoff = EmailAnalysisLookbackPolicy.cutoff(
        now: now,
        lookbackDays: lookbackDays
    )
    return emails.filter {
        $0.isInInbox
            && $0.receivedAt >= cutoff
            && $0.analysisState != .analyzed
    }
}

struct MailboxViewState: Equatable {
    var selectedProvider: MailProvider?
    var selectedGmailCategory: GmailInboxCategory = .primary
    var selectedOutlookClassification: OutlookInboxClassification = .focused
    var pagingByProvider: [MailProvider: MailboxPagingState] = [:]

    mutating func reconcileAuthenticatedProviders(_ authenticated: Set<MailProvider>) {
        if let selectedProvider, authenticated.contains(selectedProvider) {
            return
        }
        if authenticated.contains(.gmail) {
            selectedProvider = .gmail
        } else if authenticated.contains(.outlook) {
            selectedProvider = .outlook
        } else {
            selectedProvider = nil
        }
    }

    func pagingState(for provider: MailProvider) -> MailboxPagingState {
        pagingByProvider[provider] ?? MailboxPagingState()
    }

    mutating func beginPage(for provider: MailProvider, loadMore: Bool) -> Bool {
        var state = pagingState(for: provider)
        guard !state.isLoadingPage else { return false }
        if loadMore {
            guard state.canLoadMore else { return false }
        }
        state.isLoadingPage = true
        state.pageErrorMessage = nil
        pagingByProvider[provider] = state
        return true
    }

    mutating func completePage(
        for provider: MailProvider,
        nextCursor: String?
    ) {
        var state = pagingState(for: provider)
        state.isLoadingPage = false
        state.hasLoadedInitialPage = true
        state.nextCursor = nextCursor
        state.pageErrorMessage = nil
        pagingByProvider[provider] = state
    }

    mutating func failPage(for provider: MailProvider, message: String) {
        var state = pagingState(for: provider)
        state.isLoadingPage = false
        state.pageErrorMessage = message
        pagingByProvider[provider] = state
    }

    mutating func beginIndex(for provider: MailProvider) -> Bool {
        var state = pagingState(for: provider)
        guard !state.isReconcilingIndex else { return false }
        state.isReconcilingIndex = true
        state.indexWarningMessage = nil
        pagingByProvider[provider] = state
        return true
    }

    mutating func completeIndex(for provider: MailProvider, totalCount: Int) {
        var state = pagingState(for: provider)
        state.isReconcilingIndex = false
        state.totalInboxCount = totalCount
        state.indexWarningMessage = nil
        pagingByProvider[provider] = state
    }

    mutating func failIndex(for provider: MailProvider, message: String) {
        var state = pagingState(for: provider)
        state.isReconcilingIndex = false
        state.indexWarningMessage = message
        pagingByProvider[provider] = state
    }
}

struct MailDetailAlert: Identifiable, Equatable {
    let title: String
    let message: String

    var id: String { "\(title)|\(message)" }
}

func mailDetailAlert(
    action: MailboxMutationAction,
    error: Error,
    language: AppLanguage = .current
) -> MailDetailAlert {
    if error is MailboxMutationError {
        return MailDetailAlert(
            title: AppLanguage.localized("mail.alert.statusSaveError", defaultValue: "메일 상태 저장 오류", language: language, comment: "Mail mutation alert title."),
            message: (error as? MailboxMutationError)?.errorDescription(language: language)
                ?? error.localizedDescription
        )
    }
    return MailDetailAlert(
        title: AppLanguage.localized(
            action == .markAsRead ? "mail.alert.readSyncError" : "mail.alert.deleteError",
            defaultValue: action == .markAsRead ? "읽음 동기화 오류" : "메일 삭제 오류",
            language: language,
            comment: "Mail mutation alert title."
        ),
        message: error.localizedDescription
    )
}

func mailboxProvider(for provider: MailProvider) -> any MailboxPagingProvider {
    switch provider {
    case .gmail:
        EmailService.shared
    case .outlook:
        OutlookMailService.shared
    }
}

struct HorizontalLockedScrollView<Content: View>: UIViewRepresentable {
    let showsIndicators: Bool
    let content: Content

    init(showsIndicators: Bool = false, @ViewBuilder content: () -> Content) {
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = showsIndicators
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let hostedView = context.coordinator.hostingController.view
        hostedView?.backgroundColor = .clear
        hostedView?.translatesAutoresizingMaskIntoConstraints = false

        if let hostedView {
            scrollView.addSubview(hostedView)
            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                hostedView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
            ])
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content
        scrollView.showsHorizontalScrollIndicator = showsIndicators
    }

    final class Coordinator {
        let hostingController: UIHostingController<Content>

        init(content: Content) {
            hostingController = UIHostingController(rootView: content)
        }
    }
}

struct MailTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appTutorialState) private var tutorial
    @Query(
        filter: #Predicate<EmailMessage> { $0.isInInbox == true },
        sort: \EmailMessage.receivedAt,
        order: .reverse
    )
    private var cachedInboxEmails: [EmailMessage]

    @State private var viewState = MailboxViewState()
    @State private var alertTitle = AppLanguage.localized("mail.alert.connectionError", defaultValue: "메일 연결 오류", language: .current, comment: "Mail connection alert title.")
    @State private var isConnecting = false
    @State private var isGmailAuthenticated = false
    @State private var isOutlookAuthenticated = false
    @State private var selectedEmail: EmailMessage?
    @State private var showCategoryGuide = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var analysisProgress: MailAnalysisProgress?
    @State private var mailAnalysisSyncGate = MailAnalysisSyncGate()
    @State private var autoRegisteringEmailID: String?
    @State private var retryLoadMoreByProvider: [MailProvider: Bool] = [:]

    @State private var pendingTrashUndo: [EmailMessage] = []
    @State private var trashUndoTask: Task<Void, Never>?
    private var authenticatedProviders: Set<MailProvider> {
        var providers = Set<MailProvider>()
        if isGmailAuthenticated { providers.insert(.gmail) }
        if isOutlookAuthenticated { providers.insert(.outlook) }
        return providers
    }

    private var isAnyMailAuthenticated: Bool {
        !authenticatedProviders.isEmpty
    }

    private var isAnalyzing: Bool {
        mailAnalysisSyncGate.isAnalyzing
    }

    private var selectedProvider: MailProvider? {
        viewState.selectedProvider
    }

    private var selectedPagingState: MailboxPagingState {
        guard let selectedProvider else { return MailboxPagingState() }
        return viewState.pagingState(for: selectedProvider)
    }

    private var selectedProviderEmails: [EmailMessage] {
        guard let selectedProvider else { return [] }
        return cachedInboxEmails.filter { $0.provider == selectedProvider }
    }

    private var selectedEmails: [EmailMessage] {
        guard let selectedProvider else { return [] }
        let pendingIDs = Set(pendingTrashUndo.map(\.localListID))
        let visible = selectedProviderEmails.filter { !pendingIDs.contains($0.localListID) }
        switch selectedProvider {
        case .gmail:
            return visible.filter {
                $0.gmailInboxCategories.contains(viewState.selectedGmailCategory)
            }
        case .outlook:
            return visible.filter {
                $0.outlookInboxClassification == viewState.selectedOutlookClassification
            }
        }
    }

    var analysisCandidateEmails: [EmailMessage] {
        mailboxAnalysisCandidates(
            from: cachedInboxEmails,
            lookbackDays: EmailAnalysisLookbackPolicy.storedLookbackDays()
        )
    }

    nonisolated static func pendingTrashMessage(
        count: Int,
        language: AppLanguage
    ) -> String {
        return AppLanguage.localizedCount(
            "mail.trash.pending",
            count: count,
            defaultValue: language == .english
                ? (count == 1 ? "%lld message will move to Trash" : "%lld messages will move to Trash")
                : "%lld개 메일을 휴지통으로 이동",
            language: language,
            comment: "Pending mail trash status."
        )
    }
    var body: some View {
        NavigationStack {
            Group {
                if isAnyMailAuthenticated {
                    mailboxBrowser
                } else {
                    notConnectedView
                }
            }
            .navigationTitle("메일")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await analyzeInbox() }
                    } label: {
                        Label(AppLanguage.localized("mail.analyze", defaultValue: "정리", language: .current, comment: "Analyze mail action."), systemImage: "sparkles")
                    }
                    .disabled(
                        !isAnyMailAuthenticated
                            || selectedPagingState.isLoadingPage
                            || isAnalyzing
                    )
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedPagingState.isLoadingPage
                        || selectedPagingState.isReconcilingIndex
                        || isAnalyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await refreshSelectedMailbox(showSuccess: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel(AppLanguage.localized("mail.refresh.accessibilityLabel", defaultValue: "메일 새로고침", language: .current, comment: "Mail refresh button."))
                        .accessibilityIdentifier("mail.refreshButton")
                        .disabled(selectedProvider == nil)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let analysisProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(analysisProgress.statusText)
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        ProgressView(value: analysisProgress.fraction)
                            .accessibilityLabel(analysisProgress.statusText)
                            .accessibilityValue(analysisProgress.accessibilityValue)
                            .accessibilityIdentifier("mail.analysisProgress")
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .refreshable {
                await refreshSelectedMailbox(showSuccess: true)
            }
            .sheet(item: $selectedEmail) { email in
                MailDetailView(email: email)
                    .modelContainer(modelContext.container)
            }
            .sheet(isPresented: $showCategoryGuide) {
                MailCategoryGuideView()
                    .presentationDetents([.medium])
            }
            .alert(alertTitle, isPresented: $showError) {
                Button("확인") {}
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
            .task {
                await refreshAuthenticationState()
                try? MailboxLocalStore.live.replayPendingMutations(in: modelContext)
                if selectedProvider != nil {
                    await refreshSelectedMailbox(showSuccess: false)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gmailAuthChanged)) { note in
            isGmailAuthenticated = note.object as? Bool
                ?? EmailService.shared.isAuthenticated
            reconcileAuthenticatedProvidersAndRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .outlookAuthChanged)) { note in
            if note.object as? Bool == false || !OutlookMailService.shared.isConfigured {
                isOutlookAuthenticated = false
                reconcileAuthenticatedProvidersAndRefresh()
            } else {
                Task {
                    isOutlookAuthenticated =
                        await OutlookMailService.shared.canAccessMailSilently()
                    reconcileAuthenticatedProvidersAndRefresh()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            VStack(spacing: 8) {
                if !pendingTrashUndo.isEmpty {
                    HStack {
                        Text(
                            Self.pendingTrashMessage(
                                count: pendingTrashUndo.count,
                                language: .current
                            )
                        )
                        Spacer()
                        Button("실행 취소") { cancelPendingTrash() }
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("mail.trash.undo")
                }
                if let tutorial, let hint = tutorial.hint(for: .mailTab) {
                    AppTutorialHintCard(hint: hint)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
        .onAppear {
            tutorial?.handleMailTabAppeared()
        }
    }

    private var mailboxBrowser: some View {
        VStack(spacing: 0) {
            compactMailboxControls
            mailboxHeader
            if let warning = selectedPagingState.indexWarningMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppTheme.warning)
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(AppLanguage.localized("mail.refresh", defaultValue: "새로고침", language: .current, comment: "Mail refresh button.")) {
                        Task { await refreshSelectedMailbox(showSuccess: false) }
                    }
                    .accessibilityLabel(AppLanguage.localized("mail.refresh.accessibilityLabel", defaultValue: "메일 새로고침", language: .current, comment: "Mail refresh button."))
                    .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            mailboxRows
        }
    }

    private var compactMailboxControls: some View {
        HStack(spacing: 10) {
            if authenticatedProviders.count > 1 {
                providerMenu
            } else if let selectedProvider {
                Label(providerDisplayName(selectedProvider), systemImage: "envelope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }

            categoryControl
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var providerMenu: some View {
        Menu {
            if isGmailAuthenticated {
                Button {
                    selectProvider(.gmail)
                } label: {
                    Label("Gmail", systemImage: selectedProvider == .gmail ? "checkmark" : "envelope")
                }
            }
            if isOutlookAuthenticated {
                Button {
                    selectProvider(.outlook)
                } label: {
                    Label("Outlook", systemImage: selectedProvider == .outlook ? "checkmark" : "envelope.badge")
                }
            }
        } label: {
            Label(
                selectedProvider.map(providerDisplayName) ?? "메일",
                systemImage: "line.3.horizontal.decrease.circle"
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("mail.provider.menu")
    }

    @ViewBuilder
    private var categoryControl: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if selectedProvider == .gmail {
                    ForEach(GmailInboxCategory.allCases) { category in
                        categoryButton(
                            title: category.title,
                            systemImage: category.systemImage,
                            isSelected: viewState.selectedGmailCategory == category,
                            accessibilityID: "mail.gmail.\(category.rawValue)"
                        ) {
                            viewState.selectedGmailCategory = category
                        }
                    }
                } else if selectedProvider == .outlook {
                    ForEach(OutlookInboxClassification.allCases, id: \.rawValue) { classification in
                        categoryButton(
                            title: classification == .focused ? "중요" : "기타",
                            systemImage: classification == .focused
                                ? "person.crop.circle.badge.checkmark"
                                : "tray",
                            isSelected: viewState.selectedOutlookClassification == classification,
                            accessibilityID: "mail.outlook.\(classification.rawValue)"
                        ) {
                            viewState.selectedOutlookClassification = classification
                        }
                    }
                }
            }
        }
        .frame(height: 32)
    }

    private func categoryButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        accessibilityID: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    isSelected ? AppTheme.accentSoft : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AppTheme.accent : .secondary)
        .accessibilityIdentifier(accessibilityID)
    }

    private func selectProvider(_ provider: MailProvider) {
        let hasLoaded = viewState.pagingState(for: provider).hasLoadedInitialPage
        viewState.selectedProvider = provider
        if !hasLoaded {
            Task { await refreshSelectedMailbox(showSuccess: false) }
        }
    }

    private var mailboxHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let selectedProvider {
                Text(mailboxHeaderText(for: selectedProvider))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showCategoryGuide = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("메일 분류 기준")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var mailboxRows: some View {
        if !selectedPagingState.hasLoadedInitialPage
            && selectedPagingState.isLoadingPage
            && selectedProviderEmails.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("받은편지함을 불러오는 중...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !selectedPagingState.hasLoadedInitialPage,
                  let message = selectedPagingState.pageErrorMessage,
                  selectedProviderEmails.isEmpty {
            ContentUnavailableView {
                Label(
                    "받은편지함을 불러오지 못했습니다",
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(message)
            } actions: {
                pageRetryButton
            }
        } else if selectedEmails.isEmpty {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "이 분류에 불러온 메일이 없습니다.",
                    systemImage: selectedProvider == .gmail
                        ? viewState.selectedGmailCategory.systemImage
                        : "tray"
                )
                pageFooter
            }
        } else {
            List {
                ForEach(selectedEmails, id: \.localListID) { email in
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
                            .tint(AppTheme.success)
                        }
                    }
                }
                .onDelete(perform: deleteEmails)

                pageFooter
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var pageFooter: some View {
        if selectedPagingState.isLoadingPage
            && selectedPagingState.hasLoadedInitialPage {
            HStack {
                Spacer()
                ProgressView("이전 메일을 불러오는 중...")
                Spacer()
            }
            .padding(.vertical, 12)
        } else if selectedPagingState.pageErrorMessage != nil {
            pageRetryButton
        } else if selectedPagingState.canLoadMore {
            Button("이전 메일 더 불러오기") {
                guard let selectedProvider else { return }
                Task { await loadPage(for: selectedProvider, loadMore: true) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityIdentifier("mail.page.loadMore")
        } else if selectedPagingState.hasLoadedInitialPage {
            Text("받은편지함을 모두 불러왔습니다")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityIdentifier("mail.page.complete")
        }
    }

    private var pageRetryButton: some View {
        Button("다시 시도") {
            guard let selectedProvider else { return }
            let shouldLoadMore = retryLoadMoreByProvider[selectedProvider] ?? false
            Task {
                await loadPage(for: selectedProvider, loadMore: shouldLoadMore)
            }
        }
        .accessibilityIdentifier("mail.page.retry")
    }

    private var notConnectedView: some View {
        ContentUnavailableView {
            Label(
                "메일 계정 미연결",
                systemImage: "envelope.badge.shield.half.filled"
            )
        } description: {
            Text("Gmail 또는 Outlook을 연결하면 받은편지함 전체를 볼 수 있습니다.")
        } actions: {
            VStack(spacing: 12) {
                Button {
                    Task { await connectGmail() }
                } label: {
                    Label("Gmail 연결", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting)

                Button {
                    Task { await connectOutlook() }
                } label: {
                    Label("Outlook 연결", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                .disabled(isConnecting)
            }
        }
    }

    private func mailboxHeaderText(for provider: MailProvider) -> String {
        let loadedCount = cachedInboxEmails.filter { $0.provider == provider }.count
        let language = AppLanguage.current
        if let total = viewState.pagingState(for: provider).totalInboxCount {
            let format = AppLanguage.localized(
                "mail.mailboxHeader.total",
                defaultValue: "%@ Inbox · All Time · %lld of %lld loaded",
                language: language,
                comment: "Mailbox header with total count"
            )
            return String(
                format: format,
                locale: language.locale,
                providerDisplayName(provider),
                Int64(loadedCount),
                Int64(total)
            )
        }
        let format = AppLanguage.localized(
            "mail.mailboxHeader.current",
            defaultValue: "%@ Inbox · All Time · %lld loaded",
            language: language,
            comment: "Mailbox header with loaded count"
        )
        return String(format: format, locale: language.locale, providerDisplayName(provider), Int64(loadedCount))
    }

    private func providerDisplayName(_ provider: MailProvider) -> String {
        provider == .gmail ? "Gmail" : "Outlook"
    }

    private func connectGmail() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await EmailService.shared.authenticate()
        } catch {
            let nsError = error as NSError
            if nsError.domain ==
                "com.apple.AuthenticationServices.WebAuthenticationSession",
               nsError.code == 1 {
                alertTitle = AppLanguage.localized("mail.alert.title", defaultValue: "알림", language: .current, comment: "Mail alert title.")
                errorMessage = AppLanguage.localized("mail.auth.cancelled", defaultValue: "로그인이 취소되었습니다.", language: .current, comment: "Mail authentication cancellation.")
            } else {
                alertTitle = AppLanguage.localized("mail.connection.gmail.error", defaultValue: "Gmail 연결 오류", language: .current, comment: "Gmail connection error title.")
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
            alertTitle = AppLanguage.localized("mail.connection.outlook.error", defaultValue: "Outlook 연결 오류", language: .current, comment: "Outlook connection error title.")
            errorMessage = OutlookMailError.missingClientID.localizedDescription
            showError = true
        } catch {
            let nsError = error as NSError
            if nsError.domain == MSALErrorDomain
                && nsError.code == MSALError.userCanceled.rawValue {
                alertTitle = AppLanguage.localized("mail.alert.title", defaultValue: "알림", language: .current, comment: "Mail alert title.")
                errorMessage = AppLanguage.localized("mail.auth.cancelled", defaultValue: "로그인이 취소되었습니다.", language: .current, comment: "Mail authentication cancellation.")
            } else {
                alertTitle = AppLanguage.localized("mail.connection.outlook.error", defaultValue: "Outlook 연결 오류", language: .current, comment: "Outlook connection error title.")
                errorMessage = error.localizedDescription
            }
            showError = true
        }
    }

    @MainActor
    private func refreshSelectedMailbox(showSuccess: Bool) async {
        guard mailAnalysisSyncGate.requestSync(),
              let provider = selectedProvider else { return }

        do {
            try MailboxLocalStore.live.replayPendingMutations(in: modelContext)
        } catch {
            alertTitle = AppLanguage.localized("mail.alert.statusSaveError", defaultValue: "메일 상태 저장 오류", language: .current, comment: "Mail mutation alert title.")
            errorMessage = error.localizedDescription
            showError = true
        }

        async let pageLoad: Void = loadPage(for: provider, loadMore: false)
        async let indexLoad: Void = reconcileInbox(for: provider)
        _ = await (pageLoad, indexLoad)

        let state = viewState.pagingState(for: provider)
        if showSuccess,
           state.pageErrorMessage == nil,
           state.indexWarningMessage == nil {
            alertTitle = AppLanguage.localized("mail.sync.success", defaultValue: "%@ Inbox sync complete", language: .current, comment: "Mailbox sync success title.")
            alertTitle = String(format: alertTitle, locale: AppLanguage.current.locale, providerDisplayName(provider))
            errorMessage = mailboxHeaderText(for: provider)
            showError = true
        }
    }

    @MainActor
    private func loadPage(for provider: MailProvider, loadMore: Bool) async {
        let previousState = viewState.pagingState(for: provider)
        let cursor = loadMore ? previousState.nextCursor : nil
        guard viewState.beginPage(for: provider, loadMore: loadMore) else { return }
        retryLoadMoreByProvider[provider] = nil

        do {
            let page = try await mailboxProvider(for: provider)
                .fetchInboxPage(after: cursor)
            try MailboxLocalStore.live.upsert(page, into: modelContext)
            try MailboxLocalStore.live.replayPendingMutations(in: modelContext)
            viewState.completePage(for: provider, nextCursor: page.nextCursor)
            retryLoadMoreByProvider[provider] = nil
        } catch {
            viewState.failPage(for: provider, message: error.localizedDescription)
            retryLoadMoreByProvider[provider] = loadMore
        }
    }

    @MainActor
    private func reconcileInbox(for provider: MailProvider) async {
        guard viewState.beginIndex(for: provider) else { return }
        do {
            let activeIDs = try await mailboxProvider(for: provider)
                .fetchInboxMessageIDs()
            try MailboxLocalStore.live.reconcileInbox(
                provider: provider,
                activeMessageIDs: activeIDs,
                in: modelContext
            )
            try MailboxLocalStore.live.replayPendingMutations(in: modelContext)
            viewState.completeIndex(for: provider, totalCount: activeIDs.count)
        } catch {
            viewState.failIndex(
                for: provider,
                message: AppLanguage.localized("mail.inbox.reconcileFailed", defaultValue: "The full inbox state could not be checked.", language: .current, comment: "Inbox reconciliation failure.")
            )
        }
    }

    @MainActor
    private func analyzeInbox() async {
        guard !mailAnalysisSyncGate.isAnalyzing,
              !selectedPagingState.isLoadingPage,
              isAnyMailAuthenticated else { return }
        let pendingEmails = analysisCandidateEmails
        guard !pendingEmails.isEmpty else {
            alertTitle = AppLanguage.localized("mail.analysis.title", defaultValue: "메일 정리", language: .current, comment: "Mail analysis title.")
            errorMessage = AppLanguage.localized("mail.analysis.none", defaultValue: "새로 정리할 메일이 없습니다.", language: .current, comment: "No pending mail analysis.")
            showError = true
            return
        }
        guard mailAnalysisSyncGate.beginAnalysis() else { return }

        await MailAnalysisBatch.run(
            emails: pendingEmails,
            process: analyzeEmail,
            onProgress: { analysisProgress = $0 }
        )
        try? await Task.sleep(for: .milliseconds(500))
        analysisProgress = nil
        if mailAnalysisSyncGate.finishAnalysis() {
            await refreshSelectedMailbox(showSuccess: false)
        }
    }

    @MainActor
    private func analyzeEmail(_ email: EmailMessage) async {
        if email.body.isEmpty && email.htmlBody == nil {
            do {
                let content = try await mailboxProvider(for: email.provider)
                    .fetchMessageContent(messageID: email.providerMessageID)
                try MailboxLocalStore.live.updateContent(
                    content,
                    for: email,
                    in: modelContext
                )
            } catch {
                email.analysisState = .failed
                email.analysisError = AppLanguage.localized("mail.analysis.noBody", defaultValue: "The email body could not be loaded for analysis.", language: .current, comment: "Email analysis missing-body error.")
                return
            }
        }
        await EmailMessageAnalysisService.shared.analyze(email, context: modelContext)
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
        let existing = (
            try? appContext.fetch(FetchDescriptor<Todo>(predicate: existingPredicate))
        ) ?? []
        guard existing.isEmpty else {
            alertTitle = AppLanguage.localized("mail.todo.alreadyRegistered.title", defaultValue: "Already Registered", language: .current, comment: "Already registered mail alert.")
            errorMessage = AppLanguage.localized("mail.todo.alreadyRegistered.message", defaultValue: "This email is already registered as a To-Do.", language: .current, comment: "Already registered mail alert.")
            showError = true
            return
        }

        if email.body.isEmpty && email.htmlBody == nil {
            do {
                let content = try await mailboxProvider(for: email.provider)
                    .fetchMessageContent(messageID: email.providerMessageID)
                try MailboxLocalStore.live.updateContent(
                    content,
                    for: email,
                    in: modelContext
                )
            } catch {
                alertTitle = AppLanguage.localized("mail.todo.registerFailed", defaultValue: "To-Do Registration Failed", language: .current, comment: "Mail to-do registration error.")
                errorMessage = error.localizedDescription
                showError = true
                return
            }
        }

        let synthetic = GmailMessage(
            id: email.todoSourceRef,
            threadID: email.threadID,
            messageID: "",
            subject: email.subject,
            from: email.from,
            snippet: email.snippet,
            body: email.body,
            htmlBody: email.htmlBody,
            receivedAt: email.receivedAt,
            labelIds: email.labelIDs,
            isBulk: false
        )
        let todo = await EmailService.shared.makeManualTodo(from: synthetic)

        do {
            appContext.insert(todo)
            TaskBehaviorRecorder.recordCreation(of: todo, actor: .user, in: appContext)
            try appContext.save()
            _ = CalendarService.shared.applyAutoRegistration(for: todo)
            try appContext.save()
            EmailLearningStore.shared.recordAnalyzed(messageIDs: [email.todoSourceRef])
            alertTitle = AppLanguage.localized("mail.todo.registered.title", defaultValue: "To-Do Registered", language: .current, comment: "Mail to-do registration success.")
            errorMessage = AppLanguage.localized("mail.todo.registered.message", defaultValue: "A To-Do was registered from the email summary.", language: .current, comment: "Mail to-do registration success.")
            showError = true
        } catch {
            alertTitle = AppLanguage.localized("mail.todo.registerFailed", defaultValue: "To-Do Registration Failed", language: .current, comment: "Mail to-do registration error.")
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func deleteEmails(at offsets: IndexSet) {
        let targets = offsets.compactMap {
            selectedEmails.indices.contains($0) ? selectedEmails[$0] : nil
        }
        Task { await trashEmails(targets) }
    }

    @MainActor
    private func trashEmails(_ targets: [EmailMessage]) async {
        guard !targets.isEmpty else { return }
        trashUndoTask?.cancel()
        pendingTrashUndo = targets
        trashUndoTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            let pending = pendingTrashUndo
            pendingTrashUndo = []
            await commitTrash(pending)
        }
    }

    @MainActor
    private func cancelPendingTrash() {
        trashUndoTask?.cancel()
        trashUndoTask = nil
        pendingTrashUndo = []
    }

    @MainActor
    private func commitTrash(_ targets: [EmailMessage]) async {
        for email in targets {
            do {
                let provider = mailboxProvider(for: email.provider)
                try await MailboxLocalStore.live.trash(
                    email,
                    in: modelContext,
                    remote: { try await provider.trashMessage(messageID: email.providerMessageID) }
                )
            } catch {
                let alert = mailDetailAlert(action: .trash, error: error)
                alertTitle = alert.title
                errorMessage = alert.message
                showError = true
                return
            }
        }
    }

    @MainActor
    private func refreshAuthenticationState() async {
        isGmailAuthenticated = EmailService.shared.isAuthenticated
        if OutlookMailService.shared.isConfigured {
            isOutlookAuthenticated =
                await OutlookMailService.shared.canAccessMailSilently()
        } else {
            isOutlookAuthenticated = false
        }
        viewState.reconcileAuthenticatedProviders(authenticatedProviders)
    }

    @MainActor
    private func reconcileAuthenticatedProvidersAndRefresh() {
        let previous = selectedProvider
        viewState.reconcileAuthenticatedProviders(authenticatedProviders)
        guard let selectedProvider,
              previous != selectedProvider
                || !viewState.pagingState(for: selectedProvider).hasLoadedInitialPage
        else { return }
        Task { await refreshSelectedMailbox(showSuccess: false) }
    }
}

private struct MailCategoryGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Gmail") {
                    ForEach(GmailInboxCategory.allCases) { category in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: category.systemImage)
                                .foregroundStyle(AppTheme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(category.title)
                                    .font(.headline)
                                Text(category.explanation)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Text("Gmail API가 제공한 원본 system category label을 그대로 사용합니다.")
                }

                Section("Outlook") {
                    Text("Focused는 중요, Other는 기타로 표시합니다.")
                    Text("Outlook category 이름은 메일 행의 badge로 그대로 표시합니다.")
                }

                Section("받은편지함") {
                    Text("읽음 여부와 관계없이 받은편지함의 전체 기간을 페이지 단위로 불러옵니다.")
                    Text("아직 불러오지 않은 이전 메일이 있으면 목록 아래에서 계속 불러올 수 있습니다.")
                }
            }
            .navigationTitle("메일 분류 기준")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
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
                analysisBadge
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
            if email.provider == .outlook, !email.providerCategoryNames.isEmpty {
                HStack(spacing: 6) {
                    ForEach(email.providerCategoryNames.prefix(3), id: \.self) { category in
                        Text(category)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .foregroundStyle(email.isRead ? .secondary : .primary)
    }

    @ViewBuilder
    private var analysisBadge: some View {
        switch email.analysisState {
        case .unanalyzed:
            EmptyView()
        case .analyzing:
            ProgressView().controlSize(.mini)
        case .analyzed:
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
                .accessibilityLabel("AI 정리 완료")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(AppTheme.warning)
                .accessibilityLabel("AI 정리 실패")
        }
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
    @State private var isSyncingRead = false
    @State private var isTrashing = false
    @State private var isReanalyzing = false
    @State private var alert: MailDetailAlert?

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
                                Label("AI 정리", systemImage: "sparkles")
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
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding()
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
                    .disabled(isTrashing || isSyncingRead)
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
        let provider = mailboxProvider(for: email.provider)
        if !email.isRead {
            isSyncingRead = true
            do {
                try await MailboxLocalStore.live.markAsRead(
                    email,
                    in: modelContext,
                    remote: {
                        try await provider.markAsRead(
                            messageID: email.providerMessageID
                        )
                    }
                )
            } catch {
                alert = mailDetailAlert(action: .markAsRead, error: error)
            }
            isSyncingRead = false
        }

        isLoadingBody = true
        do {
            let content = try await provider.fetchMessageContent(
                messageID: email.providerMessageID
            )
            try MailboxLocalStore.live.updateContent(
                content,
                for: email,
                in: modelContext
            )
        } catch {
            if alert == nil {
                alert = MailDetailAlert(
                    title: "메일 본문 로드 오류",
                    message: error.localizedDescription
                )
            }
        }
        isLoadingBody = false
        await EmailMessageAnalysisService.shared.analyze(
            email,
            context: modelContext
        )
    }

    @MainActor
    private func reanalyzeCurrentEmail() async {
        guard !isReanalyzing, !isLoadingBody else { return }
        isReanalyzing = true
        defer { isReanalyzing = false }

        if email.body.isEmpty && email.htmlBody == nil {
            isLoadingBody = true
            do {
                let content = try await mailboxProvider(for: email.provider)
                    .fetchMessageContent(messageID: email.providerMessageID)
                try MailboxLocalStore.live.updateContent(
                    content,
                    for: email,
                    in: modelContext
                )
            } catch {
                alert = MailDetailAlert(
                    title: "메일 본문 로드 오류",
                    message: error.localizedDescription
                )
                isLoadingBody = false
                return
            }
            isLoadingBody = false
        }

        EmailAnalysisContract.resetAnalysis(email)
        do {
            try modelContext.save()
        } catch {
            alert = MailDetailAlert(
                title: "AI 정리 오류",
                message: error.localizedDescription
            )
            return
        }

        await EmailMessageAnalysisService.shared.analyze(
            email,
            context: modelContext
        )
    }

    @MainActor
    private func trashCurrentEmail() async {
        guard !isTrashing, !isSyncingRead else { return }
        isTrashing = true
        defer { isTrashing = false }

        let provider = mailboxProvider(for: email.provider)
        do {
            try await MailboxLocalStore.live.trash(
                email,
                in: modelContext,
                remote: {
                    try await provider.trashMessage(
                        messageID: email.providerMessageID
                    )
                }
            )
            dismiss()
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
    @Environment(\.modelContext) private var modelContext

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
                            .font(.caption).foregroundStyle(AppTheme.destructive)
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
        let syntheticMessageID = ""
        if email.body.isEmpty || email.htmlBody == nil {
            do {
                let content = try await mailboxProvider(for: email.provider)
                    .fetchMessageContent(messageID: email.providerMessageID)
                try MailboxLocalStore.live.updateContent(
                    content,
                    for: email,
                    in: modelContext
                )
                syntheticThreadID = email.threadID
            } catch {
                errorMessage = error.localizedDescription
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
            errorMessage = AppLanguage.localized("mail.register.duplicate", defaultValue: "This email is already registered.", language: .current, comment: "Mail registration duplicate error.")
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
            TaskBehaviorRecorder.recordCreation(of: todo, actor: .user, in: appContext)
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
