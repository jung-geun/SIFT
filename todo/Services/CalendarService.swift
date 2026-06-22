import Foundation
import EventKit
import SwiftData

/// EventKit을 통해 iCloud·Google 캘린더를 읽고 TODO 마감을 캘린더에 등록.
///
/// 사용자가 기기 설정 > 계정에서 캘린더 계정을 추가하면 EKEventStore에 자동 포함.
/// → Gmail/iCloud 캘린더 별도 OAuth 불필요.
final class CalendarService {
    static let shared = CalendarService()
    private init() {}

    private let store = EKEventStore()
    private(set) var isAuthorized = false

    // MARK: - Authorization

    /// 앱 시작 시 기존에 허용된 캘린더 권한을 복원.
    /// 시스템 권한 다이얼로그를 표시하지 않고 현재 상태만 읽음.
    /// 앱 업데이트 후에도 isAuthorized가 false로 초기화되는 문제를 해결.
    func restoreAuthorizationIfGranted() {
        let status = EKEventStore.authorizationStatus(for: .event)
        isAuthorized = status == .fullAccess
    }

    /// iOS 17+ full access 요청 (읽기 + 쓰기)
    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            isAuthorized = granted
            return granted
        } catch {
            isAuthorized = false
            return false
        }
    }

    // MARK: - 이벤트 읽기

    struct CalendarEventSummary: Sendable {
        let title: String
        let startDate: Date
        let endDate: Date
        let isRecurring: Bool
        let identifier: String
        let calendarTitle: String
    }

    /// 향후 N일 이내 이벤트 목록 (반복 일정 자동 전개 포함)
    func upcomingEvents(days: Int = 30) -> [CalendarEventSummary] {
        guard isAuthorized else { return [] }
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEventSummary(
                title: event.title ?? "",
                startDate: event.startDate,
                endDate: event.endDate,
                isRecurring: event.hasRecurrenceRules,
                identifier: event.eventIdentifier ?? "",
                calendarTitle: event.calendar?.title ?? ""
            )
        }.sorted { $0.startDate < $1.startDate }
    }

    /// 반복 일정만 필터링
    func recurringEvents(days: Int = 90) -> [CalendarEventSummary] {
        upcomingEvents(days: days).filter { $0.isRecurring }
    }

    // MARK: - TODO → 캘린더 등록

    /// todo의 dueDate를 캘린더 이벤트로 등록하고 eventIdentifier를 반환.
    /// 이미 등록된 이벤트(calendarEventID 있음)가 있으면 업데이트.
    @discardableResult
    func registerOrUpdate(todo: Todo) throws -> String? {
        guard isAuthorized, let dueDate = todo.dueDate else { return nil }

        // 기존 이벤트 업데이트
        if let existingID = todo.calendarEventID,
           let event = store.event(withIdentifier: existingID) {
            event.title = todo.title.isEmpty ? "할 일 마감" : todo.title
            event.startDate = dueDate
            event.endDate = dueDate.addingTimeInterval(3600)
            event.notes = todo.notes
            try store.save(event, span: .thisEvent)
            return existingID
        }

        // 신규 등록
        let event = EKEvent(eventStore: store)
        event.title = todo.title.isEmpty ? "할 일 마감" : todo.title
        event.startDate = dueDate
        event.endDate = dueDate.addingTimeInterval(3600)
        event.notes = todo.notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier
    }

    /// 캘린더에서 이벤트 제거 (todo 삭제·완료 시)
    func removeEvent(eventID: String) throws {
        guard isAuthorized,
              let event = store.event(withIdentifier: eventID) else { return }
        try store.remove(event, span: .thisEvent)
    }

    /// 이벤트를 삭제하지 않고 알람(리마인더)만 모두 제거.
    /// 외부 캘린더(Google 등) 이벤트처럼 삭제하기 부담스러울 때 사용.
    func removeAlarms(eventID: String) throws {
        guard isAuthorized,
              let event = store.event(withIdentifier: eventID) else { return }
        guard !(event.alarms ?? []).isEmpty else { return }
        event.alarms = []
        try store.save(event, span: .thisEvent)
    }

    // MARK: - 이메일 → 캘린더 자동 등록

    private let emailMappingKey = "pieroot.todo.emailEventMapping"

    private var emailEventMapping: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: emailMappingKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: emailMappingKey) }
    }

    func hasEvent(forEmailRef ref: String) -> Bool {
        // fast-path: 매핑 ID가 여전히 resolve되면 바로 반환
        if let id = emailEventMapping[ref], store.event(withIdentifier: id) != nil { return true }
        // 콘텐츠 스캔 폴백 (날짜 모르므로 광범위 ±30일)
        guard isAuthorized else { return false }
        let start = Date().addingTimeInterval(-30 * 86400)
        let end   = Date().addingTimeInterval( 30 * 86400)
        let pred  = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: pred).contains { event in
            event.url?.scheme == "x-todoapp-email" && event.url?.host == ref
        }
    }

    /// sourceRef를 URL로 임베드한 이벤트를 EventKit 스캔으로 찾는다.
    /// Google/CalDAV 동기화 후 eventIdentifier가 재할당돼도 URL은 유지됨.
    private func findEmailEvent(sourceRef: String, near date: Date) -> EKEvent? {
        guard isAuthorized else { return nil }
        // 지정 날짜 ±7일 윈도우 스캔 (CalDAV 지연 여유)
        let start = date.addingTimeInterval(-7 * 86400)
        let end   = date.addingTimeInterval( 7 * 86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).first { event in
            event.url?.scheme == "x-todoapp-email" && event.url?.host == sourceRef
        }
    }

    @discardableResult
    func createEventFromEmail(
        title: String,
        start: Date,
        end: Date?,
        isAllDay: Bool,
        location: String,
        notes: String,
        sourceRef: String
    ) throws -> String {
        guard isAuthorized else { throw CalendarError.notAuthorized }

        // ① fast-path: 매핑 ID가 여전히 resolve되면 바로 반환
        if let existing = emailEventMapping[sourceRef],
           store.event(withIdentifier: existing) != nil { return existing }

        // ② 콘텐츠 스캔: ID 재할당됐어도 URL로 찾기
        if let found = findEmailEvent(sourceRef: sourceRef, near: start) {
            var mapping = emailEventMapping
            mapping[sourceRef] = found.eventIdentifier
            emailEventMapping = mapping
            return found.eventIdentifier
        }

        let event       = EKEvent(eventStore: store)
        event.title     = title.isEmpty ? "(제목 없음)" : title
        event.startDate = start
        event.endDate   = end ?? start.addingTimeInterval(isAllDay ? 86400 : 3600)
        event.isAllDay  = isAllDay
        if !location.isEmpty { event.location = location }
        if !notes.isEmpty    { event.notes    = notes }
        event.url       = URL(string: "x-todoapp-email://\(sourceRef.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? sourceRef)")
        event.calendar  = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)

        var mapping = emailEventMapping
        mapping[sourceRef] = event.eventIdentifier
        emailEventMapping = mapping
        return event.eventIdentifier
    }
}

