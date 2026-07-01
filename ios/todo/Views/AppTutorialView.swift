import SwiftUI
import SwiftData
import UserNotifications
import Combine
enum AppTutorialStep: String, CaseIterable, Identifiable {
    case addTodo
    case persona
    case aiProvider
    case emailOptional
    case permissions
    case calendarEnabled
    case mailEnabled
    case autoSort

    var id: String { rawValue }

    static func sequence(calendarEnabled: Bool, mailEnabled: Bool) -> [AppTutorialStep] {
        var base: [AppTutorialStep] = [
            .addTodo,
            .persona,
            .aiProvider,
            .emailOptional,
            .permissions
        ]
        if calendarEnabled { base.append(.calendarEnabled) }
        if mailEnabled { base.append(.mailEnabled) }
        base.append(.autoSort)
        return base
    }
}

enum AppTabID: Int, CaseIterable {
    case todo = 0
    case calendar = 1
    case mail = 2
}

struct AppTabVisibility: Equatable {
    var calendarVisible: Bool
    var mailVisible: Bool

    var visibleTabs: Set<Int> {
        var ids: Set<Int> = [AppTabID.todo.rawValue]
        if calendarVisible { ids.insert(AppTabID.calendar.rawValue) }
        if mailVisible { ids.insert(AppTabID.mail.rawValue) }
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
}

@MainActor
final class AppTutorialState: ObservableObject {
    @Published var isActive = false
    @Published var currentStep: AppTutorialStep?
    @Published var tabVisibility = AppTabVisibility(calendarVisible: false, mailVisible: false)

    private var visitedCalendarTab = false
    private var visitedMailTab = false

    func start(tabVisibility: AppTabVisibility) {
        self.tabVisibility = tabVisibility
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

    func handleAddTodoDismissed() {
        guard currentStep == .addTodo else { return }
        advance()
    }

    func handlePersonaDetailClosed() {
        guard currentStep == .persona else { return }
        advance()
    }

    func handleAIDetailClosed() {
        guard currentStep == .aiProvider else { return }
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
        case (.addTodo, .todoList):
            return AppTutorialHint(
                title: "새 할 일 추가",
                body: "우측 상단 + 버튼을 눌러 실제로 새 할 일을 열어보세요. 제목은 필수이고, 마감일과 알림은 선택입니다."
            )
        case (.addTodo, .addTodo):
            return AppTutorialHint(
                title: "새 할 일 화면",
                body: "여기서 제목을 입력해 추가할 수 있습니다. 둘러본 뒤 취소하거나 추가하면 다음 안내로 넘어갑니다."
            )

        case (.aiProvider, .todoList):
            return AppTutorialHint(
                title: "설정 다시 열기",
                body: "우측 상단 설정 버튼을 눌러 TODO 자동 정렬 및 AI 항목으로 이동해보세요."
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

        case (.aiProvider, .settings):
            return AppTutorialHint(
                title: "자동 정렬 AI",
                body: "TODO 자동 정렬 및 AI를 눌러 자동 정렬에 사용할 AI를 선택할 수 있는 화면으로 들어가보세요."
            )
        case (.aiProvider, .aiDetail):
            return AppTutorialHint(
                title: "AI 선택",
                body: "이 화면에서 TODO 자동 정렬에 사용할 AI를 선택할 수 있습니다. 확인했으면 뒤로 돌아가 계속하세요."
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
        if let tutorial, tutorial.isActive {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .onAppear {
                    tutorial.updateTabVisibility(tabVisibility)
                }
                .onChange(of: tabVisibility) { _, newValue in
                    tutorial.updateTabVisibility(newValue)
                }
        }
    }
}

struct AppTutorialHintCard: View {
    let hint: AppTutorialHint

    @Environment(\.appTutorialState) private var tutorial

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Text(hint.title)
                    .font(.headline)
                Spacer()
                Button("닫기") {
                    tutorial?.stop()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            Text(hint.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

