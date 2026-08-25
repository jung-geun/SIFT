import SwiftUI
import SwiftData
import UserNotifications
import Combine
import TipKit
enum AppTutorialStep: String, CaseIterable, Identifiable {
    case addTodoOpen
    case addTodoTitle
    case addTodoDueDate
    case addTodoPriority
    case addTodoSave
    case persona
    case priorityRules
    case emailOptional
    case permissions
    case calendarEnabled
    case mailEnabled
    case autoSort

    var id: String { rawValue }

    static func sequence(calendarEnabled: Bool, mailEnabled: Bool) -> [AppTutorialStep] {
        var base: [AppTutorialStep] = [
            .addTodoOpen,
            .addTodoTitle,
            .addTodoDueDate,
            .addTodoPriority,
            .addTodoSave,
            .persona,
            .priorityRules,
            .emailOptional,
            .permissions
        ]
        if calendarEnabled { base.append(.calendarEnabled) }
        if mailEnabled { base.append(.mailEnabled) }
        base.append(.autoSort)
        return base
    }
}

private extension AppTutorialStep {
    var isAddTodoStep: Bool {
        switch self {
        case .addTodoOpen, .addTodoTitle, .addTodoDueDate, .addTodoPriority, .addTodoSave:
            return true
        default:
            return false
        }
    }
}

enum AppTabID: Int, CaseIterable {
    case todo = 0
    case calendar = 1
    case mail = 2
    case meeting = 3
}

struct AppTabVisibility: Equatable {
    var calendarVisible: Bool
    var mailVisible: Bool

    var visibleTabs: Set<Int> {
        var ids: Set<Int> = [AppTabID.todo.rawValue]
        if calendarVisible { ids.insert(AppTabID.calendar.rawValue) }
        if mailVisible { ids.insert(AppTabID.mail.rawValue) }
        ids.insert(AppTabID.meeting.rawValue)
        return ids
    }

    func clamped(_ tab: Int) -> Int {
        visibleTabs.contains(tab) ? tab : AppTabID.todo.rawValue
    }
}

enum AppTutorialScreen {
    case todoList
    case addTodo
    case settings
    case personaDetail
    case aiDetail
    case emailDetail
    case permissionsDetail
    case calendarTab
    case mailTab
}

struct AppTutorialHint: Equatable {
    let title: String
    let body: String
    var allowsNextAction = false

    var localizedTitle: String {
        AppTutorialCopy.localized(title)
    }

    var localizedBody: String {
        AppTutorialCopy.localized(body)
    }
}

struct AppTutorialCompletionNotice: Identifiable, Equatable {
    let id = UUID()
}

private enum AppTutorialCopy {
    static var next: String { localized("다음") }
    static var close: String { localized("닫기") }
    static var endTutorial: String { localized("튜토리얼 종료") }
    static var completionTitle: String { localized("튜토리얼 완료") }
    static var completionMessage: String { localized("튜토리얼을 다시 확인하고 싶다면 설정 > 앱 정보 > 튜토리얼 다시 시작에 있습니다.") }
    static var confirm: String { localized("확인") }

    static func localized(_ korean: String) -> String {
        guard AppLanguage.current == .english else { return korean }
        return english[korean] ?? korean
    }

