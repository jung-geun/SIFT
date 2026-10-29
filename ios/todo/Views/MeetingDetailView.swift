import SwiftUI
import Combine
import SwiftData


private enum PersistedMeetingDiagnosticError: Error {
    case transcriptFinalizationFailed
}
struct MeetingDetailView: View {
    @Environment(\.modelContext) private var meetingContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.userVocabulary) private var userVocabulary
    @State private var isAnalyzing = false
    @State private var analysisError: String?
    let meeting: MeetingRecord
    @StateObject private var player = MeetingAudioPlaybackController()
    @State private var playbackTask: Task<Void, Never>?
    @State private var waveform: MeetingWaveform?
    @State private var waveformError: String?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportShare: MeetingExportShare?
    @State private var isRetryingTranscript = false
    @State private var isRetryingOfflineTranscript = false
    @State private var retryError: String?
    @State private var offlineModelInstalled = false
    @State private var appleTranscriptionAvailable = false
    @ObservedObject private var whisperModel = MeetingWhisperModelController.shared
    @ObservedObject private var localModel = OnDeviceLLMService.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var transcriptionLanguages: [MeetingLanguageOption] = []
    @State private var summaryLanguageOptions: [MeetingLanguageOption] = []
    @ObservedObject private var diarizationActivity = MeetingDiarizationActivity.shared
    @ObservedObject private var speakerModel = MeetingDiarizationModelController.shared
    @State private var speakerDisplay = MeetingSpeakerDisplay()
    @State private var speakerError: String?
    @State private var speakerPassTask: Task<MeetingDiarizationPostProcessor.Outcome, Error>?
    @State private var isQueuingSpeakers = false
    @State private var isCancellingSpeakers = false
    @State private var showingRetranscribeConfirm = false
    @State private var showingOfflineRetranscribeConfirm = false
    @State private var textEditTarget: MeetingSegment?
    @State private var textEditDraft = ""
    @State private var speakerSheetTarget: MeetingSegment?
    @State private var segmentEditError: String?
    @State private var proofreadPresentation: MeetingProofread.InlinePresentation = .hidden
    @StateObject private var processingReporter = MeetingProcessingReporter()
    @ScaledMetric(relativeTo: .body) private var transcriptViewportHeight = 300
    private let transcriptViewportAnchor = "meeting-transcript-viewport"

    private var contentInset: CGFloat {
        horizontalSizeClass == .compact ? 16 : AppTheme.Spacing.section
    }

    var body: some View {
        if meeting.isAudioTrackGroup {
            MeetingTrackGroupDetailView(meeting: meeting)
        } else {
            singleTrackBody
        }
    }

    private var singleTrackBody: some View {
            List {
                audioSection
                if let result = meeting.result {
                    transcriptSection(result)
                    analysisSection(result)
                    decisionsSection(result)
                    questionsSection(result)
                    MeetingActionDraftSection(record: meeting, sourceLabel: meeting.audioTrackDisplayName)
                }
                if meeting.parentMeetingID != nil {
                    Section(AppLanguage.localized("meeting.audioTrack.source", defaultValue: AppLanguage.current == .english ? "Audio source" : "음성 소스", language: .current,
                        comment: "Source of the independently processed audio track.")) {
                        Text(meeting.audioTrackDisplayName)
                            .accessibilityIdentifier("meeting.audioTrack.source")
                        Text(AppLanguage.localized("meeting.audioTrack.independent", defaultValue: AppLanguage.current == .english
                            ? "This track's original audio, transcript and speakers are processed independently of other sources."
                            : "이 트랙의 원음·전사·화자는 다른 음성 소스와 독립적으로 처리됩니다.",
                            language: .current, comment: "Speaker IDs and transcript belong only to this source track."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !transcriptionLanguages.isEmpty || !summaryLanguageOptions.isEmpty {
                Section(MeetingLanguageCopy.text("meeting.languages.section", "Processing languages")) {
                    if !transcriptionLanguages.isEmpty {
                        MeetingLanguagePicker(title: MeetingLanguageCopy.sourceTitle,
                            selection: Binding(get: { meeting.languageTag }, set: { saveLanguage($0, summary: false) }),
                            options: transcriptionLanguages, identifier: "meeting.detail.sourceLanguage",
                            automaticLanguageDetection: Binding(get: { meeting.automaticLanguageDetection }, set: saveAutomaticLanguageDetection),
                            automaticDetectionAvailable: offlineModelInstalled)
                    }
                    if !summaryLanguageOptions.isEmpty {
                        MeetingLanguagePicker(title: MeetingLanguageCopy.summaryTitle,
                            selection: Binding(get: { resolvedSummaryLanguageTag }, set: { saveLanguage($0, summary: true) }),
                            options: summaryLanguageOptions, identifier: "meeting.detail.summaryLanguage")
                    }
                    Text(MeetingLanguageCopy.text("meeting.languages.reprocess", "Language changes apply to your next transcription or summary request. Existing original text is not translated or replaced automatically."))
                        .font(.caption).foregroundStyle(.secondary)
                    MeetingAIAccuracyNotice()
                    if meeting.automaticLanguageDetection {
                        MeetingAutomaticLanguageNotice()
                        if !offlineModelInstalled {
                            Text(AppLanguage.localized("meeting.offlineTranscription.installRequired", defaultValue: "Install the Whisper model in Settings → Meeting to use offline transcription.", language: .current, comment: "Offline transcription requires installing its model."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isReprocessing)
                }
                if meeting.status == .transcriptFinalizationFailed, let manifest = meeting.audioManifest {
                    failedFinalizationSection(manifest)
                }
            }
        .appListStyle()
        .navigationTitle("회의 기록")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if meeting.result != nil && (canRegenerateSummary || canRetryAppleTranscript || canRetryOfflineTranscript || canRetrySpeakers) {
                    Menu {
                        if canRegenerateSummary {
                            Button("다시 요약") { regenerateSummary() }
                        }
                        if canRetryAppleTranscript {
                            Button("다시 전사") {
                                showingRetranscribeConfirm = true
                            }
                        }
                        if canRetryOfflineTranscript {
                            Button(AppLanguage.localized("meeting.offlineTranscription.retry", defaultValue: "Transcribe offline", language: .current, comment: "Retry offline transcription from the meeting menu.")) {
                                showingOfflineRetranscribeConfirm = true
                            }
                            .accessibilityIdentifier("meeting.offlineTranscription.retry")
                        }
                        if canRetrySpeakers {
                            Button(AppLanguage.localized(
                                "meeting.diarization.retry",
                                defaultValue: AppLanguage.current == .english ? "Detect speakers again" : "화자 다시 분석",
                                language: .current,
                                comment: "Explicit on-device speaker diarization retry from saved audio."
                            )) {
                                retrySpeakers()
                            }
                            .accessibilityIdentifier("meeting.diarization.retry")
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
            let generation = Task.detached(priority: .utility) {
                try MeetingWaveformGenerator.generate(manifest: manifest)
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
        .task { await speakerModel.refresh() }
        .task { await refreshLanguageChoices() }
        .task(id: meeting.languageTag) {
            let tag = meeting.languageTag
            let supported = await MeetingTranscriptionLanguages.supportsApple(tag)
            guard !Task.isCancelled, meeting.languageTag == tag else { return }
            appleTranscriptionAvailable = supported
        }
        .onChange(of: whisperModel.isInstalled) { _, _ in Task { await refreshLanguageChoices() } }
        .onChange(of: meeting.status) { _, _ in Task { await refreshLanguageChoices() } }
        .onChange(of: localModel.loadedModelIdentifier) { _, _ in summaryLanguageOptions = MeetingSummaryLanguages.available }
        .onChange(of: localModel.modelID) { _, _ in summaryLanguageOptions = MeetingSummaryLanguages.available }
        .onChange(of: BetaFeaturePolicy().routingDecision(for: .meetingAnalysis)) { _, _ in summaryLanguageOptions = MeetingSummaryLanguages.available }
        // Speaker names and pass status change the payload without a new result.
        .task(id: meeting.diarizationData) {
            speakerDisplay = MeetingSpeakerDisplay(record: meeting)
        }
        .task(id: meeting.updatedAt) {
            speakerDisplay = MeetingSpeakerDisplay(record: meeting)
            guard let result = meeting.result else {
                proofreadPresentation = .hidden
                return
            }
            proofreadPresentation = MeetingProofread.inlinePresentation(
                raw: meeting.rawResult,
                current: result,
                engineLabel: meeting.refinementEngineLabel,
                language: .current
            )
        }
        .onDisappear {
            playbackTask?.cancel()
            playbackTask = nil
            player.stop()
            guard meeting.parentMeetingID != nil else { return }
            do { try MeetingAudioTrackStore.refreshParent(of: meeting, in: meetingContext) }
            catch { DiagnosticRecorder.shared.record(error: error, component: "meeting.capture", operation: "refreshTrackParent") }
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            player.refreshPlaybackProgress()
        }
        .alert("음성 재생 실패", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.dismissError() } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? AppLanguage.localized("meeting.playback.unknownError", defaultValue: "Unknown playback error", language: .current, comment: "Fallback when the playback error has no message."))
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
        .confirmationDialog(
            AppLanguage.localized("meeting.offlineTranscription.confirm.title", defaultValue: "Transcribe saved audio offline?", language: .current, comment: "Confirmation before replacing the transcript with offline transcription."),
            isPresented: $showingOfflineRetranscribeConfirm, titleVisibility: .visible
        ) {
            Button(AppLanguage.localized("meeting.offlineTranscription.transcribe", defaultValue: "Transcribe offline", language: .current, comment: "Confirm offline transcription of saved audio."), role: .destructive) {
                retryOfflineTranscript()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(meeting.importedAudioFileName != nil
                 ? AppLanguage.localized("meeting.offlineTranscription.confirm.imported", defaultValue: "This replaces the current transcript and analysis. The imported audio remains saved.", language: .current, comment: "Offline retranscription confirmation for imported audio.")
                 : AppLanguage.localized("meeting.offlineTranscription.confirm.recorded", defaultValue: "This replaces the current transcript and analysis. Saved audio and the original Apple transcript are preserved.", language: .current, comment: "Offline retranscription confirmation for recorded audio."))
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
        .sheet(item: $speakerSheetTarget) { segment in
            MeetingSpeakerAssignmentSheet(
                segment: segment,
                profiles: speakerDisplay.sortedProfiles,
                onAssign: { ids in commitSpeakerEdit { try MeetingSpeakerEditCommitter.assign(record: meeting, segmentID: segment.id, speakerIDs: ids, save: $0) } },
                onRename: { id, name in commitSpeakerEdit { try MeetingSpeakerEditCommitter.rename(record: meeting, speakerID: id, displayName: name, save: $0) } },
                onCreate: { name in commitSpeakerEdit { _ = try MeetingSpeakerEditCommitter.createProfile(record: meeting, segmentID: segment.id, displayName: name, save: $0) } }
            )
        }
    }

    // MARK: - Sections (extracted to keep the body type-checkable)

    @ViewBuilder
    private var audioSection: some View {
        Section {
            if let fileName = meeting.importedAudioFileName {
                Label(fileName, systemImage: "doc.waveform")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting.audioImport.provenance")
            }
            if let manifest = meeting.audioManifest {
                audioPlayer(manifest)
            } else {
                Text("음성을 아직 저장하지 못했습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("음성")
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    Text(languageDisplay).font(.caption).textCase(nil).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                    Text("음성")
                    Text(languageDisplay).font(.caption).textCase(nil).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func audioPlayer(_ manifest: MeetingAudioManifest) -> some View {
        MeetingAudioPlaybackView(player: player, waveform: waveform, waveformError: waveformError,
            totalMilliseconds: totalMs(manifest)) {
            if player.isPlaying {
                player.pause()
            } else {
                startPlayback(manifest)
            }
        }
        if isExporting { ProgressView("음성을 내보내는 중").font(.caption) }
        if let exportError { Text(exportError).font(.caption).foregroundStyle(AppTheme.destructive) }
    }

    private func startPlayback(_ manifest: MeetingAudioManifest) {
        guard !player.isPreparingPlayback else { return }
        playbackTask?.cancel()
        playbackTask = Task {
            do {
                try Task.checkCancellation()
                try await player.play(manifest: manifest)
            } catch is CancellationError {
            } catch { player.report(error) }
        }
    }

    private var languageDisplay: String {
        guard meeting.automaticLanguageDetection else {
            return MeetingLanguageOption(id: meeting.languageTag).displayName(locale: AppLanguage.current.locale)
        }
        let detected = MeetingLanguageOption.deduplicated(meeting.asrDetectedLanguages.map { MeetingLanguageOption(id: $0) },
            displayLocale: AppLanguage.current.locale).map { $0.displayName(locale: AppLanguage.current.locale) }
        return detected.isEmpty ? MeetingLanguageCopy.automaticTitle
            : "\(MeetingLanguageCopy.automaticTitle) · \(detected.joined(separator: ", "))"
    }


    private var resolvedSummaryLanguageTag: String {
        MeetingSummaryLanguages.requestedLanguageTag(sourceLanguageTag: meeting.processingSourceLanguageTag,
            savedSummaryLanguageTag: meeting.summaryLanguageTag)
    }

    private var canRegenerateSummary: Bool {
        meeting.result?.segments.isEmpty == false
            && MeetingSummaryLanguages.canSummarize(sourceLanguageTag: meeting.processingSourceLanguageTag,
                summaryLanguageTag: resolvedSummaryLanguageTag)
    }

    private var canRetryAppleTranscript: Bool {
        meeting.audioManifest != nil && meeting.importedAudioFileName == nil
            && !meeting.automaticLanguageDetection && meeting.status != .transcriptFinalizationFailed
            && appleTranscriptionAvailable
    }

    private var canRetryOfflineTranscript: Bool {
        meeting.audioManifest != nil && offlineModelInstalled
            && (meeting.automaticLanguageDetection || MeetingLanguageCatalog.whisperLanguageCode(for: meeting.languageTag) != nil)
    }

    private var canRetrySpeakers: Bool {
        meeting.audioManifest != nil && meeting.status != .transcriptFinalizationFailed
            && SettingsStore.shared.effectiveMeetingDiarizationEnabled && speakerModel.isInstalled
    }

    private func refreshLanguageChoices() async {
        let installed = await MeetingWhisperModelStore.shared.isInstalled()
        let apple = meeting.importedAudioFileName == nil && meeting.status != .transcriptFinalizationFailed
            ? await MeetingTranscriptionLanguages.apple() : []
        guard !Task.isCancelled else { return }
        offlineModelInstalled = installed
        transcriptionLanguages = MeetingTranscriptionLanguages.options(apple: apple, whisperAvailable: installed)
        summaryLanguageOptions = MeetingSummaryLanguages.available
    }

    private func saveLanguage(_ tag: String, summary: Bool) {
        guard !isReprocessing else { return }
        do {
            try MeetingRecordCommitter.persist(record: meeting, save: { try meetingContext.save() }) {
                if summary { meeting.summaryLanguageTag = tag }
                else {
                    meeting.languageTag = tag
                    meeting.automaticLanguageDetection = false
                }
                meeting.updatedAt = Date()
            }
            if summary { MeetingLanguagePreferences.shared.selectSummary(tag) }
            else { MeetingLanguagePreferences.shared.selectSource(tag) }
        } catch { analysisError = error.localizedDescription }
    }

    private func saveAutomaticLanguageDetection(_ enabled: Bool) {
        guard !isReprocessing else { return }
        do {
            try MeetingRecordCommitter.persist(record: meeting, save: { try meetingContext.save() }) {
                meeting.automaticLanguageDetection = enabled
                meeting.updatedAt = Date()
            }
            MeetingLanguagePreferences.shared.selectAutomaticDetection(enabled)
        } catch { analysisError = error.localizedDescription }
    }



    @ViewBuilder
    private func failedFinalizationSection(_ manifest: MeetingAudioManifest) -> some View {
        Section(LocalizedStringKey(!meeting.automaticLanguageDetection && meeting.importedAudioFileName == nil && meeting.asrSource != .savedAudio ? "전사 확정 실패" : "음성 저장됨 · 전사 대기")) {
            if !meeting.automaticLanguageDetection && meeting.importedAudioFileName == nil && meeting.asrSource != .savedAudio {
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
                .disabled(isReprocessing)
            } else if meeting.automaticLanguageDetection || meeting.asrSource == .savedAudio {
                Text(MeetingLanguageCopy.text("meeting.languages.savedAudio", "Original audio saved · awaiting Whisper transcription"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(AppLanguage.localized("meeting.offlineTranscription.importedReady", defaultValue: "The imported audio is saved. Use offline transcription to create its transcript.", language: .current, comment: "Imported audio is ready for offline transcription."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if canRetryOfflineTranscript {
            Button(AppLanguage.localized("meeting.offlineTranscription.transcribeInstead", defaultValue: "Transcribe offline instead", language: .current, comment: "Use offline transcription after Apple transcript finalization failed.")) {
                retryOfflineTranscript()
            }
            .accessibilityIdentifier("meeting.offlineTranscription.failedFinalization")
            .disabled(isReprocessing || !offlineModelInstalled)
            }
            if !offlineModelInstalled {
                Text(AppLanguage.localized("meeting.offlineTranscription.installRequired", defaultValue: "Install the Whisper model in Settings → Meeting to use offline transcription.", language: .current, comment: "Offline transcription requires installing its model."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let retryError {
                Text(retryError).font(.caption).foregroundStyle(AppTheme.destructive)
            }
            if meeting.importedAudioFileName == nil && meeting.asrSource != .savedAudio {
                NavigationLink {
                    DiagnosticReportView(
                        pendingError: DiagnosticReportService.shared.collectionEnabled
                            ? nil
                            : PersistedMeetingDiagnosticError.transcriptFinalizationFailed,
                        component: "meeting.transcription",
                        operation: "persistedFinalizationFailure"
                    )
                } label: {
                    Label(
                        AppLanguage.localized(
                            "meeting.action.reportDiagnostic",
                            defaultValue: AppLanguage.current == .english ? "Report Error" : "오류 보고",
                            language: .current,
                            comment: "Open diagnostic reporting after a meeting transcription error."
                        ),
                        systemImage: "exclamationmark.bubble"
                    )
                }
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
    private func transcriptSection(_ result: MeetingResult) -> some View {
        let visibleSegments = result.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let activeSegmentID = activeSegmentID(in: result)
        Section("전사문") {

            if visibleSegments.isEmpty {
                ContentUnavailableView("전사문이 없습니다", systemImage: "waveform.slash")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visibleSegments) { segment in
                                transcriptRow(
                                    segment,
                                    result: result,
                                    isActive: segment.id == activeSegmentID,
                                    presentation: speakerDisplay.continuity[.init(trackID: meeting.meetingID,
                                        localID: segment.stableLineageID)],
                                    correction: correction(for: segment.id)
                                )
                                .id(segment.id)
                            }
                        }
                        .frame(maxWidth: 784, alignment: .leading)
                        .padding(.vertical, AppTheme.Spacing.compact)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: min(transcriptViewportHeight, 420))
                    .clipped()
                    .accessibilityIdentifier("meeting.transcript.viewport")
                    .listRowInsets(EdgeInsets(top: 0, leading: contentInset - AppTheme.Spacing.item,
                        bottom: 0, trailing: contentInset - AppTheme.Spacing.item))
                    .listRowSeparator(.hidden)
                    .id(transcriptViewportAnchor)
                    .onChange(of: activeSegmentID) { _, activeID in
                        guard let activeID else { return }
                        if reduceMotion {
                            proxy.scrollTo(activeID, anchor: .center)
                        } else {
                            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(activeID, anchor: .center)
                            }
                        }
                    }
                }
            }
            if meeting.asrSource == .offline {
                if let apple = meeting.appleRawResult {
                    DisclosureGroup(AppLanguage.localized("meeting.transcript.provenance.appleOriginal", defaultValue: AppLanguage.current == .english ? "Apple live original" : "Apple 실시간 원문", language: .current, comment: "Read-only original Apple Speech transcript retained after offline ASR.")) {
                        ForEach(apple.segments) { segment in
                            if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(segment.text).font(.subheadline)
                            }
                        }
                    }
                    .accessibilityIdentifier("meeting.transcript.appleOriginal")
                }
                if let raw = meeting.rawResult {
                    DisclosureGroup(AppLanguage.localized("meeting.transcript.provenance.offlineOriginal", defaultValue: AppLanguage.current == .english ? "Offline transcription before text review" : "텍스트 검수 전 오프라인 전사", language: .current, comment: "Read-only Whisper ASR text before optional AI proofreading.")) {
                        ForEach(raw.segments) { segment in
                            if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(segment.text).font(.subheadline)
                            }
                        }
                    }
                    .accessibilityIdentifier("meeting.transcript.offlineOriginal")
                }
            }
        }
    }

    @ViewBuilder
    private func analysisSection(_ result: MeetingResult) -> some View {
        if (!result.summary.isEmpty && meeting.summaryKindRaw != "sourceExcerpts")
            || meeting.offlineASRFailure != nil || processingReporter.isBusy || isAnalyzing || isDiarizing
            || analysisError != nil || retryError != nil || speakerError != nil || segmentEditError != nil {
        Section {
            if let failure = meeting.offlineASRFailure {
                Text(failure == .modelUnavailable
                     ? AppLanguage.localized("meeting.offlineTranscription.modelUnavailable", defaultValue: "Whisper model unavailable. Install it in Settings → Meeting and retry.", language: .current, comment: "Offline transcription could not run because its model is unavailable.")
                     : (result.segments.isEmpty
                        ? AppLanguage.localized("meeting.offlineTranscription.failedAudioPreserved", defaultValue: "Offline transcription failed. The saved audio is intact and can be retried.", language: .current, comment: "Offline transcription failed without an earlier transcript; saved audio is preserved.")
                        : AppLanguage.localized("meeting.audioTrack.offlineFailed", defaultValue: "Offline transcription failed. Your earlier transcript is intact.", language: .current, comment: "Offline transcription failed while preserving the previous valid transcript.")))
                    .font(.caption).foregroundStyle(AppTheme.warning)
            }
            if !result.summary.isEmpty, meeting.summaryKindRaw != "sourceExcerpts" {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                    Label(meeting.summaryKindRaw == "generated"
                        ? MeetingLanguageCopy.text("meeting.languages.generated", "AI summary")
                        : MeetingLanguageCopy.text("meeting.languages.excerpts", "Source excerpts / unverified summary"),
                        systemImage: meeting.summaryKindRaw == "generated" ? "sparkles" : "text.quote")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.accent)
                    if let tag = meeting.summaryResultLanguageTag {
                        Text(MeetingLanguageOption(id: tag).displayName(locale: AppLanguage.current.locale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(result.summary)
                    MeetingAIAccuracyNotice()
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowInsets(EdgeInsets(top: 16, leading: contentInset, bottom: 16, trailing: contentInset))
            }

            if processingReporter.isBusy {
                MeetingProcessingStatusView(
                    phase: processingReporter.phase,
                    showsTranscription: processingReporter.includesTranscription,
                    offlineTranscription: isRetryingOfflineTranscript,
                    transcriptionProgress: processingReporter.transcriptionProgress
                )
            }
            if isAnalyzing {
                ProgressView("요약을 다시 만드는 중")
                    .font(.caption)
            }
            if isDiarizing { speakerStatus }
            if let analysisError {
                Text(analysisError).font(.caption).foregroundStyle(AppTheme.destructive)
            }
            if let retryError {
                Text(retryError).font(.caption).foregroundStyle(AppTheme.destructive)
            }
            if let speakerError {
                Text(speakerError).font(.caption).foregroundStyle(AppTheme.destructive)
            }
            if let segmentEditError {
                Text(segmentEditError).font(.caption).foregroundStyle(AppTheme.destructive)
            }
        }
        }
    }

    @ViewBuilder
    private func transcriptMetadata(_ segment: MeetingSegment, correction: MeetingProofread.SegmentCorrection?) -> some View {
        Text("\(duration(segment.startMs))–\(duration(segment.endMs))")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        if let confidence = segment.confidence, confidence < 0.5 {
            Label("확인 필요", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(AppTheme.warning)
        }
        if correction != nil {
            Text("AI 교정")
                .font(.caption.weight(.medium)).foregroundStyle(AppTheme.success)
        }
    }

    private func transcriptRow(
        _ segment: MeetingSegment,
        result: MeetingResult,
        isActive: Bool,
        presentation: MeetingSpeakerContinuity.Presentation?,
        correction: MeetingProofread.SegmentCorrection?
    ) -> some View {
        let startsTurn = presentation?.startsTurn ?? true
        return VStack(alignment: .leading, spacing: 4) {
            if startsTurn {
                Text(speakerLabel(for: segment, presentation: presentation))
                    .font(.caption.weight(.medium)).foregroundStyle(AppTheme.secondaryText)
            }
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact) {
                transcriptText(segment, isActive: isActive, correction: correction)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    transcriptMetadata(segment, correction: correction)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.top, startsTurn ? AppTheme.Spacing.compact : 2)
        .padding(.bottom, 2)
        .padding(.horizontal, AppTheme.Spacing.item)
        .contentShape(Rectangle())
        .onTapGesture {
            seek(to: segment)
        }
        .overlay(alignment: .leading) {
            if isActive {
                Rectangle()
                    .fill(AppTheme.accent)
                    .frame(width: 3)
            }
        }
        .background(
            isActive ? AppTheme.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
        )
        .animation(AppTheme.motion(reduceMotion: reduceMotion), value: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(isActive
            ? AppLanguage.localized("meeting.transcript.playbackHint.active", defaultValue: "Current playback segment. Double-tap to play from this segment.", language: .current, comment: "Accessibility hint for the currently playing transcript segment.")
            : AppLanguage.localized("meeting.transcript.playbackHint", defaultValue: "Double-tap to play from this segment.", language: .current, comment: "Accessibility hint for a playable transcript segment."))
        .accessibilityValue(
            MeetingSpeakerLabelFormatter.accessibilityValue(
                speakerLabel: speakerLabel(for: segment, presentation: presentation),
                transcript: correction.map {
                    String(format: AppLanguage.localized("meeting.transcript.correction.accessibilityValue", defaultValue: "Before correction: %1$@. After correction: %2$@.", language: .current, comment: "Accessibility comparison of original and corrected transcript text."), locale: AppLanguage.current.locale, $0.before, $0.after)
                } ?? segment.text,
                inherited: presentation?.isInherited == true)
        )
        .contextMenu {
            Button("내용 수정") {
                textEditDraft = segment.text
                textEditTarget = segment
            }
            .disabled(isReprocessing)
            Button("화자 수정") {
                speakerSheetTarget = segment
            }
            .disabled(isReprocessing || meeting.audioManifest == nil)
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

    @ViewBuilder
    private func transcriptText(_ segment: MeetingSegment, isActive: Bool,
                                correction: MeetingProofread.SegmentCorrection?) -> some View {
        if let correction {
            Text(inlineAttributed(correction.tokens))
                .fontWeight(isActive ? .semibold : .regular)
        } else {
            Text(segment.text)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle((player.isPlaying || player.isPaused) && !isActive ? Color.secondary : Color.primary)
        }
    }

    private func seek(to segment: MeetingSegment) {
        guard let manifest = meeting.audioManifest else { return }
        let total = totalMs(manifest)
        guard total > 0 else { return }
        player.seek(toProgress: Double(segment.startMs) / Double(total), totalMilliseconds: total)
        // A live/preparing player consumes the new seek without another session.
        if !player.isPlaying, !player.isPreparingPlayback { startPlayback(manifest) }
    }

    private var isDiarizing: Bool { isQueuingSpeakers || diarizationActivity.isRunning(meeting.meetingID) }

    private var isReprocessing: Bool {
        meeting.status == .finalizingTranscript || isAnalyzing || isRetryingTranscript || isDiarizing
    }

    private func speakerLabel(for segment: MeetingSegment,
                              presentation: MeetingSpeakerContinuity.Presentation?) -> String {
        if segment.speakerIDs.isEmpty, speakerDisplay.mixedSegmentIDs.contains(segment.id) {
            return AppLanguage.localized(
                "meeting.speaker.mixed",
                defaultValue: AppLanguage.current == .english
                    ? "Several speakers · re-transcribe to separate"
                    : "여러 화자 · 다시 전사하면 분리 가능",
                language: .current,
                comment: "Untimed segment containing several sequential speakers."
            )
        }
        return MeetingSpeakerLabelFormatter.label(
            for: presentation?.speakerIDs ?? segment.speakerIDs, profiles: speakerDisplay.profiles,
            state: presentation?.isInherited == true ? .provisional : .final,
            kind: presentation?.kind ?? .speaker
        )
    }

    @ViewBuilder
    private var speakerStatus: some View {
        if isDiarizing {
            ProgressView(
                AppLanguage.localized(
                    "meeting.diarization.progress",
                    defaultValue: AppLanguage.current == .english
                        ? "Detecting speakers from saved audio"
                        : "저장된 음성에서 화자를 확인하는 중",
                    language: .current,
                    comment: "Saved-audio speaker analysis progress."
                ),
                value: diarizationActivity.progress[meeting.meetingID] ?? 0
            )
            .font(.caption)
            .accessibilityIdentifier("meeting.diarization.state")
            Button(AppLanguage.localized(
                "meeting.diarization.cancel",
                defaultValue: AppLanguage.current == .english ? "Stop speaker detection" : "화자 분석 중지",
                language: .current,
                comment: "Stop only the saved-audio speaker analysis; recording and transcript remain saved."
            )) {
                isCancellingSpeakers = true
                speakerPassTask?.cancel()
                Task {
                    await MeetingDiarizationPostProcessor.cancel(meetingID: meeting.meetingID)
                    isCancellingSpeakers = false
                }
            }
            .accessibilityIdentifier("meeting.diarization.cancel")
            .disabled(isCancellingSpeakers)
        } else if let text = speakerDisplay.statusText {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meeting.diarization.state")
        }
    }

    private func commitSpeakerEdit(_ operation: (() throws -> Void) throws -> Void) {
        segmentEditError = nil
        do {
            try operation { try meetingContext.save() }
        } catch {
            segmentEditError = error.localizedDescription
        }
    }

    private func activeSegmentID(in result: MeetingResult) -> String? {
        guard player.isPlaying || player.isPaused else { return nil }
        return result.segmentID(at: player.playbackMilliseconds)
    }

    private func correction(for segmentID: String) -> MeetingProofread.SegmentCorrection? {
        guard case .changed(_, let corrections) = proofreadPresentation else { return nil }
        return corrections[segmentID]
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
        if meeting.automaticLanguageDetection {
            retryOfflineTranscript()
            return
        }
        guard let source = meeting.result else { return }
        let sourceData = meeting.resultData
        let languageTag = meeting.languageTag
        let meetingID = meeting.meetingID
        let revision = source.transcriptRevision + 1
        isRetryingTranscript = true
        retryError = nil
        analysisError = nil
        processingReporter.reset()
        processingReporter.startTranscribing(totalMilliseconds: manifest.totalSamples / 16)
        Task {
            defer { isRetryingTranscript = false }
            let (updates, continuation) = AsyncStream<MeetingTranscriptionProgress.Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let observing = Task {
                for await update in updates { processingReporter.updateTranscription(update) }
            }
            do {
                let entries = try await MeetingTranscriptRetryService()
                    .retranscribe(manifest: manifest, languageTag: languageTag, progress: { continuation.yield($0) })
                continuation.finish()
                await observing.value
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
                        text: entry.text,
                        isFinal: entry.isFinal,
                        confidence: entry.confidence,
                        timedRuns: entry.timedRuns
                    )
                }.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
                let baseResult = MeetingResult(transcriptRevision: revision, segments: segments)

                guard meeting.transcriptRevision == source.transcriptRevision,
                      meeting.resultData == sourceData,
                      meeting.audioManifest == manifest else {
                    retryError = AppLanguage.localized("meeting.error.changedDuringRetry", defaultValue: "The meeting changed, so the retranscription was not applied. Try again.", language: .current, comment: "Meeting retranscription conflict.")
                    processingReporter.reset()
                    return
                }
                try MeetingRecordCommitter.persist(
                    record: meeting,
                    save: { try meetingContext.save() },
                    mutate: {
                        try meeting.replaceTranscriptionBase(baseResult, status: .ready)
                        try meeting.update(diarization: nil)
                    }
                )
                await finishRetranscription()
            } catch {
                continuation.finish()
                await observing.value
                retryError = error.localizedDescription
                processingReporter.reset()
            }
        }
    }

    private func retryOfflineTranscript() {
        guard !isReprocessing, meeting.audioManifest != nil, offlineModelInstalled else { return }
        isRetryingTranscript = true
        isRetryingOfflineTranscript = true
        retryError = nil
        analysisError = nil
        processingReporter.reset()
        Task {
            defer {
                isRetryingTranscript = false
                isRetryingOfflineTranscript = false
            }
            do {
                let outcome = try await MeetingOfflineTranscriptionOrchestrator().run(
                    record: meeting, context: meetingContext, reporter: processingReporter
                )
                guard outcome == .committed else {
                    retryError = AppLanguage.localized("meeting.offlineTranscription.changedDuringRetry", defaultValue: "The meeting changed, so the offline transcript was not applied. Try again.", language: .current, comment: "Offline transcription was not applied because the meeting changed.")
                    processingReporter.reset()
                    return
                }
                await finishRetranscription()
            } catch {
                retryError = error.localizedDescription
                processingReporter.reset()
            }
        }
    }

    /// Both ASR engines release their audio resources before speaker replay.
    private func finishRetranscription() async {
        processingReporter.set(.idle)
        do {
            speakerError = try await runSpeakerPass().userMessage
        } catch {
            speakerError = error.localizedDescription
        }
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
            retryError = AppLanguage.localized(
                "meeting.error.proofreadAfterRetry",
                defaultValue: "Retranscription was saved, but AI proofreading or summary could not be completed.",
                language: .current, comment: "Meeting retranscription processing error."
            )
        }
    }

    private func runSpeakerPass() async throws -> MeetingDiarizationPostProcessor.Outcome {
        isQueuingSpeakers = true
        isCancellingSpeakers = false
        let task = Task { try await MeetingDiarizationPostProcessor.run(record: meeting, context: meetingContext) }
        speakerPassTask = task
        defer {
            speakerPassTask = nil
            isQueuingSpeakers = false
            isCancellingSpeakers = false
            speakerDisplay = MeetingSpeakerDisplay(record: meeting)
        }
        return try await task.value
    }

    private func retrySpeakers() {
        guard !isReprocessing else { return }
        speakerError = nil
        let hadAnalysis = meeting.result.map { !$0.summary.isEmpty || !$0.actionDrafts.isEmpty } ?? false
        Task {
            let outcome: MeetingDiarizationPostProcessor.Outcome
            do {
                outcome = try await runSpeakerPass()
            } catch {
                speakerError = error.localizedDescription
                return
            }
            speakerError = outcome.userMessage
            // A speaker-turn split is a new revision and invalidates the old
            // summary and drafts; rebuild them without re-proofreading.
            guard outcome == .completed(didSplit: true), hadAnalysis else { return }
            do {
                _ = try await MeetingPostProcessor.refineAndAnalyze(
                    record: meeting,
                    context: meetingContext,
                    allowRefine: false,
                    allowModelLoad: false,
                    reporter: processingReporter,
                    dependencies: makeVocabularyMeetingDependencies(userVocabulary?.service)
                )
            } catch {
                analysisError = error.localizedDescription
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

    private func regenerateSummary() {
        guard !isReprocessing else { return }
        isAnalyzing = true
        analysisError = nil
        retryError = nil
        processingReporter.reset()
        Task {
            defer { isAnalyzing = false }
            do {
                _ = try await MeetingPostProcessor.refineAndAnalyze(
                    record: meeting, context: meetingContext, allowRefine: false, allowModelLoad: false,
                    reporter: processingReporter, dependencies: makeVocabularyMeetingDependencies(userVocabulary?.service))
            } catch is CancellationError {
                processingReporter.reset()
            } catch {
                analysisError = error.localizedDescription
                processingReporter.reset()
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
        // Manual speaker assignments follow lineage; the transcript changed, so any
        // in-flight speaker pass is fenced by its source digest.
        let payload = record.diarization.map { payload -> MeetingDiarizationPayload in
            var copy = payload
            copy.manualAssignments = MeetingSpeakerProfileBook.carryManualAssignments(
                payload.manualAssignments, from: result, to: updated
            )
            return copy
        }
        try MeetingRecordCommitter.persist(
            record: record,
            save: save,
            mutate: {
                try record.update(result: updated, status: status)
                record.refinementEngineLabel = ""
                if let payload { try record.update(diarization: payload) }
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

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
