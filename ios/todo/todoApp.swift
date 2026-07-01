import SwiftUI
import SwiftData
import CloudKit
import UserNotifications
import BackgroundTasks
import EventKit
import MSAL

// MARK: - BGTask 식별자

private let kEmailRefreshTaskID  = "pieroot.todo.emailRefresh"
private let kMemoryAnalysisTaskID = "pieroot.todo.memoryAnalysis"


// MARK: - App Delegate

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    // 무음 푸시가 들어왔을 때 fetch한 새 todo를 SwiftData에 삽입하기 위한 컨텍스트.
    // todoApp에서 설정됨.
    var modelContext: ModelContext?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self

        // Preview 모드에서는 BGTask 미지원 (Preview 컨테이너에 Info.plist 없음 → crash)
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        // 기본값 등록 (설정 전 첫 실행 시 bool/integer가 0/false 반환하는 것 방지)
        // emailAutoAnalysisEnabled=true: 기존 사용자 배경 메일→할일 동작 유지 (회귀 방지)
        UserDefaults.standard.register(defaults: [
            "pieroot.todo.emailRefreshHour": 7,
            "pieroot.todo.emailAutoAnalysisEnabled": true
        ])

        if !isPreview {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: kEmailRefreshTaskID, using: nil) { task in
                Task { await self.handleEmailRefresh(task: task as! BGAppRefreshTask) }
            }
            BGTaskScheduler.shared.register(forTaskWithIdentifier: kMemoryAnalysisTaskID, using: nil) { task in
                Task { await self.handleMemoryAnalysis(task: task as! BGProcessingTask) }
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
    private func handleEmailRefresh(task: BGAppRefreshTask) async {
        // 다음 폴링 예약 (현재 작업 완료 전에 예약해야 OS가 취소 시에도 재예약됨)
        scheduleEmailRefresh()

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        guard let ctx = modelContext else {
            task.setTaskCompleted(success: false)
            return
        }

        let success = await fetchEmailTodos(context: ctx)
        task.setTaskCompleted(success: success)
    }

    // MARK: - BGProcessingTask: 메모리 분석 (2일+ 간격)

    @MainActor
    private func handleMemoryAnalysis(task: BGProcessingTask) async {
        scheduleMemoryAnalysis()

        task.expirationHandler = { task.setTaskCompleted(success: false) }

        guard let ctx = modelContext else {
            task.setTaskCompleted(success: false)
            return
        }
        let todos = (try? ctx.fetch(FetchDescriptor<Todo>())) ?? []
        MemoryService.shared.analyze(todos: todos)
        task.setTaskCompleted(success: true)
    }

    // MARK: - 이메일 fetch + todo 삽입 (공통)

    @MainActor @discardableResult
    private func fetchEmailTodos(context: ModelContext) async -> Bool {
        // 메일 자동 분석 토글 — 배경(BGTask) 경로 독립 게이트 (마스터 onDeviceLLMEnabled와 무관)
        // register(defaults:)로 기본값 true 보장 → 기존 사용자 동작 그대로 유지
        guard UserDefaults.standard.bool(forKey: "pieroot.todo.emailAutoAnalysisEnabled") else { return false }

        let gmailAuthenticated = EmailService.shared.isAuthenticated
        let outlookAuthenticated = await OutlookMailService.shared.canAccessMailSilently()
        guard gmailAuthenticated || outlookAuthenticated else { return false }

        var didSucceed = false
        var failures: [String] = []

        if gmailAuthenticated {
            do {
                _ = try await EmailService.shared.fetchAndStoreExtractedItems(
                    context: context,
                    allowFoundationModels: false
                )
                didSucceed = true
            } catch {
                print("[EmailService] fetch 실패: \(error.localizedDescription)")
                failures.append("gmail")
            }
        }

        if outlookAuthenticated {
            do {
                _ = try await OutlookMailService.shared.fetchAndStoreExtractedItems(
                    context: context,
                    allowFoundationModels: false
                )
                didSucceed = true
            } catch {
                print("[OutlookMailService] fetch 실패: \(error.localizedDescription)")
                failures.append("outlook")
            }
        }

        if didSucceed { return true }
        return failures.isEmpty == false ? false : didSucceed
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
func scheduleEmailRefresh() {
    let hour = UserDefaults.standard.integer(forKey: "pieroot.todo.emailRefreshHour")
    let request = BGAppRefreshTaskRequest(identifier: kEmailRefreshTaskID)
    request.earliestBeginDate = nextEmailRefreshDate(hour: hour > 0 ? hour : 7)
    try? BGTaskScheduler.shared.submit(request)
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

func scheduleMemoryAnalysis() {
    let request = BGProcessingTaskRequest(identifier: kMemoryAnalysisTaskID)
    request.requiresNetworkConnectivity = false
    request.requiresExternalPower = false
    request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 24 * 3600)  // 최소 2일 후
    try? BGTaskScheduler.shared.submit(request)
}

// MARK: - App Entry Point

@main
struct todoApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    /// iCloud 동기화 설정 키.
    static let iCloudSyncKey = "pieroot.todo.iCloudSyncEnabled"

    /// swappable 컨테이너 홀더 — iCloud 동기화 전환 시 재시작 없이 교체.
    /// init() 에서 AppDataContainer.shared 싱글턴이 설정되므로
    /// 서비스 레이어(MemoryService 등)도 AppDataContainer.shared.container로 접근 가능.
    @StateObject private var appData = AppDataContainer()

    /// iCloud 동기화 모니터 — 앱 레벨로 승격하여 어느 탭에서든 알림 수신.
    @StateObject private var syncMonitor = CloudSyncMonitor()

    /// 선택된 탭 (lastUsed 복원용).
    @AppStorage("pieroot.todo.selectedTab") private var selectedTab = 0
    @AppStorage("pieroot.todo.hasOnboarded") private var hasOnboarded = false
    @AppStorage("pieroot.todo.hasCompletedTutorial") private var hasCompletedTutorial = false

    /// 시작 화면 정책: "lastUsed"(마지막 화면) | "fixed"(고정 탭)
    @AppStorage("pieroot.todo.launchBehavior") private var launchBehavior = "lastUsed"

    /// 고정 탭 인덱스 (launchBehavior == "fixed" 일 때 사용)
    @AppStorage("pieroot.todo.launchTab") private var launchTab = 0
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @StateObject private var tutorial = AppTutorialState()
    @State private var tabVisibility = AppTabVisibility(calendarVisible: false, mailVisible: false)

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

    // MARK: - Init

    init() {
        // iCloud Key-Value Store(SettingsStore)를 앱 최시작 시점에 조기 초기화하여
        // 초기 동기화(Initial Sync) 알림이 누락되지 않도록 방지합니다.
        _ = SettingsStore.shared
    }

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
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
            TabView(selection: tabBinding) {
                TodoListView()
                    .tabItem { Label("할 일", systemImage: "checklist") }
                    .tag(AppTabID.todo.rawValue)

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
            }
            .environmentObject(syncMonitor)
            .environment(\.appTutorialState, tutorial)
            .onOpenURL { url in
                MSALPublicClientApplication.handleMSALResponse(
                    url,
                    sourceApplication: nil
                )
            }
            .onAppear {
                NSUbiquitousKeyValueStore.default.synchronize()

                let ctx = appData.container.mainContext
                appDelegate.modelContext = ctx
                todoApp.deduplicatePersonas(context: ctx)

                CalendarService.shared.restoreAuthorizationIfGranted()
                Task {
                    await refreshTabVisibility()
                    if launchBehavior == "fixed" {
                        selectedTab = launchTab
                    }
                    if hasOnboarded && !hasCompletedTutorial {
                        selectedTab = AppTabID.todo.rawValue
                        tutorial.start(tabVisibility: tabVisibility)
                    }
                }
                scheduleEmailRefresh()
                scheduleMemoryAnalysis()

                // 어느 탭이든 앱 실행 시 iCloud 동기화 시작
                if iCloudSyncEnabled {
                    syncMonitor.startObserving(initialCount: 0)
                }

                // 콜드 런치: scenePhase는 이미 .active라 onChange가 발동하지 않음
                Task {
                    await LLMAutomationOrchestrator.shared.runIfEligible(context: ctx)
                }
                Task {
                    await CalendarService.shared.runWeeklyImportIfDue(context: ctx)
                }
                Task {
                    // iCloud 동기화가 진행 중이면 완료 후 캘린더 동기화
                    // (iCloud에 먼저 도착한 캘린더 이벤트를 Todo 없는 신규로 오인하는 경쟁 조건 방지)
                    if iCloudSyncEnabled { await syncMonitor.waitForCompletion() }
                    await CalendarService.shared.syncCalendarWithTodos(context: ctx)
                    await CalendarService.shared.cleanupOldCompletedTodos(context: ctx)
                }
            }
            .onChange(of: appData.rebuildID) { _, _ in
                // 컨테이너 재건(iCloud 동적 전환) 후 AppDelegate 컨텍스트 갱신
                appDelegate.modelContext = appData.container.mainContext
                todoApp.deduplicatePersonas(context: appData.container.mainContext)
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                if let ctx = appDelegate.modelContext {
                    Task {
                        if iCloudSyncEnabled { await syncMonitor.waitForCompletion() }
                        await CalendarService.shared.syncCalendarWithTodos(context: ctx)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .gmailAuthChanged)) { _ in
                Task { await refreshTabVisibility() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .outlookAuthChanged)) { _ in
                Task { await refreshTabVisibility() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .calendarAuthorizationChanged)) { _ in
                Task { await refreshTabVisibility() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .appTutorialRequested)) { _ in
                Task {
                    await refreshTabVisibility()
                    selectedTab = AppTabID.todo.rawValue
                    tutorial.start(tabVisibility: tabVisibility)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsDismissRequested)) { _ in
                Task { await refreshTabVisibility() }
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    // 포그라운드 전환 시에도 동기화 시작 (탭 무관)
                    if iCloudSyncEnabled {
                        syncMonitor.startObserving(initialCount: 0)
                    }
                    Task {
                        await refreshTabVisibility()
                        if launchBehavior == "fixed" {
                            selectedTab = launchTab
                        }
                    }
                    if let ctx = appDelegate.modelContext {
                        Task {
                            await LLMAutomationOrchestrator.shared.runIfEligible(context: ctx)
                        }
                        Task {
                            await CalendarService.shared.runWeeklyImportIfDue(context: ctx)
                        }
                        Task {
                            if iCloudSyncEnabled { await syncMonitor.waitForCompletion() }
                            await CalendarService.shared.syncCalendarWithTodos(context: ctx)
                            await CalendarService.shared.cleanupOldCompletedTodos(context: ctx)
                        }
                    }
                case .background:
                    OnDeviceLLMService.shared.unloadModel(reason: .background)
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
        }
        .modelContainer(appData.container)

        // macOS Settings 창 (Mac Catalyst / native Mac 대응)
        #if os(macOS)
        Settings {
            NavigationStack {
                PersonaSettingsView()
            }
            .modelContainer(appData.container)
            .environment(\.appTutorialState, tutorial)
        }
        #endif
    }

    @MainActor
    private func refreshTabVisibility() async {
        CalendarService.shared.restoreAuthorizationIfGranted()
        let calendarVisible = CalendarService.shared.isAuthorized
        let outlookVisible = OutlookMailService.shared.isConfigured
            ? await OutlookMailService.shared.canAccessMailSilently()
            : false
        let mailVisible = EmailService.shared.isAuthenticated || outlookVisible
        tabVisibility = AppTabVisibility(calendarVisible: calendarVisible, mailVisible: mailVisible)
        selectedTab = tabVisibility.clamped(selectedTab)
        launchTab = tabVisibility.clamped(launchTab)
    }

}
