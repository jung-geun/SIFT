import Foundation
import EventKit
import SwiftData


/// EventKit이 보존하는 URL 필드에 저장하는 SIFT 소유권 마커.
///
/// `eventIdentifier`는 기기별이고 SwiftData는 재설치 시 사라질 수 있으므로, 이
/// 버전 있는 마커가 SIFT가 만든 이벤트를 외부 캘린더 import와 구별하는 기준이다.
struct CalendarEventMarker: Equatable, Sendable {
    enum Entity: String, Sendable, Equatable {
        case todo
        case standaloneEvent = "event"
    }

    let entity: Entity
    let identifier: UUID
    let origin: CalendarEventOrigin

    private static let scheme = "sift-calendar"
    private static let version = "1"

    static func url(
        entity: Entity,
        identifier: UUID,
        origin: CalendarEventOrigin
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = entity.rawValue
        components.path = "/\(identifier.uuidString)"
        components.queryItems = [
            URLQueryItem(name: "v", value: version),
            URLQueryItem(name: "origin", value: origin.rawValue)
        ]
        return components.url
    }

    static func parse(_ url: URL?) -> CalendarEventMarker? {
        guard let url else { return nil }
        if url.scheme == "sift-todo" {
            return parseLegacy(url)
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let entity = Entity(rawValue: components.host ?? ""),
              let identifier = UUID(uuidString: components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        else {
            return nil
        }
        let queryItems = components.queryItems ?? []
        let versionValue = queryItems.first(where: { $0.name == "v" })?.value
        let originRawValue = queryItems.first(where: { $0.name == "origin" })?.value
        guard components.scheme == scheme,
              versionValue == version,
              let originRawValue,
              let origin = CalendarEventOrigin(rawValue: originRawValue),
              origin.isSiftManaged
        else {
            return nil
        }
        return CalendarEventMarker(entity: entity, identifier: identifier, origin: origin)
    }

    /// v1 이전 이벤트도 소유권은 식별할 수 있다. 세부 생성 경로가 없으므로
    /// 수동 SIFT 일정으로 보수적으로 복원한다.
    private static func parseLegacy(_ url: URL?) -> CalendarEventMarker? {
        guard let url,
              url.scheme == "sift-todo",
              url.host == "todo",
              let identifier = UUID(uuidString: url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        else {
            return nil
        }
        return CalendarEventMarker(entity: .todo, identifier: identifier, origin: .siftManual)
    }
}

/// EventKit의 반복 일정 변경 범위. `allEvents`는 series master에서 `.futureEvents`
/// 를 적용해 해당 반복 시리즈 전체를 대상으로 한다.
enum CalendarRecurrenceScope: Sendable, Equatable {
    case thisEvent
    case futureEvents
    case allEvents
}
/// EventKit을 통해 iCloud·Google 캘린더를 읽고 TODO 마감을 캘린더에 등록.
///
/// 사용자가 기기 설정 > 계정에서 캘린더 계정을 추가하면 EKEventStore에 자동 포함.
/// → Gmail/iCloud 캘린더 별도 OAuth 불필요.
final class CalendarService {
    static let shared = CalendarService()
    private init() {}

    private let store = EKEventStore()

    private static func localizedDeadlineTitle(language: AppLanguage) -> String {
        AppLanguage.localized(
            "calendar.todoDeadline",
            defaultValue: language == .english ? "To-Do Deadline" : "할 일 마감",
            language: language,
            comment: "Calendar event fallback title"
        )
    }
    private(set) var isAuthorized = false
    private var lastStoreRefresh: Date = .distantPast
    private var unresolvedEventIDs = Set<String>()
    private let unresolvedEventIDsLock = NSLock()

    private func cachedUnresolvedEventID(_ identifier: String) -> Bool {
        unresolvedEventIDsLock.lock()
        defer { unresolvedEventIDsLock.unlock() }
        return unresolvedEventIDs.contains(identifier)
    }

    private func markUnresolvedEventID(_ identifier: String) {
        unresolvedEventIDsLock.lock()
        unresolvedEventIDs.insert(identifier)
        unresolvedEventIDsLock.unlock()
    }

    private func markResolvedEventID(_ identifier: String?) {
        guard let identifier, !identifier.isEmpty else { return }
        unresolvedEventIDsLock.lock()
        unresolvedEventIDs.remove(identifier)
        unresolvedEventIDsLock.unlock()
    }

    private func event(withIdentifier identifier: String) -> EKEvent? {
        guard !identifier.isEmpty, !cachedUnresolvedEventID(identifier) else { return nil }
        guard let event = store.event(withIdentifier: identifier) else {
            markUnresolvedEventID(identifier)
            return nil
        }
        return event
    }

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
            NotificationCenter.default.post(name: .calendarAuthorizationChanged, object: nil)
            return granted
        } catch {
            DiagnosticRecorder.shared.record(
                error: error,
                component: "calendar.eventkit",
                operation: "requestAccess"
            )
            isAuthorized = false
            NotificationCenter.default.post(name: .calendarAuthorizationChanged, object: nil)
            return false
        }
    }

    // MARK: - 이벤트 읽기
    struct CalendarEventSummary: Sendable {
        let title: String
        let notes: String
        let startDate: Date
        let endDate: Date
        let isRecurring: Bool
        let isAllDay: Bool
        let identifier: String
        let externalIdentifier: String
        let marker: CalendarEventMarker?
        let calendarTitle: String
        let calendarID: String

        init(
            title: String,
            notes: String = "",
            startDate: Date,
            endDate: Date,
            isRecurring: Bool,
            isAllDay: Bool,
            identifier: String,
            externalIdentifier: String = "",
            marker: CalendarEventMarker? = nil,
            calendarTitle: String,
            calendarID: String
        ) {
            self.title = title
            self.notes = notes
            self.startDate = startDate
            self.endDate = endDate
            self.isRecurring = isRecurring
            self.isAllDay = isAllDay
            self.identifier = identifier
            self.externalIdentifier = externalIdentifier
            self.marker = marker
            self.calendarTitle = calendarTitle
            self.calendarID = calendarID
        }
    }
    private func summary(for event: EKEvent) -> CalendarEventSummary {
        CalendarEventSummary(
            title: event.title ?? "",
            notes: event.notes ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            isRecurring: event.hasRecurrenceRules,
            isAllDay: event.isAllDay,
            identifier: event.eventIdentifier ?? "",
            externalIdentifier: event.calendarItemExternalIdentifier ?? "",
            marker: CalendarEventMarker.parse(event.url),
            calendarTitle: event.calendar?.title ?? "",
            calendarID: event.calendar?.calendarIdentifier ?? ""
        )
    }

    /// 향후 N일 이내 이벤트 목록 (반복 일정 자동 전개 포함)
    func upcomingEvents(days: Int = 30) -> [CalendarEventSummary] {
        guard isAuthorized else { return [] }
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .map(summary(for:))
            .sorted { $0.startDate < $1.startDate }
    }

    /// 반복 일정만 필터링
    func recurringEvents(days: Int = 90) -> [CalendarEventSummary] {
        upcomingEvents(days: days).filter { $0.isRecurring }
    }

    private func applySiftMarker(to event: EKEvent, for todo: Todo) {
        let origin = todo.calendarOrigin
        guard origin.isSiftManaged else { return }
        todo.calendarEventOrigin = origin.rawValue
        event.url = CalendarEventMarker.url(
            entity: .todo,
            identifier: todo.id,
            origin: origin
        )
    }


    // MARK: - TODO → 캘린더 등록

    /// todo의 dueDate를 캘린더 이벤트로 등록하고 eventIdentifier를 반환.
    /// 이미 등록된 이벤트(calendarEventID 있음)가 있으면 업데이트.
    /// todo의 dueDate를 캘린더 이벤트로 등록/업데이트.
    /// - preferredCalendarID: 신규 생성 시 사용할 캘린더 ID (nil이면 기본 캘린더 사용).
    @discardableResult
    func registerOrUpdate(
        todo: Todo,
        preferredCalendarID: String? = nil,
        language: AppLanguage = .current
    ) throws -> String? {
        guard isAuthorized,
              let window = Self.eventWindow(todoStart: todo.startDate, todoDue: todo.dueDate)
        else { return nil }

        // 기존 이벤트 업데이트 — 1순위: 이 기기의 eventIdentifier로 조회
        if let existingID = todo.calendarEventID,
           let event = event(withIdentifier: existingID) {
            event.title = todo.title.isEmpty
                ? Self.localizedDeadlineTitle(language: language)
                : todo.title
            event.startDate = window.start
            event.endDate = window.end
            event.notes = todo.notes
            applySiftMarker(to: event, for: todo)
            try store.save(event, span: .thisEvent)
            todo.calendarSyncedTitle = event.title ?? ""
            markResolvedEventID(event.eventIdentifier)
            return existingID
        }
        // A deleted event identifier is device-local. Clear it before the
        // cross-device recovery path so subsequent edits do not keep querying
        // EventKit for the same missing item.
        todo.calendarEventID = nil

        // 2순위: eventIdentifier가 stale한 경우 externalIdentifier로 재탐색 (store.reset() 후 무효화 방어)
        if !todo.calendarEventExternalID.isEmpty {
            let items = store.calendarItems(withExternalIdentifier: todo.calendarEventExternalID)
            if let found = items.compactMap({ $0 as? EKEvent }).first {
                found.title = todo.title.isEmpty
                    ? Self.localizedDeadlineTitle(language: language)
                    : todo.title
                found.startDate = window.start
                found.endDate = window.end
                found.notes = todo.notes
                applySiftMarker(to: found, for: todo)
                try store.save(found, span: .thisEvent)
                todo.calendarSyncedTitle = found.title ?? ""
                todo.calendarEventID = found.eventIdentifier
                markResolvedEventID(found.eventIdentifier)
                return found.eventIdentifier
            }
        }

        // 신규 등록
        let event = EKEvent(eventStore: store)
        event.title = todo.title.isEmpty
            ? Self.localizedDeadlineTitle(language: language)
            : todo.title
        event.startDate = window.start
        event.endDate = window.end
        event.notes = todo.notes
        if let cid = preferredCalendarID, let cal = store.calendar(withIdentifier: cid) {
            event.calendar = cal
        } else {
            event.calendar = preferredDefaultCalendar
        }
        applySiftMarker(to: event, for: todo)
        try store.save(event, span: .thisEvent)
        todo.calendarSyncedTitle = event.title ?? ""
        markResolvedEventID(event.eventIdentifier)
        // Persist both identifiers because some callers intentionally discard
        // the return value after an in-place update.
        todo.calendarEventID = event.eventIdentifier
        todo.calendarEventExternalID = event.calendarItemExternalIdentifier ?? ""
        return event.eventIdentifier
    }

    /// 캘린더에서 이벤트 제거 (todo 삭제·완료 시, 단일 이벤트용).
    /// - Returns: 실제 EventKit 이벤트를 찾아 삭제했는지 여부.
    func removeEvent(eventID: String) throws -> Bool {
        guard isAuthorized,
              let event = event(withIdentifier: eventID) else { return false }
        try store.remove(event, span: .thisEvent)
        markUnresolvedEventID(eventID)
        return true
    }

    /// 반복 이벤트 삭제 범위:
    /// - thisEvent: 선택한 발생분만 예외로 제거
    /// - futureEvents: 선택한 발생분과 이후 일정 제거
    /// - allEvents: series master에서 삭제해 전체 시리즈 제거
    func removeEventOccurrence(
        eventID: String,
        on date: Date,
        scope: CalendarRecurrenceScope = .thisEvent
    ) throws {
        guard isAuthorized else { return }

        if scope == .allEvents, let series = event(withIdentifier: eventID) {
            try store.remove(series, span: .futureEvents)
            markUnresolvedEventID(eventID)
            return
        }

        let start = date.addingTimeInterval(-60)
        let end   = date.addingTimeInterval(60)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        if let occurrence = store.events(matching: predicate)
            .first(where: { $0.eventIdentifier == eventID }) {
            let span: EKSpan = scope == .thisEvent ? .thisEvent : .futureEvents
            try store.remove(occurrence, span: span)
        } else {
            _ = try removeEvent(eventID: eventID)
        }
    }

    /// 이벤트를 삭제하지 않고 알람(리마인더)만 모두 제거.
    /// 외부 캘린더(Google 등) 이벤트처럼 삭제하기 부담스러울 때 사용.
    func removeAlarms(eventID: String) throws {
        guard isAuthorized,
              let event = event(withIdentifier: eventID) else { return }
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
    static func reconciledEmailEventMapping(
        _ mapping: [String: String],
        for ref: String,
        resolvedIdentifier: String?
    ) -> [String: String] {
        var reconciled = mapping
        if let resolvedIdentifier, !resolvedIdentifier.isEmpty {
            reconciled[ref] = resolvedIdentifier
        } else {
            reconciled.removeValue(forKey: ref)
        }
        return reconciled
    }


    func hasEvent(forEmailRef ref: String) -> Bool {
        // An unavailable calendar store cannot establish that a mapped event
        // was deleted, so it must not mutate the durable mapping.
        guard isAuthorized else { return false }

        var mapping = emailEventMapping
        if let id = mapping[ref] {
            if event(withIdentifier: id) != nil {
                return true
            }
            // EventKit has permanently lost this device-local identifier.
            // Retaining it retries the same failed lookup on every mail sync.
            mapping = Self.reconciledEmailEventMapping(
                mapping,
                for: ref,
                resolvedIdentifier: nil
            )
            emailEventMapping = mapping
        }

        // 콘텐츠 스캔 폴백 (날짜 모르므로 광범위 ±30일)
        let start = Date().addingTimeInterval(-30 * 86400)
        let end   = Date().addingTimeInterval( 30 * 86400)
        let pred  = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        if let event = store.events(matching: pred).first(where: {
            $0.url?.scheme == "x-todoapp-email" && $0.url?.host == ref
        }) {
            mapping = Self.reconciledEmailEventMapping(
                mapping,
                for: ref,
                resolvedIdentifier: event.eventIdentifier
            )
            emailEventMapping = mapping
            return true
        }
        return false
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
    private func clearEmailCalendarReferences(for todo: Todo) {
        if !todo.sourceRef.isEmpty {
            var mapping = emailEventMapping
            mapping.removeValue(forKey: todo.sourceRef)
            emailEventMapping = mapping
        }
        todo.calendarEventID = nil
        todo.calendarEventExternalID = ""
    }

    private func reconcileStaleCalendarReferences(in todos: [Todo]) -> Bool {
        guard isAuthorized else { return false }
        var hasChanges = false

        for todo in todos where todo.todoSource != .calendar {
            guard let eventID = todo.calendarEventID, !eventID.isEmpty else { continue }
            if event(withIdentifier: eventID) != nil { continue }

            if !todo.calendarEventExternalID.isEmpty {
                let items = store.calendarItems(withExternalIdentifier: todo.calendarEventExternalID)
                if let found = items.compactMap({ $0 as? EKEvent }).first,
                   let foundID = found.eventIdentifier,
                   !foundID.isEmpty {
                    todo.calendarEventID = foundID
                    markResolvedEventID(foundID)
                    hasChanges = true
                    continue
                }
            }

            todo.calendarEventID = nil
            hasChanges = true
        }

        return hasChanges
    }

    @discardableResult
    func removeEmailCalendarArtifacts(for todo: Todo) -> Bool {
        guard todo.todoSource == .email, isAuthorized else { return false }

        var eventIDs = Set<String>()
        if let eventID = todo.calendarEventID, !eventID.isEmpty {
            eventIDs.insert(eventID)
        }
        if !todo.sourceRef.isEmpty, let mappedID = emailEventMapping[todo.sourceRef], !mappedID.isEmpty {
            eventIDs.insert(mappedID)
        }
        if !todo.calendarEventExternalID.isEmpty {
            let items = store.calendarItems(withExternalIdentifier: todo.calendarEventExternalID)
            for case let event as EKEvent in items {
                if let eventID = event.eventIdentifier, !eventID.isEmpty {
                    eventIDs.insert(eventID)
                }
            }
        }
        if let dueDate = todo.dueDate,
           !todo.sourceRef.isEmpty,
           let found = findEmailEvent(sourceRef: todo.sourceRef, near: dueDate),
           let foundID = found.eventIdentifier,
           !foundID.isEmpty {
            eventIDs.insert(foundID)
        }

        guard !eventIDs.isEmpty else { return false }
        var removedEventCount = 0
        for eventID in eventIDs {
            do {
                if try removeEvent(eventID: eventID) {
                    removedEventCount += 1
                }
            } catch {
                DiagnosticRecorder.shared.record(
                    error: error,
                    component: "calendar.eventkit",
                    operation: "removeEvent"
                )
                return false
            }
        }

        guard removedEventCount > 0 else { return false }

        clearEmailCalendarReferences(for: todo)
        return true
    }

    @discardableResult
    private func removePendingEmailCalendarLinkIfNeeded(for todo: Todo) -> Bool {
        guard todo.triage != .todo else { return false }
        return removeEmailCalendarArtifacts(for: todo)
    }


    @discardableResult
    func createEventFromEmail(
        title: String,
        start: Date,
        end: Date?,
        isAllDay: Bool,
        location: String,
        notes: String,
        sourceRef: String,
        calendarID: String? = nil,
        language: AppLanguage = .current
    ) throws -> String {
        guard isAuthorized else { throw CalendarError.notAuthorized }

        // ① fast-path: 매핑 ID가 여전히 resolve되면 바로 반환
        if let existing = emailEventMapping[sourceRef],
           event(withIdentifier: existing) != nil { return existing }

        // ② 콘텐츠 스캔: ID 재할당됐어도 URL로 찾기
        if let found = findEmailEvent(sourceRef: sourceRef, near: start) {
            var mapping = emailEventMapping
            mapping[sourceRef] = found.eventIdentifier
            emailEventMapping = mapping
            return found.eventIdentifier
        }

        let event       = EKEvent(eventStore: store)
        event.title = title.isEmpty
            ? (AppLanguage.localized("todo.untitled", defaultValue: "(No Title)", language: language))
            : title
        event.startDate = start
        event.endDate   = end ?? start.addingTimeInterval(isAllDay ? 86400 : 3600)
        event.isAllDay  = isAllDay
        if !location.isEmpty { event.location = location }
        if !notes.isEmpty    { event.notes    = notes }
        event.url       = URL(string: "x-todoapp-email://\(sourceRef.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? sourceRef)")
        if let cid = calendarID, let cal = store.calendar(withIdentifier: cid) {
            event.calendar = cal
        } else {
            event.calendar = preferredDefaultCalendar
        }
        try store.save(event, span: .thisEvent)
        markResolvedEventID(event.eventIdentifier)

        var mapping = emailEventMapping
        mapping[sourceRef] = event.eventIdentifier
        emailEventMapping = mapping
        return event.eventIdentifier
    }
}

// MARK: - CalendarService + 자동 등록

extension CalendarService {
    static func isAutomaticRegistrationCandidate(_ todo: Todo) -> Bool {
        guard todo.triage == .todo else { return false }
        guard todo.todoSource != .calendar else { return false }
        guard todo.dueDate != nil else { return false }
        return true
    }


    /// 마감일이 있는 todo를 캘린더에 자동 등록한다 (중복 방지 내장).
    /// - 캘린더 출처 todo는 역방향 재등록 방지를 위해 무시.
    /// - 권한 없음·마감 없음·이미 등록된 경우 무시.
    /// - 마감이 있으면 우선순위·정책과 무관하게 항상 등록됨.
    @discardableResult
    func applyAutoRegistration(for todo: Todo) -> Bool {
        guard Self.isAutomaticRegistrationCandidate(todo) else { return false }
        guard isAuthorized else { return false }

        // 1) 이 기기의 eventIdentifier로 이벤트 존재 확인
        if let id = todo.calendarEventID, event(withIdentifier: id) != nil {
            return false  // 이미 등록됨
        }
        // Do not retain a device-local identifier that EventKit no longer
        // resolves. A valid external identifier can still recover the link.
        todo.calendarEventID = nil


        // 2) 크로스-기기 dedup: calendarItemExternalIdentifier로 조회
        //    iCloud 동기화 후 eventIdentifier가 바뀌어도 externalIdentifier는 동일 → 중복 등록 방지
        if !todo.calendarEventExternalID.isEmpty {
            let items = store.calendarItems(withExternalIdentifier: todo.calendarEventExternalID)
            if let event = items.compactMap({ $0 as? EKEvent }).first {
                // 다른 기기에서 등록한 이벤트가 이미 이 기기에 동기화됨 → 로컬 ID만 갱신
                todo.calendarEventID = event.eventIdentifier
                return false
            }
        }

        // 3) 이벤트가 없음 → 새로 등록
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
        let useGlobal = SettingsStore.isICloudSyncEnabled
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
        errorDescription(language: .current)
    }

    func errorDescription(language: AppLanguage) -> String {
        AppLanguage.localized("error.calendar.unauthorized", defaultValue: "Calendar access is not authorized. Allow access in Settings > Privacy & Security.", language: language)
    }
}

// MARK: - 캘린더 → TODO 주간 import (양방향 연동)

extension CalendarService {

    private static let weeklyImportKey = "pieroot.todo.lastCalendarImportDate"

    /// 동기화 창에 있던 외부 캘린더 발생분이 더는 EventKit에 없으면, 원본에서
    /// import한 미완료 Todo도 제거해야 두 저장소가 같은 상태를 유지한다.
    static func missingImportedTodoIDs(
        from todos: [Todo],
        observedOccurrenceRefs: Set<String>,
        observedExternalIDs: Set<String> = [],
        now: Date,
        calendar: Calendar = .current
    ) -> Set<UUID> {
        // observedOccurrenceRefs는 `upcomingEvents`와 같은 now...+30d 범위다.
        // 관측하지 않은 과거 발생분을 삭제 대상으로 오인하면 안 된다.
        let windowStart = now
        let windowEnd = calendar.date(byAdding: .day, value: 30, to: now) ?? now
        return Set(todos.compactMap { todo in
            guard todo.todoSource == .calendar,
                  !todo.isCompleted,
                  !todo.sourceRef.isEmpty,
                  let dueDate = todo.dueDate,
                  dueDate >= windowStart,
                  dueDate <= windowEnd
            else {
                return nil
            }
            if !todo.calendarEventExternalID.isEmpty && observedExternalIDs.contains(todo.calendarEventExternalID) {
                return nil
            }
            if observedOccurrenceRefs.contains(todo.sourceRef) {
                return nil
            }
            return todo.id
        })
    }

    /// EKEvent 제목을 Todo에 채택할지 판단한다.
    /// - 기준선(`Todo.calendarSyncedTitle`)과 이벤트 제목이 같으면 상류는 그대로이고
    ///   로컬 사용자가 제목을 바꾼 것이므로 채택하지 않는다.
    /// - 기준선이 비어 있는 이전 버전 데이터는 1회 채택 후 기준선이 세워진다.
    static func shouldAdoptCalendarTitle(
        todoTitle: String,
        syncedBaseline: String,
        eventTitle: String
    ) -> Bool {
        guard todoTitle != eventTitle else { return false }
        return eventTitle != syncedBaseline
    }

    /// 캘린더 이벤트의 시간 정보를 Todo의 시작/마감으로 해석한 결과.
    struct CalendarTodoWindow: Equatable, Sendable {
        let startDate: Date?
        let dueDate: Date
    }

    /// 마감만 아는 Todo를 캘린더에 쓸 때 사용하는 기본 이벤트 길이.
    static let defaultTodoEventDuration: TimeInterval = 3600

    /// EventKit/CalDAV 왕복에서 초 단위가 절삭될 수 있으므로 시간 비교에 허용 오차를 둔다.
    /// 파일 내 다른 발생분 스캔(±60초)과 같은 기준이다.
    private static let eventTimeMatchTolerance: TimeInterval = 60

    /// 시각이 있는 일정은 시작~종료 구간을 그대로 Todo의 시작/마감으로 옮긴다.
    /// 종일 일정과 길이가 없는 일정은 종료 시각에 사용자 의도가 없으므로 시작 시각만 마감으로 쓴다.
    static func todoWindow(eventStart: Date, eventEnd: Date, isAllDay: Bool) -> CalendarTodoWindow {
        guard !isAllDay, eventEnd > eventStart else {
            return CalendarTodoWindow(startDate: nil, dueDate: eventStart)
        }
        return CalendarTodoWindow(startDate: eventStart, dueDate: eventEnd)
    }

    /// Todo를 캘린더 이벤트 구간으로 투영한다. 마감이 없으면 등록 대상이 아니다.
    static func eventWindow(todoStart: Date?, todoDue: Date?) -> (start: Date, end: Date)? {
        guard let todoDue else { return nil }
        if let todoStart, todoDue > todoStart { return (todoStart, todoDue) }
        return (todoDue, todoDue.addingTimeInterval(defaultTodoEventDuration))
    }

    /// 앱이 만들거나 앱과 연결된 이벤트에서 상류 시간 변경만 채택한다.
    /// nil = 변경 없음. 마감만 있는 기존 Todo의 1시간 투영과 이벤트가 일치하면
    /// 종료 시각을 마감으로 승격시키지 않는다(기존 마감이 1시간 밀리는 회귀 방지).
    static func adoptedTodoWindow(
        todoStart: Date?,
        todoDue: Date?,
        eventStart: Date,
        eventEnd: Date,
        isAllDay: Bool
    ) -> CalendarTodoWindow? {
        let adopted = todoWindow(eventStart: eventStart, eventEnd: eventEnd, isAllDay: isAllDay)
        guard !isAllDay else { return adopted }
        guard let projected = eventWindow(todoStart: todoStart, todoDue: todoDue) else { return adopted }
        let isStartMatched = abs(eventStart.timeIntervalSince(projected.start)) < eventTimeMatchTolerance
        let isEndMatched = abs(eventEnd.timeIntervalSince(projected.end)) < eventTimeMatchTolerance
        return isStartMatched && isEndMatched ? nil : adopted
    }


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
    @discardableResult
    func syncCalendarTodos(context: ModelContext) async -> Bool {
        let now = Date()
        var todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []
        var hasChanges = false
        hasChanges = reconcileStaleCalendarReferences(in: todos) || hasChanges
        let importedEvents = upcomingEvents(days: 30).filter { !$0.identifier.isEmpty }
        // 재설치 복원은 가까운 30일만 기다리지 않는다. URL 마커가 있는 SIFT
        // 일정만 1년까지 확장해 읽고, 외부 캘린더 import 범위는 그대로 유지한다.
        let markedSiftEvents = upcomingEvents(days: 366).filter {
            !$0.identifier.isEmpty && $0.marker != nil
        }
        var allEventsByOccurrence: [String: CalendarEventSummary] = [:]
        for event in importedEvents + markedSiftEvents {
            let key = "\(event.identifier)#\(event.startDate.timeIntervalSinceReferenceDate)"
            allEventsByOccurrence[key] = event
        }
        let allEvents = allEventsByOccurrence.values.sorted { $0.startDate < $1.startDate }

        // 1. 등록 대기열 만료 항목 자동 제거 (마감 지났지만 진행중 미등록)
        for todo in todos where todo.triage == .review && !todo.isCompleted {
            if let due = todo.dueDate, due < now {
                if todo.todoSource == .email {
                    _ = removeEmailCalendarArtifacts(for: todo)
                }
                TaskBehaviorRecorder.recordDeletion(of: todo, actor: .system, in: context)
                context.delete(todo)
                hasChanges = true
            }
        }
        todos = (try? context.fetch(FetchDescriptor<Todo>())) ?? []


        let iso = ISO8601DateFormatter()
        var calendarTodosByRef: [String: Todo] = [:]
        var calendarTodosByExternalID: [String: Todo] = [:]
        for todo in todos where todo.todoSource == .calendar {
            calendarTodosByRef[todo.sourceRef] = todo
            if !todo.calendarEventExternalID.isEmpty {
                calendarTodosByExternalID[todo.calendarEventExternalID] = todo
            }
        }

        var todosByID: [UUID: Todo] = [:]
        for todo in todos where todosByID[todo.id] == nil {
            todosByID[todo.id] = todo
        }

        // 앱이 만든 캘린더 이벤트(manual/email 출처)만 역import 차단
        // calendar 출처 todo는 제외 — 반복 일정 occurrence dedup은 calendarTodosByRef가 전담
        let linkedEventIDs = Set(
            todos.filter { $0.todoSource != .calendar }.compactMap { $0.calendarEventID }
        )
        let linkedEventExternalIDs = Set(
            todos.filter { $0.todoSource != .calendar }.compactMap { $0.calendarEventExternalID }.filter { !$0.isEmpty }
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
        let observedCalendarOccurrenceRefs = Set(eventsToProcess.flatMap { event -> [String] in
            guard event.marker == nil else { return [] }
            var refs = ["\(event.identifier)#\(iso.string(from: event.startDate))"]
            if !event.externalIdentifier.isEmpty {
                refs.append("\(event.externalIdentifier)#\(iso.string(from: event.startDate))")
            }
            return refs
        })
        let observedExternalIDs = Set(eventsToProcess.compactMap { event -> String? in
            guard event.marker == nil, !event.externalIdentifier.isEmpty else { return nil }
            return event.externalIdentifier
        })


        for event in eventsToProcess {
            if let marker = event.marker {
                guard marker.entity == .todo else {
                    // Calendar tab에서 SIFT가 만든 독립 이벤트다. Todo로 역수입하지 않는다.
                    continue
                }

                if let existing = todosByID[marker.identifier] {
                    let previousDueDate = existing.dueDate
                    let adoptTitle = Self.shouldAdoptCalendarTitle(
                        todoTitle: existing.title,
                        syncedBaseline: existing.calendarSyncedTitle,
                        eventTitle: event.title
                    )
                    let isNotesChanged = existing.notes != event.notes
                    let adoptedWindow = Self.adoptedTodoWindow(
                        todoStart: existing.startDate,
                        todoDue: existing.dueDate,
                        eventStart: event.startDate,
                        eventEnd: event.endDate,
                        isAllDay: event.isAllDay
                    )
                    let isTimeChanged = adoptedWindow.map {
                        $0.startDate != existing.startDate || $0.dueDate != existing.dueDate
                    } ?? false
                    let isFixedScheduleChanged = existing.isFixedSchedule != event.isRecurring
                    let isLinkChanged = existing.calendarEventID != event.identifier
                        || existing.calendarEventExternalID != event.externalIdentifier
                        || existing.calendarEventOrigin != marker.origin.rawValue
                    if adoptTitle || isNotesChanged || isTimeChanged || isFixedScheduleChanged || isLinkChanged {
                        if adoptTitle { existing.title = event.title }
                        existing.notes = event.notes
                        if isTimeChanged, let adoptedWindow {
                            existing.startDate = adoptedWindow.startDate
                            existing.dueDate = adoptedWindow.dueDate
                        }
                        existing.isFixedSchedule = event.isRecurring
                        existing.calendarEventID = event.identifier
                        existing.calendarEventExternalID = event.externalIdentifier
                        existing.calendarEventOrigin = marker.origin.rawValue
                        existing.updatedAt = Date()
                        hasChanges = true
                        if previousDueDate != existing.dueDate {
                            TaskBehaviorRecorder.recordDueDateChange(
                                of: existing,
                                from: previousDueDate,
                                to: existing.dueDate,
                                actor: event.isRecurring ? .recurrence : .calendarSync,
                                in: context
                            )
                        }
                    }
                    if existing.calendarSyncedTitle != event.title {
                        existing.calendarSyncedTitle = event.title
                        hasChanges = true
                    }
                    continue
                }

                // 앱을 재설치했거나 동기화된 SwiftData를 아직 받기 전인 경우에도
                // EventKit URL 마커의 안정 UUID로 SIFT가 만든 Todo를 복원한다.
                let restoredWindow = Self.todoWindow(
                    eventStart: event.startDate, eventEnd: event.endDate, isAllDay: event.isAllDay
                )
                let restored = Todo(
                    id: marker.identifier,
                    title: event.title,
                    notes: event.notes,
                    startDate: restoredWindow.startDate,
                    dueDate: restoredWindow.dueDate,
                    source: .manual,
                    sourceRef: "sift-calendar://todo/\(marker.identifier.uuidString)"
                )
                restored.calendarEventID = event.identifier
                restored.calendarEventExternalID = event.externalIdentifier
                restored.calendarEventOrigin = marker.origin.rawValue
                restored.isFixedSchedule = event.isRecurring
                restored.calendarSyncedTitle = event.title
                context.insert(restored)
                todos.append(restored)
                todosByID[restored.id] = restored
                hasChanges = true
                continue
            }

            let eventKey = !event.externalIdentifier.isEmpty ? event.externalIdentifier : event.identifier
            let canonicalRef = "\(eventKey)#\(iso.string(from: event.startDate))"
            let localRef = "\(event.identifier)#\(iso.string(from: event.startDate))"
            let externalRef = !event.externalIdentifier.isEmpty ? "\(event.externalIdentifier)#\(iso.string(from: event.startDate))" : nil

            let window = Self.todoWindow(
                eventStart: event.startDate, eventEnd: event.endDate, isAllDay: event.isAllDay
            )

            let matchedExisting = calendarTodosByRef[canonicalRef]
                ?? calendarTodosByRef[localRef]
                ?? (externalRef.flatMap { calendarTodosByRef[$0] })
                ?? (!event.externalIdentifier.isEmpty ? calendarTodosByExternalID[event.externalIdentifier] : nil)

            if let existing = matchedExisting {
                let previousDueDate = existing.dueDate
                // 동기화: 제목·마감·고정 여부만 갱신, triageStatus·isCompleted 보존
                let adoptTitle = Self.shouldAdoptCalendarTitle(
                    todoTitle: existing.title,
                    syncedBaseline: existing.calendarSyncedTitle,
                    eventTitle: event.title
                )
                let isDueDateChanged = existing.dueDate != window.dueDate
                let isStartDateChanged = existing.startDate != window.startDate
                let isFixedScheduleChanged = existing.isFixedSchedule != event.isRecurring
                if adoptTitle || isDueDateChanged || isStartDateChanged || isFixedScheduleChanged {
                    if adoptTitle { existing.title = event.title }
                    existing.startDate = window.startDate
                    existing.dueDate = window.dueDate
                    existing.isFixedSchedule = event.isRecurring
                    hasChanges = true
                    if isDueDateChanged {
                        TaskBehaviorRecorder.recordDueDateChange(
                            of: existing,
                            from: previousDueDate,
                            to: existing.dueDate,
                            actor: event.isRecurring ? .recurrence : .calendarSync,
                            in: context
                        )
                    }
                }
                if existing.calendarSyncedTitle != event.title {
                    existing.calendarSyncedTitle = event.title
                    hasChanges = true
                }
                if existing.calendarEventID != event.identifier {
                    existing.calendarEventID = event.identifier
                    hasChanges = true
                }
                if !event.externalIdentifier.isEmpty && existing.calendarEventExternalID != event.externalIdentifier {
                    existing.calendarEventExternalID = event.externalIdentifier
                    hasChanges = true
                }
                if existing.sourceRef != canonicalRef {
                    existing.sourceRef = canonicalRef
                    hasChanges = true
                }
            } else if linkedEventIDs.contains(event.identifier) || (!event.externalIdentifier.isEmpty && linkedEventExternalIDs.contains(event.externalIdentifier)) {
                // 앱이 만든 캘린더 이벤트의 역import 방지
                continue

            } else {
                // 반복 일정: 이미 진행중(triage=.todo, 미완료)인 항목이 있으면 스킵
                if event.isRecurring {
                    let hasActive = todos.contains {
                        $0.todoSource == .calendar
                        && ($0.calendarEventID == event.identifier || (!event.externalIdentifier.isEmpty && $0.calendarEventExternalID == event.externalIdentifier))
                        && $0.triage == .todo
                        && !$0.isCompleted
                    }
                    if hasActive { continue }
                }

                // 보조 콘텐츠 매칭: identifier 재할당(Google/CalDAV) 또는 타 기기 생성분 대비
                let startLow  = event.startDate.addingTimeInterval(-60)
                let startHigh = event.startDate.addingTimeInterval(60)
                let isDuplicate = todos.contains { other in
                    if !event.externalIdentifier.isEmpty && other.calendarEventExternalID == event.externalIdentifier {
                        return true
                    }
                    if other.title == event.title, let anchor = other.scheduleAnchor, anchor >= startLow && anchor <= startHigh {
                        return true
                    }
                    return false
                }
                if isDuplicate { continue }

                // 신규 삽입: 등록 대기열에만, 캘린더 재등록 없음
                let todo = Todo(
                    title: event.title,
                    startDate: window.startDate,
                    dueDate: window.dueDate,
                    source: .calendar,
                    sourceRef: canonicalRef
                )
                todo.calendarEventID = event.identifier
                todo.triageStatus = TodoTriage.review.rawValue
                todo.isFixedSchedule = event.isRecurring
                todo.calendarEventExternalID = event.externalIdentifier
                todo.calendarEventOrigin = CalendarEventOrigin.externalCalendar.rawValue
                todo.calendarSyncedTitle = event.title
                context.insert(todo)
                TaskBehaviorRecorder.recordCreation(
                    of: todo,
                    actor: event.isRecurring ? .recurrence : .calendarSync,
                    in: context
                )
                await TodoEligibilityReconciler.shared.reconcile(todo)
                hasChanges = true
            }
        }

        let missingImportedIDs = Self.missingImportedTodoIDs(
            from: todos,
            observedOccurrenceRefs: observedCalendarOccurrenceRefs,
            observedExternalIDs: observedExternalIDs,
            now: now
        )
        for todo in todos where missingImportedIDs.contains(todo.id) {
            TaskBehaviorRecorder.recordDeletion(of: todo, actor: .calendarSync, in: context)
            context.delete(todo)
            hasChanges = true
        }

        if hasChanges {
            try? context.save()
        }
        return hasChanges
    }

    /// 어플과 캘린더의 일정을 양방향으로 동기화하고, 충돌 시 최근 수정된 내용을 우선하여 갱신합니다.
    @MainActor
    func syncCalendarWithTodos(context: ModelContext) async {
        guard isAuthorized else { return }

        // SwiftData fetch를 EK store 조작보다 먼저 수행.
        // store.reset()이 EKEventStoreChangedNotification을 동기 트리거할 수 있어
        // CloudKit import 중 fetch와 충돌 시 EXC_BREAKPOINT 트랩 발생.
        let descriptor = FetchDescriptor<Todo>()
        guard let todos = try? context.fetch(descriptor) else { return }

        // fetch 완료 후 EK 캐시 리프레시 (for 루프 이전에 최신 이벤트 데이터 확보)
        store.reset()
        store.refreshSourcesIfNecessary()

        var hasChanges = false
        hasChanges = reconcileStaleCalendarReferences(in: todos) || hasChanges

        for todo in todos {
            if removePendingEmailCalendarLinkIfNeeded(for: todo) {
                todo.updatedAt = Date()
                hasChanges = true
                continue
            }

            // 캘린더에서 역수입한 todo는 이 메서드의 관리 대상이 아님
            if todo.todoSource == .calendar { continue }

            // 어플에서 생성된 할 일인데 자동 등록 대상이며 캘린더 ID가 없는 경우 -> 자동 등록
            if Self.isAutomaticRegistrationCandidate(todo) && todo.calendarEventID == nil {
                if todo.todoSource == .email,
                   let dueDate = todo.dueDate,
                   !todo.sourceRef.isEmpty,
                   let existing = findEmailEvent(sourceRef: todo.sourceRef, near: dueDate),
                   let existingID = existing.eventIdentifier,
                   !existingID.isEmpty {
                    todo.calendarEventID = existingID
                    todo.updatedAt = existing.lastModifiedDate ?? existing.creationDate ?? Date()
                    hasChanges = true
                    continue
                }
                if let eventID = try? registerOrUpdate(todo: todo) {
                    todo.calendarEventID = eventID
                    // 저장 성공 후 이벤트의 수정 시간을 어플의 updatedAt과 정확히 싱크
                    if let savedEvent = event(withIdentifier: eventID) {
                        todo.updatedAt = savedEvent.lastModifiedDate ?? Date()
                    } else {
                        todo.updatedAt = Date()
                    }
                    hasChanges = true
                }
                continue
            }

            // 캘린더 ID가 매핑되어 있는 경우 -> 캘린더 변경분을 어플로 반영한다.
            // 제목은 마지막 동기화 기준선과 비교해 상류 변경만 채택한다. 다른 필드는
            // UI 즉시 내보내기 뒤 EventKit을 반영하는 기존 단방향 규칙을 유지한다.
            if let eventID = todo.calendarEventID {
                if let event = event(withIdentifier: eventID) {
                    // 실제 데이터 차이가 있는지 명시적으로 검증
                    let eventTitle = event.title ?? ""
                    let adoptTitle = Self.shouldAdoptCalendarTitle(
                        todoTitle: todo.title,
                        syncedBaseline: todo.calendarSyncedTitle,
                        eventTitle: eventTitle
                    )
                    let isNotesChanged = todo.notes != (event.notes ?? "")
                    let adoptedWindow = Self.adoptedTodoWindow(
                        todoStart: todo.startDate,
                        todoDue: todo.dueDate,
                        eventStart: event.startDate,
                        eventEnd: event.endDate,
                        isAllDay: event.isAllDay
                    )
                    let isTimeChanged = adoptedWindow.map {
                        $0.startDate != todo.startDate || $0.dueDate != todo.dueDate
                    } ?? false

                    if adoptTitle || isNotesChanged || isTimeChanged {
                        let previousDueDate = todo.dueDate
                        // 캘린더의 수정 시각이 변경되었거나 데이터에 차이가 있다면 어플 Todo를 캘린더 정보로 갱신
                        if adoptTitle { todo.title = eventTitle }
                        if isTimeChanged, let adoptedWindow {
                            todo.startDate = adoptedWindow.startDate
                            todo.dueDate = adoptedWindow.dueDate
                        }
                        todo.notes = event.notes ?? ""
                        todo.updatedAt = event.lastModifiedDate ?? event.creationDate ?? Date()
                        hasChanges = true
                        TaskBehaviorRecorder.recordDueDateChange(
                            of: todo,
                            from: previousDueDate,
                            to: todo.dueDate,
                            actor: event.hasRecurrenceRules ? .recurrence : .calendarSync,
                            in: context
                        )
                    }
                    if todo.calendarSyncedTitle != eventTitle {
                        todo.calendarSyncedTitle = eventTitle
                        hasChanges = true
                    }
                } else {
                    // eventIdentifier 무효화 방어: externalIdentifier로 재탐색
                    var recovered = false
                    if !todo.calendarEventExternalID.isEmpty {
                        let items = store.calendarItems(withExternalIdentifier: todo.calendarEventExternalID)
                        if let found = items.compactMap({ $0 as? EKEvent }).first {
                            todo.calendarEventID = found.eventIdentifier
                            let foundTitle = found.title ?? ""
                            let adoptTitle = Self.shouldAdoptCalendarTitle(
                                todoTitle: todo.title,
                                syncedBaseline: todo.calendarSyncedTitle,
                                eventTitle: foundTitle
                            )
                            let adoptedWindow = Self.adoptedTodoWindow(
                                todoStart: todo.startDate,
                                todoDue: todo.dueDate,
                                eventStart: found.startDate,
                                eventEnd: found.endDate,
                                isAllDay: found.isAllDay
                            )
                            let isTimeChanged = adoptedWindow.map {
                                $0.startDate != todo.startDate || $0.dueDate != todo.dueDate
                            } ?? false
                            let isNotesChanged = todo.notes != (found.notes ?? "")
                            if adoptTitle || isTimeChanged || isNotesChanged {
                                let previousDueDate = todo.dueDate
                                if adoptTitle { todo.title = foundTitle }
                                if isTimeChanged, let adoptedWindow {
                                    todo.startDate = adoptedWindow.startDate
                                    todo.dueDate = adoptedWindow.dueDate
                                }
                                todo.notes = found.notes ?? ""
                                todo.updatedAt = found.lastModifiedDate ?? found.creationDate ?? Date()
                                hasChanges = true
                                TaskBehaviorRecorder.recordDueDateChange(
                                    of: todo,
                                    from: previousDueDate,
                                    to: todo.dueDate,
                                    actor: found.hasRecurrenceRules ? .recurrence : .calendarSync,
                                    in: context
                                )
                            }
                            if todo.calendarSyncedTitle != foundTitle {
                                todo.calendarSyncedTitle = foundTitle
                                hasChanges = true
                            }
                            recovered = true
                        }
                    }
                    if !recovered {
                        let previousDueDate = todo.dueDate
                        // 캘린더에서 진짜 삭제된 경우 → 마감 정보 해제
                        todo.calendarEventID = nil
                        todo.dueDate = nil
                        todo.startDate = nil
                        todo.updatedAt = Date()
                        hasChanges = true
                        TaskBehaviorRecorder.recordDueDateChange(
                            of: todo,
                            from: previousDueDate,
                            to: todo.dueDate,
                            actor: .calendarSync,
                            in: context
                        )
                    }
                }
            }
        }

        // 변경된 데이터가 있다면 SwiftData DB에 영속화하여 View 갱신
        if hasChanges {
            try? context.save()
        }

        _ = await syncCalendarTodos(context: context)
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
            TaskBehaviorRecorder.recordDeletion(of: todo, actor: .system, in: context)
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

// MARK: - 캘린더 소스 관리 + 이벤트 CRUD

extension CalendarService {

    // MARK: 중첩 타입

    struct CalendarSourceGroup: Identifiable {
        let id: String       // EKSource.sourceIdentifier
        let title: String
        let calendars: [CalendarInfo]
    }

    struct CalendarInfo: Identifiable {
        let id: String       // EKCalendar.calendarIdentifier
        let title: String
        let sourceTitle: String
    }

    struct CalendarEventDetail: Identifiable {
        let identifier: String
        var title: String
        var startDate: Date
        var endDate: Date
        var notes: String
        var calendarID: String
        /// 반복 일정의 특정 발생분인 경우 해당 startDate, nil이면 단일/첫 발생분 경로
        var isRecurring: Bool
        var marker: CalendarEventMarker?

        var occurrenceDate: Date?

        var id: String {
            if let occ = occurrenceDate {
                return "\(identifier)-\(occ.timeIntervalSince1970)"
            }
            return identifier
        }
    }

    // MARK: 기본 캘린더 설정 (기기별 로컬 영속)

    var defaultCalendarID: String {
        get { UserDefaults.standard.string(forKey: "pieroot.todo.defaultCalendarID") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pieroot.todo.defaultCalendarID") }
    }

    /// 앱 기본 캘린더. 설정 저장값 조회 실패 시 시스템 기본 캘린더로 폴백.
    var preferredDefaultCalendar: EKCalendar? {
        let id = defaultCalendarID
        if !id.isEmpty, let cal = store.calendar(withIdentifier: id) { return cal }
        return store.defaultCalendarForNewEvents
    }

    // MARK: 비활성 캘린더 ID 집합 (기기별 로컬 영속)

    private var disabledCalendarIDsKey: String { "pieroot.todo.disabledCalendarIDs" }

    var disabledCalendarIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: disabledCalendarIDsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: disabledCalendarIDsKey)
        }
    }

    func setCalendar(_ id: String, enabled: Bool) {
        var disabled = disabledCalendarIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        disabledCalendarIDs = disabled
    }

    // MARK: 활성 캘린더 필터링

    /// 활성화된 EKCalendar 배열. 전체 활성이면 nil (predicateForEvents 최적화).
    var activeEKCalendars: [EKCalendar]? {
        let disabled = disabledCalendarIDs
        guard !disabled.isEmpty else { return nil }
        let filtered = store.calendars(for: .event).filter {
            !disabled.contains($0.calendarIdentifier)
        }
        return filtered.isEmpty ? nil : filtered
    }

    // MARK: 캘린더 소스 목록

    /// EKSource별로 그룹핑된 캘린더 목록 반환 (CalendarSourceSheet 전용).
    func availableCalendars() -> [CalendarSourceGroup] {
        guard isAuthorized else { return [] }
        store.refreshSourcesIfNecessary()
        return store.sources
            .sorted { $0.title < $1.title }
            .compactMap { source -> CalendarSourceGroup? in
                let cals = source.calendars(for: .event)
                    .sorted { $0.title < $1.title }
                guard !cals.isEmpty else { return nil }
                let infos = cals.map {
                    CalendarInfo(
                        id: $0.calendarIdentifier,
                        title: $0.title,
                        sourceTitle: source.title
                    )
                }
                return CalendarSourceGroup(
                    id: source.sourceIdentifier,
                    title: source.title,
                    calendars: infos
                )
            }
    }

    // MARK: 임의 날짜 범위 이벤트 조회 (활성 캘린더 필터 적용)

    /// 과도한 호출을 막는 throttle — 30초에 한 번만 소스를 리프레시.
    private func refreshStoreIfNeeded() {
        guard Date().timeIntervalSince(lastStoreRefresh) > 30 else { return }
        store.refreshSourcesIfNecessary()
        lastStoreRefresh = Date()
    }

    /// CalendarTabView 전용 — 활성화된 캘린더만 쿼리.
    /// 백그라운드 sync(`upcomingEvents`, `syncCalendarTodos`)는 filter 미적용.
    func events(from start: Date, to end: Date) -> [CalendarEventSummary] {
        guard isAuthorized else { return [] }
        refreshStoreIfNeeded()
        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: activeEKCalendars
        )
        return store.events(matching: predicate)
            .map(summary(for:))
            .sorted { $0.startDate < $1.startDate }
    }

    // MARK: 이벤트 메타데이터

    func eventDetail(identifier: String) -> CalendarEventDetail? {
        guard let event = event(withIdentifier: identifier) else { return nil }
        return CalendarEventDetail(
            identifier: identifier,
            title: event.title ?? "",
            startDate: event.startDate,
            endDate: event.endDate,
            notes: event.notes ?? "",
            calendarID: event.calendar?.calendarIdentifier ?? "",
            isRecurring: event.hasRecurrenceRules,
            marker: CalendarEventMarker.parse(event.url),
            occurrenceDate: nil
        )
    }

    /// 반복 일정의 특정 발생분 메타데이터.
    /// ±60초 윈도우 스캔으로 해당 날짜의 EKEvent 인스턴스를 찾아 반환.
    /// occurrenceDate가 non-nil이면 EventEditSheet 저장 시 updateOccurrence로 분기됨.
    func occurrenceDetail(identifier: String, on date: Date) -> CalendarEventDetail? {
        guard isAuthorized else { return nil }
        let scanStart = date.addingTimeInterval(-60)
        let scanEnd   = date.addingTimeInterval(60)
        let pred = store.predicateForEvents(withStart: scanStart, end: scanEnd, calendars: nil)
        if let occurrence = store.events(matching: pred)
            .first(where: { $0.eventIdentifier == identifier }) {
            return CalendarEventDetail(
                identifier: identifier,
                title: occurrence.title ?? "",
                startDate: occurrence.startDate,
                endDate: occurrence.endDate,
                notes: occurrence.notes ?? "",
                calendarID: occurrence.calendar?.calendarIdentifier ?? "",
                isRecurring: occurrence.hasRecurrenceRules,
                marker: CalendarEventMarker.parse(occurrence.url),
                occurrenceDate: date
            )
        }
        // ±60초 스캔 실패 시 첫 발생분 폴백 (occurrenceDate: nil)
        return eventDetail(identifier: identifier)
    }

    func ekCalendar(withIdentifier id: String) -> EKCalendar? {
        store.calendar(withIdentifier: id)
    }

    // MARK: 이벤트 CRUD (CalendarTabView 전용)

    @discardableResult
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String,
        calendarID: String?
    ) throws -> String {
        guard isAuthorized else { throw CalendarError.notAuthorized }
        let event       = EKEvent(eventStore: store)
        event.title     = title.isEmpty ? "(제목 없음)" : title
        event.startDate = startDate
        event.endDate   = endDate
        event.notes     = notes.isEmpty ? nil : notes
        if let cid = calendarID, let cal = store.calendar(withIdentifier: cid) {
            event.calendar = cal
        } else {
            event.calendar = preferredDefaultCalendar
        }
        event.url = CalendarEventMarker.url(
            entity: .standaloneEvent,
            identifier: UUID(),
            origin: .siftManual
        )
        try store.save(event, span: .thisEvent)
        markResolvedEventID(event.eventIdentifier)
        return event.eventIdentifier ?? ""
    }

    func updateEvent(
        identifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String
    ) throws {
        guard isAuthorized,
              let event = event(withIdentifier: identifier) else { return }
        event.title     = title.isEmpty ? "(제목 없음)" : title
        event.startDate = startDate
        event.endDate   = endDate
        event.notes     = notes.isEmpty ? nil : notes
        try store.save(event, span: .thisEvent)
        markResolvedEventID(event.eventIdentifier)
    }

    func deleteEvent(identifier: String) throws {
        guard isAuthorized,
              let event = event(withIdentifier: identifier) else { return }
        try store.remove(event, span: .thisEvent)
        markUnresolvedEventID(identifier)
    }

    /// 반복 일정 수정 범위. `allEvents`는 series master에서 `.futureEvents`를 적용해
    /// 반복 시리즈 전체를 변경하며, `futureEvents`는 선택한 발생분부터 변경한다.
    func updateOccurrence(
        identifier: String,
        on occurrenceDate: Date,
        title: String,
        startDate: Date,
        endDate: Date,
        notes: String,
        scope: CalendarRecurrenceScope = .thisEvent
    ) throws {
        guard isAuthorized else { throw CalendarError.notAuthorized }

        func applyChanges(to event: EKEvent) {
            event.title = title.isEmpty ? "(제목 없음)" : title
            event.startDate = startDate
            event.endDate = endDate
            event.notes = notes.isEmpty ? nil : notes
        }

        if scope == .allEvents, let series = event(withIdentifier: identifier) {
            applyChanges(to: series)
            try store.save(series, span: .futureEvents)
            markResolvedEventID(series.eventIdentifier)
            return
        }

        let scanStart = occurrenceDate.addingTimeInterval(-60)
        let scanEnd = occurrenceDate.addingTimeInterval(60)
        let predicate = store.predicateForEvents(withStart: scanStart, end: scanEnd, calendars: nil)
        if let occurrence = store.events(matching: predicate)
            .first(where: { $0.eventIdentifier == identifier }) {
            applyChanges(to: occurrence)
            let span: EKSpan = scope == .thisEvent ? .thisEvent : .futureEvents
            try store.save(occurrence, span: span)
            markResolvedEventID(occurrence.eventIdentifier)
        } else if let fallback = event(withIdentifier: identifier) {
            applyChanges(to: fallback)
            let span: EKSpan = scope == .thisEvent ? .thisEvent : .futureEvents
            try store.save(fallback, span: span)
            markResolvedEventID(fallback.eventIdentifier)
        }
    }
}
