import SwiftUI
import SwiftData
import UserNotifications
import Combine
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
    case todoSettings
    case calendarTab
    case mailTab
}

struct AppTutorialHint: Equatable {
    let title: String
    let body: String
    var allowsNextAction = false
    var titleKey: String? = nil
    var bodyKey: String? = nil

    var localizedTitle: String {
        AppTutorialCopy.localized(title, key: titleKey)
    }

    var localizedBody: String {
        AppTutorialCopy.localized(body, isBody: true, key: bodyKey)
    }
}

struct AppTutorialCompletionNotice: Identifiable, Equatable {
    let id = UUID()
}

private enum AppTutorialCopy {
    static var next: String { localized("다음") }
    static var endTutorial: String { localized("튜토리얼 종료") }
    static var completionTitle: String { localized("튜토리얼 완료") }
    static var completionMessage: String { localized("튜토리얼을 다시 확인하고 싶다면 할 일 > 더 보기 > 설정 > 앱 정보 > 튜토리얼 다시 시작에 있습니다.", isBody: true) }
    static var confirm: String { localized("확인") }

    static func localized(_ korean: String, isBody: Bool = false, key: String? = nil) -> String {
        AppLanguage.localized(
            key ?? "tutorial.\(isBody ? "body." : "")\(korean)",
            defaultValue: korean,
            language: .current,
            comment: isBody ? "Tutorial hint body." : "Tutorial hint title or action."
        )
    }
}

@MainActor
final class AppTutorialState: ObservableObject {
    @Published var isActive = false
    @Published var currentStep: AppTutorialStep?
    @Published var tabVisibility = AppTabVisibility(calendarVisible: false, mailVisible: false)
    @Published var completionNotice: AppTutorialCompletionNotice?

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
                body: "마감 시각 설정을 켜면 날짜와 시간을 고를 수 있습니다. 추가 옵션에서 캘린더에 지금 등록하거나 알림을 선택할 수 있습니다.",
                allowsNextAction: true
            )
        case (.addTodoPriority, .addTodo):
            return AppTutorialHint(
                title: "우선순위 선택",
                body: "기본 우선순위는 자동입니다. 추가 옵션에서 필요할 때만 직접 우선순위를 고정하세요.",
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
                body: "우측 상단 더 보기 > 설정 > 할 일 > TODO 우선순위 규칙으로 이동해보세요.",
                bodyKey: "tutorial.todoSettings.priorityRules.fromTodoList.body"
            )

        case (.emailOptional, .todoList):
            return AppTutorialHint(
                title: "설정 다시 열기",
                body: "우측 상단 더 보기 > 설정을 눌러 이메일 연동 항목을 확인해보세요."
            )

        case (.permissions, .todoList):
            return AppTutorialHint(
                title: "설정 다시 열기",
                body: "우측 상단 더 보기 > 설정 > 할 일에서 알림 권한을 확인해보세요.",
                bodyKey: "tutorial.todoSettings.notifications.fromTodoList.body"
            )

        case (.persona, .todoList):
            return AppTutorialHint(
                title: "설정 열기",
                body: "우측 상단 더 보기 > 설정을 눌러 나의 페르소나를 확인해보세요."
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
                body: "할 일을 눌러 TODO 우선순위 규칙이 있는 화면으로 이동해보세요.",
                bodyKey: "tutorial.todoSettings.priorityRules.fromSettings.body"
            )
        case (.priorityRules, .todoSettings):
            return AppTutorialHint(
                title: "우선순위 규칙",
                body: "TODO 우선순위 규칙을 눌러 자동 정렬이 사용하는 규칙을 확인해보세요.",
                bodyKey: "tutorial.todoSettings.priorityRules.openRules.body"
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
                title: "알림 권한",
                body: "할 일을 눌러 알림 권한 상태를 확인해보세요.",
                titleKey: "tutorial.todoSettings.notifications.title",
                bodyKey: "tutorial.todoSettings.notifications.fromSettings.body"
            )
        case (.permissions, .todoSettings):
            return AppTutorialHint(
                title: "알림 권한",
                body: "필요하면 알림 권한을 허용해 마감 알림을 받으세요. 알림은 선택이며, 허용하지 않아도 뒤로 돌아가 튜토리얼을 계속할 수 있습니다.",
                titleKey: "tutorial.todoSettings.notifications.title",
                bodyKey: "tutorial.todoSettings.notifications.reviewPermission.body"
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
                body: "AI 정리 버튼을 눌러 실제 자동 정렬을 실행해보세요. 할 일이 없으면 먼저 하나 추가한 뒤 눌러보세요.",
                bodyKey: "tutorial.body.왼쪽 위 AI 정리 버튼을 눌러 실제 자동 정렬을 실행해보세요. 할 일이 없으면 먼저 하나 추가한 뒤 눌러보세요."
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
// An EnvironmentKey carries a reference but does not subscribe to its publisher.
// Re-evaluate controls and scroll targets as well as the hint when steps change.
// Place inside lazy navigation/scroll builders so their task IDs see each step.
struct AppTutorialObserving<Content: View>: View {
    @Environment(\.appTutorialState) private var tutorial
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let tutorial {
            AppTutorialObservedContent(tutorial: tutorial, content: content)
        } else {
            content()
        }
    }
}

