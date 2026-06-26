import SwiftUI
import SwiftData
import Security
import Combine
import EventKit

struct PersonaSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    
    var body: some View {
        Form {
            Section {
                NavigationLink(destination: PersonaDetailView()) {
                    Label("나의 페르소나", systemImage: "person.circle")
                }
                
                NavigationLink(destination: MemoryDetailView()) {
                    Label("행동 패턴 분석", systemImage: "brain.head.profile")
                }
                
                NavigationLink(destination: IntelligenceDetailView()) {
                    Label("TODO 자동 정렬 및 AI", systemImage: "brain")
                }
                
                NavigationLink(destination: EmailDetailView()) {
                    Label("이메일 연동", systemImage: "envelope")
                }
                
                NavigationLink(destination: CalendarDetailView()) {
                    Label("캘린더 설정", systemImage: "calendar")
                }

                NavigationLink(destination: LaunchScreenDetailView()) {
                    Label("시작 화면", systemImage: "rectangle.on.rectangle")
                }

                NavigationLink(destination: SystemStatusDetailView()) {
                    Label("시스템 권한 및 상태", systemImage: "shield")
                }
                
                NavigationLink(destination: ICloudSyncDetailView()) {
                    Label("iCloud 동기화", systemImage: "icloud")
                }
                
                NavigationLink(destination: AppInfoDetailView()) {
                    Label("앱 정보", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("닫기") { dismiss() }
            }
        }
        .task {
            // D: selectedProvider 마이그레이션 (1회만 실행)
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "pieroot.todo.didMigrateToUnifiedAI") {
                if defaults.bool(forKey: "pieroot.todo.onDeviceLLMEnabled") {
                    let raw = defaults.string(forKey: "selectedAIProvider") ?? ""
                    if raw.isEmpty || raw == PersonaAIProvider.foundationModels.rawValue {
                        let store = SettingsStore.shared
                        let key = "selectedAIProvider"
                        let val = PersonaAIProvider.onDevice.rawValue
                        let isLocal = !iCloudSyncEnabled || store.isLocal(key: key)
                        if isLocal {
                            store.setLocal(key, value: val)
                        } else {
                            store.setGlobal(key, value: val)
                        }
                    }
                }
                defaults.set(true, forKey: "pieroot.todo.didMigrateToUnifiedAI")
            }
        }
    }
}