    private static let english: [String: String] = [
        "다음": "Next",
        "닫기": "Close",
        "확인": "OK",
        "튜토리얼 종료": "End Tutorial",
        "튜토리얼 완료": "Tutorial Complete",
        "튜토리얼을 다시 확인하고 싶다면 설정 > 앱 정보 > 튜토리얼 다시 시작에 있습니다.": "To review the tutorial again, go to Settings > App Info > Replay Tutorial.",
        "새 할 일 추가": "Add a New To-Do",
        "우측 상단 + 버튼을 눌러 새 할 일 화면을 열어보세요.": "Tap the + button in the upper right to open the new to-do screen.",
        "제목과 메모": "Title and Notes",
        "제목은 필수입니다. 메모에는 배경 정보나 처리 기준을 적어두면 나중에 AI 정리와 검색에 도움이 됩니다.": "The title is required. Use notes for background or handling criteria so AI sorting and search can work better later.",
        "마감 시각 설정": "Set Due Time",
        "마감 시각 설정을 켜면 날짜와 시간을 고를 수 있습니다. 캘린더 권한이 있으면 캘린더 등록도 함께 켜지고, 마감이 있는 할 일에는 알림 프리셋을 추가할 수 있습니다.": "Turn on Set Due Time to choose a date and time. If calendar permission is available, calendar registration can also be enabled, and to-dos with due times can use reminder presets.",
        "우선순위 선택": "Choose Priority",
        "기본 우선순위는 자동입니다. AI 정리와 마감 정보를 기준으로 계산되지만, 중요도가 확실한 일은 낮음·보통·높음·긴급 중 하나를 직접 선택해 강제로 고정할 수 있습니다.": "Priority is automatic by default. It is calculated from AI sorting and due-date information, but you can force a fixed priority by choosing Low, Medium, High, or Urgent.",
        "저장하기": "Save",
        "내용을 확인한 뒤 추가를 누르면 할 일이 저장됩니다. 지금 저장하지 않으려면 취소로 나가도 튜토리얼은 다음 단계로 이어집니다.": "After reviewing the details, tap Add to save the to-do. You can cancel without saving and the tutorial will continue to the next step.",
        "설정 다시 열기": "Open Settings Again",
        "우측 상단 설정 버튼을 눌러 TODO 자동 정렬 및 AI 항목으로 이동해보세요.": "Tap Settings in the upper right and open To-Do Auto Sorting and AI.",
        "우측 상단 설정 버튼을 눌러 이메일 연동 항목을 확인해보세요.": "Tap Settings in the upper right and review Email Integration.",
        "우측 상단 설정 버튼을 눌러 시스템 권한 및 상태 항목을 확인해보세요.": "Tap Settings in the upper right and review System Permissions and Status.",
        "설정 열기": "Open Settings",
        "우측 상단 설정 버튼을 눌러 나의 페르소나를 확인해보세요.": "Tap Settings in the upper right to review My Persona.",
        "나의 페르소나": "My Persona",
        "설정 목록에서 나의 페르소나를 눌러 프로필을 확인해보세요.": "In Settings, tap My Persona to review your profile.",
        "페르소나 확인": "Review Persona",
        "여기서 생활 유형과 설명을 확인하거나 다시 설정할 수 있습니다. 확인했으면 뒤로 돌아가 계속하세요.": "Here you can review or reset your lifestyle type and description. Go back when you are done.",
        "자동 정렬 AI": "Auto Sorting AI",
        "TODO 자동 정렬 및 AI를 눌러 자동 정렬에 사용할 AI를 선택할 수 있는 화면으로 들어가보세요.": "Tap To-Do Auto Sorting and AI to choose which AI is used for automatic sorting.",
        "AI 선택": "Choose AI",
        "이 화면에서 TODO 자동 정렬에 사용할 AI를 선택할 수 있습니다. 확인했으면 뒤로 돌아가 계속하세요.": "This screen lets you choose the AI used for to-do auto sorting. Go back when you are done.",
        "이메일 연동": "Email Integration",
        "이메일 연동을 눌러 메일 연결 화면을 확인해보세요. 메일 연동은 선택입니다.": "Tap Email Integration to review mail connection. Mail integration is optional.",
        "메일 연결": "Connect Mail",
        "필요하면 여기서 메일 계정을 연결하세요. 메일 연동은 건너뛰어도 됩니다. 확인했으면 뒤로 돌아가 계속하세요.": "Connect a mail account here if needed. You can skip mail integration. Go back when you are done.",
        "시스템 권한": "System Permissions",
        "시스템 권한 및 상태를 눌러 알림과 캘린더 권한 상태를 확인해보세요.": "Tap System Permissions and Status to review notification and calendar permissions.",
        "권한 허용": "Allow Permissions",
        "필요하면 허용 버튼으로 알림과 캘린더 권한을 주세요. 확인했으면 뒤로 돌아가 계속하세요.": "If needed, use the Allow buttons to grant notification and calendar permissions. Go back when you are done.",
        "캘린더 탭으로 이동": "Go to the Calendar Tab",
        "이제 설정을 닫고 탭바의 캘린더를 눌러 실제 캘린더 탭을 열어보세요.": "Close Settings, then tap Calendar in the tab bar to open the calendar tab.",
        "캘린더 탭 열기": "Open Calendar Tab",
        "탭바의 캘린더를 눌러 일정과 할 일을 함께 보는 화면을 확인해보세요.": "Tap Calendar in the tab bar to see schedules and to-dos together.",
        "캘린더 확인": "Review Calendar",
        "여기서 캘린더 일정과 앱 할 일을 함께 볼 수 있습니다. 확인했으면 할 일 탭으로 돌아가 계속하세요.": "Here you can view calendar events and app to-dos together. Return to the To-Dos tab when you are done.",
        "메일 탭으로 이동": "Go to the Mail Tab",
        "이제 설정을 닫고 탭바의 메일을 눌러 실제 메일 탭을 열어보세요.": "Close Settings, then tap Mail in the tab bar to open the mail tab.",
        "메일 탭 열기": "Open Mail Tab",
        "탭바의 메일을 눌러 연결된 메일을 확인하는 화면을 열어보세요.": "Tap Mail in the tab bar to open connected mail.",
        "메일 확인": "Review Mail",
        "여기서 연결된 메일을 확인하고 할 일로 등록할 수 있습니다. 확인했으면 할 일 탭으로 돌아가 계속하세요.": "Here you can review connected mail and add messages as to-dos. Return to the To-Dos tab when you are done.",
        "설정 닫기": "Close Settings",
        "이제 설정을 닫고 할 일 탭으로 돌아가 AI 정리를 눌러보세요.": "Close Settings, return to the To-Dos tab, and tap AI Sort.",
        "AI 정리 실행": "Run AI Sort",
        "왼쪽 위 AI 정리 버튼을 눌러 실제 자동 정렬을 실행해보세요. 할 일이 없으면 먼저 하나 추가한 뒤 눌러보세요.": "Tap AI Sort in the upper left to run automatic sorting. If there are no to-dos, add one first.",
        "필요한 권한 허용": "Allow Required Permissions",
        "알림과 캘린더가 아직 허용되지 않았습니다. 각 행의 허용 버튼을 눌러 마감 알림과 캘린더 등록을 사용할 수 있게 해주세요.": "Notifications and Calendar are not allowed yet. Tap Allow in each row so due reminders and calendar registration can work.",
        "알림 권한 허용": "Allow Notifications",
        "알림이 아직 허용되지 않았습니다. 알림 행의 허용 버튼을 눌러 마감 알림을 받을 수 있게 해주세요.": "Notifications are not allowed yet. Tap Allow in the Notifications row to receive due reminders.",
        "캘린더 권한 허용": "Allow Calendar",
        "캘린더가 아직 허용되지 않았습니다. 캘린더 행의 허용 버튼을 눌러 마감 일정을 자동 등록할 수 있게 해주세요.": "Calendar is not allowed yet. Tap Allow in the Calendar row so due dates can be registered automatically.",
        "권한 확인 완료": "Permissions Checked",
        "필요한 권한이 허용되어 있습니다. 뒤로 돌아가 튜토리얼을 계속하세요.": "The required permissions are allowed. Go back to continue the tutorial."
    ]
}

