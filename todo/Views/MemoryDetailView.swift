import SwiftUI
import SwiftData

// 2. 행동 패턴 분석
struct MemoryDetailView: View {
    @Query private var todos: [Todo]
    @Query(sort: \MemoryAnalysis.createdAt, order: .reverse) private var analyses: [MemoryAnalysis]
    
    @State private var isAnalyzing = false
    @State private var pendingMemoryResult: MemoryAnalysisResult?
    @State private var afmAvailable = false
    @State private var errorMessage: String?
    @State private var showError = false
    private var memoryInsights: [String] {
        analyses.first?.insights ?? []
    }
    
    private var memoryDate: Date? {
        analyses.first?.createdAt
    }
    
    var body: some View {
        Form {
            Section {
                if let date = memoryDate {
                    LabeledContent("마지막 분석") {
                        Text(date.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                }
                
                if pendingMemoryResult == nil, !memoryInsights.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("발견된 패턴")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(memoryInsights, id: \.self) { insight in
                            Text("• \(insight)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } else if pendingMemoryResult == nil, memoryDate == nil {
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
                            Text(afmAvailable ? "Apple Foundation Models로 분석 중…" : "통계 기반으로 분석 중…")
                        }
                    } else {
                        Label(pendingMemoryResult == nil ? "지금 패턴 분석" : "다시 분석", systemImage: "chart.bar.xaxis")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isAnalyzing || todos.filter { $0.isCompleted }.isEmpty)
            } footer: {
                Text("완료한 할 일의 시간대 · 태그별 처리 속도 · 완료율을 분석합니다. Apple Foundation Models가 사용자 친화적 패턴 인사이트를 재작성합니다(미가용 시 통계 기반). AI 우선순위와 페르소나 생성에 자동 반영됩니다. 백그라운드에서 2일 간격으로 자동 실행됩니다.")
            }
        }
        .navigationTitle("행동 패턴 분석")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                afmAvailable = FoundationModelsService.isAvailable
            }
            #endif
        }
        .alert("AI 분석 오류", isPresented: $showError) {
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
                Label("새 분석 결과", systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .foregroundStyle(.blue)
                Spacer()
                if result.usedAFM {
                    Label("AFM", systemImage: "cpu")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue, in: Capsule())
                } else {
                    Label("통계 기반", systemImage: "chart.bar")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            
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
    
    private func analyzeMemory() async {
        isAnalyzing = true
        defer { isAnalyzing = false }

        do {
            let result = try await MemoryService.shared.analyzeForegroundPreview(todos: todos)
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