// MARK: - View Extension (Shared Helpers)
extension View {
    @ViewBuilder
    func scopeBadge(for key: String, iCloudSyncEnabled: Bool) -> some View {
        let isLocal = SettingsStore.shared.isLocal(key: key)
        
        HStack(spacing: 4) {
            if iCloudSyncEnabled {
                if isLocal {
                    Text("로컬")
                        .font(.caption2)
                } else {
                    Image(systemName: "icloud")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text("iCloud 동기화")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            } else {
                Text("로컬")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }
}

// MARK: - Subviews

// 1. 나의 페르소나
struct PersonaDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Persona.updatedAt, order: .reverse) private var personas: [Persona]
    @Query private var todos: [Todo]
    
    @State private var isGenerating = false
    @State private var generationResult: (personaText: String, insights: [String])?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showOnboardingResetup = false
    @State private var afmAvailable = false
    
    private let generationService = PersonaGenerationService()
    
    var body: some View {
        Form {
            Section {
                if let p = personas.first {
                    let types = p.personaTypes
                    let desc  = p.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if types.isEmpty && desc.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle")
                                .foregroundStyle(.secondary)
                            Text("아직 설정되지 않음")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if !types.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(types, id: \.rawValue) { type in
                                        HStack(spacing: 6) {
                                            Image(systemName: type.systemImage)
                                            Text(type.displayName)
                                        }
                                        .font(.subheadline.bold())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        if !desc.isEmpty {
                            Text(desc)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 2)
                        }
                    }
                    
                    Button {
                        showOnboardingResetup = true
                    } label: {
                        Label("페르소나 다시 설정", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    
                    Button {
                        generationResult = nil
                        Task { await runGeneration() }
                    } label: {
                        if isGenerating {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("AI 분석 중…")
                            }
                        } else {
                            Label(
                                personas.first?.descriptionText.isEmpty ?? true ? "AI 페르소나 생성" : "AI 페르소나 개선",
                                systemImage: "sparkles"
                            )
                            .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isGenerating || !afmAvailable)
                    
                    if !afmAvailable {
                        Label("이 기기에서 Apple Foundation Models를 사용할 수 없습니다", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    
                    if let result = generationResult {
                        generationResultCard(result)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            } footer: {
                Text("생활 유형은 AI 키 없이도 할 일 우선순위에 즉시 반영됩니다. AI 페르소나 개선은 사용자의 패턴을 토대로 자동으로 점진적으로 개선합니다.")
            }
        }
        .navigationTitle("나의 페르소나")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 중복된 페르소나 정리
            todoApp.deduplicatePersonas(context: modelContext)
            
            // iCloud 활성화 시 CloudKit 동기화 도착을 최대 3초 대기한 뒤 Persona 생성
            let useICloud = UserDefaults.standard.bool(forKey: todoApp.iCloudSyncKey)
            if personas.isEmpty && useICloud {
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !personas.isEmpty { break }
                }
            }
            if personas.isEmpty {
                let p = Persona()
                modelContext.insert(p)
            }
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                afmAvailable = FoundationModelsService.isAvailable
            } else {
                afmAvailable = false
            }
            #else
            afmAvailable = false
            #endif
        }
        .sheet(isPresented: $showOnboardingResetup) {
            OnboardingView(isPresented: $showOnboardingResetup, isResetup: true)
        }
        .alert("오류", isPresented: $showError, presenting: errorMessage) { _ in
            Button("확인", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }
    
    @ViewBuilder
    private func generationResultCard(_ result: (personaText: String, insights: [String])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("생성된 페르소나", systemImage: "checkmark.circle")
                .font(.subheadline.bold())
                .foregroundStyle(.green)
            
            Text(result.personaText)
                .font(.body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            
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
                Button("이 페르소나 사용") { applyGeneratedPersona() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                
                Button("다시 생성") {
                    generationResult = nil
                    Task { await runGeneration() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("취소") { generationResult = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func runGeneration() async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let existing = personas.first?.descriptionText ?? ""
            let result = try await generationService.generate(
                existingPersona: existing,
                todos: todos,
                provider: .foundationModels
            )
            generationResult = result
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    private func applyGeneratedPersona() {
        guard let result = generationResult, let p = personas.first else { return }
        p.descriptionText = result.personaText
        p.updatedAt = Date()
        generationResult = nil
    }
}

// 2. 행동 패턴 분석
struct MemoryDetailView: View {
    @Query private var todos: [Todo]
    @Query(sort: \MemoryAnalysis.createdAt, order: .reverse) private var analyses: [MemoryAnalysis]
    
    @State private var isAnalyzing = false
    @State private var pendingMemoryResult: MemoryAnalysisResult?
    @State private var afmAvailable = false

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
                    pendingMemoryResult = nil
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
                    pendingMemoryResult = nil
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
        let result = await MemoryService.shared.analyzeForegroundPreview(todos: todos)
        if !result.summary.isEmpty || !result.insights.isEmpty {
            pendingMemoryResult = result
        }
    }
    
    private func applyMemoryAnalysis() {
        guard let result = pendingMemoryResult else { return }
        MemoryService.shared.applyAnalysisResult(result)
        pendingMemoryResult = nil
    }
}

// 3. TODO 자동 정렬 및 AI
struct IntelligenceDetailView: View {
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("pieroot.todo.onDeviceModelID") private var onDeviceModelID = "mlx-community/Qwen3.5-2B-MLX-4bit"
    
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var llmService: OnDeviceLLMService = .shared
    
    @State private var showDownloadConfirm = false
    @State private var afmAvailable = false
    
    private var selectedProvider: PersonaAIProvider {
        get {
            let raw: String = SettingsStore.shared.get("selectedAIProvider", defaultValue: PersonaAIProvider.foundationModels.rawValue)
            return PersonaAIProvider(rawValue: raw) ?? .foundationModels
        }
        nonmutating set {
            saveSetting(key: "selectedAIProvider", value: newValue.rawValue)
        }
    }
    
    private var selectedProviderBinding: Binding<PersonaAIProvider> {
        Binding(
            get: {
                let raw: String = SettingsStore.shared.get("selectedAIProvider", defaultValue: PersonaAIProvider.foundationModels.rawValue)
                return PersonaAIProvider(rawValue: raw) ?? .foundationModels
            },
            set: { newValue in
                saveSetting(key: "selectedAIProvider", value: newValue.rawValue)
            }
        )
    }
    
    private var selectedModelSizeMB: Int {
        OnDeviceLLMService.modelCatalog.first { $0.id == onDeviceModelID }?.sizeMB ?? 1400
    }
    
    private var isOnDeviceLLMCapable: Bool {
        ProcessInfo.processInfo.physicalMemory >= 6 * 1_024 * 1_024 * 1_024
    }
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("AI 자동화", isOn: settingsBinding(key: "pieroot.todo.onDeviceLLMEnabled", defaultValue: false))
                    scopeBadge(for: "pieroot.todo.onDeviceLLMEnabled", iCloudSyncEnabled: iCloudSyncEnabled)
                }
            } header: {
                Label("AI 자동화", systemImage: "gearshape.2")
            } footer: {
                Text("앱 실행 시 자동으로 페르소나를 갱신합니다 (6시간 쿨다운). 이메일 분석·할 일 자동 등록은 아래 이메일 연동의 '메일 자동 분석' 토글로 별도 제어합니다. 수동 정렬(✦)·페르소나 생성은 이 설정과 상관없이 항상 동작합니다.")
            }
            
            Section {
                Picker("TODO 자동 정렬 AI", selection: selectedProviderBinding) {
                    ForEach(PersonaAIProvider.allCases) { p in
                        Label(p.displayName, systemImage: p.systemImage).tag(p)
                    }
                }
                .pickerStyle(.menu)
                scopeBadge(for: "selectedAIProvider", iCloudSyncEnabled: iCloudSyncEnabled)
                
                
                
                if selectedProvider == .onDevice && !llmService.isModelCachedOnDisk {
                    Label("온디바이스 모델을 먼저 다운로드하세요 (아래 모델 관리 섹션)", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                
                Label("할 일 목록 화면 ✦ 버튼으로 AI 우선순위 정리 실행", systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Label("TODO 자동 정렬 AI", systemImage: "brain")
            } footer: {
                Text(intelligenceFooter)
            }
            
            if selectedProvider == .onDevice && isOnDeviceLLMCapable {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("모델")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(llmService.modelID.components(separatedBy: "/").last ?? llmService.modelID)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.primary)
                        }
                        Spacer()
                        llmModelStatusBadge
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        if llmService.isModelCachedOnDisk && !llmService.isModelLoaded {
                            Button {
                                Task { await llmService.loadModelIfNeeded() }
                            } label: {
                                Label("지금 로드", systemImage: "cpu.fill")
                            }
                        }
                        if llmService.isModelLoaded || llmService.isModelCachedOnDisk {
                            Button(role: .destructive) {
                                Task { await llmService.deleteDownloadedModel() }
                            } label: {
                                Label("모델 삭제 (약 \(selectedModelSizeMB / 100 * 100 / 1000).\((selectedModelSizeMB / 100) % 10)GB 확보)", systemImage: "trash")
                            }
                        }
                        if !llmService.isModelCachedOnDisk && !llmService.isLoading {
                            Button {
                                showDownloadConfirm = true
                            } label: {
                                Label("모델 다운로드", systemImage: "arrow.down.circle")
                            }
                        }
                    }
                    
                    Picker("모델", selection: $onDeviceModelID) {
                        ForEach(OnDeviceLLMService.modelCatalog) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: onDeviceModelID) { _, _ in
                        if llmService.isModelLoaded { llmService.unloadModel() }
                    }
                    
                    if llmService.isLoading {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: llmService.downloadProgress > 0 ? llmService.downloadProgress : nil)
                            if llmService.downloadProgress > 0 {
                                Text("\(Int(llmService.downloadProgress * 100))% 완료")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("초기화 중…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    
                    if llmService.downloadInterrupted {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                "다운로드가 중단됐습니다 (\(Int(llmService.downloadProgress * 100))% 완료)",
                                systemImage: "pause.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                            HStack(spacing: 8) {
                                Button("다시 시도") {
                                    Task { await llmService.loadModelIfNeeded() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button(role: .destructive) {
                                    Task { await llmService.deleteDownloadedModel() }
                                } label: {
                                    Text("부분 삭제")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    
                    if let err = llmService.loadError {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("다운로드 실패", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button("다시 시도") {
                                Task { await llmService.loadModelIfNeeded() }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                    
                    if !llmService.isLoading && !llmService.downloadInterrupted && !llmService.isModelCachedOnDisk {
                        if OnDeviceLLMService.isMLXAvailable {
                            Button {
                                showDownloadConfirm = true
                            } label: {
                                Label("모델 다운로드 (약 \(selectedModelSizeMB / 100 * 100 / 1000).\((selectedModelSizeMB / 100) % 10)GB)", systemImage: "arrow.down.circle")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Xcode에서 패키지를 먼저 추가해야 합니다", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.orange)
                                Text("File → Add Package Dependencies\n\(URL(string: "https://github.com/ml-explore/mlx-swift-examples")!.absoluteString)\nbranch: main → MLXLLM, MLXLMCommon 선택")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Label("온디바이스 모델 관리", systemImage: "square.and.arrow.down")
                } footer: {
                    Text("'Qwen AI' 선택 시 활성화됩니다. 최초 1회만 다운로드합니다. Wi-Fi 환경에서 진행을 권장합니다. 모델은 기기에만 저장되며 이메일 본문은 기기 밖으로 전송되지 않습니다.")
                }
                .confirmationDialog(
                    "모델 다운로드",
                    isPresented: $showDownloadConfirm,
                    titleVisibility: .visible
                ) {
                    Button("다운로드 (약 \(selectedModelSizeMB / 100 * 100 / 1000).\((selectedModelSizeMB / 100) % 10)GB)") {
                        Task { await llmService.loadModelIfNeeded() }
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("\(onDeviceModelID) 모델을 기기에 다운로드합니다. Wi-Fi 환경에서 진행을 권장하며, 모든 추론은 기기 내에서만 이루어집니다.")
                }
            }
        }
        .navigationTitle("TODO 자동 정렬 및 AI")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let raw: String = SettingsStore.shared.get("selectedAIProvider", defaultValue: PersonaAIProvider.foundationModels.rawValue)
            if PersonaAIProvider(rawValue: raw) == nil {
                saveSetting(key: "selectedAIProvider", value: PersonaAIProvider.foundationModels.rawValue)
            }

            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                afmAvailable = FoundationModelsService.isAvailable
            } else {
                afmAvailable = false
            }
            #else
            afmAvailable = false
            #endif
        }
    }
    
    private var intelligenceFooter: String {
        switch selectedProvider {
        case .foundationModels:
            return "Apple Foundation Models(온디바이스)가 할 일을 정렬합니다. Qwen을 선택하면 해당 모델이 AFM보다 먼저 동작합니다.\n\n\(credentialStorageHint)"
        case .onDevice:
            return "Qwen 온디바이스 모델이 우선 정렬하고, 미로드 시 Apple Foundation Models로 폴백합니다.\n\n\(credentialStorageHint)"
        }
    }
    
    private var credentialStorageHint: String {
        if iCloudSyncEnabled {
            return "인증정보와 보안정보들은 사용자의 iCloud Keychain에 안전하게 저장됩니다."
        }
        return "인증정보와 보안정보들은 사용자의 Keychain에 안전하게 저장됩니다."
    }
    
    @ViewBuilder
    private var llmModelStatusBadge: some View {
        let (label, color): (String, Color) = {
            if llmService.isDeleting        { return ("삭제 중", .red) }
            if llmService.isModelLoaded     { return ("로드됨", .green) }
            if llmService.isLoading         { return ("다운로드 중", .blue) }
            if llmService.downloadInterrupted { return ("중단됨", .orange) }
            if llmService.isModelCachedOnDisk { return ("설치됨", .yellow) }
            return ("미설치", .gray)
        }()
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
    
    private func saveSetting<T>(key: String, value: T, onChange: ((T) -> Void)? = nil) {
        let isLocal = !iCloudSyncEnabled || SettingsStore.shared.isLocal(key: key)
        if isLocal {
            SettingsStore.shared.setLocal(key, value: value)
        } else {
            SettingsStore.shared.setGlobal(key, value: value)
        }
        onChange?(value)
    }
    
    private func settingsBinding<T>(key: String, defaultValue: T, onChange: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(
            get: {
                SettingsStore.shared.get(key, defaultValue: defaultValue)
            },
            set: { newValue in
                saveSetting(key: key, value: newValue) { val in
                    onChange?(val)
                }
            }
        )
    }
    
}

// 4. 이메일 연동
struct EmailDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @AppStorage("pieroot.todo.lastEmailFetchDate") private var lastEmailFetchTimestamp: Double = 0
    
    @State private var isGmailAuthenticated = false
    @State private var isConnectingGmail = false
    @State private var isFetchingEmails = false
    @State private var lastFetchMessage: String?
    @State private var showEmailPeriod = false
    @State private var suppressedSendersList: [String] = []
    @State private var errorMessage: String?
    @State private var showError = false
    
    private var emailLookbackDays: Int {
        get { SettingsStore.shared.get("pieroot.todo.emailLookbackDays", defaultValue: 3) }
        nonmutating set { saveSetting(key: "pieroot.todo.emailLookbackDays", value: newValue) }
    }
    private var emailRefreshHour: Int {
        get { SettingsStore.shared.get("pieroot.todo.emailRefreshHour", defaultValue: 7) }
        nonmutating set { saveSetting(key: "pieroot.todo.emailRefreshHour", value: newValue) }
    }
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Label("Gmail 계정", systemImage: "envelope.circle.fill")
                        .symbolRenderingMode(.multicolor)
                    Spacer()
                    Text(isGmailAuthenticated ? "연결됨" : "미연결")
                        .font(.subheadline)
                        .foregroundStyle(isGmailAuthenticated ? .green : .secondary)
                }
                .contextMenu {
                    if isGmailAuthenticated {
                        Button {
                            Task { await fetchEmailsNow() }
                        } label: {
                            Label("지금 메일 확인", systemImage: "arrow.clockwise")
                        }
                        Button(role: .destructive) {
                            EmailService.shared.signOut()
                            isGmailAuthenticated = false
                            lastFetchMessage = nil
                        } label: {
                            Label("연결 해제", systemImage: "minus.circle")
                        }
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if isGmailAuthenticated {
                        Button {
                            Task { await fetchEmailsNow() }
                        } label: {
                            Label("메일 확인", systemImage: "arrow.clockwise")
                        }
                        .tint(.blue)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if isGmailAuthenticated {
                        Button(role: .destructive) {
                            EmailService.shared.signOut()
                            isGmailAuthenticated = false
                            lastFetchMessage = nil
                        } label: {
                            Label("연결 해제", systemImage: "minus.circle")
                        }
                    }
                }
                
                if isGmailAuthenticated {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("메일 자동 분석", isOn: settingsBinding(key: "pieroot.todo.emailAutoAnalysisEnabled", defaultValue: true))
                        scopeBadge(for: "pieroot.todo.emailAutoAnalysisEnabled", iCloudSyncEnabled: iCloudSyncEnabled)
                    }
                    
                    DisclosureGroup(isExpanded: $showEmailPeriod) {
                        HStack {
                            Label("마지막 동기화", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            if lastEmailFetchTimestamp > 0 {
                                Text(Date(timeIntervalSince1970: lastEmailFetchTimestamp), style: .relative)
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            } else {
                                Text("없음")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("자동 동기화 시각", selection: settingsBinding(key: "pieroot.todo.emailRefreshHour", defaultValue: 7) { _ in
                                scheduleEmailRefresh()
                            }) {
                                ForEach(0..<24, id: \.self) { h in
                                    Text(Self.hourLabel(h)).tag(h)
                                }
                            }
                            .pickerStyle(.menu)
                            scopeBadge(for: "pieroot.todo.emailRefreshHour", iCloudSyncEnabled: iCloudSyncEnabled)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Stepper("메일 확인 기간: \(emailLookbackDays)일", value: settingsBinding(key: "pieroot.todo.emailLookbackDays", defaultValue: 3), in: 1...30)
                            Text("최근 \(emailLookbackDays)일치 메일을 분석합니다. 기본값 3일.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            scopeBadge(for: "pieroot.todo.emailLookbackDays", iCloudSyncEnabled: iCloudSyncEnabled)
                        }
                    } label: {
                        HStack {
                            Label("동기화 설정", systemImage: "gear")
                            Spacer()
                            if lastEmailFetchTimestamp > 0 {
                                Text(Date(timeIntervalSince1970: lastEmailFetchTimestamp), style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Button {
                        Task { await connectGmail() }
                    } label: {
                        if isConnectingGmail {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("연결 중…")
                            }
                        } else {
                            Label("Gmail 연결", systemImage: "plus.circle")
                        }
                    }
                    .disabled(isConnectingGmail)
                }
                
                if let msg = lastFetchMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("이메일 연동", systemImage: "envelope")
            } footer: {
                Text("'메일 자동 분석' 활성화 시 연결된 메일을 자동 분석해 마감 할 일을 등록합니다. 포그라운드는 Apple Foundation Models(온디바이스), 백그라운드는 NSDataDetector 사용. 이메일 본문은 기기 밖으로 전송되지 않습니다. OS 상황(배터리·네트워크)에 따라 실제 실행 시각은 다를 수 있습니다.")
            }
            
            if isGmailAuthenticated {
                Section {
                    if suppressedSendersList.isEmpty {
                        Text("숨긴 발신자 없음")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(suppressedSendersList, id: \.self) { sender in
                            HStack {
                                Label(sender, systemImage: "bell.slash")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Button("해제") {
                                    EmailLearningStore.shared.unsuppress(sender)
                                    suppressedSendersList = EmailLearningStore.shared.suppressedSenders()
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.orange)
                            }
                        }
                    }
                } header: {
                    Label("자동 숨긴 발신자", systemImage: "eye.slash")
                } footer: {
                    Text("같은 발신자의 이메일을 2회 이상 삭제하면 자동으로 숨겨집니다. 해제하면 이후 메일이 다시 분류됩니다.")
                }
            }
        }
        .navigationTitle("이메일 연동")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isGmailAuthenticated = EmailService.shared.isAuthenticated
            suppressedSendersList = EmailLearningStore.shared.suppressedSenders()
        }
        .alert("오류", isPresented: $showError, presenting: errorMessage) { _ in
            Button("확인", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }
    
    private func saveSetting<T>(key: String, value: T, onChange: ((T) -> Void)? = nil) {
        let isLocal = !iCloudSyncEnabled || SettingsStore.shared.isLocal(key: key)
        if isLocal {
            SettingsStore.shared.setLocal(key, value: value)
        } else {
            SettingsStore.shared.setGlobal(key, value: value)
        }
        onChange?(value)
    }
    
    private func settingsBinding<T>(key: String, defaultValue: T, onChange: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(
            get: {
                SettingsStore.shared.get(key, defaultValue: defaultValue)
            },
            set: { newValue in
                saveSetting(key: key, value: newValue) { val in
                    onChange?(val)
                }
            }
        )
    }
    
    private static func hourLabel(_ h: Int) -> String {
        switch h {
        case 0:  return "자정 00:00"
        case 12: return "정오 12:00"
        default:
            let period = h < 12 ? "오전" : "오후"
            let display = h <= 12 ? h : h - 12
            return "\(period) \(display)시 (\(String(format: "%02d", h)):00)"
        }
    }
    
    private func connectGmail() async {
        isConnectingGmail = true
        defer { isConnectingGmail = false }
        do {
            try await EmailService.shared.authenticate()
            isGmailAuthenticated = true
            lastFetchMessage = "Gmail 연결 완료"
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" && nsError.code == 1 {
                errorMessage = "로그인이 취소되었습니다."
            } else {
                errorMessage = error.localizedDescription
            }
            showError = true
        }
    }
    
    private func fetchEmailsNow() async {
        isFetchingEmails = true
        defer { isFetchingEmails = false }
        do {
            let existing = (try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []
            let existingRefs = Set(existing.map { $0.sourceRef })
            let (newTodos, extractedEvents) = try await EmailService.shared.fetchAndExtractAll(
                excludingAlreadyHandledMessageIDs: existingRefs
            )
            var todoCount = 0
            for todo in newTodos where !existingRefs.contains(todo.sourceRef) {
                modelContext.insert(todo)
                todoCount += 1
                CalendarService.shared.applyAutoRegistration(for: todo)
            }
            
            var eventCount = 0
            if CalendarAutoPolicy.isAuto && CalendarService.shared.isAuthorized {
                let iso = ISO8601DateFormatter()
                for (event, sourceRef) in extractedEvents {
                    guard !CalendarService.shared.hasEvent(forEmailRef: sourceRef),
                          let start = iso.date(from: event.startISO) else { continue }
                    let end = event.endISO.isEmpty ? nil : iso.date(from: event.endISO)
                    if (try? CalendarService.shared.createEventFromEmail(
                        title: event.title, start: start, end: end,
                        isAllDay: event.isAllDay, location: event.location,
                        notes: event.notes, sourceRef: sourceRef
                    )) != nil { eventCount += 1 }
                }
            }
            
            lastEmailFetchTimestamp = Date().timeIntervalSince1970
            var parts: [String] = []
            if todoCount > 0  { parts.append("할 일 \(todoCount)개") }
            if eventCount > 0 { parts.append("일정 \(eventCount)개") }
            lastFetchMessage = parts.isEmpty ? "새 항목 없음" : parts.joined(separator: ", ") + " 추출됨"
        } catch {
            lastFetchMessage = "오류: \(error.localizedDescription)"
        }
    }
}

// 5. 캘린더 설정
struct CalendarDetailView: View {
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("마감 자동 캘린더 등록", isOn: Binding(
                        get: { CalendarAutoPolicy.isAuto },
                        set: { newValue in
                            saveSetting(key: "pieroot.todo.calendarAutoRegister", value: newValue) { val in
                                let isLocal = !iCloudSyncEnabled || SettingsStore.shared.isLocal(key: "pieroot.todo.calendarAutoRegister")
                                if isLocal {
                                    SettingsStore.shared.setLocal("pieroot.todo.calendarAutoChoiceMade", value: true)
                                } else {
                                    SettingsStore.shared.setGlobal("pieroot.todo.calendarAutoChoiceMade", value: true)
                                }
                            }
                        }
                    ))
                    .disabled(!CalendarService.shared.isAuthorized)
                    scopeBadge(for: "pieroot.todo.calendarAutoRegister", iCloudSyncEnabled: iCloudSyncEnabled)
                }
                
                if !CalendarService.shared.isAuthorized {
                    Label("캘린더 권한이 필요합니다", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Picker("완료 시 처리", selection: settingsBinding(key: "pieroot.todo.calendarCompletionAction", defaultValue: "silence")) {
                        Text("이벤트 삭제").tag("remove")
                        Text("알람만 끄기").tag("silence")
                    }
                    .pickerStyle(.menu)
                    .disabled(!CalendarService.shared.isAuthorized)
                    scopeBadge(for: "pieroot.todo.calendarCompletionAction", iCloudSyncEnabled: iCloudSyncEnabled)
                }
            } footer: {
                Text("마감 시각이 있는 모든 할 일(수동·이메일 모두)을 시스템 캘린더에 자동으로 등록합니다. 긴급·최우선 항목은 이 설정과 무관하게 항상 등록됩니다. '알람만 끄기'는 이벤트는 캘린더에 남기고 리마인더만 제거합니다.")
            }

            defaultCalendarSection
        }
        .navigationTitle("캘린더 설정")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 기본 캘린더 설정이 비어있으면 시스템 기본값 ID를 초기화
            if CalendarService.shared.isAuthorized
                && CalendarService.shared.defaultCalendarID.isEmpty,
               let sysDefault = CalendarService.shared.preferredDefaultCalendar {
                CalendarService.shared.defaultCalendarID = sysDefault.calendarIdentifier
            }
        }
    }

    @ViewBuilder
    private var defaultCalendarSection: some View {
        if CalendarService.shared.isAuthorized {
            Section {
                let currentID    = CalendarService.shared.defaultCalendarID
                let currentColor: Color = {
                    guard let cal = CalendarService.shared.ekCalendar(withIdentifier: currentID)
                    else { return .accentColor }
                    return Color(cgColor: cal.cgColor)
                }()
                let currentTitle: String = CalendarService.shared
                    .availableCalendars()
                    .flatMap { $0.calendars }
                    .first { $0.id == currentID }
                    .map { $0.title } ?? "기본"

                NavigationLink(destination: DefaultCalendarPickerView()) {
                    HStack(spacing: 10) {
                        Text("기본 캘린더")
                        Spacer()
                        Circle()
                            .fill(currentColor)
                            .frame(width: 10, height: 10)
                        Text(currentTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("기본 캘린더")
            } footer: {
                Text("새 할 일·이벤트를 추가할 때 기본으로 사용할 캘린더입니다. 개별 추가 시 변경할 수 있습니다.")
            }
        }
    }

    private func saveSetting<T>(key: String, value: T, onChange: ((T) -> Void)? = nil) {
        let isLocal = !iCloudSyncEnabled || SettingsStore.shared.isLocal(key: key)
        if isLocal {
            SettingsStore.shared.setLocal(key, value: value)
        } else {
            SettingsStore.shared.setGlobal(key, value: value)
        }
        onChange?(value)
    }
    
    private func settingsBinding<T>(key: String, defaultValue: T, onChange: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(
            get: {
                SettingsStore.shared.get(key, defaultValue: defaultValue)
            },
            set: { newValue in
                saveSetting(key: key, value: newValue) { val in
                    onChange?(val)
                }
            }
        )
    }
}

// 6. 시작 화면 설정
struct LaunchScreenDetailView: View {
    @AppStorage("pieroot.todo.launchBehavior") private var launchBehavior = "lastUsed"
    @AppStorage("pieroot.todo.launchTab")     private var launchTab = 0

    var body: some View {
        Form {
            Section {
                Picker("시작 방식", selection: $launchBehavior) {
                    Text("마지막 화면").tag("lastUsed")
                    Text("고정 탭").tag("fixed")
                }
                .pickerStyle(.menu)

                if launchBehavior == "fixed" {
                    Picker("기본 탭", selection: $launchTab) {
                        Text("할 일").tag(0)
                        Text("캘린더").tag(1)
                        Text("메일").tag(2)
                    }
                    .pickerStyle(.menu)
                }
            } footer: {
                Text("'마지막 화면'은 앱 종료 시 보던 탭으로 돌아옵니다. '고정 탭'은 항상 지정한 탭으로 시작합니다.")
            }
        }
        .navigationTitle("시작 화면")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// 7. 시스템 권한 및 상태
struct SystemStatusDetailView: View {
    @State private var notificationStatus = "확인 중…"
    @State private var calendarStatus     = "확인 중…"
    
    var body: some View {
        Form {
            Section {
                HStack {
                    Label("알림", systemImage: "bell.badge")
                    Spacer()
                    Text(notificationStatus)
                        .font(.subheadline)
                        .foregroundStyle(notificationStatus == "허용됨" ? .green : .orange)
                    if notificationStatus != "허용됨" {
                        Button("허용") { Task { await requestNotification() } }
                            .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    }
                }
                
                HStack {
                    Label("캘린더", systemImage: "calendar")
                    Spacer()
                    Text(calendarStatus)
                        .font(.subheadline)
                        .foregroundStyle(calendarStatus == "허용됨" ? .green : .orange)
                    if calendarStatus != "허용됨" {
                        Button("허용") { Task { await requestCalendar() } }
                            .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
        .navigationTitle("시스템 권한 및 상태")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshStatus()
        }
    }
    
    private func refreshStatus() async {
        let status = await NotificationService.shared.authorizationStatus()
        notificationStatus = switch status {
        case .authorized, .provisional, .ephemeral: "허용됨"
        case .denied: "거부됨"
        case .notDetermined: "미설정"
        @unknown default: "알 수 없음"
        }
        calendarStatus = CalendarService.shared.isAuthorized ? "허용됨" : "미설정"
    }
    
    private func requestNotification() async {
        notificationStatus = await NotificationService.shared.requestAuthorization() ? "허용됨" : "거부됨"
    }
    
    private func requestCalendar() async {
        calendarStatus = await CalendarService.shared.requestAccess() ? "허용됨" : "거부됨"
    }
}

// 7. iCloud 동기화
struct ICloudSyncDetailView: View {
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @State private var showSyncRestartAlert = false
    @ObservedObject private var settingsStore = SettingsStore.shared
    
    var body: some View {
        Form {
            Section {
                Toggle("데이터 동기화 (iCloud)", isOn: Binding(
                    get: { iCloudSyncEnabled },
                    set: { newValue in
                        iCloudSyncEnabled = newValue
                        if newValue {
                            SettingsStore.shared.uploadLocalSettingsToCloud()
                        }
                        // @AppStorage가 UserDefaults에 newValue를 반영한 직후 호출 →
                        // KeychainStore.shouldSync가 올바른 값을 읽어 시크릿 동기화 정책 재적용.
                        // ON: 시크릿 → synchronizable (iCloud Keychain 동기화 시작)
                        // OFF: 시크릿 → ThisDeviceOnly (타 기기 iCloud Keychain에서 회수)
                        KeychainStore.applySyncPolicy()
                        showSyncRestartAlert = true
                    }
                ))
                
                if iCloudSyncEnabled {
                    Label("할 일·페르소나가 iCloud를 통해 동기화됩니다", systemImage: "checkmark.icloud.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("데이터가 이 기기에만 저장됩니다", systemImage: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("iCloud 동기화를 활성화하면 할 일, 페르소나, 할 일 감사 기록이 같은 Apple ID로 로그인한 모든 기기와 동기화됩니다. 행동 패턴 분석과 이메일 학습 데이터는 기기 로컬에만 저장됩니다.")
            }
            .alert("앱 재시작 필요", isPresented: $showSyncRestartAlert) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(iCloudSyncEnabled
                     ? "iCloud 동기화가 활성화되었습니다. 앱을 종료 후 다시 실행하면 동기화가 시작됩니다."
                     : "iCloud 동기화가 비활성화되었습니다. 앱을 종료 후 다시 실행하면 로컬 전용으로 전환됩니다.")
            }
            
            if iCloudSyncEnabled {
                Section {
                    syncManagementRow(title: "AI 자동화", key: "pieroot.todo.onDeviceLLMEnabled")
                    syncManagementRow(title: "TODO 자동 정렬 AI", key: "selectedAIProvider")
                    syncManagementRow(title: "메일 자동 분석", key: "pieroot.todo.emailAutoAnalysisEnabled")
                    syncManagementRow(title: "자동 동기화 시각", key: "pieroot.todo.emailRefreshHour")
                    syncManagementRow(title: "메일 확인 기간", key: "pieroot.todo.emailLookbackDays")
                    syncManagementRow(title: "마감 자동 캘린더 등록", key: "pieroot.todo.calendarAutoRegister")
                    syncManagementRow(title: "완료 시 처리", key: "pieroot.todo.calendarCompletionAction")
                } header: {
                    Label("iCloud 동기화 관리", systemImage: "icloud.fill")
                } footer: {
                    Text("각 설정 항목의 저장 위치를 iCloud 동기화 또는 로컬 전용으로 일괄 지정할 수 있습니다.")
                }
            }
        }
        .navigationTitle("iCloud 동기화")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func syncManagementRow(title: String, key: String) -> some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Menu {
                Button {
                    SettingsStore.shared.setLocal(key: key, isLocal: false)
                } label: {
                    Label("iCloud 동기화", systemImage: "icloud")
                }
                Button {
                    SettingsStore.shared.setLocal(key: key, isLocal: true)
                } label: {
                    Text("로컬")
                }
            } label: {
                HStack(spacing: 4) {
                    if SettingsStore.shared.isLocal(key: key) {
                        Text("로컬")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("iCloud", systemImage: "icloud")
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// 8. 앱 정보
struct AppInfoDetailView: View {
    @State private var showDevChanges = false
    
    var body: some View {
        Form {
            Section {
                LabeledContent("버전") {
                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
                    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
                    Text("\(version) (\(build))")
                }
                LabeledContent("이메일 연동") { Text("Gmail (1계정)") }

                Button {
                    showDevChanges = true
                } label: {
                    Label("개발 현황 및 예정 기능", systemImage: "list.bullet.clipboard")
                }
                .buttonStyle(.borderless)
            }

            Section(header: Text("약관 및 정책")) {
                NavigationLink(destination: LegalDocumentView(document: .privacy)) {
                    Label("개인정보 처리방침", systemImage: "hand.raised.fill")
                }
                NavigationLink(destination: LegalDocumentView(document: .terms)) {
                    Label("서비스 약관", systemImage: "doc.text")
                }
            }
        }
        .navigationTitle("앱 정보")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDevChanges) {
            devChangesSheet
        }
    }
    
    private var devChangesSheet: some View {
        NavigationStack {
            List {
                Section {
                    devRow("✅", "SwiftData 기반 로컬/iCloud 데이터 저장소 구축")
                    devRow("✅", "최초 기동 시 iCloud 동기화 여부 설정 지원 (0단계 온보딩)")
                    devRow("✅", "iCloud 글로벌 설정 vs 기기별 로컬 설정 분리 및 중앙 관리")
                    devRow("✅", "Gmail OAuth2 연동 및 메일 자동 분석 (할 일 자동 추출)")
                    devRow("✅", "이메일 딥링크 지원 (앱 내에서 원본 메일로 바로 이동)")
                    devRow("✅", "캘린더 마감 자동 등록 및 완료 처리 정책 연동")
                    devRow("✅", "앱-시스템 캘린더 실시간 양방향 동기화 및 충돌 자동 해결")
                    devRow("✅", "완료된 항목 1달 경과 시 자동 숨김 처리")
                    devRow("✅", "데이터베이스 용량 초과 방지를 위한 자동 오래된 데이터 청소")
                    devRow("✅", "시간대/태그별 처리 속도 통계 기반 행동 패턴 메모리 분석")
                    devRow("✅", "설정 화면 8대 대분류 카테고리 분할 및 독립 뷰 리팩토링")
                    devRow("✅", "온디바이스 LLM 최적화 (가상 모델 제거 및 Qwen3.5 2B MLX 탑재)")
                } header: { Text("완료") }
                
                Section {
                    devRow("🔄", "온디바이스 Qwen3.5 4B 고성능 모델 기기 메모리 최적화")
                    devRow("🔄", "백그라운드 캘린더 변경사항 감지 정확도 향상 및 자동 동기화 고도화")
                } header: { Text("진행 중") }
                
                Section {
                    devRow("📋", "다중 이메일 계정 연동 및 Gmail 외 서비스(IMAP 등) 연동 확장")
                    devRow("📋", "Apple Foundation Models 정식 버전 대응 및 통합 재도입")
                    devRow("📋", "사용자 맞춤형 커스텀 파인튜닝 LLM 교체 및 간편 로드")
                } header: { Text("예정") }
            }
            .navigationTitle("개발 현황")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { showDevChanges = false }
                }
            }
        }
    }
    
    @ViewBuilder
    private func devRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon).font(.body)
            Text(text).font(.subheadline)
        }
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView()
            .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
    }
}
