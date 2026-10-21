import SwiftUI
import SwiftData
import CloudKit
import UserNotifications
import BackgroundTasks
import EventKit
import OSLog
import Combine


// MARK: - BGTask 식별자

private let kEmailRefreshTaskID = "pieroot.todo.emailRefresh"
private let backgroundTaskLogger = Logger(subsystem: "pieroot.todo", category: "BackgroundTasks")

/// Decides Mail-tab visibility solely from locally available account records.
/// Remote credential validation belongs to `MailTabView` after the tab renders.
func mailTabIsVisibleForStoredCredentials(
    uiTestShowsAllTabs: Bool,
    gmailAccount: String,
    outlookAccount: String = ""
) -> Bool {
    uiTestShowsAllTabs || !gmailAccount.isEmpty || !outlookAccount.isEmpty
}

private final class BGTaskCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false
    private let task: BGTask

    init(task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}


// MARK: - App Delegate

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var modelContext: ModelContext?
    private var emailRefreshTask: Task<Void, Never>?

    #if targetEnvironment(macCatalyst)
    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == UIMenuSystem.main else { return }

        let command = UIKeyCommand(
            title: AppLanguage.localized("settings.title", defaultValue: "설정", language: .current) + "…",
            action: #selector(openAppSettings(_:)),
            input: ",",
            modifierFlags: .command
        )
        let menu = UIMenu(title: "", identifier: .preferences, options: .displayInline, children: [command])
        if builder.menu(for: .preferences) != nil {
            builder.replace(menu: .preferences, with: menu)
        } else {
            builder.insertSibling(menu, afterMenu: .about)
        }
    }

    @objc private func openAppSettings(_ sender: UIKeyCommand) {
        NotificationCenter.default.post(name: .settingsRequested, object: nil)
    }
    #endif

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-test-seed-diagnostic-report") {
            DiagnosticRecorder.shared.setCollectionEnabled(true)
            DiagnosticRecorder.shared.record(
                error: NSError(
                    domain: "todo.UITestSeed",
                    code: 42,
                    userInfo: [NSLocalizedDescriptionKey: "seeded diagnostic"]
                ),
                component: "app.lifecycle",
                operation: "uiTestSeed"
            )
        }
        #endif
        DiagnosticEnvironment.setAppState("active")
        DiagnosticReportService.shared.configure()

        // Preview 모드에서는 BGTask 미지원 (Preview 컨테이너에 Info.plist 없음 → crash)
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        // 기본값 등록 (설정 전 첫 실행 시 bool/integer가 0/false 반환하는 것 방지)
        // emailAutoAnalysisEnabled=true: 기존 사용자 배경 메일→할일 동작 유지 (회귀 방지)
        UserDefaults.standard.register(defaults: [
            "pieroot.todo.emailRefreshHour": 7,
            "pieroot.todo.emailAutoAnalysisEnabled": true
        ])

        if !isPreview {
            let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: kEmailRefreshTaskID, using: nil) { task in
                guard let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    backgroundTaskLogger.error("Received unexpected BGTask type for \(kEmailRefreshTaskID, privacy: .public)")
                    return
                }
                Task { @MainActor in
                    self.beginEmailRefresh(task: refreshTask)
                }
            }
            if !didRegister {
                DiagnosticRecorder.shared.record(
                    error: DiagnosticFailure(code: 0, reason: "BGTask handler registration failed"),
                    component: "app.background",
                    operation: "registerTaskHandler"
                )
                backgroundTaskLogger.error("Failed to register BGTask handler for \(kEmailRefreshTaskID, privacy: .public)")
            }
        }

        // CloudKit 원격 알림 등록 (다른 디바이스 변경 시 silent push 수신)
        application.registerForRemoteNotifications()

        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // SwiftData+CloudKit이 자동으로 동기화를 처리하지만,
        // 이 메서드가 있어야 OS가 silent push를 앱에 전달한다.
        completionHandler(.newData)
    }

    // MARK: - BGAppRefreshTask 핸들러

    @MainActor
    private func beginEmailRefresh(task: BGAppRefreshTask) {
        emailRefreshTask?.cancel()
        emailRefreshTask = Task { @MainActor [weak self] in
            await self?.handleEmailRefresh(task: task)
        }
    }

    @MainActor
    private func handleEmailRefresh(task: BGAppRefreshTask) async {
        // 다음 폴링 예약 (현재 작업 완료 전에 예약해야 OS가 취소 시에도 재예약됨)
        scheduleEmailRefresh()
        let completion = BGTaskCompletionGate(task: task)
        defer { emailRefreshTask = nil }

        task.expirationHandler = { [weak self] in
            self?.emailRefreshTask?.cancel()
            completion.finish(success: false)
        }

        guard let ctx = modelContext else {
            completion.finish(success: false)
            return
        }

        let success = await fetchEmailTodos(context: ctx)
        completion.finish(success: success && !Task.isCancelled)
    }



    // MARK: - 이메일 fetch + todo 삽입 (공통)

    @MainActor @discardableResult
    private func fetchEmailTodos(context: ModelContext) async -> Bool {
        let metadataOK = await MailboxIncrementalSyncCoordinator.shared.syncAvailableProviders(backgroundOnly: true)
        guard !Task.isCancelled else { return false }

        // 메일 자동 분석 토글 — 배경(BGTask) 경로 독립 게이트 (마스터 onDeviceLLMEnabled와 무관)
        // register(defaults:)로 기본값 true 보장 → 기존 사용자 동작 그대로 유지
        guard UserDefaults.standard.bool(forKey: "pieroot.todo.emailAutoAnalysisEnabled") else { return metadataOK }

        let imapAccount = UserDefaults.standard.string(forKey: "pieroot.todo.imap.account") ?? ""
        let imapBackgroundEnabled = UserDefaults.standard.bool(forKey: "pieroot.todo.imap.backgroundEnabled")
        guard !Task.isCancelled else { return false }
        guard !imapAccount.isEmpty,
              imapBackgroundEnabled,
              IMAPCredentialStore.hasCredential(for: imapAccount),
              !IMAPCredentialStore.isCredentialRejected(for: imapAccount)
        else { return metadataOK }

        var didSucceed = false
        var failures: [String] = []

        if !imapAccount.isEmpty && imapBackgroundEnabled {
            do {
                let emailContext = ModelContext(AppDataContainer.shared.emailContainer)
                _ = try await GmailIMAPIngestionService(emailContext: emailContext)
                    .sync(account: imapAccount, backgroundEnabled: true)
                didSucceed = true
            } catch {
                DiagnosticRecorder.shared.record(
                    error: error,
                    component: "mail.gmail",
                    operation: "backgroundFetch"
                )
                if case GmailIMAPError.credentialRejected = error {
                    IMAPCredentialStore.markCredentialRejected(for: imapAccount)
                }
                print("[GmailIMAP] background fetch failed: \(error.localizedDescription)")
                failures.append("gmail-imap")
            }
        }

        if didSucceed { return true }
        return (failures.isEmpty == false ? false : didSucceed) || metadataOK
    }

    // MARK: - Foreground 알림 표시

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}

