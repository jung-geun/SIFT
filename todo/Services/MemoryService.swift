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

    @discardableResult
    func analyze(todos: [Todo]) -> (summary: String, insights: [String]) {
        let completed = todos.filter { $0.isCompleted && $0.completedAt != nil }
        guard !completed.isEmpty else {
            // 완료된 할 일이 없으면 기존 분석을 유지하기 위해 덮어쓰지 않습니다.
            return (latestAnalysis?.summary ?? "", latestAnalysis?.insights ?? [])
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
            let h = top.key
            detectedProductiveHour = h
            lines.append("가장 생산적인 시간대: \(h)시~\(h+1)시 (\(top.value)건 완료)")
            insights.append("\(h)시~\(h+1)시에 집중력이 가장 높음")
        }

        // 2. 태그별 평균 완료 소요 시간 (생성→완료)
        var tagTimes: [String: [Double]] = [:]
        for todo in completed {
            guard let comp = todo.completedAt else { continue }
            let hours = comp.timeIntervalSince(todo.createdAt) / 3600
            for tag in todo.tags { tagTimes[tag, default: []].append(hours) }
        }

        if tagTimes.count >= 2 {
            let avgs = tagTimes.mapValues { $0.reduce(0, +) / Double($0.count) }
            if let fastest = avgs.min(by: { $0.value < $1.value }),
               let slowest = avgs.max(by: { $0.value < $1.value }),
               fastest.key != slowest.key {
                lines.append("빠른 처리: '\(fastest.key)' 평균 \(Int(fastest.value))h / 느린 처리: '\(slowest.key)' 평균 \(Int(slowest.value))h")
                insights.append("'\(fastest.key)' 할 일이 가장 빠름 — 연속 처리에 적합")
                insights.append("'\(slowest.key)'은 완료까지 평균 \(Int(slowest.value))h 소요됨")
            }
        }

        // 3. 전체 완료율
        let rate = Double(completed.count) / Double(todos.count)
        let rateStr = String(format: "%.0f%%", rate * 100)
        lines.append("전체 완료율: \(rateStr) (\(completed.count)/\(todos.count)개)")
        if rate < 0.4 {
            insights.append("완료율 \(rateStr) — 완료되지 않은 항목이 전체의 \(String(format: "%.0f%%", (1 - rate) * 100)) 비율로 남아 있음")
        } else if rate > 0.8 {
            insights.append("완료율 \(rateStr) — 높은 실행력")
        }

        // 4. 평균 완료 소요 시간
        let times = completed.compactMap { t -> Double? in
            guard let comp = t.completedAt else { return nil }
            return comp.timeIntervalSince(t.createdAt) / 3600
        }
        if !times.isEmpty {
            let avg = times.reduce(0, +) / Double(times.count)
            let avgStr = avg < 24 ? "\(Int(avg))시간" : "\(Int(avg/24))일 \(Int(avg.truncatingRemainder(dividingBy: 24)))시간"
            lines.append("평균 완료 소요: \(avgStr)")
        }

        // 5. 마감 준수 패턴
        let overdueCount = completed.filter { todo in
            guard let due = todo.dueDate, let comp = todo.completedAt else { return false }
            return comp > due
        }.count
        let computedOverdueRate = completed.isEmpty ? 0.0 : Double(overdueCount) / Double(completed.count)
        if computedOverdueRate > 0.3 {
            let s = String(format: "완료 항목의 %.0f%%가 마감 이후에 처리됨", computedOverdueRate * 100)
            lines.append(s)
            insights.append(s)
        }

        // fastTags: 평균 완료 시간이 전체 평균보다 빠른 태그 집합 (HeuristicEngine 미세 부스트용)
        var fastTagSet: Set<String> = []
        if tagTimes.count >= 2 {
            let avgs = tagTimes.mapValues { $0.reduce(0, +) / Double($0.count) }
            let overall = avgs.values.reduce(0, +) / Double(avgs.count)
            fastTagSet = Set(avgs.filter { $0.value < overall }.keys)
        }

        let summary = lines.joined(separator: "\n")
        save(summary: summary, insights: insights, fastTags: Array(fastTagSet), overdueRate: computedOverdueRate, productiveHour: detectedProductiveHour)
        return (summary, insights)
    }

    // MARK: - Foreground FM Analysis (B: 포그라운드 전용)

    /// 포그라운드에서만 호출. 휴리스틱 `analyze()`를 먼저 실행해
    /// summary·fastTags를 확정한 뒤, FM이 insights 배열만 재작성한다.
    ///
    /// - summary·fastTags: 휴리스틱 값 유지 (FM 랭킹/페르소나 프롬프트 주입용이므로
    ///   FM 산문으로 대체 시 E-시리즈 컨텍스트 초과 재발 방지)
    /// - insights: FM이 사용자 친화적 문장으로 재작성 (UI 표시용)
    /// - FM 미가용·실패 시 휴리스틱 insights 그대로.
    /// - 백그라운드 BGTask는 `analyze(todos:)` 직접 호출(ANE 백그라운드 미사용).
    @discardableResult
    func analyzeForeground(todos: [Todo]) async -> (summary: String, insights: [String]) {
        // 1. 휴리스틱 코어 (동기): summary·fastTags 확정 + UserDefaults 저장
        let (summary, heuristicInsights) = analyze(todos: todos)

        // 2. FM으로 insights만 재작성 (포그라운드 전용)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsService.isAvailable {
            do {
                let fmInsights = try await FoundationModelsService().generatePatternInsights(
                    summary: summary,
                    todos: todos
                )
                if !fmInsights.isEmpty {
                    // insights만 갱신 (summary·fastTags는 휴리스틱 값 유지)
                    save(summary: summary, insights: fmInsights, fastTags: Array(latestAnalysis?.fastTags ?? []), overdueRate: latestAnalysis?.overdueRate ?? 0.0, productiveHour: latestAnalysis?.productiveHour)
                    return (summary, fmInsights)
                }
            } catch {
                print("[MemoryService] FM 패턴 분석 실패 — 휴리스틱 사용: \(error.localizedDescription)")
            }
        }
        #endif
        return (summary, heuristicInsights)
    }

    // MARK: - Foreground Preview (사용자 확인 후 적용)

    /// 포그라운드 전용 — 분석만 수행하고 UserDefaults에 저장하지 않는다.
    /// UI에서 미리보기를 보여주고 사용자가 확인하면 `applyAnalysisResult(_:)` 로 저장.
    func analyzeForegroundPreview(todos: [Todo]) async -> MemoryAnalysisResult {
        let completed = todos.filter { $0.isCompleted && $0.completedAt != nil }
        guard !completed.isEmpty else {
            return MemoryAnalysisResult(summary: "", insights: [], fastTags: [], overdueRate: 0, productiveHour: nil)
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
            let h = top.key
            detectedProductiveHour = h
            lines.append("가장 생산적인 시간대: \(h)시~\(h+1)시 (\(top.value)건 완료)")
            insights.append("\(h)시~\(h+1)시에 집중력이 가장 높음")
        }

        // 2. 태그별 평균 완료 소요 시간
        var tagTimes: [String: [Double]] = [:]
        for todo in completed {
            guard let comp = todo.completedAt else { continue }
            let hours = comp.timeIntervalSince(todo.createdAt) / 3600
            for tag in todo.tags { tagTimes[tag, default: []].append(hours) }
        }

        if tagTimes.count >= 2 {
            let avgs = tagTimes.mapValues { $0.reduce(0, +) / Double($0.count) }
            if let fastest = avgs.min(by: { $0.value < $1.value }),
               let slowest = avgs.max(by: { $0.value < $1.value }),
               fastest.key != slowest.key {
                lines.append("빠른 처리: '\(fastest.key)' 평균 \(Int(fastest.value))h / 느린 처리: '\(slowest.key)' 평균 \(Int(slowest.value))h")
                insights.append("'\(fastest.key)' 할 일이 가장 빠름 — 연속 처리에 적합")
                insights.append("'\(slowest.key)'은 완료까지 평균 \(Int(slowest.value))h 소요됨")
            }
        }

        // 3. 전체 완료율
        let rate = Double(completed.count) / Double(todos.count)
        let rateStr = String(format: "%.0f%%", rate * 100)
        lines.append("전체 완료율: \(rateStr) (\(completed.count)/\(todos.count)개)")
        if rate < 0.4 {
            insights.append("완료율 \(rateStr) — 완료되지 않은 항목이 전체의 \(String(format: "%.0f%%", (1 - rate) * 100)) 비율로 남아 있음")
        } else if rate > 0.8 {
            insights.append("완료율 \(rateStr) — 높은 실행력")
        }

        // 4. 평균 완료 소요 시간
        let times = completed.compactMap { t -> Double? in
            guard let comp = t.completedAt else { return nil }
            return comp.timeIntervalSince(t.createdAt) / 3600
        }
        if !times.isEmpty {
            let avg = times.reduce(0, +) / Double(times.count)
            let avgStr = avg < 24 ? "\(Int(avg))시간" : "\(Int(avg/24))일 \(Int(avg.truncatingRemainder(dividingBy: 24)))시간"
            lines.append("평균 완료 소요: \(avgStr)")
        }

        // 5. 마감 준수 패턴
        let overdueCount = completed.filter { todo in
            guard let due = todo.dueDate, let comp = todo.completedAt else { return false }
            return comp > due
        }.count
        let computedOverdueRate = completed.isEmpty ? 0.0 : Double(overdueCount) / Double(completed.count)
        if computedOverdueRate > 0.3 {
            let s = String(format: "완료 항목의 %.0f%%가 마감 이후에 처리됨", computedOverdueRate * 100)
            lines.append(s)
            insights.append(s)
        }

        // fastTags 계산
        var fastTagSet: Set<String> = []
        if tagTimes.count >= 2 {
            let avgs = tagTimes.mapValues { $0.reduce(0, +) / Double($0.count) }
            let overall = avgs.values.reduce(0, +) / Double(avgs.count)
            fastTagSet = Set(avgs.filter { $0.value < overall }.keys)
        }

        let previewSummary = lines.joined(separator: "\n")

        // FM으로 insights 재작성 시도 (저장하지 않음)
        var finalInsights = insights
        var usedAFM = false
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelsService.isAvailable {
            do {
                let fmInsights = try await FoundationModelsService().generatePatternInsights(
                    summary: previewSummary,
                    todos: todos
                )
                if !fmInsights.isEmpty {
                    finalInsights = fmInsights
                    usedAFM = true
                }
            } catch {
                print("[MemoryService] FM 패턴 미리보기 분석 실패 — 휴리스틱 사용: \(error.localizedDescription)")
            }
        }
        #endif

        return MemoryAnalysisResult(
            summary: previewSummary,
            insights: finalInsights,
            fastTags: fastTagSet,
            overdueRate: computedOverdueRate,
            productiveHour: detectedProductiveHour,
            usedAFM: usedAFM
        )
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
