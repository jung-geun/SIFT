import SwiftUI
import SwiftData
import UserNotifications
import BackgroundTasks

// MARK: - BGTask 식별자

private let kEmailRefreshTaskID  = "pieroot.todo.emailRefresh"
private let kMemoryAnalysisTaskID = "pieroot.todo.memoryAnalysis"

// MARK: - Debug Overlay

struct DebugOverlayView: View {
    let swiftDataMode: String
    @AppStorage("debugOverlayDismissed") private var dismissed = false

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Debug", systemImage: "wrench.and.screwdriver.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        dismissed = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 6)

                VStack(alignment: .leading, spacing: 3) {
                    row("✅ main() 진입", "앱 코드 실행 중")
                    row("iOS", ProcessInfo.processInfo.operatingSystemVersionString)
                    row("기기", UIDevice.current.model)
                    row("SwiftData", swiftDataMode)
                    row("AI 제공자", UserDefaults.standard.string(forKey: "selectedAIProvider") ?? "미설정(AFM)")
                    row("FoundationModels", "링크 제거됨 — iOS 27 beta XPC 크래시 대응")
                    row("BGTask등록", ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ? "Preview 스킵" : "등록됨")
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.4), lineWidth: 1))
            .padding(.horizontal, 16)
            .padding(.top, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}

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
        return true
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
        guard EmailService.shared.isAuthenticated else { return false }
        // 메일 자동 분석 토글 — 배경(BGTask) 경로 독립 게이트 (마스터 onDeviceLLMEnabled와 무관)
        // register(defaults:)로 기본값 true 보장 → 기존 사용자 동작 그대로 유지
        guard UserDefaults.standard.bool(forKey: "pieroot.todo.emailAutoAnalysisEnabled") else { return false }
        do {
            // C: 백그라운드 BGTask → allowFoundationModels:false (ANE 백그라운드 미사용)
            let (todos, events) = try await EmailService.shared.fetchAndExtractAll(allowFoundationModels: false)

            // Todo 삽입 (sourceRef로 중복 방지)
            let existing = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
            let existingRefs = Set(existing.map { $0.sourceRef })
            for todo in todos where !existingRefs.contains(todo.sourceRef) {
                context.insert(todo)
                // 캘린더 자동 등록 정책 적용 (긴급/최우선 강제 포함)
                CalendarService.shared.applyAutoRegistration(for: todo)
            }

            // 캘린더 일정 자동 등록 (이메일에서 추출한 캘린더 이벤트)
            if CalendarService.shared.isAuthorized
                && CalendarAutoPolicy.isAuto {
                let iso = ISO8601DateFormatter()
                for (event, sourceRef) in events {
                    guard !CalendarService.shared.hasEvent(forEmailRef: sourceRef),
                          let start = iso.date(from: event.startISO) else { continue }
                    let end = event.endISO.isEmpty ? nil : iso.date(from: event.endISO)
                    _ = try? CalendarService.shared.createEventFromEmail(
                        title: event.title, start: start, end: end,
                        isAllDay: event.isAllDay, location: event.location,
                        notes: event.notes, sourceRef: sourceRef
                    )
                }
            }

            // 마지막 동기화 시각 저장
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "pieroot.todo.lastEmailFetchDate")
            return true
        } catch {
            print("[EmailService] fetch 실패: \(error.localizedDescription)")
            return false
        }
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

    static private(set) var swiftDataMode = "초기화 중"

    let sharedModelContainer: ModelContainer = {
        let schema = Schema([Todo.self, Persona.self, TaskAuditEvent.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let c = try ModelContainer(for: schema, configurations: [config])
            todoApp.swiftDataMode = "영구 저장 ✅"
            return c
        } catch {
            print("[SwiftData] 저장소 초기화 실패: \(error). 기존 파일 삭제 후 재시도.")
            try? FileManager.default.removeItem(at: config.url)
            do {
                let c = try ModelContainer(for: schema, configurations: [config])
                todoApp.swiftDataMode = "재시도 후 영구 저장 ⚠️"
                return c
            } catch {
                print("[SwiftData] 재시도 실패: \(error). 메모리 전용 모드로 실행.")
                todoApp.swiftDataMode = "메모리 전용 ❌ \(error.localizedDescription)"
                let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try! ModelContainer(for: schema, configurations: [fallback])
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                TodoListView()
                    .onAppear {
                        appDelegate.modelContext = sharedModelContainer.mainContext
                        // 앱 업데이트·재실행 후 캘린더 권한 복원 (다이얼로그 없이)
                        CalendarService.shared.restoreAuthorizationIfGranted()
                        scheduleEmailRefresh()
                        scheduleMemoryAnalysis()
                        // 콜드 런치: scenePhase는 이미 .active라 onChange가 발동하지 않음
                        let ctx = sharedModelContainer.mainContext
                        Task {
                            await LLMAutomationOrchestrator.shared.runIfEligible(context: ctx)
                        }
                        Task {
                            await CalendarService.shared.runWeeklyImportIfDue(context: sharedModelContainer.mainContext)
                        }
                    }
                DebugOverlayView(swiftDataMode: todoApp.swiftDataMode)
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    // 앱 활성화 시 LLM 자동화 파이프라인 실행 (조건 충족 시)
                    // 포그라운드에서만 실행 — iOS는 백그라운드 GPU 작업을 금지함
                    if let ctx = appDelegate.modelContext {
                        Task {
                            await LLMAutomationOrchestrator.shared.runIfEligible(context: ctx)
                        }
                        Task {
                            await CalendarService.shared.runWeeklyImportIfDue(context: ctx)
                        }
                    }
                case .background:
                    // 백그라운드 진입 시 즉시 모델 언로드 (iOS 26.2+ GPU 크래시 방지 안전망)
                    OnDeviceLLMService.shared.unloadModel(reason: .background)
                default:
                    break
                }
            }
        }
        .modelContainer(sharedModelContainer)

        // macOS Settings 창 (Mac Catalyst / native Mac 대응)
        #if os(macOS)
        Settings {
            NavigationStack {
                PersonaSettingsView()
            }
            .modelContainer(sharedModelContainer)
        }
        #endif
    }
}