// MARK: - BGTask 스케줄링

/// 다음 이메일 폴링을 BGTaskScheduler에 예약.
/// OS best-effort: `earliestBeginDate`를 다음 설정 시각으로 지정하지만
/// 실제 실행 시각은 OS가 배터리·네트워크 상황에 따라 결정.
@MainActor
func scheduleEmailRefresh() {
#if targetEnvironment(simulator)
    backgroundTaskLogger.debug("Skipping email refresh BGTask scheduling on Simulator")
    return
#else
    guard UIApplication.shared.backgroundRefreshStatus == .available else {
        backgroundTaskLogger.debug("Skipping email refresh BGTask scheduling because background refresh is unavailable")
        return
    }

    let hour = UserDefaults.standard.integer(forKey: "pieroot.todo.emailRefreshHour")
    let earliestBeginDate = nextEmailRefreshDate(hour: hour > 0 ? hour : 7)
    DispatchQueue.global(qos: .utility).async {
        let request = BGAppRefreshTaskRequest(identifier: kEmailRefreshTaskID)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "app.background",
                operation: "scheduleEmailRefresh"
            )
            backgroundTaskLogger.error("Failed to schedule email refresh BGTask: \(error.localizedDescription, privacy: .public)")
        }
    }
#endif
}

/// 설정된 시(hour)의 다음 발생 시각을 반환.
/// 오늘 해당 시각이 아직 남아 있으면 오늘, 이미 지났으면 내일 반환.
func nextEmailRefreshDate(hour: Int) -> Date {
    let cal = Calendar.current
    var comps = cal.dateComponents([.year, .month, .day], from: Date())
    comps.hour = max(0, min(23, hour))
    comps.minute = 0
    comps.second = 0
    let todayTarget = cal.date(from: comps) ?? Date(timeIntervalSinceNow: 3600)
    if todayTarget > Date() { return todayTarget }
    return cal.date(byAdding: .day, value: 1, to: todayTarget) ?? Date(timeIntervalSinceNow: 86400)
}