@MainActor
final class AppTutorialState: ObservableObject {
    @Published var isActive = false
    @Published var currentStep: AppTutorialStep?
    @Published var tabVisibility = AppTabVisibility(calendarVisible: false, mailVisible: false)
    @Published var completionNotice: AppTutorialCompletionNotice?
    @Published private(set) var sessionID = UUID().uuidString

    private var visitedCalendarTab = false
    private var visitedMailTab = false

    func start(tabVisibility: AppTabVisibility) {
        self.tabVisibility = tabVisibility
        sessionID = UUID().uuidString
        visitedCalendarTab = false
        visitedMailTab = false
        currentStep = AppTutorialStep.sequence(
            calendarEnabled: tabVisibility.calendarVisible,
            mailEnabled: tabVisibility.mailVisible
        ).first
        isActive = currentStep != nil
    }

    func stop(markCompleted: Bool = false) {
        if markCompleted {
            UserDefaults.standard.set(true, forKey: "pieroot.todo.hasCompletedTutorial")
            completionNotice = AppTutorialCompletionNotice()
        }
        visitedCalendarTab = false
        visitedMailTab = false
        currentStep = nil
        isActive = false
    }

    func updateTabVisibility(_ tabVisibility: AppTabVisibility) {
        self.tabVisibility = tabVisibility
        guard isActive else { return }
        let steps = AppTutorialStep.sequence(
            calendarEnabled: tabVisibility.calendarVisible,
            mailEnabled: tabVisibility.mailVisible
        )
        if let currentStep, !steps.contains(currentStep) {
            advance()
        }
    }