// MARK: - CalendarService + 자동 등록

extension CalendarService {

    /// 마감일이 있는 todo를 캘린더에 자동 등록한다 (중복 방지 내장).
    /// - 캘린더 출처 todo는 역방향 재등록 방지를 위해 무시.
    /// - 권한 없음·마감 없음·이미 등록된 경우 무시.
    /// - 마감이 있으면 우선순위·정책과 무관하게 항상 등록됨.
    @discardableResult
    func applyAutoRegistration(for todo: Todo) -> Bool {
        // 캘린더 출처 todo는 재등록하지 않음 (역방향 중복 방지)
        guard todo.todoSource != .calendar else { return false }
        // 권한 없음·마감 없음·이미 등록됨이면 무시
        guard isAuthorized, todo.dueDate != nil, todo.calendarEventID == nil else { return false }
        if let id = try? registerOrUpdate(todo: todo) {
            todo.calendarEventID = id
            return true
        }
        return false
    }
}

// MARK: - 캘린더 자동 등록 정책 (UserDefaults 기반)

/// 마감을 캘린더에 자동 등록할지 여부를 사용자 선택으로 결정하는 정책 헬퍼.
/// 첫 등록 시점에 1회 물어보고 선택을 영속화한다. 이후 설정에서 변경 가능.
enum CalendarAutoPolicy {
    private static let choiceKey = "pieroot.todo.calendarAutoChoiceMade"
    private static let valueKey  = "pieroot.todo.calendarAutoRegister"