private struct AppTutorialObservedContent<Content: View>: View {
    @ObservedObject var tutorial: AppTutorialState
    let content: () -> Content

    var body: some View { content() }
}


struct AppTutorialView: View {
    @Binding var selectedTab: Int
    let tabVisibility: AppTabVisibility

    @Environment(\.appTutorialState) private var tutorial

    var body: some View {
        AppTutorialObserving {
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
}

/// Toolbar guidance stays under the toolbar, never over its buttons. Guidance
/// for an entire screen has no pointer pretending to identify a single control.
struct AppTutorialTipHost: View {
    @ObservedObject var tutorial: AppTutorialState
    let screen: AppTutorialScreen

    private var showsHint: Bool {
        switch screen {
        case .todoList, .personaDetail, .aiDetail, .emailDetail, .calendarTab, .mailTab:
            return true
        case .settings:
            return tutorial.currentStep == .calendarEnabled || tutorial.currentStep == .mailEnabled
                || tutorial.currentStep == .autoSort
        case .addTodo:
            return tutorial.currentStep == .addTodoSave
        case .todoSettings:
            return false
        }
    }

    private var isToolbarHint: Bool {
        switch screen {
        case .todoList, .settings, .addTodo: true
        default: false
        }
    }

    var body: some View {
        if showsHint, let hint = tutorial.hint(for: screen) {
            AppTutorialCard(hint: hint)
                .environment(\.appTutorialState, tutorial)
                .frame(maxWidth: isToolbarHint ? 360 : 520)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: isToolbarHint ? .trailing : .leading)
        }
    }
}

private struct AppTutorialAnchorModifier: ViewModifier {
    @Environment(\.appTutorialState) private var tutorial
    let screen: AppTutorialScreen
    let steps: [AppTutorialStep]
    let above: Bool

    func body(content: Content) -> some View {
        if let tutorial {
            content.modifier(AppTutorialObservedAnchor(
                tutorial: tutorial, screen: screen, steps: steps, above: above
            ))
        } else {
            content
        }
    }
}

private struct AppTutorialObservedAnchor: ViewModifier {
    @ObservedObject var tutorial: AppTutorialState
    let screen: AppTutorialScreen
    let steps: [AppTutorialStep]
    let above: Bool

    private var hint: AppTutorialHint? {
        guard let step = tutorial.currentStep, steps.contains(step) else { return nil }
        return tutorial.hint(for: screen)
    }

    func body(content: Content) -> some View {
        if let hint {
            // Inline layout reserves space for the hint. There is no dismiss
            // region, coordinate conversion, or transparent view over the target.
            VStack(alignment: .leading, spacing: 10) {
                if above { AppTutorialCard(hint: hint).frame(maxWidth: 420) }
                content
                if !above { AppTutorialCard(hint: hint).frame(maxWidth: 420) }
            }
        } else {
            content
        }
    }
}

extension View {
    func appTutorialAnchor(
        screen: AppTutorialScreen, steps: [AppTutorialStep], above: Bool = false
    ) -> some View {
        modifier(AppTutorialAnchorModifier(screen: screen, steps: steps, above: above))
    }
}

struct AppTutorialGlowModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                        .stroke(AppTheme.accent.opacity(0.6), lineWidth: 2)
                        .padding(-5)
                        .allowsHitTesting(false)
                }
            }
    }

}

extension View {
    func appTutorialGlow(_ active: Bool) -> some View {
        modifier(AppTutorialGlowModifier(active: active))
    }
}

private struct AppTutorialCard: View {
    let hint: AppTutorialHint

    @Environment(\.appTutorialState) private var tutorial

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            HStack(alignment: .top) {
                Text(hint.localizedTitle)
                    .font(.headline)
                Spacer()
                Button(AppTutorialCopy.endTutorial) {
                    tutorial?.stop(markCompleted: true)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("tutorial.end")
            }

            Text(hint.localizedBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hint.allowsNextAction {
                Button(AppTutorialCopy.next) {
                    tutorial?.advanceFromTip()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tutorial.next")
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.section)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tutorial.hint")
    }
}