    func handleAddTodoOpened() {
        guard currentStep == .addTodoOpen else { return }
        advance()
    }

    func handleAddTodoDismissed() {
        guard let currentStep, currentStep.isAddTodoStep else { return }
        skipAddTodoSteps()
    }

    func handleAddTodoTextChanged(title: String, notes: String) {
        guard currentStep == .addTodoTitle,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        advance()
    }

    func handleAddTodoDueDateEnabled(_ enabled: Bool) {
        guard currentStep == .addTodoDueDate, enabled else { return }
        advance()
    }

    func handleAddTodoPriorityReviewed() {
        guard currentStep == .addTodoPriority else { return }
        advance()
    }

    func advanceFromTip() {
        guard let currentStep else { return }
        if currentStep == .addTodoOpen {
            return
        }
        advance()
    }

    func handlePersonaDetailClosed() {
        guard currentStep == .persona else { return }
        advance()
    }

    func handlePriorityRulesDetailClosed() {
        guard currentStep == .priorityRules else { return }
        advance()
    }

    func handleEmailDetailClosed() {
        guard currentStep == .emailOptional else { return }
        advance()
    }

    func handlePermissionsClosed() {
        guard currentStep == .permissions else { return }
        advance()
    }

    func handleTodoListAppeared() {
        switch currentStep {
        case .calendarEnabled where visitedCalendarTab:
            visitedCalendarTab = false
            advance()
        case .mailEnabled where visitedMailTab:
            visitedMailTab = false
            advance()
        default:
            break
        }
    }

    func handleCalendarTabAppeared() {
        guard currentStep == .calendarEnabled else { return }
        visitedCalendarTab = true
    }

    func handleMailTabAppeared() {
        guard currentStep == .mailEnabled else { return }
        visitedMailTab = true
    }

    func handleTabSelection(_ tab: Int) {
        switch currentStep {
        case .calendarEnabled:
            if tab == AppTabID.calendar.rawValue {
                visitedCalendarTab = true
            }
        case .mailEnabled:
            if tab == AppTabID.mail.rawValue {
                visitedMailTab = true
            }
        default:
            break
        }
    }

    func handlePrioritizeTriggered() {
        guard currentStep == .autoSort else { return }
        stop(markCompleted: true)
    }