    /// 사용자가 아직 선택하지 않았으면 false
    static var choiceMade: Bool {
        SettingsStore.shared.get(choiceKey, defaultValue: false)
    }
    /// 자동 등록 ON 여부 (choiceMade == false이면 의미 없음)
    static var isAuto: Bool {
        SettingsStore.shared.get(valueKey, defaultValue: false)
    }
    /// 사용자가 선택한 값을 저장. choiceMade도 동시에 true로 설정.
    static func setChoice(auto: Bool) {
        let store = SettingsStore.shared
        let useGlobal = UserDefaults.standard.bool(forKey: "pieroot.todo.iCloudSyncEnabled")
        if useGlobal {
            store.setGlobal(choiceKey, value: true)
            store.setGlobal(valueKey, value: auto)
        } else {
            store.setLocal(choiceKey, value: true)
            store.setLocal(valueKey, value: auto)
        }
    }
    /// 설정에서 값만 변경(이미 선택됐다고 간주).
    static func setValue(auto: Bool) {
        setChoice(auto: auto)
    }
}

// MARK: - Error

enum CalendarError: LocalizedError {
    case notAuthorized
    var errorDescription: String? {
        "캘린더 접근 권한이 없습니다. 설정 > 개인정보 보호에서 허용해주세요."
    }
}

// MARK: - 캘린더 → TODO 주간 import (양방향 연동)

extension CalendarService {

    private static let weeklyImportKey = "pieroot.todo.lastCalendarImportDate"

