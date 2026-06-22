import SwiftUI
import SwiftData
import Security

struct PersonaSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var personas: [Persona]
    @Query private var todos: [Todo]

    // MARK: - System Status
    @State private var notificationStatus = "확인 중…"
    @State private var calendarStatus     = "확인 중…"

    // MARK: - Gmail
    // 캘린더 자동 등록 정책은 CalendarAutoPolicy(UserDefaults)로 통합 관리
    // emailAutoCalendar AppStorage는 제거 — CalendarAutoPolicy.isAuto를 사용
    @AppStorage("pieroot.todo.emailLookbackDays")   private var emailLookbackDays = 3
    @AppStorage("pieroot.todo.lastEmailFetchDate") private var lastEmailFetchTimestamp: Double = 0
    @AppStorage("pieroot.todo.emailRefreshHour")   private var emailRefreshHour: Int = 7
    @State private var isGmailAuthenticated = false
    @State private var isConnectingGmail    = false
    @State private var isFetchingEmails     = false
    @State private var lastFetchMessage: String?

    // MARK: - Persona Generation
    @AppStorage("selectedAIProvider") private var selectedProvider: PersonaAIProvider = .foundationModels
    @State private var modelInput     = ""
    @State private var apiKeyInput    = ""
    @State private var storedAPIKey   = ""
    @State private var isGenerating   = false
    @State private var generationResult: (personaText: String, insights: [String])?
    @State private var errorMessage: String?
    @State private var showError = false

    private let generationService = PersonaGenerationService()

    // MARK: - Memory
    @State private var memoryInsights: [String] = []
    @State private var memoryDate: Date?
    @State private var isAnalyzing = false
    @State private var pendingMemoryResult: MemoryAnalysisResult?

    // MARK: - Email Learning
    @State private var suppressedSendersList: [String] = []

    // MARK: - Onboarding Re-setup
    @State private var showOnboardingResetup = false
    @State private var showEmailPeriod = false
    @State private var showDevChanges = false

    // MARK: - iCloud Sync
    @AppStorage("pieroot.todo.iCloudSyncEnabled") private var iCloudSyncEnabled = false
    @State private var showSyncRestartAlert = false

    // MARK: - AFM Availability (cached to avoid synchronous access in body)
    // 보류 — 온디바이스 Qwen(MLX) 전환 진행 중. AFM은 iOS 27 GA 이후 재검토.
    @State private var afmAvailable = false

    // MARK: - Calendar
    // "silence" = 알람만 끄기 (기본), "remove" = 이벤트 삭제
    @AppStorage("pieroot.todo.calendarCompletionAction") private var calendarCompletionAction = "silence"

    // MARK: - On-Device LLM (Qwen/MLX)
    @AppStorage("pieroot.todo.emailAnalysisEngine") private var emailAnalysisEngineKey = EmailAnalysisEngineKey.onDevice.rawValue
    @AppStorage("pieroot.todo.onDeviceLLMEnabled")  private var onDeviceLLMEnabled = false
    @AppStorage("pieroot.todo.emailAutoAnalysisEnabled") private var emailAutoAnalysisEnabled = true
    @ObservedObject private var llmService: OnDeviceLLMService = .shared
    @State private var showDownloadConfirm = false
    @AppStorage("pieroot.todo.onDeviceModelID") private var onDeviceModelID = "mlx-community/Qwen3.5-2B-MLX-4bit"

    /// Qwen3.5-2B-MLX-4bit (~1.4GB) 기본. Qwen3.5-4B (~2.4GB) 고품질 옵션. 실제 메모리 6GB 이상 기기(iPhone 15/16+).
    private var selectedModelSizeMB: Int {
        OnDeviceLLMService.modelCatalog.first { $0.id == onDeviceModelID }?.sizeMB ?? 1400
    }
    private var isOnDeviceLLMCapable: Bool {
        ProcessInfo.processInfo.physicalMemory >= 6 * 1_024 * 1_024 * 1_024
    }

    private var isCloudReady: Bool {
        selectedProvider.requiresAPIKey && !storedAPIKey.isEmpty
    }

    // E: automationBinding 제거 — Qwen 분리 후 vestigial.
    // onDeviceLLMEnabled 단독으로 "AI 자동화" 토글을 제어한다.
    // emailAnalysisEngineKey(@AppStorage)는 vestigial — UI에서 더 이상 사용하지 않음.

    // MARK: - Body

    var body: some View {
        Form {
            aiAutomationSection       // AI 자동화 마스터 토글 (최상단)
            personaSection            // 나의 페르소나 + AI 페르소나 생성/개선
            intelligenceSection       // TODO 자동 정렬 AI 피커 — 페르소나 바로 아래
            onDeviceModelSection      // 온디바이스 모델 관리 (Qwen 선택 시만)
            memorySection
            gmailSection
            suppressedSendersSection
            calendarSection
            systemStatusSection
            infoSection
        }
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("닫기") { dismiss() }
            }
        }
        .task {
            // Create Persona outside view body to avoid mutation-during-render crashes
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
            await refreshStatus()
            isGmailAuthenticated = EmailService.shared.isAuthenticated
            loadAPIKey()
            loadModel()
            memoryInsights = MemoryService.shared.insights
            memoryDate = MemoryService.shared.lastAnalysisDate
            suppressedSendersList = EmailLearningStore.shared.suppressedSenders()
            // D: selectedProvider 마이그레이션 (1회만 실행)
            // 기존 onDeviceLLMEnabled=true 사용자 → selectedProvider=.onDevice 승계
            // (이전: onDeviceLLMEnabled 단독으로 우선순위 결정 → 이후: selectedProvider 단독)
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "pieroot.todo.didMigrateToUnifiedAI") {
                if defaults.bool(forKey: "pieroot.todo.onDeviceLLMEnabled") {
                    let raw = defaults.string(forKey: "selectedAIProvider") ?? ""
                    if raw.isEmpty || raw == PersonaAIProvider.foundationModels.rawValue {
                        selectedProvider = .onDevice
                    }
                }
                defaults.set(true, forKey: "pieroot.todo.didMigrateToUnifiedAI")
            }
        }
        .onChange(of: selectedProvider) { _, _ in
            apiKeyInput = ""
            loadAPIKey()
            loadModel()
        }
        .alert("오류", isPresented: $showError, presenting: errorMessage) { _ in
            Button("확인", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
        .sheet(isPresented: $showOnboardingResetup) {
            OnboardingView(isPresented: $showOnboardingResetup, isResetup: true)
        }
        .sheet(isPresented: $showDevChanges) {
            devChangesSheet
        }
    }

    // MARK: - Sections

    // 1. 페르소나 요약 (읽기 전용) — 편집은 "페르소나 다시 설정" 시트로
    private var personaSection: some View {
        Section {
            if let p = personas.first {
                let types = p.personaTypes
                let desc  = p.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)

                if types.isEmpty && desc.isEmpty {
                    // 빈 상태: 온보딩을 건너뛴 경우
                    HStack(spacing: 8) {
                        Image(systemName: "person.circle")
                            .foregroundStyle(.secondary)
                        Text("아직 설정되지 않음")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // 선택된 유형 칩
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
                    // 설명 텍스트 (읽기 전용)
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

                // A: AI 페르소나 생성/개선 (AFM 강제 — 모델 선택 없음, runGeneration()에서 .foundationModels 하드코딩)
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
        } header: {
            Label("나의 페르소나", systemImage: "person.circle")
        } footer: {
            Text("생활 유형은 AI 키 없이도 할 일 우선순위에 즉시 반영됩니다. AI 페르소나 개선은 사용자의 패턴을 토대로 자동으로 점진적으로 개선합니다.")
        }
    }

    // A: personaGenerationSection → personaSection에 통합됨 (제거)

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

    // 3. 행동 패턴 메모리
    private var memorySection: some View {
        Section {
            // 분석 날짜
            if let date = memoryDate {
                LabeledContent("마지막 분석") {
                    Text(date.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                }
            }

            // 인사이트 목록 (저장된 기존 패턴)
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

            // 미리보기 카드 (분석 완료 후 사용자 확인 대기)
            if let result = pendingMemoryResult {
                memoryAnalysisResultCard(result)
            }

            // 수동 분석 버튼
            Button {
                pendingMemoryResult = nil
                Task { await analyzeMemory() }
            } label: {
                if isAnalyzing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("패턴 분석 중…")
                    }
                } else {
                    Label(pendingMemoryResult == nil ? "지금 패턴 분석" : "다시 분석", systemImage: "chart.bar.xaxis")
                }
            }
            .disabled(isAnalyzing || todos.filter { $0.isCompleted }.isEmpty)

        } header: {
            Label("행동 패턴 메모리", systemImage: "brain.head.profile")
        } footer: {
            Text("완료한 할 일의 시간대 · 태그별 처리 속도 · 완료율을 분석합니다. Apple Foundation Models가 사용자 친화적 패턴 인사이트를 재작성합니다(미가용 시 통계 기반). AI 우선순위와 페르소나 생성에 자동 반영됩니다. 백그라운드에서 2일 간격으로 자동 실행됩니다.")
        }
    }

    @ViewBuilder
    private func memoryAnalysisResultCard(_ result: MemoryAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("새 분석 결과", systemImage: "sparkles")
                .font(.subheadline.bold())
                .foregroundStyle(.blue)

            // 요약 통계
            if !result.summary.isEmpty {
                Text(result.summary)
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            // 인사이트 목록
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

            // 적용 / 다시 분석 / 취소
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

    // 4. Gmail 연동
    private var gmailSection: some View {
        Section {
            // Gmail 계정 행 — 롱프레스(contextMenu) 또는 왼쪽 스와이프로 연결 해제
            HStack {
                Label("Gmail 계정", systemImage: "envelope.circle.fill")
                    .symbolRenderingMode(.multicolor)
                Spacer()
                Text(isGmailAuthenticated ? "연결됨" : "미연결")
                    .font(.subheadline)
                    .foregroundStyle(isGmailAuthenticated ? .green : .secondary)
            }
            // 롱프레스: 지금 메일 확인 + 연결 해제
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
            // 오른쪽 스와이프(leading): 지금 메일 확인
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
            // 왼쪽 스와이프(trailing): 연결 해제
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
                // 메일 자동 분석 토글 — 포그라운드(AFM) + 배경(NSDataDetector) 양쪽 게이트
                Toggle("메일 자동 분석", isOn: $emailAutoAnalysisEnabled)

                // 메일 동기화 설정 — 펼치면 마지막 동기화·자동 시각·확인 기간 한번에 표시
                DisclosureGroup(isExpanded: $showEmailPeriod) {
                    // 마지막 동기화 시각
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

                    // 자동 동기화 시각
                    Picker("자동 동기화 시각", selection: $emailRefreshHour) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(Self.hourLabel(h)).tag(h)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: emailRefreshHour) { _, _ in scheduleEmailRefresh() }

                    // 메일 확인 기간
                    Stepper("메일 확인 기간: \(emailLookbackDays)일", value: $emailLookbackDays, in: 1...30)
                    Text("최근 \(emailLookbackDays)일치 메일을 분석합니다. 기본값 3일.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
    }

    // 4-2. 자동 숨긴 발신자 관리
    @ViewBuilder
    private var suppressedSendersSection: some View {
        // 연결된 Gmail이 없거나 숨긴 발신자가 없으면 섹션 자체를 숨김
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

    // D: TODO 자동 정렬 AI 피커 (단일 선택, 사용자 선택이 AFM보다 우선)
    @ViewBuilder
    private var intelligenceSection: some View {
        Section {
            // D: 단일 Picker — 중복 AFM 행 제거, selectedProvider 단독 표시
            Picker("TODO 자동 정렬 AI", selection: $selectedProvider) {
                ForEach(PersonaAIProvider.allCases) { p in
                    Label(p.displayName, systemImage: p.systemImage).tag(p)
                }
            }
            .pickerStyle(.menu)

            // 클라우드 제공자 선택 시 API 키 + 모델 입력
            // (A에서 personaGenerationSection에 있던 UI를 D로 이동)
            if selectedProvider.requiresAPIKey {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    SecureField("API 키 입력", text: $apiKeyInput)
                        .autocorrectionDisabled()
                    if !apiKeyInput.isEmpty {
                        Button("저장") { saveAPIKey() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                if !storedAPIKey.isEmpty {
                    Label("저장된 키 있음", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    let hint: String = {
                        switch selectedProvider {
                        case .gemini: return "Google AI Studio (aistudio.google.com)"
                        case .claude: return "Anthropic Console (console.anthropic.com)"
                        default:      return "OpenAI Platform (platform.openai.com)"
                        }
                    }()
                    Text("\(hint)에서 API 키를 발급받아 입력하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField(selectedProvider.defaultModel, text: $modelInput)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: modelInput) { _, v in
                            UserDefaults.standard.set(v, forKey: "aiModel.\(selectedProvider.rawValue)")
                        }
                }
            }

            // Qwen 선택 시 모델 미설치 안내
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
    }

    private var intelligenceFooter: String {
        switch selectedProvider {
        case .foundationModels:
            return "Apple Foundation Models(온디바이스)가 할 일을 정렬합니다. 다른 모델을 선택하면 해당 모델이 AFM보다 먼저 동작합니다."
        case .onDevice:
            return "Qwen 온디바이스 모델이 우선 정렬하고, 미로드 시 Apple Foundation Models로 폴백합니다."
        default:
            return isCloudReady
                ? "\(selectedProvider.displayName)이 우선 정렬하고, 키 없음 시 Apple Foundation Models로 폴백합니다."
                : "API 키를 설정하면 \(selectedProvider.displayName)으로 정렬합니다. 미설정 시 Apple Foundation Models."
        }
    }

    // 온디바이스 모델 관리 (Qwen 정렬 옵션용 — Qwen 선택 + 지원 기기(≥6GB)만 표시)
    @ViewBuilder
    private var onDeviceModelSection: some View {
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

    // AI 자동화 마스터 토글 (최상단 섹션)
    // onDeviceLLMEnabled: 앱 열 때 포그라운드 자동화(메일+페르소나)만 제어.
    // 수동 동작(✦ 정렬, AI 페르소나 개선, 지금 패턴 분석)은 이 토글과 무관하게 항상 동작.
    private var aiAutomationSection: some View {
        Section {
            Toggle("AI 자동화", isOn: $onDeviceLLMEnabled)
        } header: {
            Label("AI 자동화", systemImage: "gearshape.2")
        } footer: {
            Text("앱 실행 시 자동으로 페르소나를 갱신합니다 (6시간 쿨다운). 이메일 분석·할 일 자동 등록은 아래 이메일 연동의 '메일 자동 분석' 토글로 별도 제어합니다. 수동 정렬(✦)·페르소나 생성은 이 설정과 상관없이 항상 동작합니다.")
        }
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

    // 캘린더 자동 등록 설정 (이메일 연동에서 분리 — Gmail 미연결 상태에서도 수동 할 일에 적용)
    private var calendarSection: some View {
        Section {
            // 통합 정책 토글 — 모든 할 일(수동+이메일)의 마감 자동 캘린더 등록
            Toggle("마감 자동 캘린더 등록", isOn: Binding(
                get: { CalendarAutoPolicy.isAuto },
                set: { CalendarAutoPolicy.setValue(auto: $0) }
            ))
            .disabled(!CalendarService.shared.isAuthorized)

            if !CalendarService.shared.isAuthorized {
                Label("캘린더 권한이 필요합니다", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // 완료 시 캘린더 처리 방식
            Picker("완료 시 처리", selection: $calendarCompletionAction) {
                Text("이벤트 삭제").tag("remove")
                Text("알람만 끄기").tag("silence")
            }
            .pickerStyle(.menu)
            .disabled(!CalendarService.shared.isAuthorized)

        } header: {
            Label("캘린더", systemImage: "calendar")
        } footer: {
            Text("마감 시각이 있는 모든 할 일(수동·이메일 모두)을 시스템 캘린더에 자동으로 등록합니다. 긴급·최우선 항목은 이 설정과 무관하게 항상 등록됩니다. '알람만 끄기'는 이벤트는 캘린더에 남기고 리마인더만 제거합니다.")
        }
    }

    // 5. 시스템 권한
    private var systemStatusSection: some View {
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
        } header: {
            Label("시스템 권한", systemImage: "shield")
        }
    }

    // 6. 앱 정보
    private var infoSection: some View {
        Section {
            LabeledContent("버전") { Text("1.0") }

            // iCloud 동기화 토글
            Toggle("데이터 동기화 (iCloud)", isOn: Binding(
                get: { iCloudSyncEnabled },
                set: { newValue in
                    iCloudSyncEnabled = newValue
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

            LabeledContent("이메일 연동") { Text("Gmail (1계정)") }
            Button {
                showDevChanges = true
            } label: {
                Label("개발 현황 및 예정 기능", systemImage: "list.bullet.clipboard")
            }
        } header: {
            Label("앱 정보", systemImage: "info.circle")
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
    }

    private var devChangesSheet: some View {
        NavigationStack {
            List {
                Section {
                    devRow("✅", "SwiftData 로컬 저장소")
                    devRow("✅", "Gmail OAuth2 연동 + 할 일 자동 추출")
                    devRow("✅", "이메일 딥링크 (원본 메일 열기)")
                    devRow("✅", "캘린더 마감 자동 등록")
                    devRow("✅", "AI 우선순위 (Claude·OpenAI·Gemini)")
                    devRow("✅", "행동 패턴 메모리 분석")
                    devRow("✅", "백그라운드 자동 동기화 (시각 설정)")
                    devRow("✅", "온디바이스 AI 엔진 구조 구현 완료")
                } header: { Text("완료") }

                Section {
                    devRow("🔄", "온디바이스 Qwen3.5-4B MLX 모델 연결\n(Xcode 패키지 추가 후 활성화)")
                } header: { Text("진행 중") }

                Section {
                    devRow("📋", "다중 이메일 계정 · Gmail 외 서비스 지원")
                    devRow("📋", "Apple Foundation Models 재도입\n(iOS 27 GA 이후 검토)")
                    devRow("📋", "커스텀 파인튜닝 모델 교체 지원")
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

    // MARK: - Actions

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

    // MARK: - Helpers

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

    // MARK: - Gmail

    private func connectGmail() async {
        isConnectingGmail = true
        defer { isConnectingGmail = false }
        do {
            try await EmailService.shared.authenticate()
            isGmailAuthenticated = true
            lastFetchMessage = "Gmail 연결 완료"
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func fetchEmailsNow() async {
        isFetchingEmails = true
        defer { isFetchingEmails = false }
        do {
            let (newTodos, extractedEvents) = try await EmailService.shared.fetchAndExtractAll()

            // Todo 삽입
            let existing = (try? modelContext.fetch(FetchDescriptor<Todo>())) ?? []
            let existingRefs = Set(existing.map { $0.sourceRef })
            var todoCount = 0
            for todo in newTodos where !existingRefs.contains(todo.sourceRef) {
                modelContext.insert(todo)
                todoCount += 1
                // 캘린더 자동 등록 정책 적용 (긴급/최우선 강제 포함)
                CalendarService.shared.applyAutoRegistration(for: todo)
            }

            // 캘린더 일정 등록
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

    // MARK: - Persona Generation

    private func runGeneration() async {
        isGenerating = true
        defer { isGenerating = false }
        do {
            let existing = personas.first?.descriptionText ?? ""
            // A: AFM 강제 — 페르소나 생성/개선은 항상 Apple Foundation Models 사용
            let result = try await generationService.generate(
                existingPersona: existing,
                todos: todos,
                provider: .foundationModels,
                apiKey: nil,
                model: nil
            )
            generationResult = result
        } catch {
            // LLMError.cancelled(reason:)는 LocalizedError이므로 사유 포함 메시지가 자동 표시됨
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

    // MARK: - Memory Analysis

    private func analyzeMemory() async {
        isAnalyzing = true
        defer { isAnalyzing = false }
        // 분석만 수행하고 저장하지 않음 — 미리보기 카드로 표시 후 사용자 확인 대기
        let result = await MemoryService.shared.analyzeForegroundPreview(todos: todos)
        if !result.summary.isEmpty || !result.insights.isEmpty {
            pendingMemoryResult = result
        }
    }

    private func applyMemoryAnalysis() {
        guard let result = pendingMemoryResult else { return }
        MemoryService.shared.applyAnalysisResult(result)
        memoryInsights = result.insights
        memoryDate = MemoryService.shared.lastAnalysisDate
        pendingMemoryResult = nil
    }

    // MARK: - Keychain

    private func saveAPIKey() {
        guard !apiKeyInput.isEmpty else { return }
        let service = selectedProvider.keychainKey
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = Data(apiKeyInput.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
        storedAPIKey = apiKeyInput
        apiKeyInput  = ""
    }

    private func loadAPIKey() {
        guard selectedProvider.requiresAPIKey else { storedAPIKey = ""; return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: selectedProvider.keychainKey,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { storedAPIKey = ""; return }
        storedAPIKey = String(data: data, encoding: .utf8) ?? ""
    }

    private func loadModel() {
        guard selectedProvider.requiresAPIKey else { modelInput = ""; return }
        modelInput = UserDefaults.standard.string(forKey: "aiModel.\(selectedProvider.rawValue)") ?? ""
    }
}

#Preview {
    NavigationStack {
        PersonaSettingsView()
            .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
    }
}