    func hint(for screen: AppTutorialScreen) -> AppTutorialHint? {
        guard isActive, let currentStep else { return nil }

        switch (currentStep, screen) {
        case (.addTodoOpen, .todoList):
            return AppTutorialHint(
                title: "새 할 일 추가",
                body: "우측 상단 + 버튼을 눌러 새 할 일 화면을 열어보세요."
            )
        case (.addTodoTitle, .addTodo):
            return AppTutorialHint(
                title: "제목과 메모",
                body: "제목은 필수입니다. 메모에는 배경 정보나 처리 기준을 적어두면 나중에 AI 정리와 검색에 도움이 됩니다.",
                allowsNextAction: true
            )
        case (.addTodoDueDate, .addTodo):
            return AppTutorialHint(
                title: "마감 시각 설정",
                body: "마감 시각 설정을 켜면 날짜와 시간을 고를 수 있습니다. 캘린더 권한이 있으면 캘린더 등록도 함께 켜지고, 마감이 있는 할 일에는 알림 프리셋을 추가할 수 있습니다.",
                allowsNextAction: true
            )
        case (.addTodoPriority, .addTodo):
            return AppTutorialHint(
                title: "우선순위 선택",
                body: "기본 우선순위는 자동입니다. AI 정리와 마감 정보를 기준으로 계산되지만, 중요도가 확실한 일은 낮음·보통·높음·긴급 중 하나를 직접 선택해 강제로 고정할 수 있습니다.",
                allowsNextAction: true
            )
        case (.addTodoSave, .addTodo):
            return AppTutorialHint(
                title: "저장하기",
                body: "내용을 확인한 뒤 추가를 누르면 할 일이 저장됩니다. 지금 저장하지 않으려면 취소로 나가도 튜토리얼은 다음 단계로 이어집니다."
            )

        case (.priorityRules, .todoList):
            return AppTutorialHint(
                title: "설정 다시 열기",
                body: "우측 상단 설정 버튼을 눌러 TODO 우선순위 규칙 항목으로 이동해보세요."
            )

        case (.emailOptional, .todoList):
            return AppTutorialHint(
                title: "설정 다시 열기",
                body: "우측 상단 설정 버튼을 눌러 이메일 연동 항목을 확인해보세요."
            )

        case (.permissions, .todoList):
            return AppTutorialHint(
                title: "설정 다시 열기",
                body: "우측 상단 설정 버튼을 눌러 시스템 권한 및 상태 항목을 확인해보세요."
            )

        case (.persona, .todoList):
            return AppTutorialHint(
                title: "설정 열기",
                body: "우측 상단 설정 버튼을 눌러 나의 페르소나를 확인해보세요."
            )
        case (.persona, .settings):
            return AppTutorialHint(
                title: "나의 페르소나",
                body: "설정 목록에서 나의 페르소나를 눌러 프로필을 확인해보세요."
            )
        case (.persona, .personaDetail):
            return AppTutorialHint(
                title: "페르소나 확인",
                body: "여기서 생활 유형과 설명을 확인하거나 다시 설정할 수 있습니다. 확인했으면 뒤로 돌아가 계속하세요."
            )

        case (.priorityRules, .settings):
            return AppTutorialHint(
                title: "우선순위 규칙",
                body: "TODO 우선순위 규칙을 눌러 자동 정렬이 사용하는 규칙을 확인해보세요."
            )
        case (.priorityRules, .aiDetail):
            return AppTutorialHint(
                title: "규칙 기반 정렬",
                body: "이 화면은 마감일과 중요도, 태그, 행동 패턴을 사용한 규칙 기반 정렬을 안내합니다. 확인했으면 뒤로 돌아가 계속하세요."
            )

        case (.emailOptional, .settings):
            return AppTutorialHint(
                title: "이메일 연동",
                body: "이메일 연동을 눌러 메일 연결 화면을 확인해보세요. 메일 연동은 선택입니다."
            )
        case (.emailOptional, .emailDetail):
            return AppTutorialHint(
                title: "메일 연결",
                body: "필요하면 여기서 메일 계정을 연결하세요. 메일 연동은 건너뛰어도 됩니다. 확인했으면 뒤로 돌아가 계속하세요."
            )

        case (.permissions, .settings):
            return AppTutorialHint(
                title: "시스템 권한",
                body: "시스템 권한 및 상태를 눌러 알림과 캘린더 권한 상태를 확인해보세요."
            )
        case (.permissions, .permissionsDetail):
            return AppTutorialHint(
                title: "권한 허용",
                body: "필요하면 허용 버튼으로 알림과 캘린더 권한을 주세요. 확인했으면 뒤로 돌아가 계속하세요."
            )

        case (.calendarEnabled, .settings):
            return AppTutorialHint(
                title: "캘린더 탭으로 이동",
                body: "이제 설정을 닫고 탭바의 캘린더를 눌러 실제 캘린더 탭을 열어보세요."
            )
        case (.calendarEnabled, .todoList):
            return AppTutorialHint(
                title: "캘린더 탭 열기",
                body: "탭바의 캘린더를 눌러 일정과 할 일을 함께 보는 화면을 확인해보세요."
            )
        case (.calendarEnabled, .calendarTab):
            return AppTutorialHint(
                title: "캘린더 확인",
                body: "여기서 캘린더 일정과 앱 할 일을 함께 볼 수 있습니다. 확인했으면 할 일 탭으로 돌아가 계속하세요."
            )

        case (.mailEnabled, .settings):
            return AppTutorialHint(
                title: "메일 탭으로 이동",
                body: "이제 설정을 닫고 탭바의 메일을 눌러 실제 메일 탭을 열어보세요."
            )
        case (.mailEnabled, .todoList):
            return AppTutorialHint(
                title: "메일 탭 열기",
                body: "탭바의 메일을 눌러 연결된 메일을 확인하는 화면을 열어보세요."
            )
        case (.mailEnabled, .mailTab):
            return AppTutorialHint(
                title: "메일 확인",
                body: "여기서 연결된 메일을 확인하고 할 일로 등록할 수 있습니다. 확인했으면 할 일 탭으로 돌아가 계속하세요."
            )


        case (.autoSort, .settings):
            return AppTutorialHint(
                title: "설정 닫기",
                body: "이제 설정을 닫고 할 일 탭으로 돌아가 AI 정리를 눌러보세요."
            )
        case (.autoSort, .todoList):
            return AppTutorialHint(
                title: "AI 정리 실행",
                body: "왼쪽 위 AI 정리 버튼을 눌러 실제 자동 정렬을 실행해보세요. 할 일이 없으면 먼저 하나 추가한 뒤 눌러보세요."
            )

        default:
            return nil
        }
    }

