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
    @State private var analysisError: String?
    let meeting: MeetingRecord
    @StateObject private var player = MeetingAudioPlaybackController()
    @State private var playbackTask: Task<Void, Never>?
    @State private var waveform: MeetingWaveform?
    @State private var waveformError: String?
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportShare: MeetingAudioDownload?
    @State private var settingsExportShare: MeetingAudioDownload?
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
    @State private var documentTab: MeetingDocumentTab = .transcript
    @State private var showingSettings = false
    @State private var showingSummaryModels = false
    @State private var showingSettingsSummaryModels = false
    @State private var citationTarget: String?
    @State private var citationRequest = UUID()
    @State private var processingTask: Task<Void, Never>?
    @State private var customInstructionsDraft = ""
    @State private var customInstructionsOriginal = ""
    @State private var processingNotice: String?
    @State private var summaryUpdatedAt: Date?
    var initialCitation: MeetingSummaryCitation? = nil

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
                    Section {
                        Picker(MeetingLanguageCopy.text("meeting.document.title", "Meeting document"), selection: $documentTab) {
                            ForEach(MeetingDocumentTab.allCases) { tab in Text(tab.title).tag(tab) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("meeting.document.tabs")
                    }
                    if documentTab == .transcript { transcriptSection(result) }
                    if documentTab == .summary {
                        analysisSection(result)
                        if result.summarySections?.isEmpty != false {
                            decisionsSection(result)
                            questionsSection(result)
                        }
                    }
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
                if meeting.status == .transcriptFinalizationFailed, let manifest = meeting.audioManifest {
                    failedFinalizationSection(manifest)
                }
            }
        .appListStyle()
        .navigationTitle("회의 기록")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(MeetingLanguageCopy.text("meeting.settings.title", "Meeting settings"))
                .accessibilityIdentifier("meeting.settings.open")
                if meeting.audioManifest != nil {
                    Menu {
                        Button(MeetingLanguageCopy.text("meeting.manage.downloadOriginal", "Download original recording (ZIP)")) {
                            export(format: .original)
                        }
                        Button(MeetingLanguageCopy.text("meeting.manage.downloadWAV", "Download audio (WAV)")) {
                            export(format: .wav)
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
        .meetingAudioDownload($exportShare) { exportError = $0.localizedDescription }
        .sheet(isPresented: $showingSettings) {
            processingSettings
                .onAppear {
                    customInstructionsDraft = meeting.summaryCustomInstructions
                    customInstructionsOriginal = meeting.summaryCustomInstructions
                }
                .onDisappear { _ = commitCustomInstructions() }
        }
        .sheet(isPresented: $showingSummaryModels) {
            MeetingSummaryView(meeting: meeting) {
                summaryUpdatedAt = meeting.updatedAt
                documentTab = .summary
            }
        }
        .task(id: initialCitation) {
            if let initialCitation { openCitation(initialCitation) }
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


    private struct TranscriptTurnGroup: Identifiable {
        let segments: [MeetingSegment]
        let presentation: MeetingSpeakerContinuity.Presentation
        var id: String { segments[0].id }
        var startMs: Int64 { segments[0].startMs }
        var endMs: Int64 { segments.last?.endMs ?? segments[0].endMs }
        var text: String {
            segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        func contains(_ segmentID: String?) -> Bool {
            guard let segmentID else { return false }
            return segments.contains { $0.id == segmentID || $0.stableLineageID == segmentID }
        }
    }

    private func groupedTranscriptTurns(_ segments: [MeetingSegment]) -> [TranscriptTurnGroup] {
        var groups: [TranscriptTurnGroup] = []
        for segment in segments {
            let rowID = MeetingConversationTimeline.Row.ID(trackID: meeting.meetingID, localID: segment.stableLineageID)
            let presentation = speakerDisplay.continuity[rowID]
                ?? MeetingSpeakerContinuity.Presentation(speakerIDs: segment.speakerIDs, isInherited: false, startsTurn: true, kind: .speaker)
            if presentation.startsTurn || groups.isEmpty {
                groups.append(TranscriptTurnGroup(segments: [segment], presentation: presentation))
            } else {
                let last = groups.removeLast()
                let updatedPresentation = MeetingSpeakerContinuity.Presentation(
                    speakerIDs: last.presentation.speakerIDs,
                    isInherited: last.presentation.isInherited && presentation.isInherited,
                    startsTurn: true,
                    kind: last.presentation.kind
                )
                groups.append(TranscriptTurnGroup(segments: last.segments + [segment], presentation: updatedPresentation))
            }
        }
        return groups
    }

    @ViewBuilder
    private func transcriptSection(_ result: MeetingResult) -> some View {
        let visibleSegments = result.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let turns = groupedTranscriptTurns(visibleSegments)
        let activeSegmentID = activeSegmentID(in: result)
        let activeTurnID = turns.first(where: { $0.contains(activeSegmentID) })?.id
        let citationTurnID = turns.first(where: { $0.contains(citationTarget) })?.id
        Section("전사문") {
            speakerStatus

            if turns.isEmpty {
                ContentUnavailableView("전사문이 없습니다", systemImage: "waveform.slash")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(turns) { turn in
                                transcriptTurnRow(
                                    turn,
                                    isFirstTurn: turn.id == turns.first?.id,
                                    result: result,
                                    isActive: turn.id == activeTurnID,
                                    isCited: turn.id == citationTurnID
                                )
                                .id(turn.id)
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
                    .task(id: citationRequest) {
                        await Task.yield()
                        guard !Task.isCancelled, let targetID = citationTurnID ?? citationTarget else { return }
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                    .onChange(of: activeTurnID) { _, activeID in
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

        Section {
            MeetingSummaryEntry(isProcessing: isReprocessing) {
                showingSummaryModels = true
            }
            if let summaryUpdatedAt, summaryUpdatedAt == meeting.updatedAt {
                Text(MeetingLanguageCopy.text("meeting.summary.success", "Summary regenerated. Review its citations."))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("meeting.summary.success")
            }
            if let failure = meeting.offlineASRFailure {
                Text(failure == .modelUnavailable
                     ? AppLanguage.localized("meeting.offlineTranscription.modelUnavailable", defaultValue: "Whisper model unavailable. Install it in Settings → Meeting and retry.", language: .current, comment: "Offline transcription could not run because its model is unavailable.")
                     : (result.segments.isEmpty
                        ? AppLanguage.localized("meeting.offlineTranscription.failedAudioPreserved", defaultValue: "Offline transcription failed. The saved audio is intact and can be retried.", language: .current, comment: "Offline transcription failed without an earlier transcript; saved audio is preserved.")
                        : AppLanguage.localized("meeting.audioTrack.offlineFailed", defaultValue: "Offline transcription failed. Your earlier transcript is intact.", language: .current, comment: "Offline transcription failed while preserving the previous valid transcript.")))
                    .font(.caption).foregroundStyle(AppTheme.warning)
            }
            MeetingCitedSummaryView(result: result, record: meeting, openCitation: openCitation)
                .listRowInsets(EdgeInsets(top: 16, leading: contentInset, bottom: 16, trailing: contentInset))

            if processingReporter.isBusy {
                MeetingProcessingStatusView(
                    phase: processingReporter.phase,
                    showsTranscription: processingReporter.includesTranscription,
                    offlineTranscription: isRetryingOfflineTranscript,
                    transcriptionProgress: processingReporter.transcriptionProgress
                )
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


    private func transcriptTurnRow(
        _ turn: TranscriptTurnGroup,
        isFirstTurn: Bool,
        result: MeetingResult,
        isActive: Bool,
        isCited: Bool
    ) -> some View {
        let firstSegment = turn.segments[0]
        let primaryID = isCited ? (turn.segments.first(where: { $0.id == citationTarget || $0.stableLineageID == citationTarget })?.id ?? firstSegment.id) : firstSegment.id
        let knownSpeaker = !turn.presentation.speakerIDs.isEmpty || turn.presentation.kind == .mixed || speakerDisplay.mixedSegmentIDs.contains(firstSegment.id)
        let turnCorrections = turn.segments.compactMap { correction(for: $0.id) }
        let hasLowConfidence = turn.segments.contains { ($0.confidence ?? 1.0) < 0.5 }
        return VStack(alignment: .leading, spacing: 4) {
            MeetingTranscriptProseRow(
                text: turn.text,
                sourceLabel: isFirstTurn ? meeting.audioTrackDisplayName : nil,
                speakerLabel: knownSpeaker ? speakerLabel(for: firstSegment, presentation: turn.presentation) : nil,
                timeRange: "\(duration(turn.startMs))–\(duration(turn.endMs))",
                identifier: "meeting.transcript.segment.\(primaryID)",
                highlighted: isActive || isCited,
                canPlay: meeting.audioManifest != nil
            ) { seek(to: firstSegment) }
            .contextMenu {
                if turn.segments.count == 1 {
                    transcriptSegmentActions(firstSegment, result: result)
                } else {
                    ForEach(turn.segments) { segment in
                        Menu("\(duration(segment.startMs)) · \(segment.text.prefix(48))") {
                            transcriptSegmentActions(segment, result: result)
                        }
                    }
                }
            }
            if !turnCorrections.isEmpty {
                DisclosureGroup(MeetingLanguageCopy.text("meeting.transcript.correction", "AI correction")) {
                    ForEach(Array(turnCorrections.enumerated()), id: \.offset) { _, item in
                        Text(inlineAttributed(item.tokens)).textSelection(.enabled)
                    }
                }
                .font(.caption).padding(.horizontal, AppTheme.Spacing.item)
            }
            if hasLowConfidence {
                Label("확인 필요", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(AppTheme.warning)
                    .padding(.horizontal, AppTheme.Spacing.item)
            }
        }
        .padding(.top, isFirstTurn ? 0 : AppTheme.Spacing.compact)
    }

    @ViewBuilder
    private func transcriptSegmentActions(_ segment: MeetingSegment, result: MeetingResult) -> some View {
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
        meeting.status == .finalizingTranscript || isRetryingTranscript || isDiarizing
    }

    private func speakerLabel(for segment: MeetingSegment,
                              presentation: MeetingSpeakerContinuity.Presentation?) -> String {
        if (presentation?.speakerIDs ?? segment.speakerIDs).isEmpty,
           (presentation?.kind == .mixed || speakerDisplay.mixedSegmentIDs.contains(segment.id)) {
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
            state: .final,
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
        processingNotice = nil
        processingReporter.startTranscribing(totalMilliseconds: manifest.totalSamples / 16)
        processingTask = Task {
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

                try Task.checkCancellation()
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
                if error is CancellationError {
                    processingNotice = MeetingLanguageCopy.text("meeting.settings.cancelled", "Processing cancelled. Saved audio and the last successfully saved results are unchanged.")
                } else { retryError = error.localizedDescription }
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
        processingNotice = nil
        processingTask = Task {
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
                if error is CancellationError {
                    processingNotice = MeetingLanguageCopy.text("meeting.settings.cancelled", "Processing cancelled. Saved audio and the last successfully saved results are unchanged.")
                } else { retryError = error.localizedDescription }
                processingReporter.reset()
            }
        }
    }

    /// Both ASR engines release their audio resources before speaker replay.
    private func finishRetranscription() async {
        processingReporter.set(.idle)
        guard !Task.isCancelled else { return }
        do {
            speakerError = try await runSpeakerPass().userMessage
        } catch {
            speakerError = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
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
        processingTask = Task {
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

    private func export(format: MeetingAudioDownloadFormat, fromSettings: Bool = false) {
        guard !isExporting else { return }
        isExporting = true
        exportError = nil
        Task {
            defer { isExporting = false }
            do {
                let download = try await MeetingAudioDownload.prepare(record: meeting, in: meetingContext, format: format)
                if fromSettings { settingsExportShare = download }
                else { exportShare = download }
            } catch {
                exportError = error.localizedDescription
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



private extension MeetingDetailView {
    var processingSettings: some View {
        NavigationStack {
            Form {
                Section(MeetingLanguageCopy.text("meeting.settings.transcription", "Transcription")) {
                    if !transcriptionLanguages.isEmpty {
                        MeetingLanguagePicker(title: MeetingLanguageCopy.sourceTitle,
                            selection: Binding(get: { meeting.languageTag }, set: { saveLanguage($0, summary: false) }),
                            options: transcriptionLanguages, identifier: "meeting.detail.sourceLanguage",
                            automaticLanguageDetection: Binding(get: { meeting.automaticLanguageDetection }, set: saveAutomaticLanguageDetection),
                            automaticDetectionAvailable: offlineModelInstalled)
                    }
                    Text(MeetingLanguageCopy.text("meeting.settings.retranscribeHelp", "Choose the source language, then explicitly retranscribe. Your current transcript stays available until the new transcription succeeds. Original audio is preserved."))
                        .font(.caption).foregroundStyle(.secondary)
                    if canRetryAppleTranscript {
                        Button(MeetingLanguageCopy.text("meeting.settings.retranscribe", "Retranscribe saved audio")) { showingRetranscribeConfirm = true }
                            .accessibilityIdentifier("meeting.settings.retranscribe")
                    }
                    if canRetryOfflineTranscript {
                        Button(MeetingLanguageCopy.text("meeting.offlineTranscription.retry", "Transcribe offline")) { showingOfflineRetranscribeConfirm = true }
                            .accessibilityIdentifier("meeting.offlineTranscription.retry")
                    }
                    if !canRetryAppleTranscript && !canRetryOfflineTranscript {
                        Text(MeetingLanguageCopy.text("meeting.settings.transcriptionUnavailable", "Transcription is unavailable for this source or language. Install the Whisper model in Settings → Meeting for offline transcription."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if canRetrySpeakers {
                        Button(MeetingLanguageCopy.text("meeting.diarization.retry", "Detect speakers again")) { retrySpeakers() }
                            .accessibilityIdentifier("meeting.diarization.retry")
                    }
                }
                .disabled(isReprocessing)
                Section(MeetingLanguageCopy.text("meeting.document.summary", "Summary")) {
                    if !summaryLanguageOptions.isEmpty {
                        MeetingLanguagePicker(title: MeetingLanguageCopy.summaryTitle,
                            selection: Binding(get: { resolvedSummaryLanguageTag }, set: { saveLanguage($0, summary: true) }),
                            options: summaryLanguageOptions, identifier: "meeting.detail.summaryLanguage")
                    } else {
                        LabeledContent(MeetingLanguageCopy.summaryTitle, value: MeetingLanguageOption(id: resolvedSummaryLanguageTag).displayName(locale: AppLanguage.current.locale))
                    }
                    MeetingSummaryFormatControls(
                        format: Binding(get: { meeting.summaryFormat }, set: { value in saveSummarySettings { meeting.summaryFormat = value } }),
                        instructions: $customInstructionsDraft)
                    Text(MeetingLanguageCopy.text("meeting.settings.explicitRegenerate", "Saved settings apply to the next summary. Regenerate explicitly to replace the existing summary; the transcript is not changed."))
                        .font(.caption).foregroundStyle(.secondary)
                    MeetingSummaryEntry(isProcessing: isReprocessing) {
                        guard commitCustomInstructions() else { return }
                        showingSettingsSummaryModels = true
                    }
                    .disabled(meeting.summaryFormat == .custom && customInstructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(isReprocessing)
                Section(MeetingLanguageCopy.text("meeting.settings.recordings", "Audio recordings")) {
                    Text(meeting.audioTrackDisplayName).font(.subheadline.weight(.medium))
                    Text(meeting.createdAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    if meeting.audioManifest != nil {
                        Button(MeetingLanguageCopy.text("meeting.manage.downloadOriginal", "Download original recording (ZIP)")) {
                            export(format: .original, fromSettings: true)
                        }
                        .accessibilityIdentifier("meeting.settings.downloadOriginal")
                        Button(MeetingLanguageCopy.text("meeting.manage.downloadWAV", "Download audio (WAV)")) {
                            export(format: .wav, fromSettings: true)
                        }
                        .accessibilityIdentifier("meeting.settings.downloadWAV")
                    }
                    if isExporting { ProgressView(MeetingLanguageCopy.text("meeting.settings.exporting", "Preparing recording download")) }
                }
                .disabled(isExporting)
                if isReprocessing || processingReporter.isBusy {
                    Section {
                        MeetingProcessingStatusView(phase: processingReporter.phase, showsTranscription: processingReporter.includesTranscription,
                            offlineTranscription: isRetryingOfflineTranscript, transcriptionProgress: processingReporter.transcriptionProgress)
                        Button(MeetingLanguageCopy.text("meeting.settings.cancelProcessing", "Cancel processing"), role: .cancel) {
                            processingTask?.cancel()
                            processingNotice = MeetingLanguageCopy.text("meeting.settings.cancelled", "Processing cancelled. Saved audio and the last successfully saved results are unchanged.")
                            speakerPassTask?.cancel()
                            Task { await MeetingDiarizationPostProcessor.cancel(meetingID: meeting.meetingID) }
                        }
                        .accessibilityIdentifier("meeting.settings.cancelProcessing")
                    }
                }
                if let processingNotice {
                    Section { Text(processingNotice).foregroundStyle(.secondary).accessibilityIdentifier("meeting.settings.cancelled") }
                }
                if let error = analysisError ?? retryError ?? speakerError ?? segmentEditError ?? exportError {
                    Section { Text(error).foregroundStyle(AppTheme.destructive).accessibilityIdentifier("meeting.settings.error") }
                }
            }
            .navigationTitle(MeetingLanguageCopy.text("meeting.settings.title", "Meeting settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(MeetingLanguageCopy.text("meeting.settings.done", "Done")) {
                    if commitCustomInstructions() { showingSettings = false }
                }
            } }
        }
        .meetingAudioDownload($settingsExportShare) { exportError = $0.localizedDescription }
        .sheet(isPresented: $showingSettingsSummaryModels) {
            MeetingSummaryView(meeting: meeting) {
                summaryUpdatedAt = meeting.updatedAt
                documentTab = .summary
                showingSettings = false
            }
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
    }

    @discardableResult
    func commitCustomInstructions() -> Bool {
        guard customInstructionsDraft != customInstructionsOriginal else { return true }
        guard !isReprocessing else { return false }
        do {
            try MeetingRecordCommitter.persist(record: meeting, save: { try meetingContext.save() }) {
                meeting.summaryCustomInstructions = customInstructionsDraft
                meeting.updatedAt = Date()
            }
            customInstructionsOriginal = customInstructionsDraft
            return true
        } catch {
            analysisError = error.localizedDescription
            return false
        }
    }

    func saveSummarySettings(_ mutate: () -> Void) {
        guard !isReprocessing else { return }
        do {
            try MeetingRecordCommitter.persist(record: meeting, save: { try meetingContext.save() }) {
                mutate()
                meeting.updatedAt = Date()
            }
        } catch { analysisError = error.localizedDescription }
    }

    func openCitation(_ citation: MeetingSummaryCitation) {
        guard citation.trackID == meeting.meetingID, let result = meeting.result,
              citation.transcriptRevision == result.transcriptRevision,
              let segment = result.segments.first(where: { $0.id == citation.segmentID || $0.stableLineageID == citation.segmentID }) else {
            analysisError = MeetingLanguageCopy.text("meeting.summary.citationUnavailable", "This transcript source has changed or is unavailable. Regenerate the summary to refresh its references.")
            return
        }
        if player.isPlaying { player.pause() }
        documentTab = .transcript
        citationTarget = segment.id
        citationRequest = UUID()
    }
}
