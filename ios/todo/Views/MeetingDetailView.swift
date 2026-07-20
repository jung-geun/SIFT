import SwiftUI
import Combine
import SwiftData

struct MeetingDetailView: View {
    @Environment(\.modelContext) private var meetingContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.userVocabulary) private var userVocabulary
    @State private var isAnalyzing = false
    @State private var analysisError: String?
    @State private var confirmedDraftIDs = Set<String>()
    let meeting: MeetingRecord
    @StateObject private var player = MeetingAudioPlaybackController()
    @State private var waveform: MeetingWaveform?
    @State private var waveformError: String?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportShare: MeetingExportShare?
    @State private var isRetryingTranscript = false
    @State private var retryError: String?
    @State private var showingRetranscribeConfirm = false
    @State private var textEditTarget: MeetingSegment?
    @State private var textEditDraft = ""
    @State private var speakerEditTarget: MeetingSegment?
    @State private var speakerEditDraft = ""
    @State private var segmentEditError: String?
    @State private var proofreadPresentation: MeetingProofread.InlinePresentation = .hidden
    @State private var isOnDeviceAIAvailable: Bool?
    @StateObject private var processingReporter = MeetingProcessingReporter()
    @ScaledMetric(relativeTo: .body) private var transcriptViewportHeight = 300
    private let transcriptViewportAnchor = "meeting-transcript-viewport"

    var body: some View {
        ScrollViewReader { detailProxy in
            List {
                audioSection
                if meeting.status == .transcriptFinalizationFailed, let manifest = meeting.audioManifest {
                    failedFinalizationSection(manifest)
                }
                if let result = meeting.result {
                    transcriptSection(result)
                    decisionsSection(result)
                    questionsSection(result)
                    draftsSection(result)
                }
            }
            .onChange(of: player.isPlaying || player.isPaused) { _, playbackIsActive in
                guard playbackIsActive else { return }
                if reduceMotion {
                    detailProxy.scrollTo(transcriptViewportAnchor, anchor: .center)
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        detailProxy.scrollTo(transcriptViewportAnchor, anchor: .center)
                    }
                }
            }
        }
        .navigationTitle("회의 기록")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let result = meeting.result {
                    Menu {
                        Button("다시 요약") {
                            regenerateSummary(from: result)
                        }
                        if meeting.audioManifest != nil,
                           meeting.status != .transcriptFinalizationFailed {
                            Button("다시 전사") {
                                showingRetranscribeConfirm = true
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("회의 다시 정리")
                    .disabled(isReprocessing)
                }
                if let manifest = meeting.audioManifest {
                    Menu {
                        Button("원본 아카이브 (FLAC + manifest)") {
                            export(manifest: manifest) { try MeetingAudioExporter.exportSourceArchive(manifest: $0) }
                        }
                        Button("병합 오디오 (WAV)") {
                            export(manifest: manifest) { try MeetingAudioExporter.exportMergedAudio(manifest: $0) }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(AppLanguage.localized("meeting.export.accessibilityLabel", defaultValue: "회의 오디오 내보내기", language: .current, comment: "Meeting audio export button."))
                    .accessibilityIdentifier("meeting.exportButton")
                    .disabled(isExporting)
                }
            }
        }
        .task(id: meeting.id) {
            guard let manifest = meeting.audioManifest else { return }
            // Duration-based bucket density so a long meeting yields a wide,
            // scrollable track instead of a coarse fixed-width one.
            let totalSeconds = Double(manifest.totalSamples) / Double(manifest.sampleRate)
            let bucketCount = min(4_000, max(180, Int(totalSeconds * 12)))
            let generation = Task.detached(priority: .utility) {
                try MeetingWaveformGenerator.generate(manifest: manifest, bucketCount: bucketCount)
            }
            do {
                let generated = try await withTaskCancellationHandler {
                    try await generation.value
                } onCancel: {
                    generation.cancel()
                }
                guard !Task.isCancelled else { return }
                waveform = generated
            } catch {
                guard !Task.isCancelled else { return }
                waveformError = error.localizedDescription
            }
        }
        .task(id: meeting.updatedAt) {
            guard let result = meeting.result else {
                proofreadPresentation = .hidden
                isOnDeviceAIAvailable = nil
                return
            }
            proofreadPresentation = MeetingProofread.inlinePresentation(
                raw: meeting.rawResult,
                current: result,
                engineLabel: meeting.refinementEngineLabel,
                language: .current
            )
            if meeting.rawResultData == nil {
                isOnDeviceAIAvailable =
                    MeetingRefinementEngine().plannedEngine(allowModelLoad: true) != nil
            } else {
                isOnDeviceAIAvailable = nil
            }
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            player.refreshPlaybackProgress()
        }
        .alert("음성 재생 실패", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.dismissError() } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "알 수 없는 재생 오류")
        }
        .sheet(item: $exportShare) { share in
            ActivityShareSheet(items: [share.url])
        }
        .confirmationDialog("저장된 음성으로 다시 전사할까요?", isPresented: $showingRetranscribeConfirm, titleVisibility: .visible) {
            Button("다시 전사", role: .destructive) {
                if let manifest = meeting.audioManifest { retryTranscript(manifest: manifest) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 전사문과 분석 결과가 새 전사로 대체됩니다. 원본 음성은 보존됩니다.")
        }
        .alert("전사 내용 수정", isPresented: Binding(get: { textEditTarget != nil }, set: { if !$0 { textEditTarget = nil } }), presenting: textEditTarget) { segment in
            TextField("전사 내용", text: $textEditDraft, axis: .vertical)
            Button("저장") {
                let previousText = segment.text
                let newText = textEditDraft
                applyEdit(
                    onAccepted: {
                        guard newText.trimmingCharacters(in: .whitespacesAndNewlines) != previousText,
                              let service = userVocabulary?.service
                        else { return }
                        Task {
                            try? await service.learnFromEdit(
                                meetingID: meeting.meetingID,
                                segmentID: segment.id,
                                before: previousText,
                                after: newText
                            )
                        }
                    },
                    transform: {
                        try MeetingTranscriptEditor.editText(
                            result: $0,
                            meetingID: meeting.meetingID,
                            segmentID: segment.id,
                            text: newText
                        )
                    }
                )
            }
            .disabled(isReprocessing)
            Button("취소", role: .cancel) {}
        }
        .alert("화자 수정", isPresented: Binding(get: { speakerEditTarget != nil }, set: { if !$0 { speakerEditTarget = nil } }), presenting: speakerEditTarget) { segment in
            TextField("화자 (쉼표로 구분)", text: $speakerEditDraft)
            Button("저장") {
                let speakers = speakerEditDraft.split(separator: ",").map(String.init)
                applyEdit {
                    try MeetingTranscriptEditor.setSpeakers(
                        result: $0,
                        meetingID: meeting.meetingID,
                        segmentID: segment.id,
                        speakerIDs: speakers
                    )
                }
            }
            .disabled(isReprocessing)
            Button("취소", role: .cancel) {}
        }
    }

    // MARK: - Sections (extracted to keep the body type-checkable)

    @ViewBuilder
    private var audioSection: some View {
        Section {
            if let manifest = meeting.audioManifest {
                audioPlayer(manifest)
            } else {
                Text("음성을 아직 저장하지 못했습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("음성")
                Spacer()
                Text(languageDisplay).font(.caption2).textCase(nil).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func audioPlayer(_ manifest: MeetingAudioManifest) -> some View {
        waveformView(manifest)
        HStack(spacing: 12) {
            Button {
                if player.isPlaying {
                    player.pause()
                } else {
                    Task {
                        do { try await player.play(manifest: manifest) }
                        catch { player.report(error) }
                    }
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(AppTheme.accent)
            }
            .accessibilityLabel(AppLanguage.localized(
                player.isPlaying ? "meeting.playback.pause" : "meeting.playback.play",
                defaultValue: player.isPlaying ? "음성 일시 정지" : "음성 재생",
                language: .current,
                comment: "Meeting audio playback button."
            ))
            .accessibilityIdentifier("meeting.playbackButton")
            .buttonStyle(.plain)
            Text("\(duration(player.playbackMilliseconds))  /  \(duration(totalMs(manifest)))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        DisclosureGroup("재생 설정") {
            Stepper(value: $player.outputLevelPercent, in: 0...400, step: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text("음성 크기")
                    Spacer()
                    Text("\(player.outputLevelPercent)%")
                        .font(.caption.monospacedDigit())
                }
            }
            .accessibilityLabel("음성 크기")
            .accessibilityValue("\(player.outputLevelPercent)%")
            Text("100%는 원본 · 미만은 감쇠 · 초과는 증폭")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if player.outputLevelPercent > 100 {
                Text("100%를 넘는 증폭은 왜곡될 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.warning)
            }
        }
        .font(.subheadline)
        if isExporting { ProgressView("음성을 내보내는 중").font(.caption) }
        if let exportError { Text(exportError).font(.caption).foregroundStyle(AppTheme.destructive) }
    }

    private var languageDisplay: String {
        let meetingLanguage = AppLanguage.resolve(languageTag: meeting.languageTag)
        return AppLanguage.current.locale.localizedString(
            forLanguageCode: meetingLanguage.rawValue
        ) ?? meetingLanguage.displayName
    }


    @ViewBuilder
    private func waveformView(_ manifest: MeetingAudioManifest) -> some View {
        if let waveform {
            MeetingWaveformView(
                waveform: waveform,
                progress: player.playbackProgress,
                totalMs: totalMs(manifest),
                onSeek: { player.seek(toProgress: $0, totalMilliseconds: totalMs(manifest)) }
            )
        } else if let waveformError {
            Text("음성 트랙 생성 실패: \(waveformError)")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            ProgressView("음성 트랙을 읽는 중")
        }
    }

    @ViewBuilder
    private func failedFinalizationSection(_ manifest: MeetingAudioManifest) -> some View {
        Section("전사 확정 실패") {
            Text("전사 확정에 실패했지만 음성과 임시 전사는 보존되어 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                retryTranscript(manifest: manifest)
            } label: {
                if isRetryingTranscript {
                    ProgressView("저장된 음성에서 전사를 다시 확정하는 중")
                } else {
                    Label("전사 다시 확정", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRetryingTranscript)
            if let retryError {
                Text(retryError).font(.caption).foregroundStyle(AppTheme.destructive)
            }
        }
    }


    @ViewBuilder
    private func decisionsSection(_ result: MeetingResult) -> some View {
        if !result.decisions.isEmpty {
            Section("결정 사항") {
                ForEach(Array(result.decisions.enumerated()), id: \.offset) { _, decision in
                    Label(decision, systemImage: "checkmark.seal")
                }
            }
        }
    }

    @ViewBuilder
    private func questionsSection(_ result: MeetingResult) -> some View {
        if !result.unresolvedQuestions.isEmpty {
            Section("미해결 질문") {
                ForEach(Array(result.unresolvedQuestions.enumerated()), id: \.offset) { _, question in
                    Label(question, systemImage: "questionmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func draftsSection(_ result: MeetingResult) -> some View {
        if !result.actionDrafts.isEmpty {
            Section("확인 필요 태스크 후보") {
                ForEach(result.actionDrafts) { draft in
                    draftCard(draft, result: result)
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(_ result: MeetingResult) -> some View {
        let visibleSegments = result.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let activeSegmentID = activeSegmentID(in: result)
        Section("전사문") {
            if !result.summary.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("AI 정리", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                    Text(result.summary)
                }
                .padding(12)
                .background(AppTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 12))
            }

            if processingReporter.isBusy {
                MeetingProcessingStatusView(
                    phase: processingReporter.phase,
                    showsTranscription: processingReporter.includesTranscription
                )
            }
            if isAnalyzing {
                ProgressView("요약을 다시 만드는 중")
                    .font(.caption)
            }
            if let completedProcessingCaption {
                Text(completedProcessingCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            proofreadStatus
            if let analysisError {
                Text(analysisError).font(.caption).foregroundStyle(AppTheme.destructive)
            }
            if let retryError {
                Text(retryError).font(.caption).foregroundStyle(AppTheme.destructive)
            }
            if let segmentEditError {
                Text(segmentEditError).font(.caption).foregroundStyle(AppTheme.destructive)
            }

            if visibleSegments.isEmpty {
                ContentUnavailableView("전사문이 없습니다", systemImage: "waveform.slash")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(visibleSegments) { segment in
                                transcriptRow(
                                    segment,
                                    result: result,
                                    isActive: segment.id == activeSegmentID,
                                    correction: correction(for: segment.id)
                                )
                                .id(segment.id)
                            }
                        }
                    }
                    .frame(height: min(transcriptViewportHeight, 420))
                    .id(transcriptViewportAnchor)
                    .onChange(of: activeSegmentID) { _, activeID in
                        guard let activeID else { return }
                        if reduceMotion {
                            proxy.scrollTo(activeID, anchor: .center)
                        } else {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(activeID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptRow(
        _ segment: MeetingSegment,
        result: MeetingResult,
        isActive: Bool,
        correction: MeetingProofread.SegmentCorrection?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(duration(segment.startMs))–\(duration(segment.endMs))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(segment.speakerIDs.isEmpty ? "화자 미확정" : segment.speakerIDs.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(segment.speakerIDs.isEmpty ? Color.secondary : AppTheme.accent)
                if let confidence = segment.confidence, confidence < 0.5 {
                    Label("확인 필요", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(AppTheme.warning)
                }
                if correction != nil {
                    Text("AI 교정")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.success)
                }
            }
            if let correction {
                Text(inlineAttributed(correction.tokens))
                    .fontWeight(isActive ? .semibold : .regular)
            } else {
                Text(segment.text)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(
                        (player.isPlaying || player.isPaused) && !isActive
                            ? Color.secondary
                            : Color.primary
                    )
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: 3)
            }
        }
        .background(
            isActive ? AppTheme.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityHint(isActive ? "현재 재생 구간" : "")
        .accessibilityValue(
            correction.map { "교정 전: \($0.before). 교정 후: \($0.after)." } ?? segment.text
        )
        .contextMenu {
            Button("내용 수정") {
                textEditDraft = segment.text
                textEditTarget = segment
            }
            .disabled(isReprocessing)
            Button("화자 수정") {
                speakerEditDraft = segment.speakerIDs.joined(separator: ", ")
                speakerEditTarget = segment
            }
            .disabled(isReprocessing)
            Button("구간 분할") {
                splitSegment(segment, result: result)
            }
            .disabled(isReprocessing)
            Button("이전 구간과 병합") {
                applyEdit {
                    try MeetingTranscriptEditor.mergeWithPrevious(
                        result: $0,
                        meetingID: meeting.meetingID,
                        segmentID: segment.id
                    )
                }
            }
            .disabled(isReprocessing)
        }
    }

    private var isReprocessing: Bool {
        isAnalyzing || isRetryingTranscript
    }

    private func activeSegmentID(in result: MeetingResult) -> String? {
        guard player.isPlaying || player.isPaused else { return nil }
        return result.segmentID(at: player.playbackMilliseconds)
    }

    private func correction(for segmentID: String) -> MeetingProofread.SegmentCorrection? {
        guard case .changed(_, let corrections) = proofreadPresentation else { return nil }
        return corrections[segmentID]
    }

    @ViewBuilder
    private var proofreadStatus: some View {
        let language = AppLanguage.current
        switch proofreadPresentation {
        case .hidden:
            if isOnDeviceAIAvailable == false, !processingReporter.isBusy {
                Label(
                    AppLanguage.localized("meeting.proofread.unavailable", defaultValue: "On-device AI proofreading is unavailable on this device.", language: language, comment: "Meeting proofreading unavailable status."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .unchanged(let engineLabel):
            Text(
                String(
                    format: AppLanguage.localized("meeting.proofread.unchanged", defaultValue: "Proofreading complete · No changes · %@", language: language, comment: "Meeting proofreading status."),
                    locale: language.locale,
                    engineLabel
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .changed(let engineLabel, let corrections):
            Text(Self.proofreadChangedText(corrections: corrections.count, engineLabel: engineLabel, language: language))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var completedProcessingCaption: String? {
        guard case .completed(let outcome, _) = processingReporter.phase else { return nil }
        return MeetingProcessingStatusView.compactCompletionText(
            for: outcome,
            language: .current
        )
    }

    private func inlineAttributed(_ tokens: [MeetingProofread.Token]) -> AttributedString {
        var output = AttributedString()
        for (index, token) in tokens.enumerated() {
            if index > 0 { output += AttributedString(" ") }
            switch token {
            case .same(let word):
                output += AttributedString(word)
            case .removed(let word):
                var part = AttributedString(word)
                part.foregroundColor = AppTheme.destructive
                part.strikethroughStyle = .single
                output += part
            case .added(let word):
                var part = AttributedString(word)
                part.foregroundColor = AppTheme.success
                part.inlinePresentationIntent = .stronglyEmphasized
                output += part
            }
        }
        return output
    }

    /// A reviewable action candidate: what it is, the transcript line it came
    /// from, its confidence, and a button to register it into the task queue.
    nonisolated static func proofreadChangedText(
        corrections: Int,
        engineLabel: String,
        language: AppLanguage
    ) -> String {
        let format = AppLanguage.localized(
            "meeting.proofread.changed",
            defaultValue: language == .english
                ? "Proofreading complete · %lld corrections · %@"
                : "검수 완료 · %lld곳 교정 · %@",
            language: language,
            comment: "Meeting proofreading correction count."
        )
        return String.localizedStringWithFormat(
            format,
            Int64(corrections),
            engineLabel
        )
    }
    @ViewBuilder
    private func draftCard(_ draft: MeetingActionDraft, result: MeetingResult) -> some View {
        let language = AppLanguage.current
        let registered = confirmedDraftIDs.contains(draft.id)
        VStack(alignment: .leading, spacing: 6) {
            Text(draft.title).font(.body.weight(.semibold))
            if let source = sourceText(for: draft, in: result) {
                Text(
                    String(
                        format: AppLanguage.localized("meeting.evidence", defaultValue: "Evidence: %@", language: language, comment: "Meeting action evidence label."),
                        locale: language.locale,
                        source
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(
                    String(
                        format: AppLanguage.localized("meeting.confidence", defaultValue: "Confidence %lld%%", language: language, comment: "Meeting action confidence label."),
                        locale: language.locale,
                        Int64((draft.confidence * 100).rounded())
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    confirmDraft(draft, result: result)
                } label: {
                    Label(
                        registered
                            ? AppLanguage.localized("meeting.action.registered", defaultValue: "Registered", language: language, comment: "Meeting action registration state.")
                            : AppLanguage.localized("meeting.action.register", defaultValue: "Register as To-Do", language: language, comment: "Meeting action registration button."),
                        systemImage: registered ? "checkmark.circle.fill" : "plus.circle"
                    )
                }
                .buttonStyle(.borderless)
                .disabled(registered)
            }
        }
        .padding(.vertical, 2)
    }

    private func sourceText(for draft: MeetingActionDraft, in result: MeetingResult) -> String? {
        guard let id = draft.sourceSegmentIDs.first else { return nil }
        return result.segments.first(where: { $0.id == id })?.text
    }
    /// Imports the reviewed draft into the main Todo store as a review-queue
    /// item. The meeting screen holds the meeting context; the main-app Todo
    /// context comes from the shared container.
    private func confirmDraft(_ draft: MeetingActionDraft, result: MeetingResult) {
        analysisError = nil
        do {
            let todoContext = AppDataContainer.shared.container.mainContext
            _ = try MeetingTodoImporter.confirm(
                draftID: draft.id,
                transcriptRevision: result.transcriptRevision,
                meeting: meeting,
                todoContext: todoContext,
                meetingContext: meetingContext
            )
            confirmedDraftIDs.insert(draft.id)
        } catch {
            analysisError = error.localizedDescription
        }
    }

    @discardableResult
    private func applyEdit(
        onAccepted: () -> Void = {},
        transform: (MeetingResult) throws -> MeetingResult
    ) -> Bool {
        guard !isReprocessing else {
            segmentEditError = AppLanguage.localized(
                "meeting.error.editDuringProcessing",
                defaultValue: "The transcript cannot be edited while the meeting is being reprocessed.",
                language: .current,
                comment: "Meeting transcript edit error."
            )
            return false
        }
        segmentEditError = nil
        do {
            return try MeetingTranscriptEditCommitter.commit(
                record: meeting,
                isReprocessing: isReprocessing,
                status: meeting.status,
                save: { try meetingContext.save() },
                onAccepted: onAccepted,
                transform: transform
            )
        } catch {
            segmentEditError = error.localizedDescription
            return false
        }
    }

    private func splitSegment(_ segment: MeetingSegment, result: MeetingResult) {
        let words = segment.text.split(separator: " ")
        guard words.count >= 2, segment.endMs - segment.startMs >= 2 else {
            segmentEditError = AppLanguage.localized(
                "meeting.error.splitRequirements",
                defaultValue: "Splitting requires at least two words and a segment longer than 2 ms.",
                language: .current,
                comment: "Meeting transcript split validation."
            )
            return
        }
        let mid = words.count / 2
        applyEdit {
            try MeetingTranscriptEditor.split(
                result: $0,
                meetingID: meeting.meetingID,
                segmentID: segment.id,
                atMs: segment.startMs + (segment.endMs - segment.startMs) / 2,
                firstText: words[..<mid].joined(separator: " "),
                secondText: words[mid...].joined(separator: " ")
            )
        }
    }

    private func retryTranscript(manifest: MeetingAudioManifest) {
        guard let source = meeting.result else { return }
        let languageTag = meeting.languageTag
        let meetingID = meeting.meetingID
        let revision = source.transcriptRevision + 1
        isRetryingTranscript = true
        retryError = nil
        analysisError = nil
        processingReporter.reset()
        processingReporter.startTranscribing()
        Task {
            defer { isRetryingTranscript = false }
            do {
                let entries = try await MeetingTranscriptRetryService()
                    .retranscribe(manifest: manifest, languageTag: languageTag)
                let segments = entries.map { entry in
                    MeetingSegment(
                        id: MeetingCanonicalID.replacementSegment(
                            meetingID: meetingID,
                            transcriptRevision: revision,
                            startMs: entry.startMs,
                            endMs: max(entry.startMs + 1, entry.endMs),
                            text: entry.text
                        ),
                        startMs: entry.startMs,
                        endMs: max(entry.startMs + 1, entry.endMs),
                        speakerIDs: entry.speakerIDs,
                        text: entry.text,
                        isFinal: entry.isFinal,
                        confidence: entry.confidence
                    )
                }.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
                let baseResult = MeetingResult(transcriptRevision: revision, segments: segments)

                guard let latest = meeting.result, latest.hasSameTranscript(as: source) else {
                    retryError = AppLanguage.localized("meeting.error.changedDuringRetry", defaultValue: "The meeting changed, so the retranscription was not applied. Try again.", language: .current, comment: "Meeting retranscription conflict.")
                    processingReporter.reset()
                    return
                }
                try MeetingRecordCommitter.persist(
                    record: meeting,
                    save: { try meetingContext.save() },
                    mutate: { try meeting.replaceTranscriptionBase(baseResult, status: .ready) }
                )

                do {
                    _ = try await MeetingPostProcessor.refineAndAnalyze(
                        record: meeting,
                        context: meetingContext,
                        allowRefine: SettingsStore.shared.meetingAutoRefineEnabled,
                        allowModelLoad: false,
                        reporter: processingReporter,
                        dependencies: makeVocabularyMeetingDependencies(userVocabulary?.service)
                    )
                } catch {
                    retryError = AppLanguage.localized("meeting.error.proofreadAfterRetry", defaultValue: "Retranscription was saved, but AI proofreading or summary could not be completed.", language: .current, comment: "Meeting retranscription processing error.")
                }
            } catch {
                retryError = error.localizedDescription
                processingReporter.reset()
            }
        }
    }

    private func export(manifest: MeetingAudioManifest, using operation: @escaping @Sendable (MeetingAudioManifest) throws -> URL) {
        isExporting = true
        exportError = nil
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try operation(manifest)
                }.value
                exportShare = MeetingExportShare(url: url)
            } catch {
                exportError = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func regenerateSummary(from source: MeetingResult) {
        let meetingID = meeting.meetingID
        isAnalyzing = true
        analysisError = nil
        retryError = nil
        processingReporter.reset()
        Task {
            defer { isAnalyzing = false }
            let snapshot = await userVocabulary?.service.snapshot() ?? .empty
            let hint = snapshot.promptHint
            let outcome = await MeetingAnalysisEngine().analyze(
                meetingID: meetingID,
                result: source,
                glossaryHint: hint,
                language: AppLanguage.resolve(languageTag: meeting.languageTag)
            )
            guard let latest = meeting.result,
                  let merged = latest.replacingSummary(
                    outcome.result.summary,
                    ifTranscriptMatches: source
                  )
            else {
                analysisError = AppLanguage.localized(
                    "meeting.error.changedDuringSummary",
                    defaultValue: "The meeting changed, so the summary was not saved. Try again.",
                    language: .current,
                    comment: "Meeting summary conflict."
                )
                return
            }
            do {
                let status = meeting.status
                try MeetingRecordCommitter.persist(
                    record: meeting,
                    save: { try meetingContext.save() },
                    mutate: { try meeting.update(result: merged, status: status) }
                )
            } catch {
                analysisError = error.localizedDescription
            }
        }
    }

    private func totalMs(_ manifest: MeetingAudioManifest) -> Int64 {
        manifest.totalSamples * 1_000 / manifest.sampleRate
    }

    private func duration(_ milliseconds: Int64) -> String {
        String(format: "%02lld:%02lld", milliseconds / 60_000, (milliseconds / 1_000) % 60)
    }
}

@MainActor
enum MeetingTranscriptEditCommitter {
    static func commit(
        record: MeetingRecord,
        isReprocessing: Bool,
        status: MeetingStatus,
        save: () throws -> Void,
        onAccepted: () -> Void,
        transform: (MeetingResult) throws -> MeetingResult
    ) throws -> Bool {
        guard !isReprocessing, let result = record.result else { return false }
        let updated = try transform(result)
        guard updated != result else { return false }

        try MeetingRecordCommitter.persist(
            record: record,
            save: save,
            mutate: {
                try record.update(result: updated, status: status)
                record.refinementEngineLabel = ""
            }
        )
        onAccepted()
        return true
    }
}

private struct MeetingExportShare: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