    /// 7일 쿨다운으로 캘린더 → TODO 주간 import를 실행.
    /// LLM 불필요 — EventKit 읽기 + SwiftData 쓰기만 수행.
    @MainActor
    func runWeeklyImportIfDue(context: ModelContext) async {
        guard isAuthorized else { return }
        let last = UserDefaults.standard.double(forKey: Self.weeklyImportKey)
        let sevenDays: TimeInterval = 7 * 24 * 3600
        // 첫 실행 시 last == 0 이므로 항상 통과
        guard Date().timeIntervalSince1970 - last >= sevenDays else { return }
        await syncCalendarTodos(context: context)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.weeklyImportKey)
    }

    /// 향후 30일 캘린더 이벤트를 TODO에 동기화.
    ///
    /// - 기존 캘린더 출처 todo(occurrence 키 일치): 제목·마감·고정 여부만 갱신, triageStatus·isCompleted 보존.
    /// - linkedEventIDs(앱이 만든 캘린더 이벤트): 역import 차단. ⚠️ calendar 출처 todo는 제외 —
    ///   반복 일정의 모든 occurrence가 동일 identifier를 공유하므로 포함하면 새 occurrence가 영구 스킵됨.
    /// - 신규 이벤트: source=.calendar, triage=.review, isFixedSchedule=event.isRecurring으로 삽입.
    /// - applyAutoRegistration 호출 안 함 → 캘린더 역방향 재등록 방지.
    @MainActor
    func syncCalendarTodos(context: ModelContext) async {
        let allEvents = upcomingEvents(days: 30).filter { !$0.identifier.isEmpty }
        guard !allEvents.isEmpty else { return }

        let now = Date()
        var todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []

        // 1. 등록 대기열 만료 항목 자동 제거 (마감 지났지만 진행중 미등록)
        for todo in todos where todo.triage == .review && !todo.isCompleted {
            if let due = todo.dueDate, due < now { context.delete(todo) }
        }
        todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []

        let iso = ISO8601DateFormatter()
        var calendarTodosByRef: [String: Todo] = [:]
        for todo in todos where todo.todoSource == .calendar {
            calendarTodosByRef[todo.sourceRef] = todo
        }

        // 앱이 만든 캘린더 이벤트(manual/email 출처)만 역import 차단
        // calendar 출처 todo는 제외 — 반복 일정 occurrence dedup은 calendarTodosByRef가 전담
        let linkedEventIDs = Set(
            todos.filter { $0.todoSource != .calendar }.compactMap { $0.calendarEventID }
        )

        // 2. 반복 일정: identifier별 가장 빠른 다음 occurrence 1개만 처리
        //    비반복 일정: 30일 이내 전체
        var recurringNextByID: [String: CalendarEventSummary] = [:]
        var nonRecurringEvents: [CalendarEventSummary] = []
        for event in allEvents {
            if event.isRecurring {
                if let existing = recurringNextByID[event.identifier] {
                    if event.startDate < existing.startDate { recurringNextByID[event.identifier] = event }
                } else {
                    recurringNextByID[event.identifier] = event
                }
            } else {
                nonRecurringEvents.append(event)
            }
        }
        let eventsToProcess = Array(recurringNextByID.values) + nonRecurringEvents

        for event in eventsToProcess {
            let ref = "\(event.identifier)#\(iso.string(from: event.startDate))"

            if let existing = calendarTodosByRef[ref] {
                // 동기화: 제목·마감·고정 여부만 갱신, triageStatus·isCompleted 보존
                existing.title           = event.title
                existing.dueDate         = event.startDate
                existing.isFixedSchedule = event.isRecurring

            } else if linkedEventIDs.contains(event.identifier) {
                // 앱이 만든 캘린더 이벤트의 역import 방지
                continue

            } else {
                // 반복 일정: 이미 진행중(triage=.todo, 미완료)인 항목이 있으면 스킵
                if event.isRecurring {
                    let hasActive = todos.contains {
                        $0.todoSource == .calendar
                        && $0.calendarEventID == event.identifier
                        && $0.triage == .todo
                        && !$0.isCompleted
                    }
                    if hasActive { continue }
                }

                // 보조 콘텐츠 매칭: identifier 재할당(Google/CalDAV) 대비
                let startLow  = event.startDate.addingTimeInterval(-60)
                let startHigh = event.startDate.addingTimeInterval(60)
                let isDuplicate = calendarTodosByRef.values.contains {
                    $0.title == event.title
                    && ($0.dueDate.map { $0 >= startLow && $0 <= startHigh } ?? false)
                }
                if isDuplicate { continue }

                // 신규 삽입: 등록 대기열에만, 캘린더 재등록 없음
                let todo = Todo(
                    title: event.title,
                    dueDate: event.startDate,
                    source: .calendar,
                    sourceRef: ref
                )
                todo.calendarEventID = event.identifier
                todo.triageStatus    = TodoTriage.review.rawValue
                todo.isFixedSchedule = event.isRecurring
                context.insert(todo)
            }
        }
    }

    /// 어플과 캘린더의 일정을 양방향으로 동기화하고, 충돌 시 최근 수정된 내용을 우선하여 갱신합니다.
    @MainActor
    func syncCalendarWithTodos(context: ModelContext) async {
        guard isAuthorized else { return }

        // 외부 캘린더 소스 실시간 리프레시 및 캐시 무효화
        store.reset()
        store.refreshSourcesIfNecessary()

        let descriptor = FetchDescriptor<Todo>()
        guard let todos = try? context.fetch(descriptor) else { return }

        var hasChanges = false

        for todo in todos {
            // 캘린더에서 역수입한 todo는 이 메서드의 관리 대상이 아님
            if todo.todoSource == .calendar { continue }

            // 어플에서 생성된 할 일인데 마감이 설정되었지만 캘린더 ID가 없는 경우 -> 자동 등록
            if todo.dueDate != nil && todo.calendarEventID == nil {
                if let eventID = try? registerOrUpdate(todo: todo) {
                    todo.calendarEventID = eventID
                    // 저장 성공 후 이벤트의 수정 시간을 어플의 updatedAt과 정확히 싱크
                    if let savedEvent = store.event(withIdentifier: eventID) {
                        todo.updatedAt = savedEvent.lastModifiedDate ?? Date()
                    } else {
                        todo.updatedAt = Date()
                    }
                    hasChanges = true
                }
                continue
            }

            // 캘린더 ID가 매핑되어 있는 경우 -> 캘린더 변경분을 어플로 갱신 (단방향 동기화)
            // 어플에서의 수정사항은 이미 UI단에서 캘린더로 즉시 내보내졌으므로, 
            // 전역 동기화 시점에는 캘린더가 항상 신뢰할 수 있는 소스입니다.
            if let eventID = todo.calendarEventID {
                if let event = store.event(withIdentifier: eventID) {
                    // 실제 데이터 차이가 있는지 명시적으로 검증
                    let isTitleChanged = todo.title != (event.title ?? "")
                    let isNotesChanged = todo.notes != (event.notes ?? "")
                    let isDueDateChanged = todo.dueDate != event.startDate

                    if isTitleChanged || isNotesChanged || isDueDateChanged {
                        // 캘린더의 수정 시각이 변경되었거나 데이터에 차이가 있다면 어플 Todo를 캘린더 정보로 갱신
                        todo.title = event.title ?? ""
                        todo.dueDate = event.startDate
                        todo.notes = event.notes ?? ""
                        todo.updatedAt = event.lastModifiedDate ?? event.creationDate ?? Date()
                        hasChanges = true
                    }
                } else {
                    // 캘린더에서 이벤트가 삭제된 경우 -> 어플에서도 마감 정보 해제
                    todo.calendarEventID = nil
                    todo.dueDate = nil
                    todo.updatedAt = Date()
                    hasChanges = true
                }
            }
        }

        // 변경된 데이터가 있다면 SwiftData DB에 영속화하여 View 갱신
        if hasChanges {
            try? context.save()
        }
    }

    /// Application Support 폴더 내 SQLite 관련 파일들의 크기 총합을 바이트 단위로 반환합니다.
    private func getDatabaseSize() -> Int64 {
        let fileManager = FileManager.default
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return 0 }
        
        var totalSize: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey]
        
        // default.sqlite 및 shm, wal 등 데이터베이스 파일 전체의 실제 점유 크기 측정
        if let enumerator = fileManager.enumerator(at: appSupportURL, includingPropertiesForKeys: keys) {
            for case let fileURL as URL in enumerator {
                let filename = fileURL.lastPathComponent
                if fileURL.pathExtension == "sqlite" || filename.contains("default.sqlite") {
                    if let resources = try? fileURL.resourceValues(forKeys: Set(keys)),
                       let fileSize = resources.fileSize {
                        totalSize += Int64(fileSize)
                    }
                }
            }
        }
        return totalSize
    }

    /// 데이터베이스 파일 용량이 500MB를 초과하는 경우, 완료된 항목 중 가장 오래된 것부터 순차적으로 삭제합니다.
    @MainActor
    func cleanupOldCompletedTodos(context: ModelContext) async {
        let maxSizeLimit: Int64 = 500 * 1024 * 1024 // 500MB
        
        var currentSize = getDatabaseSize()
        guard currentSize > maxSizeLimit else { return }
        
        // 완료된 할 일 중 완료일(completedAt)이 오래된 순으로 정렬하여 조회
        let descriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> { $0.isCompleted },
            sortBy: [SortDescriptor(\.completedAt, order: .forward)]
        )
        
        guard let completedTodos = try? context.fetch(descriptor), !completedTodos.isEmpty else { return }
        
        var deletedCount = 0
        for todo in completedTodos {
            context.delete(todo)
            deletedCount += 1
            
            // 50개 삭제할 때마다 임시 저장 및 실제 용량 재평가 (과도한 파일 I/O 방지)
            if deletedCount % 50 == 0 {
                try? context.save()
                currentSize = getDatabaseSize()
                if currentSize <= maxSizeLimit {
                    break
                }
            }
        }
        
        if deletedCount % 50 != 0 {
            try? context.save()
        }
        
        print("[Database Cleanup] 용량 초과로 완료된 할 일 \(deletedCount)개 삭제 완료. 현재 용량: \(getDatabaseSize() / 1024 / 1024)MB")
    }
}