    private func advance() {
        guard let currentStep else { return }
        let steps = AppTutorialStep.sequence(
            calendarEnabled: tabVisibility.calendarVisible,
            mailEnabled: tabVisibility.mailVisible
        )
        guard let index = steps.firstIndex(of: currentStep) else {
            stop(markCompleted: true)
            return
        }
        let nextIndex = steps.index(after: index)
        if nextIndex < steps.endIndex {
            self.currentStep = steps[nextIndex]
        } else {
            stop(markCompleted: true)
        }
    }

    private func skipAddTodoSteps() {
        let steps = AppTutorialStep.sequence(
            calendarEnabled: tabVisibility.calendarVisible,
            mailEnabled: tabVisibility.mailVisible
        )
        guard let nextStep = steps.first(where: { !$0.isAddTodoStep }) else {
            stop(markCompleted: true)
            return
        }
        currentStep = nextStep
    }
}

private struct AppTutorialStateKey: EnvironmentKey {
    static let defaultValue: AppTutorialState? = nil
}

extension EnvironmentValues {
    var appTutorialState: AppTutorialState? {
        get { self[AppTutorialStateKey.self] }
        set { self[AppTutorialStateKey.self] = newValue }
    }
}

struct AppTutorialView: View {
    @Binding var selectedTab: Int
    let tabVisibility: AppTabVisibility

