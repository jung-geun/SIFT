import SwiftUI
import SwiftData

// 2. 행동 패턴 분석
struct MemoryDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var todos: [Todo]
    @Query private var auditEvents: [TaskAuditEvent]
    @Query private var behaviorEvents: [TaskBehaviorEvent]
    @Query(sort: \MemoryAnalysis.createdAt, order: .reverse) private var analyses: [MemoryAnalysis]
    
    @State private var isAnalyzing = false
    @State private var pendingMemoryResult: MemoryAnalysisResult?
    @State private var errorMessage: String?
    @State private var showError = false
    
    private var evidenceRecordCount: Int {
        todos.filter { $0.triage == .todo }.count
            + auditEvents.filter { $0.triageType == TodoTriage.todo.rawValue }.count
            + behaviorEvents.filter { $0.triageType == TodoTriage.todo.rawValue }.count
    }
    
    var body: some View {
        Form {
            Section {
                if pendingMemoryResult == nil, analyses.isEmpty {
                    Text("아직 분석 데이터가 없습니다. 할 일을 완료한 후 분석을 실행하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let result = pendingMemoryResult {
                    memoryAnalysisResultCard(result)
                }
                
                Button {
                    Task { await analyzeMemory() }
                } label: {
                    if isAnalyzing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("결정론적 통계 분석 중…")
                        }
                    } else {
                        Label(pendingMemoryResult == nil ? "지금 패턴 분석" : "다시 분석", systemImage: "chart.bar.xaxis")
                    }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("최근 90일의 현재 TODO 상태, 사용자 삭제 스냅샷, typed 변경 이벤트를 분리합니다. 모든 지원 기기에서 동일한 구조화 지표와 신뢰도를 계산하며, 결과는 적용을 눌러야 저장됩니다.")
            }

            Section {
                if analyses.isEmpty {
                    Text("아직 저장된 분석이 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(analyses) { analysis in
                        savedAnalysisCard(analysis)
                    }
                }
            } header: {
                Text("저장된 분석")
            }
        }
        .navigationTitle("행동 패턴 분석")
        .navigationBarTitleDisplayMode(.inline)
        .alert("분석 오류", isPresented: $showError) {
            Button("확인", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    @ViewBuilder
    private func memoryAnalysisResultCard(_ result: MemoryAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("새 분석 결과", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
                Spacer()
                Text(result.processorDescription)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }

            Text("\(result.behaviorProfile.confidence.label) · 근거 \(result.behaviorProfile.sampleCount)건 · \(result.behaviorProfile.windowStart.formatted(date: .abbreviated, time: .omitted))~\(result.behaviorProfile.windowEnd.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            
            if !result.summary.isEmpty {
                Text(result.summary)
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            
            if !result.insights.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("발견된 패턴")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(result.insights, id: \.self) { insight in
                        Text("• \(insight)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            HStack(spacing: 8) {
                Button("적용") { applyMemoryAnalysis() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                
                Button("다시 분석") {
                    Task { await analyzeMemory() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("취소") { pendingMemoryResult = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func savedAnalysisCard(_ analysis: MemoryAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    if !analysis.processorDescription.isEmpty {
                        Text(analysis.processorDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(analysis.confidence.label) · 근거 \(analysis.sampleCount)건")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("삭제", role: .destructive) {
                    MemoryService.shared.deleteAnalysis(analysis, context: modelContext)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !analysis.summary.isEmpty {
                Text(analysis.summary)
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if !analysis.insights.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(analysis.insights, id: \.self) { insight in
                        Text("• \(insight)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func analyzeMemory() async {
        isAnalyzing = true
        defer { isAnalyzing = false }

        do {
            let result = try await MemoryService.shared.analyzeForegroundPreview(
                todos: todos,
                auditEvents: auditEvents,
                behaviorEvents: behaviorEvents
            )
            if !result.summary.isEmpty || !result.insights.isEmpty {
                pendingMemoryResult = result
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func applyMemoryAnalysis() {
        guard let result = pendingMemoryResult else { return }
        MemoryService.shared.applyAnalysisResult(result)
        pendingMemoryResult = nil
    }
}
