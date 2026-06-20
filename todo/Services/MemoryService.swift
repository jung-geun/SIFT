import Foundation

/// 앱 내 할 일 완료 패턴을 분석해 AI 프롬프트용 메모리 요약을 생성합니다.
///
/// 분석 항목: 완료 시간대 분포 / 태그별 처리 속도 / 완료율 / 마감 준수율
/// 결과는 UserDefaults에 저장되어 AFM/Gemini/Claude 프롬프트에 자동 주입됩니다.
/// BGProcessingTask(pieroot.todo.memoryAnalysis)로 2일 이상 간격 백그라운드 실행.
struct MemoryService {

    static let shared = MemoryService()
    private init() {}

    private let summaryKey  = "pieroot.todo.memorySummary"
    private let insightsKey = "pieroot.todo.memoryInsights"
    private let dateKey     = "pieroot.todo.memoryDate"

    // MARK: - Stored State

    var summary: String {
        UserDefaults.standard.string(forKey: summaryKey) ?? ""
    }

    var insights: [String] {
        UserDefaults.standard.stringArray(forKey: insightsKey) ?? []
    }

    var lastAnalysisDate: Date? {
        let t = UserDefaults.standard.double(forKey: dateKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// HeuristicEngine이 소폭 부스트에 쓰는 "빠르게 처리하는 태그" 집합.
    /// analyze()가 실행된 적 없으면 빈 Set(부스트 없음).
    var fastTags: Set<String> {
        UserDefaults.standard.stringArray(forKey: fastTagsKey).map(Set.init) ?? []
    }

    private let fastTagsKey = "pieroot.todo.memoryFastTags"

    // MARK: - Analysis

    @discardableResult
    func analyze(todos: [Todo]) -> (summary: String, insights: [String]) {
        let completed = todos.filter { $0.isCompleted && $0.completedAt != nil }
        guard !completed.isEmpty else {
            save(summary: "", insights: [])
            return ("", [])
        }

        let cal = Calendar.current
        var lines: [String] = []
        var insights: [String] = []

        // 1. 완료 시간대 분포
        let hourCounts = Dictionary(
            grouping: completed.compactMap { $0.completedAt },
            by: { cal.component(.hour, from: $0) }
        ).mapValues { $0.count }

        if let top = hourCounts.max(by: { $0.value < $1.value }) {
            let h = top.key
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
                insights.append("'\(slowest.key)'은 완료까지 \(Int(slowest.value))h 소요 — 충분한 여유 필요")
            }
        }

        // 3. 전체 완료율
        let rate = Double(completed.count) / Double(todos.count)
        let rateStr = String(format: "%.0f%%", rate * 100)
        lines.append("전체 완료율: \(rateStr) (\(completed.count)/\(todos.count)개)")
        if rate < 0.4 {
            insights.append("완료율 \(rateStr) — 할 일을 더 작게 나누거나 마감을 현실적으로 조정 권장")
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
        if !completed.isEmpty && overdueCount > 0 {
            let overdueRate = Double(overdueCount) / Double(completed.count)
            if overdueRate > 0.3 {
                let s = String(format: "완료 항목의 %.0f%%가 마감 이후 처리 — 마감 여유 추가 권장", overdueRate * 100)
                lines.append(s)
                insights.append(s)
            }
        }

        // fastTags: 평균 완료 시간이 전체 평균보다 빠른 태그 집합 (HeuristicEngine 미세 부스트용)
        var fastTagSet: Set<String> = []
        if tagTimes.count >= 2 {
            let avgs = tagTimes.mapValues { $0.reduce(0, +) / Double($0.count) }
            let overall = avgs.values.reduce(0, +) / Double(avgs.count)
            fastTagSet = Set(avgs.filter { $0.value < overall }.keys)
        }

        let summary = lines.joined(separator: "\n")
        save(summary: summary, insights: insights, fastTags: Array(fastTagSet))
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
                    UserDefaults.standard.set(fmInsights, forKey: insightsKey)
                    return (summary, fmInsights)
                }
            } catch {
                print("[MemoryService] FM 패턴 분석 실패 — 휴리스틱 사용: \(error.localizedDescription)")
            }
        }
        #endif
        return (summary, heuristicInsights)
    }

    // MARK: - Persistence

    private func save(summary: String, insights: [String], fastTags: [String] = []) {
        UserDefaults.standard.set(summary, forKey: summaryKey)
        UserDefaults.standard.set(insights, forKey: insightsKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: dateKey)
        UserDefaults.standard.set(fastTags, forKey: fastTagsKey)
    }
}