    @Environment(\.appTutorialState) private var tutorial

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear {
                tutorial?.updateTabVisibility(tabVisibility)
            }
            .onChange(of: tabVisibility) { _, newValue in
                tutorial?.updateTabVisibility(newValue)
            }
            .alert(
                AppTutorialCopy.completionTitle,
                isPresented: Binding(
                    get: { tutorial?.completionNotice != nil },
                    set: { if !$0 { tutorial?.completionNotice = nil } }
                )
            ) {
                Button(AppTutorialCopy.confirm, role: .cancel) {}
            } message: {
                Text(AppTutorialCopy.completionMessage)
            }
    }
}

@available(iOS 17.0, *)
private struct AppTutorialTip: Tip {
    let id: String
    let hint: AppTutorialHint

    var title: Text {
        Text(hint.localizedTitle)
    }

    var message: Text? {
        Text(hint.localizedBody)
    }

    var image: Image? {
        Image(systemName: "lightbulb")
    }

    var actions: [Action] {
        var actions: [Action] = []
        if hint.allowsNextAction {
            actions.append(Action(id: "next", title: AppTutorialCopy.next))
        }
        actions.append(Action(id: "end-tutorial", title: AppTutorialCopy.endTutorial))
        return actions
    }

    var options: [Option] {
        IgnoresDisplayFrequency(true)
    }
}

struct AppTutorialTipHost: View {
    @ObservedObject var tutorial: AppTutorialState
    let screen: AppTutorialScreen

    var body: some View {
        if let hint = tutorial.hint(for: screen) {
            AppTutorialTipView(hint: hint)
                .environment(\.appTutorialState, tutorial)
        }
    }
}

struct AppTutorialTipView: View {
    let hint: AppTutorialHint

    @Environment(\.appTutorialState) private var tutorial

    private var tipID: String {
        "\(tutorial?.sessionID ?? "standalone")-\(hint.title)-\(hint.body)"
    }

    var body: some View {
        if hint.allowsNextAction {
            AppTutorialFallbackCard(hint: hint)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        } else if #available(iOS 17.0, *) {
            TipView(
                AppTutorialTip(id: tipID, hint: hint),
                arrowEdge: .bottom
            ) { action in
                if action.id == "end-tutorial" {
                    tutorial?.stop(markCompleted: true)
                }
            }
            .id(tipID)
            .tint(AppTheme.accent)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else {
            AppTutorialFallbackCard(hint: hint)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }
}

struct AppTutorialGlowModifier: ViewModifier {
    let active: Bool
    @State private var isLit = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppTheme.accent.opacity(isLit ? 0.95 : 0.35), lineWidth: 2)
                        .padding(-5)
                        .shadow(color: AppTheme.accent.opacity(isLit ? 0.65 : 0.2), radius: isLit ? 10 : 3)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { updatePulse(active) }
            .onChange(of: active) { _, newValue in
                updatePulse(newValue)
            }
    }

    private func updatePulse(_ shouldPulse: Bool) {
        if shouldPulse {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isLit = true
            }
        } else {
            isLit = false
        }
    }
}

extension View {
    func appTutorialGlow(_ active: Bool) -> some View {
        modifier(AppTutorialGlowModifier(active: active))
    }
}

private struct AppTutorialFallbackCard: View {
    let hint: AppTutorialHint

    @Environment(\.appTutorialState) private var tutorial

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(hint.localizedTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(AppTutorialCopy.close) {
                    tutorial?.stop(markCompleted: true)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            Text(hint.localizedBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hint.allowsNextAction {
                Button(AppTutorialCopy.next) {
                    tutorial?.advanceFromTip()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }
}

