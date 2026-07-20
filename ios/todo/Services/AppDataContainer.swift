import Foundation
import SwiftData
import Combine

// MARK: - AppDataContainer

/// 앱 전체 ModelContainer를 관리하는 swappable 홀더.
///
/// iCloud 동기화 전환 시 `rebuild(useICloud:)`를 호출해
/// 앱 재시작 없이 컨테이너를 동적으로 교체한다.
///
/// - `AppDataContainer.shared`: todoApp이 @StateObject로 생성한 뒤 set.
///   서비스 레이어(MemoryService 등)는 이 shared 참조를 통해 현재 컨테이너에 접근.
/// - SwiftUI 뷰 트리: todoApp.body의 `.modelContainer(appData.container)`가
///   @Published container 변경을 감지해 @Query를 자동 갱신.
final class AppDataContainer: ObservableObject {

    /// todoApp @StateObject 생성 시 설정되는 전역 접근자.
    static private(set) var shared: AppDataContainer!

    /// SwiftUI 뷰 트리에 주입되는 현재 컨테이너. 변경 시 @Query 자동 갱신.
    @Published private(set) var container: ModelContainer

    /// rebuild() 호출마다 1씩 증가 — Equatable 불가한 container 대신 onChange 트리거에 사용.
    @Published private(set) var rebuildID: Int = 0

    // MARK: - Init

    init() {
        let useICloud = UserDefaults.standard.bool(forKey: "pieroot.todo.iCloudSyncEnabled")
        if useICloud {
            AppDataContainer.migrateLocalToICloudIfNeeded()
        }
        self.container = AppDataContainer.buildContainer(useICloud: useICloud)
        AppDataContainer.shared = self
    }

    // MARK: - Rebuild (동적 전환)

    /// iCloud 토글 시 메인 스레드에서 호출.
    /// 마이그레이션 완료 후 새 컨테이너로 교체 → @Published가 SwiftUI를 갱신.
    func rebuild(useICloud: Bool) {
        if useICloud {
            AppDataContainer.migrateLocalToICloudIfNeeded()
        }
        container = AppDataContainer.buildContainer(useICloud: useICloud)
        rebuildID += 1
    }

    // MARK: - Store URL

    nonisolated static func getStoreURL(name: String) -> URL {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if !fileManager.fileExists(atPath: appSupportURL.path) {
            try? fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        }
        return appSupportURL.appendingPathComponent(name)
    }

    // MARK: - Container Builder