// MARK: - App Entry Point

@main
struct todoApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// iCloud 동기화 설정 키.
    static let iCloudSyncKey = "pieroot.todo.iCloudSyncEnabled"

    /// Canonical local storage; retrying persistence can replace the container,
    /// while iCloud preference changes never switch the visible data set.
    @StateObject private var appData: AppDataContainer

    /// iCloud 동기화 모니터 — 앱 레벨로 승격하여 어느 탭에서든 알림 수신.
    @StateObject private var syncMonitor = CloudSyncMonitor()
    @StateObject private var unexpectedTerminationRecovery = UnexpectedTerminationRecoveryService.shared

    /// 선택된 탭 (lastUsed 복원용).
    @AppStorage("pieroot.todo.selectedTab") private var selectedTab = 0
    @AppStorage("pieroot.todo.hasOnboarded") private var hasOnboarded = false
    @AppStorage("pieroot.todo.hasReviewedPermissions") private var hasReviewedPermissions = false
    @AppStorage("pieroot.todo.hasCompletedTutorial") private var hasCompletedTutorial = false

    /// 시작 화면 정책: "lastUsed"(마지막 화면) | "fixed"(고정 탭)
    @AppStorage("pieroot.todo.launchBehavior") private var launchBehavior = "lastUsed"

    /// 고정 탭 인덱스 (launchBehavior == "fixed" 일 때 사용)
    @AppStorage("pieroot.todo.launchTab") private var launchTab = 0
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage(UserCloudSyncPolicy.consentKey) private var fullCloudConsentVersion = 0
    @StateObject private var tutorial = AppTutorialState()
    @StateObject private var appUpdate = AppUpdateService()
    @State private var tabVisibility = AppTabVisibility(calendarVisible: false, mailVisible: false)
    @State private var mailAccessPolicy = MailboxCachedProviderAccess.current()
    @State private var appLanguage = AppLanguage.current
    #if !targetEnvironment(macCatalyst)
    @State private var showSettings = false
    @State private var replayTutorialAfterSettingsDismiss = false
    #endif
    private let vocabularyDependencies: UserVocabularyDependencies
    private let vocabularyEnrichmentQueue: VocabularyEnrichmentQueue
    private var uiTestShowsAllTabs: Bool {
        ProcessInfo.processInfo.arguments.contains("-pieroot.todo.uiTestShowAllTabs")
    }

    /// True only under the DEBUG mail UI-test fixture. Suppresses every live
    /// IMAP/Graph auth attempt (foreground poll + background automation) so the
    /// fixture's seeded rows render deterministically without network access.
    private var uiTestSkipsLiveMailSync: Bool {
        #if DEBUG
        MailUITestFixture.isEnabled
        #else
        false
        #endif
    }

    // MARK: - 페르소나 중복 제거 (PersonaSettingsView에서도 참조)

    static func deduplicatePersonas(context: ModelContext) {
        do {
            let descriptor = FetchDescriptor<Persona>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            let personas = try context.fetch(descriptor)
            guard personas.count > 1 else { return }

            print("[Deduplication] \(personas.count)개의 페르소나가 발견되어 중복을 제거합니다.")

            let targetToKeep = personas.first(where: { !$0.descriptionText.isEmpty || !$0.personaTypeRaw.isEmpty }) ?? personas.first

            if let keep = targetToKeep {
                for persona in personas where persona.id != keep.id {
                    context.delete(persona)
                }
                try context.save()
            }
        } catch {
            print("[Deduplication] 페르소나 중복 제거 중 오류 발생: \(error)")
        }
    }

    // MARK: - 캘린더 할 일 중복 제거 (기기 간 동기화 불일치 복구)

    static func deduplicateCalendarTodos(context: ModelContext) {
        do {
            let descriptor = FetchDescriptor<Todo>()
            let allTodos = try context.fetch(descriptor)
            let todos = allTodos.filter { $0.todoSource == .calendar }
            guard todos.count > 1 else { return }

            var seenKeys: [String: Todo] = [:]
            var duplicatesToDelete: [Todo] = []

            for todo in todos {
                // A shared UID is not a shared task across distinct calendars.
                // Unknown unlinked legacy rows lack evidence for safe deletion.
                let sourceKind: String
                let sourceIdentity: String
                if !todo.calendarSourceID.isEmpty {
                    sourceKind = "calendar"
                    sourceIdentity = todo.calendarSourceID
                } else if let localID = todo.calendarEventID, !localID.isEmpty {
                    sourceKind = "event"
                    sourceIdentity = localID
                } else {
                    continue
                }
                let timeKey: String
                if let due = todo.dueDate {
                    timeKey = String(Int(due.timeIntervalSince1970 / 60))
                } else {
                    timeKey = "nodue"
                }

                let primaryKey: String
                if !todo.calendarEventExternalID.isEmpty {
                    primaryKey = "\(sourceKind):\(sourceIdentity)#ext:\(todo.calendarEventExternalID)#\(timeKey)"
                } else {
                    primaryKey = "\(sourceKind):\(sourceIdentity)#title:\(todo.title.trimmingCharacters(in: .whitespaces))#\(timeKey)"
                }

                if let existing = seenKeys[primaryKey] {
                    let keepExisting: Bool
                    if existing.isCompleted && !todo.isCompleted {
                        keepExisting = true
                    } else if !existing.isCompleted && todo.isCompleted {
                        keepExisting = false
                    } else if existing.triage == TodoTriage.todo && todo.triage == TodoTriage.review {
                        keepExisting = true
                    } else if existing.triage == TodoTriage.review && todo.triage == TodoTriage.todo {
                        keepExisting = false
                    } else {
                        keepExisting = existing.createdAt <= todo.createdAt
                    }

                    if keepExisting {
                        duplicatesToDelete.append(todo)
                    } else {
                        duplicatesToDelete.append(existing)
                        seenKeys[primaryKey] = todo
                    }
                } else {
                    seenKeys[primaryKey] = todo
                }
            }

            if !duplicatesToDelete.isEmpty {
                print("[Deduplication] \(duplicatesToDelete.count)개의 중복 캘린더 할 일을 정리합니다.")
                for dup in duplicatesToDelete {
                    context.delete(dup)
                }
                try context.save()
            }
        } catch {
            print("[Deduplication] 캘린더 할 일 중복 제거 중 오류: \(error)")
        }
    }

    // MARK: - Init

    init() {
        #if DEBUG
        let launchArguments = ProcessInfo.processInfo.arguments
        if launchArguments.contains("-ui-test-reset-beta") {
            SettingsStore.shared.resetBetaFeaturesForUITest()
        }
        if launchArguments.contains("-ui-test-seed-legacy-ai") {
            SettingsStore.shared.seedLegacyAISettingsForUITest()
        }
        #endif
        OpenAIRegionalAvailability.shared.start(onRestriction: {
            OpenAIConnection.shared.suspendForRegionalRestriction()
        })
        do { try RemovedProviderCleanup.run() }
        catch {
            DiagnosticRecorder.shared.record(error: error, component: "security.keychain", operation: "removedProviderCleanup")
        }
        SettingsStore.shared.migrateLegacyBetaSelectedProviderIfNeeded()
        SettingsStore.shared.normalizeBetaSelectedProvider()
        let container = AppDataContainer()
        _appData = StateObject(wrappedValue: container)
        #if DEBUG
        MailUITestFixture.seedIfNeeded(into: container.emailContainer)
        MeetingSourceTrackSmokeFixture.seedIfNeeded(into: container.meetingContainer)
        #endif
        let service = UserVocabularyService(modelContainer: container.meetingContainer)
        FullCloudSyncService.shared.configure(vocabulary: service)
        let queue = VocabularyEnrichmentQueue(service: service)
        vocabularyEnrichmentQueue = queue
        vocabularyDependencies = UserVocabularyDependencies(
            service: service,
            observer: .live(service: service, enqueue: { request in
                await queue.enqueue(request)
            })
        )
    }

    @ViewBuilder
    private var todoTab: some View {
        let searchMailAccess: MailboxCachedProviderAccess? = tabVisibility.mailVisible && mailAccessPolicy.hasActiveProvider
            ? mailAccessPolicy
            : nil
        TodoListView(
            globalSearchAppContainer: appData.container,
            globalSearchEmailContainer: appData.emailContainer,
            globalSearchMeetingContainer: appData.meetingContainer,
            globalSearchMailAccess: searchMailAccess
        )
        .tabItem { Label("할 일", systemImage: "checklist") }
        .tag(AppTabID.todo.rawValue)
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            if appData.isPersistentStoreAvailable {
            if !hasOnboarded && !hasReviewedPermissions {
                FirstLaunchPermissionsView {
                    hasReviewedPermissions = true
                }
                .environment(\.locale, appLanguage.locale)
            } else {
            // 캘린더 탭(tag 1) 재탭 시 오늘로 이동하는 커스텀 바인딩
            let tabBinding = Binding<Int>(
                get: { tabVisibility.clamped(selectedTab) },
                set: { newTab in
                    let clamped = tabVisibility.clamped(newTab)
                    if tabVisibility.calendarVisible
                        && clamped == AppTabID.calendar.rawValue
                        && selectedTab == AppTabID.calendar.rawValue {
                        NotificationCenter.default.post(name: .calendarScrollToToday, object: nil)
                    }
                    selectedTab = clamped
                    tutorial.handleTabSelection(clamped)
                }
            )
            VStack(spacing: 0) {
            TabView(selection: tabBinding) {
                todoTab

                if tabVisibility.calendarVisible {
                    CalendarTabView()
                        .tabItem { Label("캘린더", systemImage: "calendar") }
                        .tag(AppTabID.calendar.rawValue)
                }

                if tabVisibility.mailVisible {
                    MailTabView()
                        .modelContainer(appData.emailContainer)
                        .tabItem { Label("메일", systemImage: "envelope") }
                        .tag(AppTabID.mail.rawValue)
                }

                MeetingView()
                    .modelContainer(appData.meetingContainer)
                    .tabItem { Label("회의", systemImage: "person.2.wave.2") }
                    .tag(AppTabID.meeting.rawValue)
            }
            .disableTabBarMinimization()
            #if !targetEnvironment(macCatalyst)
                BannerAdStrip(isEligible: hasOnboarded && hasCompletedTutorial && !tutorial.isActive && scenePhase == .active)
            #endif
            }
            #if targetEnvironment(macCatalyst)
            .modifier(CatalystSettingsPresenter())
            #else
            .sheet(isPresented: $showSettings, onDismiss: {
                guard replayTutorialAfterSettingsDismiss else { return }
                replayTutorialAfterSettingsDismiss = false
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .appTutorialRequested, object: nil)
                }
            }) {
                NavigationStack { PersonaSettingsView() }
            }
            #endif
            .environment(\.locale, appLanguage.locale)
            .appScreenStyle()
            .tint(AppTheme.accent)
            .environmentObject(syncMonitor)
            .environmentObject(appUpdate)
            .environment(\.appTutorialState, tutorial)
            .environment(\.userVocabulary, vocabularyDependencies)
            .task(id: scenePhase) {
                guard scenePhase == .active else {
                    HealthRoutineStore.shared.cancelRefresh()
                    return
                }
                // No permission prompt here: only explicitly connected categories are queried.
                await HealthRoutineStore.shared.refresh(context: appData.container.mainContext)
            }
            .onAppear {
                OpenAIConnection.shared.refreshCredentials()
                FullCloudSyncService.shared.enterForeground()
                mailAccessPolicy = MailboxCachedProviderAccess.current()
                SettingsStore.shared.migrateLegacyMemoryKeysIntoSwiftDataIfNeeded()

                let ctx = appData.container.mainContext
                appDelegate.modelContext = ctx
                todoApp.deduplicatePersonas(context: ctx)
                todoApp.deduplicateCalendarTodos(context: ctx)

                CalendarService.shared.restoreAuthorizationIfGranted()
                unexpectedTerminationRecovery.enterForeground()
                Task {
                    await refreshTabVisibility()
                    if launchBehavior == "fixed" {
                        selectedTab = launchTab
                    }
                    if hasOnboarded && !hasCompletedTutorial {
                        selectedTab = AppTabID.todo.rawValue
                        tutorial.start(tabVisibility: tabVisibility)
                    }
                    await appUpdate.refreshIfNeeded()
                }
                scheduleEmailRefresh()

                // 어느 탭이든 앱 실행 시 iCloud 동기화 시작
                if SettingsStore.supportsICloud && iCloudSyncEnabled {
                    syncMonitor.startObserving(initialCount: 0)
                }

                // Cold launches do not trigger the .active scene-phase transition.
                if !uiTestSkipsLiveMailSync {
                    Task {
                        await EmailAutomationOrchestrator.shared.runIfEligible(context: ctx)
                    }
                    MailboxIncrementalSyncCoordinator.shared.startPolling()
                }
                Task {
                    if UserCloudSyncPolicy.isRequested, !(await syncMonitor.waitForCompletion()) { return }
                    await CalendarService.shared.runWeeklyImportIfDue(context: ctx)
                }
                Task {
                    // iCloud 동기화가 진행 중이면 완료 후 캘린더 동기화
                    // (iCloud에 먼저 도착한 캘린더 이벤트를 Todo 없는 신규로 오인하는 경쟁 조건 방지)
                    if UserCloudSyncPolicy.isRequested, !(await syncMonitor.waitForCompletion()) { return }
                    await CalendarService.shared.syncCalendarWithTodos(context: ctx)
                    await CalendarService.shared.cleanupOldCompletedTodos(context: ctx)
                }
            }
            .onChange(of: appData.rebuildID) { _, _ in
                // Refresh the delegate after a successful local persistence retry.
                appDelegate.modelContext = appData.container.mainContext
                todoApp.deduplicatePersonas(context: appData.container.mainContext)
                todoApp.deduplicateCalendarTodos(context: appData.container.mainContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)
                .debounce(for: .milliseconds(150), scheduler: RunLoop.main)) { _ in
                if let ctx = appDelegate.modelContext {
                    Task {
                        if UserCloudSyncPolicy.isRequested, !(await syncMonitor.waitForCompletion()) { return }
                        await CalendarService.shared.syncCalendarWithTodos(context: ctx)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .calendarTaskAnalysisSourcesChanged)) { _ in
                Task {
                    if UserCloudSyncPolicy.isRequested, !(await syncMonitor.waitForCompletion()) { return }
                    guard let ctx = appDelegate.modelContext else { return }
                    // Apply source consent immediately, without the weekly cooldown
                    // or the outbound export side effects of a full two-way sync.
                    await CalendarService.shared.syncCalendarTodos(context: ctx)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .gmailAuthChanged)) { _ in
                mailAccessPolicy = MailboxCachedProviderAccess.current()
                Task { await refreshTabVisibility() }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("pieroot.todo.outlookAuthChanged"))) { _ in
                mailAccessPolicy = MailboxCachedProviderAccess.current()
                Task { await refreshTabVisibility() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .calendarAuthorizationChanged)) { _ in
                Task { await refreshTabVisibility() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .appTutorialRequested)) { _ in
                selectedTab = AppTabID.todo.rawValue
                tutorial.start(tabVisibility: tabVisibility)
                Task {
                    await refreshTabVisibility()
                    tutorial.updateTabVisibility(tabVisibility)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
                appLanguage = AppLanguage.current
                #if targetEnvironment(macCatalyst)
                UIMenuSystem.main.setNeedsRebuild()
                #endif
            }
            #if !targetEnvironment(macCatalyst)
            .onReceive(NotificationCenter.default.publisher(for: .settingsRequested)) { _ in
                showSettings = true
            }
            #endif
            .onReceive(NotificationCenter.default.publisher(for: .settingsDismissRequested)) { _ in
                #if !targetEnvironment(macCatalyst)
                replayTutorialAfterSettingsDismiss = true
                showSettings = false
                #endif
                Task { await refreshTabVisibility() }
                mailAccessPolicy = MailboxCachedProviderAccess.current()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserCloudSyncPolicy.didRestoreNotification)) { _ in
                OpenAIConnection.shared.refreshCredentials()
                mailAccessPolicy = MailboxCachedProviderAccess.current()
                Task { await refreshTabVisibility() }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                unexpectedTerminationRecovery.enterBackground()
                FullCloudSyncService.shared.enterBackground()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                unexpectedTerminationRecovery.enterInactive()
            }
            .onChange(of: iCloudSyncEnabled && fullCloudConsentVersion == UserCloudSyncPolicy.consentVersion) { _, _ in
                OpenAIConnection.shared.refreshCredentials()
                if UserCloudSyncPolicy.isRequested {
                    FullCloudSyncService.shared.enterForeground()
                    syncMonitor.startObserving(initialCount: 0)
                } else {
                    FullCloudSyncService.shared.stop()
                    syncMonitor.stopObserving()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    Task { await OpenAIRegionalAvailability.shared.refresh() }
                    OpenAIConnection.shared.refreshCredentials()
                    FullCloudSyncService.shared.enterForeground()
                    DiagnosticEnvironment.setAppState("active")
                    unexpectedTerminationRecovery.enterForeground()
                    mailAccessPolicy = MailboxCachedProviderAccess.current()
                    // 포그라운드 전환 시에도 동기화 시작 (탭 무관)
                    if SettingsStore.supportsICloud && iCloudSyncEnabled {
                        syncMonitor.startObserving(initialCount: 0)
                    }
                    Task {
                        await refreshTabVisibility()
                        if launchBehavior == "fixed" {
                            selectedTab = launchTab
                        }
                        await appUpdate.refreshIfNeeded()
                    }
                    if let ctx = appDelegate.modelContext {
                        if !uiTestSkipsLiveMailSync {
                            Task {
                                await EmailAutomationOrchestrator.shared.runIfEligible(context: ctx)
                            }
                        }
                        Task {
                            if UserCloudSyncPolicy.isRequested, !(await syncMonitor.waitForCompletion()) { return }
                            await CalendarService.shared.runWeeklyImportIfDue(context: ctx)
                        }
                        Task {
                            if UserCloudSyncPolicy.isRequested, !(await syncMonitor.waitForCompletion()) { return }
                            await CalendarService.shared.syncCalendarWithTodos(context: ctx)
                            await CalendarService.shared.cleanupOldCompletedTodos(context: ctx)
                        }
                    }
                    if !uiTestSkipsLiveMailSync {
                        MailboxIncrementalSyncCoordinator.shared.startPolling()
                    }
                case .background:
                    // Persist the normal lifecycle transition before potentially
                    // expensive MLX teardown. A suspend watchdog must not be shown
                    // as an unexpected *foreground* termination next launch.
                    unexpectedTerminationRecovery.enterBackground()
                    FullCloudSyncService.shared.enterBackground()
                    DiagnosticEnvironment.setAppState("background")
                    OnDeviceLLMService.shared.unloadModel(reason: .background)
                    MailboxIncrementalSyncCoordinator.shared.stopPolling()
                case .inactive:
                    // Inactive is a normal user or system interruption, not
                    // evidence of an active-session crash.
                    unexpectedTerminationRecovery.enterInactive()
                    DiagnosticEnvironment.setAppState("inactive")
                    MailboxIncrementalSyncCoordinator.shared.stopPolling()
                default:
                    break
                }
            }
            .overlay {
                AppTutorialView(
                    selectedTab: $selectedTab,
                    tabVisibility: tabVisibility
                )
            }
            .sheet(item: $unexpectedTerminationRecovery.pendingPrompt) { prompt in
                NavigationStack {
                    DiagnosticReportView(
                        pendingError: prompt.error,
                        component: "app.lifecycle",
                        operation: "unexpectedForegroundTermination",
                        showsCloseButton: true
                    )
                }
            }
            // Keep labels leading and controls trailing, including in Catalyst forms and sheets.
            .toggleStyle(.switch)
            }
            } else {
                ContentUnavailableView {
                    Label(
                        AppLanguage.localized("app.storage.unavailable", defaultValue: "Storage unavailable", language: appLanguage, comment: "Startup persistent storage failure title."),
                        systemImage: "externaldrive.badge.exclamationmark"
                    )
                } description: {
                    Text(AppLanguage.localized("app.storage.preserved", defaultValue: "Your original data has been preserved. Unlock the device and try again. No changes will be saved until storage is available.", language: appLanguage, comment: "Startup failure message; original user data is unchanged."))
                } actions: {
                    Button(AppLanguage.localized("action.retry", defaultValue: "Try again", language: appLanguage)) {
                        appData.rebuild()
                    }
                }
            }
        }
        .modelContainer(appData.container)
        #if targetEnvironment(macCatalyst)
        WindowGroup(
            Text(AppLanguage.localized("settings.title", defaultValue: "설정", language: appLanguage)),
            id: CatalystSettingsWindowID.sceneID,
            for: CatalystSettingsWindowID.self
        ) { _ in
            CatalystSettingsWindowContent()
                .modelContainer(appData.container)
                .appScreenStyle()
                .tint(AppTheme.accent)
                .toggleStyle(.switch)
                .environmentObject(syncMonitor)
                .environmentObject(appUpdate)
                .environment(\.appTutorialState, tutorial)
                .environment(\.userVocabulary, vocabularyDependencies)
        } defaultValue: {
            .settings
        }
        #endif

    }


    @MainActor
    private func refreshTabVisibility() async {
        CalendarService.shared.restoreAuthorizationIfGranted()
        let calendarVisible = uiTestShowsAllTabs || CalendarService.shared.isAuthorized
        let mailVisible = mailTabIsVisibleForStoredCredentials(
            uiTestShowsAllTabs: uiTestShowsAllTabs,
            gmailAccount: UserDefaults.standard.string(forKey: "pieroot.todo.imap.account") ?? "",
            outlookAccount: UserDefaults.standard.string(forKey: "pieroot.todo.outlook.account") ?? ""
        )
        tabVisibility = AppTabVisibility(calendarVisible: calendarVisible, mailVisible: mailVisible)
        selectedTab = tabVisibility.clamped(selectedTab)
        launchTab = tabVisibility.clamped(launchTab)
    }

}
