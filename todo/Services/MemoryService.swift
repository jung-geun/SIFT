import Foundation
import SwiftData

/// 앱 내 할 일 완료 패턴을 분석해 AI 프롬프트용 메모리 요약을 생성합니다.
///
/// 분석 항목: 완료 시간대 분포 / 태그별 처리 속도 / 완료율 / 마감 준수율
/// 결과는 SwiftData(MemoryAnalysis)에 저장되어 온디바이스 우선순위/페르소나 분석에 자동 주입됩니다.
/// BGProcessingTask(pieroot.todo.memoryAnalysis)로 2일 이상 간격 백그라운드 실행.

/// 포그라운드 패턴 분석 결과를 사용자 확인 전까지 임시 보관하는 구조체.
struct MemoryAnalysisResult {
    let summary: String
    let insights: [String]
    let fastTags: Set<String>
    let overdueRate: Double
    let productiveHour: Int?
    var usedAFM: Bool = false
}

final class MemoryService {

    static let shared = MemoryService()
    private init() {}
    
    // MARK: - SwiftData Cache
    
    private let cacheLock = NSLock()
    private var cachedAnalysis: MemoryAnalysis?
    private var lastFetchTime: Date = .distantPast
    
    private var latestAnalysis: MemoryAnalysis? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        let now = Date()
        if now.timeIntervalSince(lastFetchTime) < 5 {
            return cachedAnalysis
        }
        