    static func buildContainer(useICloud: Bool) -> ModelContainer {
        let schema = AppDataContainer.appSchema
        let config: ModelConfiguration
        if useICloud {
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "pieroot.sift-todo"
            let containerIdentifier = "iCloud.\(bundleIdentifier)"
            config = ModelConfiguration(
                schema: schema,
                url: getStoreURL(name: "icloud_v2.store"),
                cloudKitDatabase: .private(containerIdentifier)
            )
        } else {
            config = ModelConfiguration(
                schema: schema,
                url: getStoreURL(name: "local_v2.store"),
                cloudKitDatabase: .none
            )
        }

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("[SwiftData] 저장소 초기화 실패: \(error). 기존 파일 삭제 후 재시도.")
            let configURL = config.url
            try? FileManager.default.removeItem(at: configURL)
            let shmURL = configURL.deletingPathExtension().appendingPathExtension("store-shm")
            let walURL = configURL.deletingPathExtension().appendingPathExtension("store-wal")
            try? FileManager.default.removeItem(at: shmURL)
            try? FileManager.default.removeItem(at: walURL)
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch {
                print("[SwiftData] 재시도 실패: \(error). 메모리 전용 모드로 실행.")
                let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                return try! ModelContainer(for: schema, configurations: [fallback])
            }
        }
    }

    // MARK: - Schema

    static let appSchema = Schema([
        Todo.self,
        Persona.self,
        TaskAuditEvent.self,
        TaskBehaviorEvent.self,
        MemoryAnalysis.self
    ])

    // MARK: - Email Container (로컬 전용, CloudKit 절대 금지)

    /// 이메일 본문 저장 전용 스키마. appSchema와 철저히 분리하여
    /// iCloud 토글 여부와 무관하게 항상 기기 로컬에만 저장.
    static let emailSchema = Schema([EmailMessage.self])

    static func makeEmailContainer(storeURL: URL) throws -> ModelContainer {
        let config = ModelConfiguration(
            schema: emailSchema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: emailSchema, configurations: [config])
    }

    /// iCloud 설정과 무관하게 항상 로컬(cloudKitDatabase: .none)로 고정되는 컨테이너.
    /// MailTabView 서브트리에만 주입 — 메인 appSchema에 EmailMessage 포함 금지.
    lazy var emailContainer: ModelContainer = {
        do {
            return try AppDataContainer.makeEmailContainer(
                storeURL: AppDataContainer.emailStoreURL()
            )
        } catch {
            print("[EmailContainer] 초기화 실패: \(error). 메모리 전용 모드로 실행.")
            let fallback = ModelConfiguration(
                schema: AppDataContainer.emailSchema,
                isStoredInMemoryOnly: true
            )
            return try! ModelContainer(for: AppDataContainer.emailSchema, configurations: [fallback])
        }
    }()

    nonisolated static func emailDirectory() throws -> URL {
        let directory = getStoreURL(name: "EmailLocal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        return directory
    }

    nonisolated static func emailStoreURL() throws -> URL {
        let directory = try emailDirectory()
        let storeURL = directory.appendingPathComponent("email_local.store")
        let legacyURL = getStoreURL(name: "email_local.store")
        let fileManager = FileManager.default

        for suffix in ["-shm", "-wal", ""] {
            let source = URL(fileURLWithPath: legacyURL.path + suffix)
            let destination = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path),
                  !fileManager.fileExists(atPath: destination.path)
            else {
                continue
            }
            try fileManager.moveItem(at: source, to: destination)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
        }
        return storeURL
    }

    // MARK: - Meeting Container (local-only, protected)

    /// Transcripts, summaries, draft actions, manifests, and the derived
    /// personalized glossary never enter CloudKit.
    static let meetingSchema = Schema([
        MeetingRecord.self,
        MeetingGlossaryTerm.self,
        VocabularyStoreMetadata.self,
        VocabularySourceState.self,
        VocabularyObservation.self
    ])

    lazy var meetingContainer: ModelContainer = {
        let directory = AppDataContainer.meetingDirectory()
        AppDataContainer.excludeFromBackup(directory)
        AppDataContainer.setProtection(.complete, at: directory)
        let url = directory.appendingPathComponent("meeting_local.store")
        let config = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            url: url,
            cloudKitDatabase: .none
        )
        do {
            let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: [config])
            AppDataContainer.protectMeetingStoreContents(at: directory)
            return container
        } catch {
            print("[MeetingContainer] initialization failed: \(error). Falling back to memory-only storage.")
            let fallback = ModelConfiguration(
                schema: AppDataContainer.meetingSchema,
                isStoredInMemoryOnly: true
            )
            return try! ModelContainer(for: AppDataContainer.meetingSchema, configurations: [fallback])
        }
    }()

    nonisolated static func meetingDirectory() -> URL {
        let directory = getStoreURL(name: "Meetings")
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Active capture is opened before lock and remains writable while open.
    /// On Stop, callers must close the handle, then call finalizeMeetingAudio(at:).
    static func activeMeetingAudioDirectory(meetingID: String) -> URL {
        let directory = meetingDirectory()
            .appendingPathComponent(meetingID, isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeFromBackup(directory)
        setProtection(.completeUnlessOpen, at: directory)
        return directory
    }

    static func finalizeMeetingAudio(at file: URL) {
        setProtection(.complete, at: file)
    }

    private static func protectMeetingStoreContents(at directory: URL) {
        for path in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard path.lastPathComponent.hasPrefix("meeting_local.store") else { continue }
            excludeFromBackup(path)
            setProtection(.complete, at: path)
        }
    }

    private static func excludeFromBackup(_ path: URL) {
        var path = path
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? path.setResourceValues(values)
    }

    private static func setProtection(_ protection: FileProtectionType, at path: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: path.path
        )
    }

    // MARK: - Migration (legacy local/iCloud → local)

    static func migrateLegacyStoresToLocalIfNeeded() {
        let fileManager = FileManager.default
        let localV2URL = getStoreURL(name: "local_v2.store")
        let icloudV2URL = getStoreURL(name: "icloud_v2.store")
        let defaultConfig = ModelConfiguration(schema: appSchema, isStoredInMemoryOnly: false)
        let defaultURL = defaultConfig.url

        if !fileManager.fileExists(atPath: localV2URL.path), fileManager.fileExists(atPath: icloudV2URL.path) {
            do {
                try fileManager.copyItem(at: icloudV2URL, to: localV2URL)
                let legacySHM = icloudV2URL.deletingPathExtension().appendingPathExtension("store-shm")
                let localSHM = localV2URL.deletingPathExtension().appendingPathExtension("store-shm")
                if fileManager.fileExists(atPath: legacySHM.path), !fileManager.fileExists(atPath: localSHM.path) {
                    try? fileManager.copyItem(at: legacySHM, to: localSHM)
                }
                let legacyWAL = icloudV2URL.deletingPathExtension().appendingPathExtension("store-wal")
                let localWAL = localV2URL.deletingPathExtension().appendingPathExtension("store-wal")
                if fileManager.fileExists(atPath: legacyWAL.path), !fileManager.fileExists(atPath: localWAL.path) {
                    try? fileManager.copyItem(at: legacyWAL, to: localWAL)
                }
            } catch {
                print("[Migration] 기존 iCloud 저장소를 local_v2.store로 복사하지 못했습니다: \(error)")
            }
        }

        if !fileManager.fileExists(atPath: localV2URL.path), fileManager.fileExists(atPath: defaultURL.path) {
            do {
                try fileManager.moveItem(at: defaultURL, to: localV2URL)
                let defaultSHM = defaultURL.deletingPathExtension().appendingPathExtension("store-shm")
                let localSHM = localV2URL.deletingPathExtension().appendingPathExtension("store-shm")
                if fileManager.fileExists(atPath: defaultSHM.path), !fileManager.fileExists(atPath: localSHM.path) {
                    try? fileManager.moveItem(at: defaultSHM, to: localSHM)
                }
                let defaultWAL = defaultURL.deletingPathExtension().appendingPathExtension("store-wal")
                let localWAL = localV2URL.deletingPathExtension().appendingPathExtension("store-wal")
                if fileManager.fileExists(atPath: defaultWAL.path), !fileManager.fileExists(atPath: localWAL.path) {
                    try? fileManager.moveItem(at: defaultWAL, to: localWAL)
                }
            } catch {
                print("[Migration] 레거시 default.store를 local_v2.store로 이동하지 못했습니다: \(error)")
            }
        }
    }

    /// 로컬 데이터가 있고 iCloud 스토어가 없으면 깊은 복사 이관 실행.
    /// iCloud 첫 활성화 시 1회만 의미 있음 (이후엔 이미 icloud_v2.store 존재).
    static func migrateLocalToICloudIfNeeded() {
        let schema = AppDataContainer.appSchema
        let localV2URL = getStoreURL(name: "local_v2.store")
        let icloudV2URL = getStoreURL(name: "icloud_v2.store")
        let fileManager = FileManager.default

        // 1. 레거시 default.store → local_v2.store 백업 (최초 1회)
        let defaultConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let defaultURL = defaultConfig.url
        if fileManager.fileExists(atPath: defaultURL.path) && !fileManager.fileExists(atPath: localV2URL.path) {
            print("[Migration] 레거시 default.store를 local_v2.store로 마이그레이션합니다.")
            do {
                try fileManager.moveItem(at: defaultURL, to: localV2URL)
                let defaultSHM = defaultURL.deletingPathExtension().appendingPathExtension("store-shm")
                let localSHM = localV2URL.deletingPathExtension().appendingPathExtension("store-shm")
                if fileManager.fileExists(atPath: defaultSHM.path) {
                    try? fileManager.moveItem(at: defaultSHM, to: localSHM)
                }
                let defaultWAL = defaultURL.deletingPathExtension().appendingPathExtension("store-wal")
                let localWAL = localV2URL.deletingPathExtension().appendingPathExtension("store-wal")
                if fileManager.fileExists(atPath: defaultWAL.path) {
                    try? fileManager.moveItem(at: defaultWAL, to: localWAL)
                }
            } catch {
                print("[Migration] 레거시 파일 이동 실패: \(error)")
            }
        }

        // 2. local_v2.store → icloud_v2.store 깊은 복사 이관
        guard fileManager.fileExists(atPath: localV2URL.path) else { return }
        guard !fileManager.fileExists(atPath: icloudV2URL.path) else { return }

        print("[Migration] 로컬 데이터를 iCloud 데이터베이스(icloud_v2.store)로 이관을 진행합니다.")
        do {
            let localConfig = ModelConfiguration(schema: schema, url: localV2URL, cloudKitDatabase: .none)
            let localContainer = try ModelContainer(for: schema, configurations: [localConfig])
            let localContext = ModelContext(localContainer)

            let localTodos          = (try? localContext.fetch(FetchDescriptor<Todo>())) ?? []
            let localPersonas       = (try? localContext.fetch(FetchDescriptor<Persona>())) ?? []
            let localAuditEvents    = (try? localContext.fetch(FetchDescriptor<TaskAuditEvent>())) ?? []
            let localBehaviorEvents = (try? localContext.fetch(FetchDescriptor<TaskBehaviorEvent>())) ?? []
            let localAnalyses       = (try? localContext.fetch(FetchDescriptor<MemoryAnalysis>())) ?? []

            guard !localTodos.isEmpty
                    || !localPersonas.isEmpty
                    || !localAuditEvents.isEmpty
                    || !localBehaviorEvents.isEmpty
                    || !localAnalyses.isEmpty else {
                print("[Migration] 이전 데이터가 비어있어 이관을 생략합니다.")
                return
            }

            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "pieroot.sift-todo"
            let containerIdentifier = "iCloud.\(bundleIdentifier)"
            let icloudConfig = ModelConfiguration(schema: schema, url: icloudV2URL, cloudKitDatabase: .private(containerIdentifier))
            let icloudContainer = try ModelContainer(for: schema, configurations: [icloudConfig])
            let icloudContext = ModelContext(icloudContainer)

            for persona in localPersonas {
                let newPersona = Persona(descriptionText: persona.descriptionText, personaTypes: persona.personaTypes)
                newPersona.id = persona.id
                newPersona.updatedAt = persona.updatedAt
                icloudContext.insert(newPersona)
            }

            for todo in localTodos {
                let newTodo = Todo(
                    title: todo.title,
                    notes: todo.notes,
                    dueDate: todo.dueDate,
                    source: todo.todoSource,
                    sourceRef: todo.sourceRef,
                    tags: todo.tags,
                    reminderOffsets: todo.reminderOffsets
                )
                newTodo.id = todo.id
                newTodo.createdAt = todo.createdAt
                newTodo.updatedAt = todo.updatedAt
                newTodo.isCompleted = todo.isCompleted
                newTodo.completedAt = todo.completedAt
                newTodo.manualPriority = todo.manualPriority
                newTodo.computedPriorityScore = todo.computedPriorityScore
                newTodo.priorityReason = todo.priorityReason
                newTodo.estimatedDurationMinutes = todo.estimatedDurationMinutes
                newTodo.sourceSender = todo.sourceSender
                newTodo.sourceMessageID = todo.sourceMessageID
                newTodo.sourceThreadID = todo.sourceThreadID
                newTodo.sourceSenderEmail = todo.sourceSenderEmail
                newTodo.sourceAccountNamespace = todo.sourceAccountNamespace
                newTodo.triageStatus = todo.triageStatus
                newTodo.calendarEventID = todo.calendarEventID
                newTodo.memoryNotes = todo.memoryNotes
                newTodo.aiRecommendedTime = todo.aiRecommendedTime
                newTodo.aiNeedsNotification = todo.aiNeedsNotification
                newTodo.aiPersonaFit = todo.aiPersonaFit
                newTodo.aiDetail = todo.aiDetail
                newTodo.aiEngine = todo.aiEngine
                newTodo.aiRequestedProvider = todo.aiRequestedProvider
                newTodo.aiFallbackReason = todo.aiFallbackReason
                newTodo.isFixedSchedule = todo.isFixedSchedule
                icloudContext.insert(newTodo)
            }

            for event in localAuditEvents {
                let newEvent = TaskAuditEvent(from: Todo())
                newEvent.id = event.id
                newEvent.createdAt = event.createdAt
                newEvent.completedAt = event.completedAt
                newEvent.deletedAt = event.deletedAt
                newEvent.sourceType = event.sourceType
                newEvent.triageType = event.triageType
                newEvent.wasFixedSchedule = event.wasFixedSchedule
                newEvent.hadDueDate = event.hadDueDate
                icloudContext.insert(newEvent)
            }

            for event in localBehaviorEvents {
                let newEvent = TaskBehaviorEvent(
                    todo: Todo(),
                    type: event.eventType,
                    actor: event.actor,
                    occurredAt: event.occurredAt
                )
                newEvent.id = event.id
                newEvent.todoID = event.todoID
                newEvent.eventTypeRaw = event.eventTypeRaw
                newEvent.actorRaw = event.actorRaw
                newEvent.sourceType = event.sourceType
                newEvent.triageType = event.triageType
                newEvent.wasFixedSchedule = event.wasFixedSchedule
                newEvent.beforeCompletion = event.beforeCompletion
                newEvent.afterCompletion = event.afterCompletion
                newEvent.beforeDueDate = event.beforeDueDate
                newEvent.afterDueDate = event.afterDueDate
                newEvent.beforeManualPriority = event.beforeManualPriority
                newEvent.afterManualPriority = event.afterManualPriority
                newEvent.beforeComputedPriority = event.beforeComputedPriority
                newEvent.afterComputedPriority = event.afterComputedPriority
                icloudContext.insert(newEvent)
            }

            for analysis in localAnalyses {
                let newAnalysis = MemoryAnalysis(
                    summary: analysis.summary,
                    insights: analysis.insights,
                    fastTags: analysis.fastTags,
                    overdueRate: analysis.overdueRate,
                    productiveHour: analysis.productiveHour,
                    recordTitle: analysis.recordTitle,
                    accessScopeSummary: analysis.accessScopeSummary,
                    processorDescription: analysis.processorDescription,
                    behaviorProfile: analysis.behaviorProfile
                )
                newAnalysis.id = analysis.id
                newAnalysis.createdAt = analysis.createdAt
                icloudContext.insert(newAnalysis)
            }

            try icloudContext.save()
            let migratedCount = localTodos.count
                + localPersonas.count
                + localAuditEvents.count
                + localBehaviorEvents.count
                + localAnalyses.count
            print("[Migration] iCloud 컨테이너에 \(migratedCount)개의 로컬 데이터 이관 완료!")

            // 이관 완료 후 로컬 원본 삭제
            try fileManager.removeItem(at: localV2URL)
            let shmURL = localV2URL.deletingPathExtension().appendingPathExtension("store-shm")
            let walURL = localV2URL.deletingPathExtension().appendingPathExtension("store-wal")
            if fileManager.fileExists(atPath: shmURL.path) { try? fileManager.removeItem(at: shmURL) }
            if fileManager.fileExists(atPath: walURL.path) { try? fileManager.removeItem(at: walURL) }
            print("[Migration] 이전 로컬 백업 파일 정리 완료.")
        } catch {
            print("[Migration] 데이터베이스 마이그레이션 중 오류 발생: \(error)")
        }
    }
}
