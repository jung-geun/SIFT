import SwiftUI
import SwiftData
import UIKit
import WebKit
import EventKit

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
    now: Date = Date(),
    includeUnclassified: Bool = false
) -> [EmailMessage] {
    let cutoff = EmailAnalysisLookbackPolicy.cutoff(
        now: now,
        lookbackDays: lookbackDays
    )
    return emails.filter {
        $0.isInInbox
            && $0.receivedAt >= cutoff
            && ($0.analysisState != .analyzed
                || $0.analysisVersion != EmailAnalysisContract.summaryContractVersion
                || (includeUnclassified && $0.analysisTodoCandidate == nil))
    }
}

struct MailboxViewState: Equatable {
    var selectedProvider: MailProvider?
    var selectedGmailCategory: GmailInboxCategory = .primary
    var pagingByProvider: [MailProvider: MailboxPagingState] = [:]

    mutating func reconcileProviders(_ providers: Set<MailProvider>) {
        if let selectedProvider, providers.contains(selectedProvider) {
            return
        }
        if providers.contains(.gmail) {
            selectedProvider = .gmail
        } else if providers.contains(.outlook) {
            selectedProvider = .outlook
        } else {
            selectedProvider = nil
        }
    }

    mutating func reconcileAuthenticatedProviders(_ authenticated: Set<MailProvider>) {
        reconcileProviders(authenticated)
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

func mailErrorMessage(
    _ error: Error,
    language: AppLanguage = .current
) -> String {
    if let imapError = error as? GmailIMAPError {
        return imapError.errorDescription(language: language)
    }
    if let mutationError = error as? MailboxMutationError {
        return mutationError.errorDescription(language: language)
    }
    return error.localizedDescription
}

func mailDetailAlert(
    action: MailboxMutationAction,
    error: Error,
    language: AppLanguage = .current
) -> MailDetailAlert {
    if error is MailboxMutationError {
        return MailDetailAlert(
            title: AppLanguage.localized("mail.alert.statusSaveError", defaultValue: "메일 상태 저장 오류", language: language, comment: "Mail mutation alert title."),
            message: mailErrorMessage(error, language: language)
        )
    }
    if let imapError = error as? GmailIMAPError {
        return MailDetailAlert(
            title: AppLanguage.localized(
                action == .markAsRead ? "mail.alert.readSyncError" : "mail.alert.deleteError",
                defaultValue: action == .markAsRead ? "읽음 동기화 오류" : "메일 삭제 오류",
                language: language,
                comment: "Mail mutation alert title."
            ),
            message: imapError.errorDescription(language: language)
        )
    }
    return MailDetailAlert(
        title: AppLanguage.localized(
            action == .markAsRead ? "mail.alert.readSyncError" : "mail.alert.deleteError",
            defaultValue: action == .markAsRead ? "읽음 동기화 오류" : "메일 삭제 오류",
            language: language,
            comment: "Mail mutation alert title."
        ),
        message: mailErrorMessage(error, language: language)
    )
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
nonisolated enum MailAuthenticationLoadingState: Equatable {
    case checking
    case resolved
}

struct MailboxStartupPresentation: Equatable {
    let authenticationState: MailAuthenticationLoadingState
    let cachedProviders: Set<MailProvider>
    let authenticatedProviders: Set<MailProvider>
    let storedCredentialProviders: Set<MailProvider>

    var visibleProviders: Set<MailProvider> {
        storedCredentialProviders
            .union(authenticatedProviders)
            .union(cachedProviders.intersection(storedCredentialProviders))
    }

    var showsMailbox: Bool {
        !visibleProviders.isEmpty
    }

    var showsAuthenticationCheckingStatus: Bool {
        authenticationState == .checking
    }
}

struct MailboxCachedProviderAccess: Equatable, Sendable {
    let activeGmailNamespace: String
    let activeOutlookNamespace: String

    var hasActiveProvider: Bool {
        !activeGmailNamespace.isEmpty || !activeOutlookNamespace.isEmpty
    }

    var locallyConfiguredProviders: Set<MailProvider> {
        var providers = Set<MailProvider>()
        if !activeGmailNamespace.isEmpty { providers.insert(.gmail) }
        if !activeOutlookNamespace.isEmpty { providers.insert(.outlook) }
        return providers
    }

    func isLocallyConfigured(_ provider: MailProvider) -> Bool {
        locallyConfiguredProviders.contains(provider)
    }

    var storedCredentialProviders: Set<MailProvider> {
        var providers = Set<MailProvider>()
        if IMAPCredentialStore.hasCredential(for: activeGmailNamespace) {
            providers.insert(.gmail)
        }
        if OutlookIMAPCredentialStore.hasCredential(for: activeOutlookNamespace) {
            providers.insert(.outlook)
        }
        return providers
    }

    static func current() -> MailboxCachedProviderAccess {
        let gmailRaw = UserDefaults.standard.string(forKey: "pieroot.todo.imap.account") ?? ""
        let gmailNamespace = IMAPCredentialStore.canonicalAccount(gmailRaw) ?? ""
        let outlookRaw = UserDefaults.standard.string(forKey: "pieroot.todo.outlook.account") ?? ""
        let outlookNamespace = OutlookIMAPCredentialStore.canonicalAccount(outlookRaw) ?? ""
        return MailboxCachedProviderAccess(
            activeGmailNamespace: gmailNamespace,
            activeOutlookNamespace: outlookNamespace
        )
    }

    func permits(provider: MailProvider, sourceAccountNamespace: String) -> Bool {
        guard !sourceAccountNamespace.isEmpty else { return false }
        switch provider {
        case .gmail:
            return !activeGmailNamespace.isEmpty
                && sourceAccountNamespace == activeGmailNamespace
        case .outlook:
            return !activeOutlookNamespace.isEmpty
                && sourceAccountNamespace == activeOutlookNamespace
        }
    }
}

private struct MailSessionValidation: Sendable {
    let isAuthenticated: Bool
    let hasStoredCredential: Bool
}

@MainActor
enum MailTrashUndoBatchPhase: Equatable {
    case undoAvailable
    case committing
}

@MainActor
struct MailTrashUndoBatch: Identifiable {
    let id: UUID
    let emails: [EmailMessage]
    let mutations: Set<PendingMailboxMutation>
    fileprivate(set) var phase: MailTrashUndoBatchPhase = .undoAvailable
}

@MainActor
struct MailTrashUndoQueue {
    private(set) var batches: [MailTrashUndoBatch] = []

    var pendingEmailIDs: Set<String> {
        Set(batches.flatMap(\.emails).map(\.localListID))
    }

    var latestUndoableBatch: MailTrashUndoBatch? {
        batches.last(where: { $0.phase == .undoAvailable })
    }

    @discardableResult
    mutating func enqueue(
        _ emails: [EmailMessage],
        mutations: Set<PendingMailboxMutation> = []
    ) -> MailTrashUndoBatch {
        replaceUndoableBatch(with: emails, mutations: mutations).latest
    }

    @discardableResult
    mutating func replaceUndoableBatch(
        with emails: [EmailMessage],
        mutations: Set<PendingMailboxMutation>
    ) -> (latest: MailTrashUndoBatch, superseded: [MailTrashUndoBatch]) {
        let superseded = batches.filter { $0.phase == .undoAvailable }
        batches.removeAll { $0.phase == .undoAvailable }
        let latest = MailTrashUndoBatch(id: UUID(), emails: emails, mutations: mutations)
        batches.append(latest)
        return (latest, superseded)
    }

    @discardableResult
    mutating func beginCommit(id: UUID) -> MailTrashUndoBatch? {
        guard let index = batches.firstIndex(where: { $0.id == id }),
              batches[index].phase == .undoAvailable
        else {
            return nil
        }
        batches[index].phase = .committing
        return batches[index]
    }

    @discardableResult
    mutating func remove(id: UUID) -> MailTrashUndoBatch? {
        guard let index = batches.firstIndex(where: { $0.id == id }) else { return nil }
        return batches.remove(at: index)
    }
}

struct MailTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appTutorialState) private var tutorial
    @Query(
        filter: #Predicate<EmailMessage> { $0.isInInbox == true },
        sort: \EmailMessage.receivedAt,
        order: .reverse
    )
    private var cachedInboxEmails: [EmailMessage]

    @State private var authenticationState: MailAuthenticationLoadingState = .checking
    @State private var viewState = MailboxViewState()
    @State private var alertTitle = AppLanguage.localized("mail.alert.connectionError", defaultValue: "메일 연결 오류", language: .current, comment: "Mail connection alert title.")
    @State private var isConnecting = false
    @State private var isGmailAuthenticated = false
    @State private var isOutlookAuthenticated = false
    @State private var storedCredentialProviders = Set<MailProvider>()
    @State private var selectedEmail: MailDetailSelection?
    @State private var showCategoryGuide = false
    @State private var showEmailSettingsSheet = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var analysisProgress: MailAnalysisProgress?
    @State private var mailAnalysisSyncGate = MailAnalysisSyncGate()
    @State private var registeringEmail: MailDetailSelection?
    @State private var retryLoadMoreByProvider: [MailProvider: Bool] = [:]

    @State private var pendingTrashQueue = MailTrashUndoQueue()
    @State private var trashUndoTasks: [UUID: Task<Void, Never>] = [:]


    private var authenticatedProviders: Set<MailProvider> {
        var providers = Set<MailProvider>()
        if isGmailAuthenticated { providers.insert(.gmail) }
        if isOutlookAuthenticated { providers.insert(.outlook) }
        return providers
    }

    private var cachedProviderAccess: MailboxCachedProviderAccess {
        MailboxCachedProviderAccess.current()
    }

    private var validCachedInboxEmails: [EmailMessage] {
        cachedInboxEmails.filter {
            cachedProviderAccess.permits(
                provider: $0.provider,
                sourceAccountNamespace: $0.sourceAccountNamespace
            )
        }
    }

    private var cachedProviders: Set<MailProvider> {
        Set(validCachedInboxEmails.map(\.provider))
    }

    private var startupPresentation: MailboxStartupPresentation {
        MailboxStartupPresentation(
            authenticationState: authenticationState,
            cachedProviders: cachedProviders,
            authenticatedProviders: authenticatedProviders,
            storedCredentialProviders: storedCredentialProviders
        )
    }

    private func reconcileSelectedProviderForCurrentState() {
        viewState.reconcileProviders(startupPresentation.visibleProviders)
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

    private var activeGmailNamespace: String {
        cachedProviderAccess.activeGmailNamespace
    }

    private var activeOutlookNamespace: String {
        cachedProviderAccess.activeOutlookNamespace
    }
    private var selectedPagingState: MailboxPagingState {
        guard let selectedProvider else { return MailboxPagingState() }
        return viewState.pagingState(for: selectedProvider)
    }

    private var selectedProviderEmails: [EmailMessage] {
        guard let selectedProvider else { return [] }
        return validCachedInboxEmails.filter { $0.provider == selectedProvider }
    }

    private var selectedEmails: [EmailMessage] {
        guard let selectedProvider else { return [] }
        let visible = selectedProviderEmails.filter {
            !pendingTrashQueue.pendingEmailIDs.contains($0.localListID)
        }
        switch selectedProvider {
        case .gmail:
            return visible.filter {
                $0.gmailInboxCategories.contains(viewState.selectedGmailCategory)
            }
        case .outlook:
            return visible
        }
    }

    var analysisCandidateEmails: [EmailMessage] {
        let laya = LayaDecisionService.shared
        let canClassify = BetaFeaturePolicy().authorizes(.laya, for: .layaModelManagement)
            && laya.isCapable && laya.isModelInstalled
        return mailboxAnalysisCandidates(
            from: validCachedInboxEmails,
            lookbackDays: EmailAnalysisLookbackPolicy.storedLookbackDays(),
            includeUnclassified: canClassify
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

    /// True exactly when `emailID` is the first row of the currently loaded page and every
    /// readiness guard for the top-of-list incremental-sync trigger is satisfied. Extracted so
    /// the "only the first row fires, and only once ready" contract stays testable without a
    /// dedicated zero-height sentinel `List` row.
    nonisolated static func shouldTriggerTopSync(
        emailID: String,
        firstEmailID: String?,
        authenticationState: MailAuthenticationLoadingState,
        hasLoadedInitialPage: Bool,
        hasProvider: Bool
    ) -> Bool {
        emailID == firstEmailID
            && authenticationState == .resolved
            && hasLoadedInitialPage
            && hasProvider
    }
    var body: some View {
        NavigationStack {
            Group {
                if startupPresentation.showsMailbox {
                    mailboxBrowser
                } else if startupPresentation.showsAuthenticationCheckingStatus {
                    authenticationCheckingView
                } else {
                    notConnectedView
                }
            }
            .navigationTitle("메일")
            .navigationBarTitleDisplayMode(horizontalSizeClass == .regular ? .inline : .large)
            .disableNavigationBarMinimization()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await analyzeInbox() }
                    } label: {
                        Label(AppLanguage.localized("mail.analyze", defaultValue: "정리", language: .current, comment: "Analyze mail action."), systemImage: "sparkles")
                    }
                    .disabled(
                        startupPresentation.showsAuthenticationCheckingStatus
                            || !isAnyMailAuthenticated
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
                        .disabled(selectedProvider == nil || startupPresentation.showsAuthenticationCheckingStatus)
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
                if !startupPresentation.showsAuthenticationCheckingStatus {
                    await refreshSelectedMailbox(showSuccess: true)
                }
            }
            .sheet(item: $selectedEmail) { selection in
                MailDetailSelectionView(selection: selection)
                    .modelContainer(modelContext.container)
            }
            .sheet(item: $registeringEmail) { selection in
                MailRegisterSelectionView(selection: selection)
                    .environment(\.modelContext, modelContext)
            }
            .sheet(isPresented: $showCategoryGuide) {
                MailCategoryGuideView()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showEmailSettingsSheet, onDismiss: {
                Task {
                    storedCredentialProviders = MailboxCachedProviderAccess.current().storedCredentialProviders
                    if let provider = selectedProvider {
                        await validateAndUpdateAuthState(for: provider)
                        guard selectedProvider == provider else { return }
                        await refreshSelectedMailbox(showSuccess: false)
                    }
                }
            }) {
                NavigationStack {
                    EmailDetailView()
                }
            }
            .alert(alertTitle, isPresented: $showError) {
                Button("확인") {}
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
            .task {
                storedCredentialProviders = MailboxCachedProviderAccess.current().storedCredentialProviders
                authenticationState = .resolved
                reconcileSelectedProviderForCurrentState()
                try? MailboxLocalStore.live.replayPendingMutations(in: modelContext)
                if let provider = selectedProvider {
                    await validateAndUpdateAuthState(for: provider)
                    guard selectedProvider == provider else { return }
                    await refreshSelectedMailbox(showSuccess: false)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gmailAuthChanged)) { note in
            isGmailAuthenticated = note.object as? Bool
                ?? (!(UserDefaults.standard.string(forKey: "pieroot.todo.imap.account") ?? "").isEmpty)
            viewState.pagingByProvider[.gmail] = MailboxPagingState()
            reconcileAuthenticatedProvidersAndRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("pieroot.todo.outlookAuthChanged"))) { note in
            isOutlookAuthenticated = note.object as? Bool
                ?? (!(UserDefaults.standard.string(forKey: "pieroot.todo.outlook.account") ?? "").isEmpty)
            viewState.pagingByProvider[.outlook] = MailboxPagingState()
            reconcileAuthenticatedProvidersAndRefresh()
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            VStack(spacing: 8) {
                if let batch = pendingTrashQueue.latestUndoableBatch {
                    HStack {
                        Text(
                            Self.pendingTrashMessage(
                                count: batch.emails.count,
                                language: .current
                            )
                        )
                        Spacer()
                        Button("실행 취소") { cancelPendingTrash(batchID: batch.id) }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("mail.trash.undo.\(batch.id.uuidString)")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                }
                if let tutorial {
                    AppTutorialTipHost(tutorial: tutorial, screen: .mailTab)
                }
            }
        }
        .onChange(of: cachedInboxEmails.map(\.localListID)) { _, _ in
            reconcileSelectedProviderForCurrentState()
        }
        .onAppear {
            reconcileSelectedProviderForCurrentState()
            tutorial?.handleMailTabAppeared()
        }
    }

    private var mailboxBrowser: some View {
        VStack(spacing: 0) {
            compactMailboxControls
            mailboxHeader
            if startupPresentation.showsAuthenticationCheckingStatus {
                authenticationCheckingStatusRow
            }
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
                    .disabled(startupPresentation.showsAuthenticationCheckingStatus)
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
            if startupPresentation.visibleProviders.count > 1 {
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
            if startupPresentation.visibleProviders.contains(.gmail) {
                Button {
                    selectProvider(.gmail)
                } label: {
                    Label("Gmail", systemImage: selectedProvider == .gmail ? "checkmark" : "envelope")
                }
            }
            if startupPresentation.visibleProviders.contains(.outlook) {
                Button {
                    selectProvider(.outlook)
                } label: {
                    Label("Outlook", systemImage: selectedProvider == .outlook ? "checkmark" : "envelope")
                }
            }
        } label: {
            Label(
                selectedProvider.map(providerDisplayName) ?? AppLanguage.localized("search.scope.mail", defaultValue: "메일", language: .current),
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
            Task {
                await validateAndUpdateAuthState(for: provider)
                guard selectedProvider == provider else { return }
                await refreshSelectedMailbox(showSuccess: false)
            }
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
        .accessibilityIdentifier("mail.mailboxHeader")
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
                pageFooter(autoLoadsOlder: false)
            }
        } else {
            List {
                ForEach(selectedEmails, id: \.localListID) { email in
                    Button {
                        selectedEmail = MailDetailSelection(email)
                    } label: {
                        MailMessageRow(email: email)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            registeringEmail = MailDetailSelection(email)
                        } label: {
                            Label(MailRegisterSheet.saveActionTitle, systemImage: "checkmark.circle.fill")
                        }
                        .tint(AppTheme.success)
                        .accessibilityIdentifier("mail.row.saveTodo")
                    }
                    .onAppear {
                        guard Self.shouldTriggerTopSync(
                            emailID: email.localListID,
                            firstEmailID: selectedEmails.first?.localListID,
                            authenticationState: authenticationState,
                            hasLoadedInitialPage: selectedPagingState.hasLoadedInitialPage,
                            hasProvider: selectedProvider != nil
                        ), let selectedProvider else { return }
                        Task {
                            await MailboxIncrementalSyncCoordinator.shared.sync(
                                provider: selectedProvider,
                                minimumInterval: MailboxPagingPolicy.updatesMinimumInterval
                            )
                        }
                    }
                }
                .onDelete(perform: deleteEmails)

                pageFooter(autoLoadsOlder: true)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func pageFooter(autoLoadsOlder: Bool) -> some View {
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
            if autoLoadsOlder {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .onAppear {
                        guard let selectedProvider else { return }
                        Task { await loadPage(for: selectedProvider, loadMore: true) }
                    }
                    .accessibilityIdentifier("mail.page.loadMore")
            } else {
                Button("이전 메일 더 불러오기") {
                    guard let selectedProvider else { return }
                    Task { await loadPage(for: selectedProvider, loadMore: true) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .accessibilityIdentifier("mail.page.loadMore")
            }
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

    private var authenticationCheckingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(AppLanguage.localized(
                "mail.authentication.checking",
                defaultValue: "연결·메일 조회 확인 중…",
                language: .current,
                comment: "Checking the IMAP connection and inbox message access."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLanguage.localized(
            "mail.authentication.checking.accessibility",
            defaultValue: "IMAP 연결과 메일 조회 확인 중",
            language: .current,
            comment: "Checking mail authentication accessibility label."
        ))
        .accessibilityIdentifier("mail.authentication.checking")
    }

    private var authenticationCheckingStatusRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(AppLanguage.localized(
                "mail.authentication.checking",
                defaultValue: "연결·메일 조회 확인 중…",
                language: .current,
                comment: "Checking the IMAP connection and inbox message access."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AppLanguage.localized(
            "mail.authentication.checking.accessibility",
            defaultValue: "IMAP 연결과 메일 조회 확인 중",
            language: .current,
            comment: "Checking mail authentication accessibility label."
        ))
        .accessibilityIdentifier("mail.authentication.checking")
    }

    private var notConnectedView: some View {
        ContentUnavailableView {
            Label(
                AppLanguage.localized("mail.notConnected.title", defaultValue: "메일 계정 미연결", language: .current, comment: "Mail account not connected title"),
                systemImage: "envelope.badge.shield.half.filled"
            )
        } description: {
            Text(AppLanguage.localized("mail.notConnected.description", defaultValue: "Gmail 또는 Outlook을 연결하면 받은편지함을 볼 수 있습니다.", language: .current, comment: "Mail account not connected description"))
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
                    showEmailSettingsSheet = true
                } label: {
                    Label(
                        AppLanguage.localized("mail.notConnected.outlookConnect", defaultValue: "Outlook IMAP 연결 설정", language: .current, comment: "Outlook connect button in empty state"),
                        systemImage: "envelope.circle.fill"
                    )
                }
            }
        }
    }

    private func mailboxHeaderText(for provider: MailProvider) -> String {
        let loadedCount = validCachedInboxEmails.filter { $0.provider == provider }.count
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
        switch provider {
        case .gmail:
            return "Gmail"
        case .outlook:
            return "Outlook"
        }
    }
    private func pagingProvider(for provider: MailProvider) -> any MailboxPagingProvider {
        MailboxProviderRegistry.provider(for: provider)
    }
    private func connectGmail() async {
        alertTitle = AppLanguage.localized(
            "mail.connection.gmail.imapRequired",
            defaultValue: "Gmail IMAP 연결 필요",
            language: .current,
            comment: "Gmail IMAP connection guidance."
        )
        errorMessage = AppLanguage.localized(
            "mail.connection.gmail.imapSettings",
            defaultValue: "설정의 이메일 연동에서 Gmail App Password로 IMAP을 연결하세요.",
            language: .current,
            comment: "Gmail IMAP settings guidance."
        )
        showError = true
    }


    @MainActor
    private func refreshSelectedMailbox(showSuccess: Bool) async {
        #if DEBUG
        if MailUITestFixture.isEnabled {
            return
        }
        #endif
        guard authenticationState == .resolved,
              mailAnalysisSyncGate.requestSync(),
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
            let page = try await pagingProvider(for: provider)
                .fetchInboxPage(after: cursor)
            try MailboxLocalStore.live.upsert(page, into: modelContext)
            try MailboxLocalStore.live.replayPendingMutations(in: modelContext)
            if !loadMore {
                MailboxIncrementalSyncCoordinator.shared.seedBaselineIfNeeded(for: provider, page: page)
            }
            viewState.completePage(for: provider, nextCursor: page.nextCursor)
            retryLoadMoreByProvider[provider] = nil
        } catch {
            viewState.failPage(for: provider, message: mailErrorMessage(error))
            retryLoadMoreByProvider[provider] = loadMore
        }
    }

    @MainActor
    private func reconcileInbox(for provider: MailProvider) async {
        guard viewState.beginIndex(for: provider) else { return }
        do {
            let activeIDs = try await pagingProvider(for: provider)
                .fetchInboxMessageIDs()
            try MailboxLocalStore.live.reconcileInbox(
                provider: provider,
                sourceAccountNamespace: activeMailboxNamespace(for: provider),
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

    private func activeMailboxNamespace(for provider: MailProvider) -> String {
        switch provider {
        case .gmail:
            let raw = UserDefaults.standard.string(forKey: "pieroot.todo.imap.account") ?? ""
            return IMAPCredentialStore.canonicalAccount(raw) ?? ""
        case .outlook:
            let raw = UserDefaults.standard.string(forKey: "pieroot.todo.outlook.account") ?? ""
            return OutlookIMAPCredentialStore.canonicalAccount(raw) ?? ""
        }
    }

    @MainActor
    private func analyzeInbox() async {
        guard authenticationState == .resolved,
              !mailAnalysisSyncGate.isAnalyzing,
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
                let content = try await pagingProvider(for: email.provider)
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
        try? await EmailMessageAnalysisService.shared.analyze(email, context: modelContext)
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
        do {
            let mutations = try MailboxLocalStore.live.stageTrash(targets, in: modelContext)
            let replacement = pendingTrashQueue.replaceUndoableBatch(
                with: targets,
                mutations: mutations
            )
            for superseded in replacement.superseded {
                trashUndoTasks.removeValue(forKey: superseded.id)?.cancel()
                Task { @MainActor in
                    await flushPendingTrash(superseded, now: .distantFuture)
                }
            }
            let batch = replacement.latest
            trashUndoTasks[batch.id] = Task { @MainActor [batchID = batch.id] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await commitPendingTrash(batchID: batchID)
            }
        } catch {
            let alert = mailDetailAlert(action: .trash, error: error)
            alertTitle = alert.title
            errorMessage = alert.message
            showError = true
        }
    }

    @MainActor
    private func cancelPendingTrash(batchID: UUID) {
        guard let batch = pendingTrashQueue.latestUndoableBatch,
              batch.id == batchID
        else {
            return
        }
        do {
            let restored = try MailboxLocalStore.live.restoreStagedTrash(
                batch.emails,
                mutations: batch.mutations,
                in: modelContext
            )
            if restored {
                trashUndoTasks.removeValue(forKey: batchID)?.cancel()
                _ = pendingTrashQueue.remove(id: batchID)
            } else if let committingBatch = pendingTrashQueue.beginCommit(id: batchID) {
                trashUndoTasks.removeValue(forKey: batchID)?.cancel()
                Task { @MainActor in
                    await flushPendingTrash(committingBatch)
                }
            }
        } catch {
            let alert = mailDetailAlert(action: .trash, error: error)
            alertTitle = alert.title
            errorMessage = alert.message
            showError = true
        }
    }

    @MainActor
    private func commitPendingTrash(batchID: UUID) async {
        guard let batch = pendingTrashQueue.beginCommit(id: batchID) else { return }
        trashUndoTasks[batchID] = nil
        await flushPendingTrash(batch)
    }

    @MainActor
    private func flushPendingTrash(
        _ batch: MailTrashUndoBatch,
        now: Date = Date()
    ) async {
        _ = await MailboxLocalStore.live.flushStagedTrash(
            batch.mutations,
            now: now
        ) { mutation in
            let providerKind = MailProvider(rawValue: mutation.providerRawValue) ?? .gmail
            let provider = pagingProvider(for: providerKind)
            do {
                try await provider.trashMessage(
                    messageID: mutation.providerMessageID,
                    expectedGlobalMessageID: mutation.expectedGlobalMessageID
                )
            } catch GmailIMAPError.credentialRejected {
                IMAPCredentialStore.markCredentialRejected(for: mutation.sourceAccountNamespace)
                throw GmailIMAPError.credentialRejected
        }
        }
        _ = pendingTrashQueue.remove(id: batch.id)
    }

    private static func validateGmailSession(
        account: String,
        backgroundEnabled: Bool
    ) async -> MailSessionValidation {
        guard !account.isEmpty else {
            return MailSessionValidation(isAuthenticated: false, hasStoredCredential: false)
        }
        do {
            try await GmailIMAPService.shared.validateConnection(
                email: account,
                backgroundEnabled: backgroundEnabled
            )
            return MailSessionValidation(isAuthenticated: true, hasStoredCredential: true)
        } catch {
            return MailSessionValidation(
                isAuthenticated: false,
                hasStoredCredential: MailCredentialFailurePolicy.hasStoredCredential(after: error)
            )
        }
    }

    private static func validateOutlookSession(
        account: String,
        backgroundEnabled: Bool
    ) async -> MailSessionValidation {
        guard !account.isEmpty else {
            return MailSessionValidation(isAuthenticated: false, hasStoredCredential: false)
        }
        do {
            try await OutlookIMAPService.shared.validateConnection(
                email: account,
                backgroundEnabled: backgroundEnabled
            )
            return MailSessionValidation(isAuthenticated: true, hasStoredCredential: true)
        } catch {
            return MailSessionValidation(
                isAuthenticated: false,
                hasStoredCredential: MailCredentialFailurePolicy.hasStoredCredential(after: error)
            )
        }
    }

    @MainActor
    private func validateAndUpdateAuthState(for provider: MailProvider) async {
        #if DEBUG
        if MailUITestFixture.isEnabled {
            isGmailAuthenticated = true
            isOutlookAuthenticated = true
            storedCredentialProviders = [.gmail, .outlook]
            authenticationState = .resolved
            reconcileSelectedProviderForCurrentState()
            return
        }
        #endif
        switch provider {
        case .gmail:
            let account = UserDefaults.standard.string(forKey: "pieroot.todo.imap.account") ?? ""
            let bg = UserDefaults.standard.bool(forKey: "pieroot.todo.imap.backgroundEnabled")
            let validation = await Self.validateGmailSession(account: account, backgroundEnabled: bg)
            isGmailAuthenticated = validation.isAuthenticated
            if validation.hasStoredCredential {
                storedCredentialProviders.insert(.gmail)
            } else {
                storedCredentialProviders.remove(.gmail)
            }
        case .outlook:
            let account = UserDefaults.standard.string(forKey: "pieroot.todo.outlook.account") ?? ""
            let bg = UserDefaults.standard.bool(forKey: "pieroot.todo.outlook.backgroundEnabled")
            let validation = await Self.validateOutlookSession(account: account, backgroundEnabled: bg)
            isOutlookAuthenticated = validation.isAuthenticated
            if validation.hasStoredCredential {
                storedCredentialProviders.insert(.outlook)
            } else {
                storedCredentialProviders.remove(.outlook)
            }
        }
        authenticationState = .resolved
        reconcileSelectedProviderForCurrentState()
    }

    @MainActor
    private func refreshAuthenticationState() async {
        await validateAndUpdateAuthState(for: .gmail)
        await validateAndUpdateAuthState(for: .outlook)
    }

    @MainActor
    private func reconcileAuthenticatedProvidersAndRefresh() {
        let previous = selectedProvider
        viewState.reconcileAuthenticatedProviders(authenticatedProviders)
        reconcileSelectedProviderForCurrentState()
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
                    Text(AppLanguage.localized(
                        "mail.category.guide.gmailSource",
                        defaultValue: "Gmail 검색의 카테고리(category:) 분류를 IMAP으로 조회해 그대로 사용합니다.",
                        language: .current,
                        comment: "Explains where Gmail inbox tab categories come from."
                    ))
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
            if email.analysisTodoCandidate == true {
                Label(
                    AppLanguage.localized(
                        "mail.analysis.layaCandidate",
                        defaultValue: "할 일 후보 · Laya",
                        language: .current,
                        comment: "Laya recommends reviewing this email as a to-do; no automatic save."
                    ),
                    systemImage: "checkmark.circle"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            }
            Text(email.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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


// MARK: - MailRegisterSheet

/// 스와이프에서 연 등록 시트가 동기화 중 병합·삭제된 행을 붙잡지 않도록
/// `MailDetailSelectionView`와 같은 방식으로 라이브 쿼리에서 메일을 다시 찾는다.
struct MailRegisterSelectionView: View {
    let selection: MailDetailSelection
    @Environment(\.dismiss) private var dismiss
    @Query private var candidates: [EmailMessage]

    init(selection: MailDetailSelection) {
        self.selection = selection
        _candidates = selection.liveQuery
    }

    var body: some View {
        if let email = MailDetailSelection.resolve(candidates, matching: selection.key) {
            MailRegisterSheet(email: email)
        } else {
            Color.clear
                .task(id: selection.id) {
                    dismiss()
                }
        }
    }
}

/// 메일을 확인한 뒤 할 일로 저장하는 검토 시트.
/// - 제목·메모: 사용 가능한 Apple Intelligence로 초안을 만들고, 아니면 로컬 규칙으로 대체한다.
/// - 기한: 메일 본문에서 규칙 기반으로 찾은 날짜만 제안하고, 사용자가 확인·수정한다.
///   찾지 못하면 기한을 꺼 둔 채 기한 없는 할 일로 저장한다(임의 날짜를 만들지 않는다).
/// - 캘린더: 이 시트는 사용자가 켠 경우에만, 기한이 있고 캘린더 접근이 허용된 때 즉시 일정을 만든다.
///   (기한 있는 할 일을 나중에 자동 등록하는 전역 동기화 정책은 별개다.)
///   Todo를 먼저 저장하고 일정을 나중에 만들어 Todo 저장 실패 시 고아 일정이 생기지 않게 한다.
///
/// ⚠️ 프라이버시 보장:
/// - 메일 본문은 온디바이스 규칙 기반으로만 분석한다.
/// - Todo는 AppDataContainer.shared.container(main)에 저장, 절대 emailContainer에 넣지 않음.
/// - 초안은 `EmailService.makeManualTodo(from:)` 기반으로 동일한 메타데이터 경로 사용.
struct MailRegisterSheet: View {
    let email: EmailMessage

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isAllDay = true
    @State private var isDueDateSuggested = false
    @State private var deadlineEvidence = ""
    @State private var addToCalendar = false
    @State private var isCalendarAuthorized = false
    @State private var isRequestingCalendarAccess = false
    @State private var calendarAccessDenied = false
    @State private var calendarID = ""
    @State private var calendarSources: [CalendarService.CalendarSourceGroup] = []
    @State private var sourceMessageID = ""
    @State private var sourceThreadID = ""
    @State private var sourceSender = ""
    @State private var sourceSenderEmail = ""
    @State private var isAnalyzing = true
    @State private var isDuplicate = false
    @State private var errorMessage: String?
    @State private var calendarWarning: String?

    private let cal = Calendar.current

    /// 메일 상세·목록 스와이프·시트 제목이 공유하는 단일 행동 문구.
    static var saveActionTitle: String {
        localized("mail.register.action", ko: "할 일로 저장", en: "Save as To-Do")
    }

    static func localized(_ key: String, ko: String, en: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: AppLanguage.current == .english ? en : ko,
            language: .current,
            comment: "Mail to-do review sheet."
        )
    }

    private var sourceRef: String { email.todoSourceRef }

    private var canSave: Bool {
        !isAnalyzing
            && !isDuplicate
            && !isRequestingCalendarAccess
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection

                if isAnalyzing {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("메일 내용 분석 중…")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    }
                } else if isDuplicate {
                    Section {
                        Label(
                            Self.localized("mail.register.duplicate", ko: "이미 등록된 메일입니다.", en: "This email is already registered."),
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mail.register.duplicate")
                    }
                } else {
                    taskSection
                    deadlineSection
                    if hasDueDate {
                        calendarSection
                    }
                    Section("메모") {
                        TextEditor(text: $notes)
                            .frame(minHeight: 80)
                            .font(.footnote)
                            .accessibilityIdentifier("mail.register.notes")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(AppTheme.destructive)
                    }
                }
            }
            .navigationTitle(Self.saveActionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                        .accessibilityIdentifier("mail.register.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("mail.register.save")
                }
            }
            .onChange(of: hasDueDate) { _, isOn in
                if !isOn { addToCalendar = false }
            }
            .alert(
                Self.localized("mail.register.savedTitle", ko: "할 일을 저장했어요", en: "To-Do Saved"),
                isPresented: Binding(
                    get: { calendarWarning != nil },
                    set: { if !$0 { calendarWarning = nil } }
                )
            ) {
                Button("확인") { dismiss() }
            } message: {
                Text(calendarWarning ?? "")
            }
        }
        .task {
            await prepare()
        }
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(email.subject.isEmpty ? Self.localized("(제목 없음)", ko: "(제목 없음)", en: "(No Title)") : email.subject)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(sourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Label(
                Self.localized("mail.register.sourceHeader", ko: "원본 메일", en: "Source Email"),
                systemImage: "envelope"
            )
        }
    }

    private var sourceLine: String {
        let analyzer = EmailContentAnalyzer()
        let sender = sourceSender.isEmpty ? analyzer.parseSender(from: email.from) : sourceSender
        let received = email.receivedAt.formatted(
            .dateTime.month(.abbreviated).day().hour().minute().locale(AppLanguage.current.locale)
        )
        return [sender.isEmpty ? email.from : sender, received]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var taskSection: some View {
        Section {
            TextField(
                Self.localized("mail.register.titlePlaceholder", ko: "할 일 제목", en: "To-do title"),
                text: $title,
                axis: .vertical
            )
            .font(.body.weight(.medium))
            .accessibilityIdentifier("mail.register.title")
        } header: {
            Text(Self.localized("mail.register.taskHeader", ko: "할 일", en: "To-Do"))
        }
    }

    private var deadlineSection: some View {
        Section {
            Toggle(isOn: $hasDueDate.animation()) {
                Text(Self.localized("mail.register.deadlineToggle", ko: "마감 설정", en: "Set Deadline"))
            }
            .accessibilityIdentifier("mail.register.deadlineToggle")

            if hasDueDate {
                Toggle("종일", isOn: $isAllDay)
                    .accessibilityIdentifier("mail.register.allDay")
                DatePicker(
                    "날짜",
                    selection: $dueDate,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                .accessibilityIdentifier("mail.register.deadlinePicker")
            }
        } header: {
            Text("마감")
        } footer: {
            if let footer = deadlineFooter {
                Text(footer)
            }
        }
    }

    private var deadlineFooter: String? {
        switch (isDueDateSuggested, hasDueDate) {
        case (true, true):
            let prompt = Self.localized(
                "mail.register.deadlineSuggested",
                ko: "메일에서 찾은 기한이에요. 맞는지 확인해 주세요.",
                en: "This deadline was found in the email. Please check it."
            )
            return deadlineEvidence.isEmpty ? prompt : "\(prompt)\n“\(deadlineEvidence)”"
        case (true, false):
            return Self.localized(
                "mail.register.deadlineOff",
                ko: "기한 없이 저장돼요.",
                en: "It will be saved without a deadline."
            )
        case (false, false):
            return Self.localized(
                "mail.register.deadlineNotFound",
                ko: "메일에서 기한을 찾지 못했어요. 기한 없이 저장돼요.",
                en: "No deadline was found in the email. It will be saved without one."
            )
        case (false, true):
            return nil
        }
    }

    private var calendarSection: some View {
        Section {
            Toggle(isOn: calendarToggleBinding) {
                Label(
                    Self.localized("mail.register.calendarToggle", ko: "지금 캘린더에도 추가", en: "Add to Calendar Now"),
                    systemImage: "calendar.badge.plus"
                )
            }
            .disabled(isRequestingCalendarAccess)
            .accessibilityIdentifier("mail.register.calendarToggle")

            if addToCalendar && isCalendarAuthorized && !calendarSources.isEmpty {
                Picker("캘린더 선택", selection: $calendarID) {
                    ForEach(calendarSources) { source in
                        ForEach(source.calendars) { info in
                            calendarLabel(info).tag(info.id)
                        }
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("mail.register.calendarPicker")
            }
        } footer: {
            Text(
                calendarAccessDenied
                    ? Self.localized(
                        "mail.register.calendarDenied",
                        ko: "캘린더 접근 권한이 없어 일정은 만들 수 없어요. 할 일은 그대로 저장돼요.",
                        en: "Calendar access is off, so no event can be added. The to-do will still be saved."
                    )
                    : Self.localized(
                        "mail.register.calendarLaterSync",
                        ko: "마감이 있으면 나중에 캘린더 동기화 과정에서 자동 등록될 수 있어요.",
                        en: "To-dos with deadlines may also be added during a later calendar sync."
                    )
            )
        }
    }

    private var calendarToggleBinding: Binding<Bool> {
        Binding(
            get: { addToCalendar },
            set: { isOn in
                guard isOn else {
                    addToCalendar = false
                    return
                }
                Task { await enableCalendar() }
            }
        )
    }

    // MARK: Loading

    @MainActor
    private func prepare() async {
        let service = CalendarService.shared
        service.restoreAuthorizationIfGranted()
        isCalendarAuthorized = service.isAuthorized
        if isCalendarAuthorized { loadCalendars() }

        if isAlreadyRegistered(in: ModelContext(AppDataContainer.shared.container)) {
            isDuplicate = true
            isAnalyzing = false
            return
        }
        await analyzeAndPrefill()
    }

    /// 사용자가 캘린더 추가를 켤 때만 권한을 확인·요청한다. 거부돼도 할 일 저장은 막지 않는다.
    @MainActor
    private func enableCalendar() async {
        let service = CalendarService.shared
        service.restoreAuthorizationIfGranted()
        if !service.isAuthorized {
            isRequestingCalendarAccess = true
            let granted = await service.requestAccess()
            isRequestingCalendarAccess = false
            guard granted else {
                isCalendarAuthorized = false
                calendarAccessDenied = true
                addToCalendar = false
                return
            }
        }
        isCalendarAuthorized = true
        calendarAccessDenied = false
        loadCalendars()
        addToCalendar = hasDueDate
    }

    private func loadCalendars() {
        calendarSources = CalendarService.shared.availableCalendars()
        let ids = Set(calendarSources.flatMap { $0.calendars.map(\.id) })
        guard !ids.contains(calendarID) else { return }
        let defaultID = CalendarService.shared.defaultCalendarID
        calendarID = ids.contains(defaultID)
            ? defaultID
            : (calendarSources.first?.calendars.first?.id ?? "")
    }

    @MainActor
    private func analyzeAndPrefill() async {
        if email.body.isEmpty && email.htmlBody == nil {
            do {
                let provider = MailboxProviderRegistry.provider(for: email.provider)
                let content = try await provider.fetchMessageContent(messageID: email.providerMessageID)
                try MailboxLocalStore.live.updateContent(
                    content,
                    for: email,
                    in: modelContext
                )
            } catch {
                guard !Task.isCancelled else { return }
                DiagnosticRecorder.shared.record(
                    error: error,
                    component: "mail.register",
                    operation: "fetchMessageContent"
                )
                errorMessage = Self.localized(
                    "mail.register.bodyLoadFailed",
                    ko: "메일 전체 본문을 불러오지 못해 미리보기로 초안을 만들었어요.",
                    en: "The full email couldn't be loaded, so the draft uses the preview."
                )
            }
        }

        let synthetic = GmailMessage(
            id: sourceRef,
            threadID: email.threadID,
            messageID: "",
            subject: email.subject,
            from: email.from,
            snippet: email.snippet,
            body: email.body,
            htmlBody: email.htmlBody,
            receivedAt: email.receivedAt,
            labelIds: [],
            isBulk: false,
            provider: email.provider,
            providerMessageID: email.providerMessageID,
            sourceAccountNamespace: email.sourceAccountNamespace
        )

        let draftTodo = await EmailService.shared.makeManualTodo(from: synthetic, allowFoundationModels: true)
        guard !Task.isCancelled else { return }
        let extracted = EmailContentAnalyzer().analyze(synthetic, now: Date())

        title = draftTodo.title
        notes = draftTodo.notes
        sourceMessageID = draftTodo.sourceMessageID
        sourceThreadID = draftTodo.sourceThreadID
        let analyzer = EmailContentAnalyzer()
        sourceSender = analyzer.parseSender(from: email.from)
        sourceSenderEmail = analyzer.parseSenderEmail(from: email.from)

        // 메일에서 실제로 찾은 날짜만 제안한다. 없으면 기한을 끈 채로 둔다.
        if let extracted {
            dueDate = extracted.dueDate
            isAllDay = extracted.isAllDay
            deadlineEvidence = extracted.deadlineSentence
                .trimmingCharacters(in: .whitespacesAndNewlines)
            isDueDateSuggested = true
        } else {
            // 사용자가 직접 마감을 켤 때 보이는 시작값일 뿐, 저장 값으로 쓰지 않는다.
            dueDate = endOfDay(Date())
            isAllDay = true
            isDueDateSuggested = false
        }
        hasDueDate = isDueDateSuggested
        isAnalyzing = false
    }

    // MARK: Saving

    private func isAlreadyRegistered(in context: ModelContext) -> Bool {
        let ref = sourceRef
        let descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate { $0.sourceRef == ref }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// 저장 순서: 중복 확인 → Todo 저장 → (선택 시) 일정 생성 → 일정 연결 저장.
    /// Todo 저장이 실패하면 일정은 만들지 않는다. 연결 저장이 실패해도 일정은 지우지 않는다:
    /// Todo가 이미 저장됐으므로 캘린더 동기화가 메일 URL로 일정을 다시 연결한다.
    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        errorMessage = nil

        let appContext = ModelContext(AppDataContainer.shared.container)
        guard !isAlreadyRegistered(in: appContext) else {
            isDuplicate = true
            return
        }

        let savedDueDate: Date? = hasDueDate
            ? (isAllDay ? endOfDay(dueDate) : dueDate)
            : nil
        let ref = sourceRef
        let analyzer = EmailContentAnalyzer()
        let todo = Todo(
            title: cleanTitle,
            notes: notes,
            dueDate: savedDueDate,
            source: .email,
            sourceRef: ref
        )
        todo.sourceAccountNamespace = email.sourceAccountNamespace
        todo.sourceSender = sourceSender.isEmpty ? analyzer.parseSender(from: email.from) : sourceSender
        todo.sourceSenderEmail = sourceSenderEmail.isEmpty ? analyzer.parseSenderEmail(from: email.from) : sourceSenderEmail
        todo.sourceMessageID = sourceMessageID
        todo.sourceThreadID = sourceThreadID

        do {
            appContext.insert(todo)
            TaskBehaviorRecorder.recordCreation(of: todo, actor: .user, in: appContext)
            try appContext.save()
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "mail.register",
                operation: "saveTodo"
            )
            errorMessage = Self.localized(
                "mail.todo.registerFailed",
                ko: "할 일 등록 실패",
                en: "To-Do Registration Failed"
            )
            return
        }
        EmailLearningStore.shared.recordAnalyzed(messageIDs: [ref])

        let service = CalendarService.shared
        guard addToCalendar, let savedDueDate, isCalendarAuthorized, service.isAuthorized else {
            dismiss()
            return
        }

        let eventStart: Date
        let eventEnd: Date
        if isAllDay {
            eventStart = cal.startOfDay(for: savedDueDate)
            eventEnd = cal.date(byAdding: .day, value: 1, to: eventStart) ?? eventStart.addingTimeInterval(86_400)
        } else {
            eventStart = savedDueDate
            eventEnd = savedDueDate.addingTimeInterval(3_600)
        }

        let eventID: String
        do {
            eventID = try service.createEventFromEmail(
                title: cleanTitle,
                start: eventStart,
                end: eventEnd,
                isAllDay: isAllDay,
                location: "",
                notes: notes,
                sourceRef: ref,
                calendarID: calendarID.isEmpty ? nil : calendarID
            )
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "mail.register",
                operation: "createEventFromEmail"
            )
            calendarWarning = calendarFailureMessage
            return
        }

        todo.calendarEventID = eventID.isEmpty ? nil : eventID
        do {
            try appContext.save()
            dismiss()
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "mail.register",
                operation: "linkCalendarEvent"
            )
            calendarWarning = Self.localized(
                "mail.register.calendarLinkPending",
                ko: "할 일과 일정은 저장했어요. 둘의 연결은 다음 캘린더 동기화 때 맞춰져요.",
                en: "The to-do and event were saved. They'll be linked during the next calendar sync."
            )
        }
    }

    private var calendarFailureMessage: String {
        Self.localized(
            "mail.register.calendarFailed",
            ko: "할 일은 저장했지만 캘린더 일정을 추가하지 못했어요.",
            en: "The to-do was saved, but the calendar event couldn't be added."
        )
    }

    private func endOfDay(_ date: Date) -> Date {
        cal.date(bySettingHour: 23, minute: 59, second: 0, of: date) ?? date
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