        do {
            let context = ModelContext(AppDataContainer.shared.container)
            var descriptor = FetchDescriptor<MemoryAnalysis>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchLimit = 1
            cachedAnalysis = try context.fetch(descriptor).first
            lastFetchTime = now
        } catch {
            print("[MemoryService] SwiftData fetch 실패: \(error)")
        }
        return cachedAnalysis
    }

    // MARK: - Stored State

    var summary: String {
        latestAnalysis?.summary ?? ""
    }

    var insights: [String] {
        latestAnalysis?.insights ?? []
    }

    var lastAnalysisDate: Date? {
        latestAnalysis?.createdAt
    }

    /// HeuristicEngine이 소폭 부스트에 쓰는 "빠르게 처리하는 태그" 집합.
    /// analyze()가 실행된 적 없으면 빈 Set(부스트 없음).
    var fastTags: Set<String> {
        Set(latestAnalysis?.fastTags ?? [])
    }

    /// 마감 준수율 역지표: 완료된 항목 중 마감 이후 처리된 비율.
    /// 0.0이면 기록 없음 또는 모두 제때 완료.
    /// ScheduleWeights.adaptive()가 이 값을 바탕으로 deadline/urgency 가중치를 자동 조정한다.
    var overdueRate: Double {
        latestAnalysis?.overdueRate ?? 0.0
    }

    /// 가장 생산적인 시간대(0~23). nil이면 분석 데이터 없음.
    /// HeuristicEngine이 recommendedTime 산출 시 활용한다.
    var productiveHour: Int? {
        latestAnalysis?.productiveHour
    }

    // MARK: - Analysis

    static func computeAnalysis(todos: [Todo]) -> MemoryAnalysisResult {
        let now = Date()
        let weekOut = now.addingTimeInterval(7 * 24 * 3600)
        let nearTermBacklog = todos.filter { todo in
            guard !todo.isCompleted, let due = todo.dueDate else { return false }
            return due >= now && due <= weekOut
        }.count

        let completed = todos.filter { $0.isCompleted && $0.completedAt != nil }
        guard !completed.isEmpty else {
            guard nearTermBacklog > 0 else {
                return MemoryAnalysisResult(summary: "", insights: [], fastTags: [], overdueRate: 0, productiveHour: nil, usedAFM: false)
            }
            return MemoryAnalysisResult(
                summary: "7일 내 마감 미완료: \(nearTermBacklog)건",
                insights: ["향후 7일 안에 처리해야 할 미완료 항목이 \(nearTermBacklog)건 남아 있음"],
                fastTags: [],
                overdueRate: 0,
                productiveHour: nil,
                usedAFM: false
            )
        }

        let cal = Calendar.current
        var lines: [String] = []
        var insights: [String] = []
        var detectedProductiveHour: Int?

        // 1. 완료 시간대 분포
        let hourCounts = Dictionary(
            grouping: completed.compactMap { $0.completedAt },
            by: { cal.component(.hour, from: $0) }
        ).mapValues { $0.count }
        if let top = hourCounts.max(by: { $0.value < $1.value }) {
            let hour = top.key
            detectedProductiveHour = hour
            lines.append("가장 생산적인 시간대: \(hour)시~\(hour + 1)시 (\(top.value)건 완료)")
            insights.append("\(hour)시~\(hour + 1)시에 완료가 가장 집중됨")
        }

        // 2. 완료 요일 분포
        let weekdayCounts = Dictionary(
            grouping: completed.compactMap { $0.completedAt },
            by: { cal.component(.weekday, from: $0) }
        ).mapValues { $0.count }
        if let top = weekdayCounts.max(by: { $0.value < $1.value }) {
            let weekday = Self.weekdayLabel(top.key)
            lines.append("완료가 가장 많은 요일: \(weekday)요일 (\(top.value)건)")
            insights.append("\(weekday)요일에 완료 빈도가 가장 높음")
        }

        // 3. 태그별 완료 속도 중앙값
        var tagTimes: [String: [Double]] = [:]
        for todo in completed {
            guard let completedAt = todo.completedAt else { continue }
            let hours = completedAt.timeIntervalSince(todo.createdAt) / 3600
            for tag in todo.tags where !tag.isEmpty {
                tagTimes[tag, default: []].append(hours)
            }
        }
        let tagMedians = tagTimes.mapValues(Self.median)
        if tagMedians.count >= 2,
           let fastest = tagMedians.min(by: { $0.value < $1.value }),
           let slowest = tagMedians.max(by: { $0.value < $1.value }),
           fastest.key != slowest.key {
            lines.append("빠른 처리 태그: '\(fastest.key)' 중앙값 \(Self.formatHours(fastest.value)) / 느린 처리 태그: '\(slowest.key)' 중앙값 \(Self.formatHours(slowest.value))")
            insights.append("'\(fastest.key)' 태그는 비교적 빠르게 끝나고, '\(slowest.key)' 태그는 오래 끄는 편")
        }

        // 4. 전체 완료율
        let completionRate = Double(completed.count) / Double(todos.count)
        let completionRateText = String(format: "%.0f%%", completionRate * 100)
        lines.append("전체 완료율: \(completionRateText) (\(completed.count)/\(todos.count)개)")
        if completionRate < 0.4 {
            insights.append("완료율 \(completionRateText)로 미완료 항목 비중이 큼")
        } else if completionRate > 0.8 {
            insights.append("완료율 \(completionRateText)로 실행력이 안정적으로 높음")
        }

        // 5. 평균 완료 소요 시간
        let completionHours = completed.compactMap { todo -> Double? in
            guard let completedAt = todo.completedAt else { return nil }
            return completedAt.timeIntervalSince(todo.createdAt) / 3600
        }
        if !completionHours.isEmpty {
            let averageCompletionHours = completionHours.reduce(0, +) / Double(completionHours.count)
            lines.append("평균 완료 소요: \(Self.formatHours(averageCompletionHours))")
        }

        // 6. 마감 준수 패턴
        let dueDateCompleted = completed.compactMap { todo -> (due: Date, completedAt: Date)? in
            guard let due = todo.dueDate, let completedAt = todo.completedAt else { return nil }
            return (due, completedAt)
        }
        var earlyCount = 0
        var onTimeCount = 0
        var lateCount = 0
        for item in dueDateCompleted {
            if item.completedAt < item.due {
                earlyCount += 1
            } else if cal.isDate(item.completedAt, equalTo: item.due, toGranularity: .minute) {
                onTimeCount += 1
            } else {
                lateCount += 1
            }
        }
        if !dueDateCompleted.isEmpty {
            lines.append("마감 준수: 조기 \(earlyCount)건 / 정시 \(onTimeCount)건 / 지연 \(lateCount)건")
            insights.append("마감 준수 패턴은 정시 \(onTimeCount)건, 지연 \(lateCount)건, 조기 \(earlyCount)건")
        }
        let computedOverdueRate = completed.isEmpty ? 0.0 : Double(lateCount) / Double(completed.count)

        // 7. 생성→마감 리드타임
        let leadTimeHours = completed.compactMap { todo -> Double? in
            guard let due = todo.dueDate, due > todo.createdAt else { return nil }
            return due.timeIntervalSince(todo.createdAt) / 3600
        }
        if !leadTimeHours.isEmpty {
            let averageLeadTime = leadTimeHours.reduce(0, +) / Double(leadTimeHours.count)
            lines.append("생성→마감 리드타임 평균: \(Self.formatHours(averageLeadTime))")
        }

        // 8. 7일 내 미완료 백로그 압박
        if nearTermBacklog > 0 {
            lines.append("7일 내 마감 미완료: \(nearTermBacklog)건")
            insights.append("향후 7일 안에 처리해야 할 미완료 항목이 \(nearTermBacklog)건 남아 있음")
        }

        // fastTags: 태그별 완료 시간 중앙값이 전체 태그 중앙값보다 빠른 태그 집합
        let overallTagMedian = Self.median(Array(tagMedians.values))
        let fastTagSet = overallTagMedian > 0
            ? Set(tagMedians.filter { $0.value < overallTagMedian }.keys)
            : []

        return MemoryAnalysisResult(
            summary: lines.joined(separator: "\n"),
            insights: insights,
            fastTags: fastTagSet,
            overdueRate: computedOverdueRate,
            productiveHour: detectedProductiveHour,
            usedAFM: false
        )
    }

    @discardableResult
    func analyze(todos: [Todo]) -> (summary: String, insights: [String]) {
        let result = Self.computeAnalysis(todos: todos)
        guard !result.summary.isEmpty else {
            // 완료된 할 일이 없으면 기존 분석을 유지하기 위해 덮어쓰지 않습니다.
            return (latestAnalysis?.summary ?? "", latestAnalysis?.insights ?? [])
        }

        save(
            summary: result.summary,
            insights: result.insights,
            fastTags: Array(result.fastTags),
            overdueRate: result.overdueRate,
            productiveHour: result.productiveHour
        )
        return (result.summary, result.insights)
    }

    private enum BehaviorAnalysisBackend: Equatable {
        case foundationModels
        case onDevice
    }

    private enum BehaviorAnalysisError: LocalizedError {
        case foundationModelsUnavailable
        case onDeviceUnavailable
        case invalidResponse
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .foundationModelsUnavailable:
                return "Apple Foundation Models를 사용할 수 없습니다."
            case .onDeviceUnavailable:
                return "로컬 AI 모델을 사용할 수 없습니다."
            case .invalidResponse:
                return "AI 분석 결과를 해석할 수 없습니다."
            case .emptyResponse:
                return "AI 분석 결과가 비어 있습니다."
            }
        }
    }

    private struct BehaviorAnalysisPayload: Decodable {
        let summary: String
        let insights: [String]
    }

    @MainActor
    private func availableBehaviorAnalysisBackend() -> BehaviorAnalysisBackend? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsService.isAvailable {
            return .foundationModels
        }
        #endif

        let local = OnDeviceLLMService.shared
        if local.isCapable, local.isModelLoaded || local.isModelCachedOnDisk {
            return .onDevice
        }
        return nil
    }

    @MainActor
    private func generateOnDevicePatternAnalysis(todos: [Todo]) async throws -> (summary: String, insights: [String]) {
        let metadata = Self.completedTodoMetadata(todos: todos)
        guard !metadata.isEmpty else { throw BehaviorAnalysisError.emptyResponse }

        let service = OnDeviceLLMService.shared
        if !service.isModelLoaded && service.isModelCachedOnDisk {
            await service.loadModelIfNeeded()
        }
        guard service.isModelLoaded else {
            throw BehaviorAnalysisError.onDeviceUnavailable
        }

        let systemPrompt = """
        당신은 사용자의 완료된 TODO 메타데이터만 보고 행동 패턴을 요약하는 분석가입니다.
        추천, 조언, 실행 지시는 금지합니다.
        반드시 JSON 객체 하나만 출력하세요.
        """
        let userPrompt = """
        [완료된 할 일 메타데이터]
        \(metadata)

        아래 형식의 JSON만 출력하세요.
        {"summary":"1~3문장 한국어 행동 패턴 요약","insights":["관찰 문장 1","관찰 문장 2"]}

        규칙:
        - summary는 1~3문장 한국어. 추천·조언 금지.
        - insights는 2~4개의 한국어 문장 배열.
        - title, tags, createdAt, dueDate, completedAt 메타데이터만 사용.
        """

        let raw = try await service.generate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 480
        )
        let payload = try Self.decodeBehaviorAnalysisPayload(from: raw)
        return try validatedBehaviorAnalysis(summary: payload.summary, insights: payload.insights)
    }

    private func validatedBehaviorAnalysis(summary: String, insights: [String]) throws -> (summary: String, insights: [String]) {
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedInsights = insights
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmedSummary.isEmpty, !cleanedInsights.isEmpty else {
            throw BehaviorAnalysisError.emptyResponse
        }
        return (trimmedSummary, cleanedInsights)
    }

    private static func decodeBehaviorAnalysisPayload(from raw: String) throws -> BehaviorAnalysisPayload {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.range(of: "{"), let last = trimmed.range(of: "}", options: .backwards) {
            trimmed = String(trimmed[first.lowerBound..<last.upperBound])
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw BehaviorAnalysisError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(BehaviorAnalysisPayload.self, from: data)
        } catch {
            throw BehaviorAnalysisError.invalidResponse
        }
    }

    private static func completedTodoMetadata(todos: [Todo], limit: Int = 24) -> String {
        let completed = todos
            .filter { $0.isCompleted && $0.completedAt != nil }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(limit)

        return completed.enumerated().map { index, todo in
            let title = String(todo.title.replacingOccurrences(of: "\n", with: " ").prefix(60))
            let tags = todo.tags.isEmpty ? "-" : todo.tags.joined(separator: ", ")
            let created = AppDateFormat.llmString(from: todo.createdAt)
            let due = todo.dueDate.map { AppDateFormat.llmString(from: $0) } ?? "null"
            let completedAt = todo.completedAt.map { AppDateFormat.llmString(from: $0) } ?? "null"
            return """
            \(index + 1). title: \(title)
               tags: \(tags)
               createdAt: \(created)
               dueDate: \(due)
               completedAt: \(completedAt)
            """
        }.joined(separator: "\n")
    }

    private static func weekdayLabel(_ weekday: Int) -> String {
        let labels = ["", "일", "월", "화", "수", "목", "금", "토"]
        guard labels.indices.contains(weekday) else { return "\(weekday)" }
        return labels[weekday]
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func formatHours(_ hours: Double) -> String {
        let roundedHours = max(0, Int(hours.rounded()))
        if roundedHours < 24 {
            return "\(roundedHours)시간"
        }
        let days = roundedHours / 24
        let remainderHours = roundedHours % 24
        return remainderHours == 0 ? "\(days)일" : "\(days)일 \(remainderHours)시간"
    }

    // MARK: - Foreground FM Analysis (B: 포그라운드 전용)

    @discardableResult
    func analyzeForeground(todos: [Todo]) async throws -> (summary: String, insights: [String]) {
        let heuristic = Self.computeAnalysis(todos: todos)
        guard !heuristic.summary.isEmpty else {
            return (latestAnalysis?.summary ?? "", latestAnalysis?.insights ?? [])
        }

        if let backend = await availableBehaviorAnalysisBackend() {
            let analysis: (summary: String, insights: [String])
            switch backend {
            case .foundationModels:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    let fm = try await FoundationModelsService().generatePatternAnalysis(todos: todos)
                    analysis = try validatedBehaviorAnalysis(summary: fm.summary, insights: fm.insights)
                } else {
                    throw BehaviorAnalysisError.foundationModelsUnavailable
                }
                #else
                throw BehaviorAnalysisError.foundationModelsUnavailable
                #endif
            case .onDevice:
                analysis = try await generateOnDevicePatternAnalysis(todos: todos)
            }

            save(
                summary: analysis.summary,
                insights: analysis.insights,
                fastTags: Array(heuristic.fastTags),
                overdueRate: heuristic.overdueRate,
                productiveHour: heuristic.productiveHour
            )
            return analysis
        }

        save(
            summary: heuristic.summary,
            insights: heuristic.insights,
            fastTags: Array(heuristic.fastTags),
            overdueRate: heuristic.overdueRate,
            productiveHour: heuristic.productiveHour
        )
        return (heuristic.summary, heuristic.insights)
    }

    // MARK: - Foreground Preview (사용자 확인 후 적용)

    /// 포그라운드 전용 — 분석만 수행하고 UserDefaults에 저장하지 않는다.
    /// UI에서 미리보기를 보여주고 사용자가 확인하면 `applyAnalysisResult(_:)` 로 저장.
    func analyzeForegroundPreview(todos: [Todo]) async throws -> MemoryAnalysisResult {
        let heuristic = Self.computeAnalysis(todos: todos)
        guard !heuristic.summary.isEmpty else {
            return heuristic
        }

        if let backend = await availableBehaviorAnalysisBackend() {
            let analysis: (summary: String, insights: [String])
            switch backend {
            case .foundationModels:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    let fm = try await FoundationModelsService().generatePatternAnalysis(todos: todos)
                    analysis = try validatedBehaviorAnalysis(summary: fm.summary, insights: fm.insights)
                } else {
                    throw BehaviorAnalysisError.foundationModelsUnavailable
                }
                #else
                throw BehaviorAnalysisError.foundationModelsUnavailable
                #endif
            case .onDevice:
                analysis = try await generateOnDevicePatternAnalysis(todos: todos)
            }

            return MemoryAnalysisResult(
                summary: analysis.summary,
                insights: analysis.insights,
                fastTags: heuristic.fastTags,
                overdueRate: heuristic.overdueRate,
                productiveHour: heuristic.productiveHour,
                usedAFM: backend == .foundationModels
            )
        }

        return heuristic
    }

    /// 미리보기로 생성된 분석 결과를 저장한다.
    /// 사용자가 "적용" 버튼을 누른 후에만 호출.
    func applyAnalysisResult(_ result: MemoryAnalysisResult) {
        save(
            summary: result.summary,
            insights: result.insights,
            fastTags: Array(result.fastTags),
            overdueRate: result.overdueRate,
            productiveHour: result.productiveHour
        )
    }

    // MARK: - Persistence

    private func save(summary: String, insights: [String], fastTags: [String] = [], overdueRate: Double = 0.0, productiveHour: Int? = nil) {
        let analysis = MemoryAnalysis(
            summary: summary,
            insights: insights,
            fastTags: fastTags,
            overdueRate: overdueRate,
            productiveHour: productiveHour
        )
        
        do {
            let context = ModelContext(AppDataContainer.shared.container)
            context.insert(analysis)
            
            // 기존 데이터가 너무 많이 쌓이지 않도록 오래된 분석 결과 정리 (최근 5개만 유지)
            let descriptor = FetchDescriptor<MemoryAnalysis>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            let allAnalyses = try context.fetch(descriptor)
            if allAnalyses.count > 5 {
                for old in allAnalyses.dropFirst(5) {
                    context.delete(old)
                }
            }
            try context.save()
            
            // 저장 성공 시 캐시 갱신
            cacheLock.lock()
            cachedAnalysis = analysis
            lastFetchTime = Date()
            cacheLock.unlock()
            
        } catch {
            print("[MemoryService] SwiftData 저장 실패: \(error)")
        }
    }
}
