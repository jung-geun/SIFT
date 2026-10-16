import SwiftUI
import SwiftData
import UserNotifications

struct ScheduleApprovalView: View {
    let todoID: UUID?
    let suggestion: RoutineSuggestion?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pieroot.todo.schedule.availabilityStartHour") private var openingHour = 9
    @AppStorage("pieroot.todo.schedule.availabilityEndHour") private var closingHour = 22
    @State private var candidate: Todo?
    @State private var recommendation: ScheduleRecommendation?
    @State private var originalDeadline: Date?
    @State private var originalTitle = ""
    @State private var originalDuration = 30
    @State private var calendarAuthorized = false
    @State private var allowUncheckedCalendar = false
    @State private var exportCalendar = false
    @State private var remindAtStart = false
    @State private var isApplying = false
    @State private var savedTodoID: UUID?
    @State private var errorMessage: String?

    init(todoID: UUID) { self.todoID = todoID; suggestion = nil }
    init(suggestion: RoutineSuggestion) { self.suggestion = suggestion; todoID = nil }

    var body: some View {
        NavigationStack {
            Form {
                if let candidate {
                    Section(copy("schedule.task.title", fallback: "할 일")) {
                        Text(candidate.title).font(.headline)
                        Text(RoutineViewCopy.count("schedule.duration", candidate.estimatedDurationMinutes, fallback: "예상 소요 시간: %lld분"))
                        if let originalDeadline {
                            LabeledContent(copy("schedule.deadline.current", fallback: "기존 마감"), value: RoutineViewCopy.date(originalDeadline))
                            Text(copy("schedule.deadline.explanation", fallback: "승인하면 시작·마감이 아래 일정 구간으로 변경됩니다. 추천 종료는 기존 마감을 넘지 않습니다."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(copy("schedule.availability.title", fallback: "가용 시간")) {
                    Picker(copy("schedule.start", fallback: "시작"), selection: $openingHour) {
                        ForEach(0..<24) { hour in Text(String(format: "%02d:00", locale: AppLanguage.current.locale, hour)).tag(hour) }
                    }
                    Picker(copy("schedule.end", fallback: "종료"), selection: $closingHour) {
                        ForEach(1...24, id: \.self) { hour in Text(String(format: "%02d:00", locale: AppLanguage.current.locale, hour)).tag(hour) }
                    }
                    Button(copy("schedule.refresh", fallback: "충돌 검사·다시 추천")) { prepare() }
                        .disabled(isApplying || savedTodoID != nil)
                        .accessibilityIdentifier("schedule.refresh")
                }
                Section(copy("schedule.calendar.title", fallback: "캘린더 검사")) {
                    if calendarAuthorized {
                        Label(copy("schedule.calendar.checked", fallback: "기존 일정·할 일과 겹치지 않는 구간을 검사합니다"), systemImage: "checkmark.shield")
                        Toggle(copy("schedule.calendar.export", fallback: "승인한 일정을 캘린더에도 등록"), isOn: $exportCalendar)
                            .disabled(candidate?.calendarEventID != nil)
                    } else {
                        Button(copy("schedule.calendar.allow", fallback: "캘린더 접근 허용·충돌 검사")) {
                            Task {
                                _ = await CalendarService.shared.requestAccess()
                                prepare()
                            }
                        }
                        Toggle(copy("schedule.calendar.unchecked", fallback: "캘린더 충돌을 검사하지 않고 진행"), isOn: $allowUncheckedCalendar)
                        Text(copy("schedule.calendar.explanation", fallback: "권한이 없으면 다른 캘린더의 충돌 여부를 알 수 없습니다. 앱 안의 확정된 할 일만 검사합니다."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section(copy("schedule.recommendation.title", fallback: "추천 일정")) {
                    if let recommendation {
                        LabeledContent(copy("schedule.start", fallback: "시작"), value: RoutineViewCopy.date(recommendation.start))
                        LabeledContent(copy("schedule.endDue", fallback: "종료·마감"), value: RoutineViewCopy.date(recommendation.end))
                        Toggle(copy("schedule.reminder.start", fallback: "시작 시각에 알림"), isOn: $remindAtStart)
                            .accessibilityIdentifier("schedule.remindAtStart")
                        Text(copy("schedule.reminder.explanation", fallback: "알림은 직접 선택한 경우에만 권한을 확인·요청합니다. 기존 알림은 승인한 새 마감 기준으로 유지됩니다."))
                            .font(.caption).foregroundStyle(.secondary)
                        if savedTodoID == nil {
                            Button(copy("schedule.approve", fallback: "이 일정으로 승인·저장")) {
                                Task { await approve() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isApplying || (!calendarAuthorized && !allowUncheckedCalendar))
                            .accessibilityIdentifier("schedule.approve")
                        } else {
                            Label(copy("schedule.saved", fallback: "할 일이 저장되었습니다"), systemImage: "checkmark.circle")
                                .accessibilityIdentifier("schedule.saved")
                        }
                    } else {
                        Text(copy("schedule.recommendation.empty", fallback: "가용 시간·마감·충돌 조건을 만족하는 구간이 없습니다. 앞으로 14일 이내에서만 찾습니다."))
                            .foregroundStyle(.secondary)
                    }
                    if isApplying { ProgressView() }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
                }
            }
            .navigationTitle(copy("schedule.title", fallback: "일정 승인"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy("action.close", fallback: "닫기")) { dismiss() }.disabled(isApplying)
                }
            }
            .task { prepare() }
            .onChange(of: openingHour) { _, _ in recommendation = nil }
            .onChange(of: closingHour) { _, _ in recommendation = nil }
            .interactiveDismissDisabled(isApplying)
        }
    }

    private func roundedNow() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 300).rounded(.up) * 300)
    }

    private func loadCandidate(from todos: [Todo]) throws -> Todo {
        if let todoID, let todo = todos.first(where: { $0.id == todoID }) { return todo }
        if let suggestion {
            let todo = Todo(title: suggestion.title, source: .manual, sourceRef: suggestion.sourceRef)
            todo.estimatedDurationMinutes = suggestion.estimatedDurationMinutes
            return todo
        }
        throw ScheduleApprovalError.missingTask
    }

    private func propose(_ todo: Todo, todos: [Todo], preferred: Date?) -> ScheduleRecommendation? {
        ScheduleRecommendationService.recommend(
            todo: todo, todos: todos, events: CalendarService.shared.upcomingEvents(days: 14),
            preferredStart: preferred ?? roundedNow(), now: roundedNow(),
            availabilityStartHour: openingHour, availabilityEndHour: closingHour
        )
    }

    private func learnedPreference(for todo: Todo) -> Date? {
        let store = RoutineStore.shared
        guard store.isLearningEnabled, todo.todoSource == .manual,
              let routine = store.routines.first(where: {
                  $0.isConfirmed && !$0.isSuppressed && $0.activityKey == RoutineLearningService.activityKey(todo.title)
              }) else { return nil }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: routine.timeZoneIdentifier) ?? .current
        return RoutineLearningService.localTime(on: Date(), hour: routine.preferredHour,
                                               minute: routine.preferredMinute, calendar: calendar)
    }

    private func prepare() {
        guard savedTodoID == nil else { return }
        do {
            let todos = try modelContext.fetch(FetchDescriptor<Todo>())
            try RoutineStore.shared.reconcileAcceptances(todos: todos)
            let todo = try loadCandidate(from: todos)
            candidate = todo
            originalDeadline = todo.dueDate
            originalTitle = todo.title
            originalDuration = todo.estimatedDurationMinutes
            CalendarService.shared.restoreAuthorizationIfGranted()
            calendarAuthorized = CalendarService.shared.isAuthorized
            exportCalendar = todo.calendarEventID != nil
            recommendation = propose(todo, todos: todos, preferred: suggestion?.preferredStart ?? learnedPreference(for: todo) ?? todo.aiRecommendedTime ?? todo.startDate)
            errorMessage = nil
        } catch { errorMessage = uiErrorMessage(error); recommendation = nil }
    }

    private func approve() async {
        guard !isApplying, savedTodoID == nil, let approved = recommendation else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            if remindAtStart {
                var status = await NotificationService.shared.authorizationStatus()
                if status == .notDetermined {
                    _ = await NotificationService.shared.requestAuthorization()
                    status = await NotificationService.shared.authorizationStatus()
                }
                guard status == .authorized || status == .provisional || status == .ephemeral else {
                    throw ScheduleApprovalError.notificationDenied
                }
            }
            try Task.checkCancellation()
            // Establish a durable baseline before a rollback could discard unrelated edits.
            if modelContext.hasChanges { try modelContext.save() }
            let todos = try modelContext.fetch(FetchDescriptor<Todo>())
            let todo = try loadCandidate(from: todos)
            CalendarService.shared.restoreAuthorizationIfGranted()
            calendarAuthorized = CalendarService.shared.isAuthorized
            guard calendarAuthorized || allowUncheckedCalendar else { throw ScheduleApprovalError.calendarUnchecked }
            if todoID != nil, (todo.dueDate != originalDeadline || todo.title != originalTitle || todo.estimatedDurationMinutes != originalDuration) {
                prepare()
                throw ScheduleApprovalError.changed
            }
            // Recheck precisely the approved interval, not another unseen suggestion.
            guard let fresh = propose(todo, todos: todos, preferred: approved.start), fresh == approved else {
                prepare()
                throw ScheduleApprovalError.changed
            }
            var acceptance: RoutineAcceptance?
            if let suggestion {
                acceptance = try RoutineStore.shared.beginAcceptance(suggestion, todos: todos,
                                                                      appliedTime: approved.start, todoID: todo.id)
            }
            let beforeDue = todo.dueDate
            todo.startDate = approved.start
            todo.dueDate = approved.end
            todo.aiRecommendedTime = approved.start
            todo.updatedAt = Date()
            if remindAtStart {
                let offset = -approved.end.timeIntervalSince(approved.start)
                if !todo.reminderOffsets.contains(offset) { todo.reminderOffsets.append(offset) }
            }
            if suggestion != nil {
                todo.tags = ["routine"]
                modelContext.insert(todo)
                TaskBehaviorRecorder.recordCreation(of: todo, actor: .user, in: modelContext)
            } else {
                TaskBehaviorRecorder.recordDueDateChange(of: todo, from: beforeDue, to: approved.end,
                                                         actor: .user, in: modelContext)
            }
            do { try modelContext.save() }
            catch {
                modelContext.rollback()
                if let acceptance { try RoutineStore.shared.cancelAcceptance(acceptance.id) }
                throw error
            }
            savedTodoID = todo.id
            await NotificationService.shared.update(todo: todo)
            // A commit failure keeps the durable reservation. Never roll back a saved task.
            if let acceptance { try RoutineStore.shared.commitAcceptance(acceptance.id) }
            if exportCalendar {
                guard calendarAuthorized, try CalendarService.shared.registerOrUpdate(todo: todo) != nil else {
                    throw ScheduleApprovalError.calendarSave
                }
                try modelContext.save()
            }
            dismiss()
        } catch is CancellationError {
            errorMessage = copy("schedule.error.cancelled", fallback: "요청이 취소되었습니다.")
        } catch {
            let message = uiErrorMessage(error)
            errorMessage = savedTodoID == nil ? message
                : RoutineViewCopy.format("schedule.error.savedFollowUp", fallback: "할 일은 저장되었습니다. 후속 처리 확인 실패: %@", message)
        }
    }

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current)
    }

    private func uiErrorMessage(_ error: Error) -> String {
        if let error = error as? ScheduleApprovalError {
            return error.errorDescription ?? copy("schedule.error.failed", fallback: "일정 처리를 완료하지 못했습니다. 다시 시도하세요.")
        }
        if error is RoutineStoreError {
            return RoutineViewCopy.errorMessage(error)
        }
        return copy("schedule.error.failed", fallback: "일정 처리를 완료하지 못했습니다. 다시 시도하세요.")
    }
}

private enum ScheduleApprovalError: LocalizedError {
    case missingTask, changed, calendarUnchecked, notificationDenied, calendarSave
    var errorDescription: String? {
        switch self {
        case .missingTask: AppLanguage.localized("schedule.error.missingTask", defaultValue: "할 일을 더 이상 찾을 수 없습니다.", language: .current)
        case .changed: AppLanguage.localized("schedule.error.changed", defaultValue: "할 일이나 가용 구간이 변경되었습니다. 승인 전에 새로 추천한 일정을 검토하세요.", language: .current)
        case .calendarUnchecked: AppLanguage.localized("schedule.error.calendarUnchecked", defaultValue: "캘린더 접근을 허용하거나 캘린더 충돌 검사 없이 진행하도록 직접 선택하세요.", language: .current)
        case .notificationDenied: AppLanguage.localized("schedule.error.notificationDenied", defaultValue: "알림 권한이 허용되지 않았습니다. 시스템 설정에서 허용하거나 새 알림을 끄세요.", language: .current)
        case .calendarSave: AppLanguage.localized("schedule.error.calendarSave", defaultValue: "할 일은 저장되었지만 캘린더 일정은 확인하지 못했습니다.", language: .current)
        }
    }
}
