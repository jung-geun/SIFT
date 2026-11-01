import SwiftUI
import Combine
import SwiftData

/// Derived parent-time playback and conversation, with original source records retained.
struct MeetingTrackGroupDetailView: View {
    let meeting: MeetingRecord
    @Query private var tracks: [MeetingRecord]
    @State private var isExporting = false
    @State private var audioDownload: MeetingAudioDownload?
    @State private var settingsAudioDownload: MeetingAudioDownload?
    @State private var exportError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var player = MeetingAudioPlaybackController()
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackPlan: MeetingGroupAudioPlaybackPlan?
    @State private var waveform: MeetingWaveform?
    @State private var waveformError: String?
    @State private var preparationError: String?
    @State private var isPreparing = true
    @State private var timeline = MeetingConversationTimeline(sources: [])
    @State private var sourceNames: [String: String] = [:]
    @State private var speakerProfiles: [String: [String: MeetingSpeakerProfile]] = [:]
    @ScaledMetric(relativeTo: .body) private var transcriptViewportHeight = 300
    @Environment(\.modelContext) private var context
    @State private var documentTab: MeetingDocumentTab = .transcript
    @State private var showingSettings = false
    @State private var showingSummaryModels = false
    @State private var showingSettingsSummaryModels = false
    @State private var citationTarget: MeetingConversationTimeline.Row.ID?
    @State private var citationRequest = UUID()
    @State private var sourceDestination: CitationDestination?
    @State private var summaryError: String?
    @State private var summaryUpdatedAt: Date?
    @State private var customInstructionsDraft = ""
    @State private var customInstructionsOriginal = ""
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var localModel = OnDeviceLLMService.shared

    private struct CitationDestination: Identifiable {
        let track: MeetingRecord
        let citation: MeetingSummaryCitation
        var id: String { "\(track.meetingID)-\(citation.segmentID)" }
    }

    private var contentInset: CGFloat {
        horizontalSizeClass == .compact ? 16 : AppTheme.Spacing.section
    }

    private struct TrackUpdate: Equatable {
        let id: String
        let updatedAt: Date
        let startSample: Int64
    }

    init(meeting: MeetingRecord) {
        self.meeting = meeting
        let parentID = meeting.meetingID
        _tracks = Query(filter: #Predicate<MeetingRecord> { $0.parentMeetingID == parentID },
                        sort: [SortDescriptor(\MeetingRecord.audioTrackStartSample), SortDescriptor(\MeetingRecord.createdAt)])
    }

    var body: some View {
        List {
            audioSection
            Section {
                Picker(MeetingLanguageCopy.text("meeting.document.title", "Meeting document"), selection: $documentTab) {
                    ForEach(MeetingDocumentTab.allCases) { tab in Text(tab.title).tag(tab) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("meeting.document.tabs")
            }
            if documentTab == .transcript { conversationSections }
            if documentTab == .summary {
                Section {
                    MeetingSummaryEntry(isProcessing: false) {
                        showingSummaryModels = true
                    }
                    if let summaryUpdatedAt, summaryUpdatedAt == meeting.updatedAt {
                        Text(MeetingLanguageCopy.text("meeting.summary.success", "Summary regenerated. Review its citations."))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("meeting.summary.success")
                    }
                    MeetingCitedSummaryView(result: meeting.result ?? MeetingResult(), record: meeting, openCitation: openCitation)
                    if let summaryError { Text(summaryError).foregroundStyle(AppTheme.destructive) }
                }
            }
            sourceSection
        }
        .appListStyle()
        .navigationTitle("회의 기록")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel(MeetingLanguageCopy.text("meeting.settings.title", "Meeting settings"))
                    .accessibilityIdentifier("meeting.settings.open")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    allSourcesDownloadButton(fromSettings: false)
                    Divider()
                    ForEach(tracks) { track in
                        Menu(track.audioTrackDisplayName) {
                            sourceDownloadButtons(sourceID: track.meetingID, fromSettings: false)
                        }
                        .accessibilityIdentifier("meeting.download.source.\(track.meetingID).menu")
                    }
                } label: {
                    Label(MeetingLanguageCopy.text("meeting.manage.download", "Download audio"), systemImage: "arrow.down.to.line")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(MeetingLanguageCopy.text("meeting.manage.download", "Download audio"))
                .accessibilityIdentifier("meeting.download.menu")
                .disabled(downloadUnavailable || tracks.isEmpty)
            }
        }
        .task(id: tracks.map { TrackUpdate(id: $0.meetingID, updatedAt: $0.updatedAt, startSample: $0.audioTrackStartSample) }) {
            await preparePresentation()
        }
        .onDisappear {
            playbackTask?.cancel()
            playbackTask = nil
            player.stop()
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            player.refreshPlaybackProgress()
        }
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
        .sheet(item: $sourceDestination) { destination in
            NavigationStack {
                MeetingDetailView(meeting: destination.track, initialCitation: destination.citation)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button(MeetingLanguageCopy.text("meeting.settings.done", "Done")) { sourceDestination = nil }
                    } }
            }
        }
        .meetingAudioDownload($audioDownload) { error in
            exportError = error.localizedDescription
        }
        .alert(MeetingLanguageCopy.text("meeting.manage.downloadFailed", "Audio download failed"),
               isPresented: Binding(get: { exportError != nil && !showingSettings }, set: { if !$0 { exportError = nil } })) {
            Button(copy("확인", korean: "확인", english: "OK"), role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .alert("음성 재생 실패", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.dismissError() } })) {
            Button("확인", role: .cancel) { player.dismissError() }
        } message: { Text(player.errorMessage ?? "") }
    }

    @ViewBuilder private var conversationSections: some View {
        Section(copy("meeting.conversation.title", korean: "대화 타임라인", english: "Conversation timeline")) {
            if timeline.rows.isEmpty && timeline.unalignedSources.isEmpty {
                Text(copy("meeting.conversation.empty", korean: "전사 대기 중", english: "Waiting for transcript"))
                    .foregroundStyle(.secondary)
            } else if !timeline.rows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        conversationRows(timeline.rows)
                    }
                    .frame(height: min(transcriptViewportHeight, 420))
                    .clipped()
                    .accessibilityIdentifier("meeting.conversation.viewport")
                    .listRowInsets(EdgeInsets(top: 0, leading: contentInset - AppTheme.Spacing.item,
                        bottom: 0, trailing: contentInset - AppTheme.Spacing.item))
                    .listRowSeparator(.hidden)
                    .task(id: citationRequest) {
                        await Task.yield()
                        guard !Task.isCancelled, let citationTarget else { return }
                        let turns = MeetingConversationTimeline.groupTurns(timeline.rows, presentation: timeline.speakerPresentation)
                        let targetTurnID = turns.first(where: { $0.rows.contains(where: { $0.id == citationTarget }) })?.id ?? citationTarget
                        proxy.scrollTo(targetTurnID, anchor: .center)
                    }
                    .onChange(of: activeRowID) { _, id in
                        guard let id else { return }
                        let turns = MeetingConversationTimeline.groupTurns(timeline.rows, presentation: timeline.speakerPresentation)
                        let targetTurnID = turns.first(where: { $0.rows.contains(where: { $0.id == id }) })?.id ?? id
                        if reduceMotion { proxy.scrollTo(targetTurnID, anchor: .center) }
                        else {
                            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(targetTurnID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        ForEach(timeline.unalignedSources) { source in
            Section(sourceNames[source.id] ?? "") {
                Text(copy("meeting.conversation.unknownTiming", korean: "공통 시작 시각 없음 · 소스 간 순서 미확정",
                    english: "Common start time unavailable · order between sources unknown"))
                    .font(.caption).foregroundStyle(AppTheme.warning)
                conversationRows(source.rows)
                    .listRowInsets(EdgeInsets(top: 0, leading: contentInset - AppTheme.Spacing.item,
                        bottom: 0, trailing: contentInset - AppTheme.Spacing.item))
                    .listRowSeparator(.hidden)
            }
        }
    }

    private func conversationRows(_ rows: [MeetingConversationTimeline.Row]) -> some View {
        let turns = MeetingConversationTimeline.groupTurns(rows, presentation: timeline.speakerPresentation)
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                conversationTurnRow(
                    turn,
                    sourceChanged: index == 0 || turns[index - 1].id.trackID != turn.id.trackID
                )
                .padding(.top, index == 0 ? 0 : AppTheme.Spacing.compact)
                .id(turn.id)
            }
        }
        .padding(.vertical, AppTheme.Spacing.compact)
    }

    private func conversationTurnRow(_ turn: MeetingConversationTimeline.Turn, sourceChanged: Bool) -> some View {
        let firstRow = turn.rows[0]
        let sample = player.playbackMilliseconds * (MeetingMediaTimeline.sampleRate / 1_000)
        let isActive = (player.isPlaying || player.isPaused)
            && turn.rows.contains { row in
                row.startSample.map { $0 <= sample } == true && row.endSample.map { sample < $0 } == true
            }
        let isCited = citationTarget.map { target in turn.rows.contains { $0.id == target } } == true
        let primaryID = isCited ? (turn.rows.first(where: { $0.id == citationTarget })?.id ?? turn.id) : turn.id
        let timeRange = turn.startSample.flatMap { start in turn.endSample.map { "\(duration(start))–\(duration($0))" } }
            ?? "\(localDuration(turn.localStartMs))–\(localDuration(turn.localEndMs))"
        let speakerLabel = MeetingSpeakerLabelFormatter.label(
            for: turn.presentation.speakerIDs,
            profiles: speakerProfiles[turn.id.trackID] ?? [:],
            state: .final,
            kind: turn.presentation.kind
        )
        let knownSpeaker = !turn.presentation.speakerIDs.isEmpty || turn.presentation.kind == .mixed
        return MeetingTranscriptProseRow(
            text: turn.text,
            sourceLabel: sourceChanged ? sourceNames[turn.id.trackID] : nil,
            speakerLabel: knownSpeaker ? speakerLabel : nil,
            timeRange: timeRange,
            identifier: "meeting.conversation.saved.\(primaryID.trackID).\(primaryID.localID)",
            highlighted: isActive || isCited,
            canPlay: firstRow.startSample != nil && playbackPlan?.sources.contains(where: { $0.trackID == turn.id.trackID }) == true
        ) {
            seek(to: firstRow)
        }
        .contextMenu {
            if turn.rows.count > 1 {
                ForEach(turn.rows) { row in
                    Menu("\(localDuration(row.localStartMs)) · \(row.text.prefix(48))") {
                        Button(AppLanguage.localized(
                            "meeting.summary.openTranscriptSource",
                            defaultValue: AppLanguage.current == .english ? "View in transcript" : "전사문 위치 보기",
                            language: .current
                        )) {
                            openSourceTranscript(for: row)
                        }
                    }
                }
            }
        }
    }

    private func openSourceTranscript(for row: MeetingConversationTimeline.Row) {
        guard let track = tracks.first(where: { $0.meetingID == row.id.trackID }),
              let result = track.result,
              let segment = result.segments.first(where: { $0.id == row.id.localID || $0.stableLineageID == row.id.localID }) else {
            summaryError = MeetingLanguageCopy.text("meeting.summary.citationUnavailable", "This transcript source has changed or is unavailable. Regenerate the summary to refresh its references.")
            return
        }
        if player.isPlaying { player.pause() }
        sourceDestination = CitationDestination(track: track, citation: MeetingSummaryCitation(
            trackID: track.meetingID,
            segmentID: segment.id,
            transcriptRevision: result.transcriptRevision
        ))
    }

    @ViewBuilder private var audioSection: some View {
        Section(playbackPlan?.isComplete == false
            ? copy("음성", korean: "음성", english: "Audio")
            : copy("meeting.conversation.audio", korean: "전체 음성", english: "Full meeting audio")) {
            if let playbackPlan {
                MeetingAudioPlaybackView(player: player, waveform: waveform, waveformError: waveformError,
                    totalMilliseconds: totalMilliseconds(playbackPlan), identifier: "meeting.group.playbackButton") {
                    togglePlayback(playbackPlan)
                }
                if !playbackPlan.isComplete {
                    Text(copy("meeting.conversation.partialAudio", korean: "공통 시각이 확인된 재생 가능한 소스만 합성합니다. 나머지는 개별 소스에서 상태를 확인하세요.",
                        english: "Only playable sources with known common timing are mixed. Check the remaining sources individually."))
                        .font(.caption).foregroundStyle(AppTheme.warning)
                }
            } else if isPreparing {
                ProgressView("음성 트랙을 읽는 중")
            } else if let preparationError {
                Text(preparationError).font(.caption).foregroundStyle(AppTheme.warning)
            }
            if isExporting { ProgressView(MeetingLanguageCopy.text("meeting.settings.exporting", "Preparing recording download")).font(.caption) }
        }
    }

    private var sourceSection: some View {
        Section(copy("meeting.audioTrack.section", korean: "음성 트랙", english: "Audio tracks")) {
            ForEach(tracks) { track in
                NavigationLink { MeetingDetailView(meeting: track) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.audioTrackDisplayName).font(.subheadline.weight(.semibold))
                        Text(track.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        if let manifest = track.audioManifest {
                            if let start = track.conversationStartSample {
                                Text(String(format: copy("meeting.audioTrack.offsetDuration", korean: "회의 시작 +%@ · 길이 %@",
                                    english: "Starts at +%@ · duration %@"), duration(start), duration(manifest.totalSamples)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            } else {
                                Text(copy("meeting.conversation.unknownTiming", korean: "공통 시작 시각 없음 · 소스 간 순서 미확정",
                                    english: "Common start time unavailable · order between sources unknown"))
                                    .font(.caption).foregroundStyle(AppTheme.warning)
                            }
                        }
                        if track.status == .transcriptFinalizationFailed {
                            Text(copy("meeting.audioTrack.transcriptFailed", korean: "전사 확정 실패 · 이 트랙의 원음과 임시 전사를 보존했습니다.",
                                english: "Transcript finalization failed. This track's original audio and provisional text were preserved."))
                                .font(.caption).foregroundStyle(AppTheme.warning)
                        } else if track.offlineASRFailure != nil {
                            Text(copy("meeting.audioTrack.offlineFailed", korean: "오프라인 전사 실패 · 이전 유효 전사를 유지합니다.",
                                english: "Offline transcription failed. The previous valid transcript is retained."))
                                .font(.caption).foregroundStyle(AppTheme.warning)
                        } else if track.status == .finalizingTranscript {
                            ProgressView(copy("meeting.audioTrack.finalizing", korean: "이 트랙의 전사를 확정하는 중", english: "Finalizing this track's transcript"))
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("meeting.audioTrack.row.\(track.meetingID)")
                .listRowInsets(EdgeInsets(top: AppTheme.Spacing.compact, leading: contentInset,
                    bottom: AppTheme.Spacing.compact, trailing: contentInset))
            }
            if tracks.isEmpty {
                Text(copy("meeting.audioTrack.missing", korean: "이 회의의 저장된 트랙을 찾지 못했습니다.", english: "No saved tracks were found for this meeting."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func preparePresentation() async {
        timeline = MeetingConversationTimeline.saved(tracks, groupID: meeting.meetingID)
        sourceNames = Dictionary(tracks.map { ($0.meetingID, $0.audioTrackDisplayName) }, uniquingKeysWith: { first, _ in first })
        speakerProfiles = Dictionary(tracks.map { track in
            let profiles = track.diarization?.profiles ?? []
            let attribution = MeetingTranscriptAttribution(meetingID: track.meetingID,
                result: track.result ?? MeetingResult(), profiles: profiles)
            let resolved = attribution.applyingNames(to: profiles)
            return (track.meetingID, Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        }, uniquingKeysWith: { first, _ in first })
        isPreparing = true
        preparationError = nil
        defer { if !Task.isCancelled { isPreparing = false } }
        let plan: MeetingGroupAudioPlaybackPlan
        do {
            plan = try MeetingGroupAudioPlaybackPlan.make(tracks: tracks, groupID: meeting.meetingID)
        } catch {
            playbackTask?.cancel()
            playbackTask = nil
            player.stop()
            playbackPlan = nil
            waveform = nil
            preparationError = MeetingAudioPlaybackController.userFacingErrorMessage(error, language: .current)
            return
        }
        do {
            if playbackPlan != plan {
                playbackTask?.cancel()
                playbackTask = nil
                player.stop()
                playbackPlan = plan
                waveform = nil
                waveformError = nil
            }
            guard waveform == nil else { return }
            let generation = Task.detached(priority: .utility) { try MeetingWaveformGenerator.generate(plan: plan) }
            let generated = try await withTaskCancellationHandler {
                try await generation.value
            } onCancel: { generation.cancel() }
            guard !Task.isCancelled else { return }
            waveform = generated
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            waveformError = MeetingAudioPlaybackController.userFacingErrorMessage(error, language: .current)
        }
    }

    private func totalMilliseconds(_ plan: MeetingGroupAudioPlaybackPlan) -> Int64 {
        MeetingAudioPlaybackController.milliseconds(forLogicalSample: plan.totalSamples, sampleRate: plan.sampleRate)
    }

    private func togglePlayback(_ plan: MeetingGroupAudioPlaybackPlan) {
        if player.isPlaying { player.pause() }
        else {
            guard !player.isPreparingPlayback else { return }
            playbackTask?.cancel()
            playbackTask = Task {
                do {
                    try Task.checkCancellation()
                    try await player.play(plan: plan)
                } catch is CancellationError {
                } catch { player.report(error) }
            }
        }
    }

    private func seek(to row: MeetingConversationTimeline.Row) {
        guard let plan = playbackPlan, let start = row.startSample,
              plan.totalSamples > 0, plan.sources.contains(where: { $0.trackID == row.id.trackID }) else { return }
        player.seek(toProgress: Double(start) / Double(plan.totalSamples), totalMilliseconds: totalMilliseconds(plan))
        if !player.isPlaying, !player.isPreparingPlayback { togglePlayback(plan) }
    }

    private var activeRowID: MeetingConversationTimeline.Row.ID? {
        guard player.isPlaying || player.isPaused else { return nil }
        let sample = player.playbackMilliseconds * (MeetingMediaTimeline.sampleRate / 1_000)
        var lower = 0
        var upper = timeline.rows.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if (timeline.rows[middle].startSample ?? Int64.max) <= sample { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower > 0, timeline.rows[lower - 1].endSample.map({ sample < $0 }) == true else { return nil }
        return timeline.rows[lower - 1].id
    }

    private var downloadUnavailable: Bool {
        isExporting || audioDownload != nil || settingsAudioDownload != nil
    }

    private func allSourcesDownloadButton(fromSettings: Bool) -> some View {
        Button(MeetingLanguageCopy.text("meeting.manage.downloadAll", "Download all original sources (ZIP)")) {
            prepareDownload(fromSettings: fromSettings)
        }
        .accessibilityIdentifier("meeting.download.all")
        .disabled(downloadUnavailable || tracks.isEmpty)
    }

    @ViewBuilder private func sourceDownloadButtons(sourceID: String, fromSettings: Bool) -> some View {
        Button(MeetingLanguageCopy.text("meeting.manage.downloadOriginal", "Download original recording (ZIP)")) {
            prepareDownload(sourceID: sourceID, fromSettings: fromSettings)
        }
        .accessibilityIdentifier("meeting.download.source.\(sourceID).original")
        .disabled(downloadUnavailable)
        Button(MeetingLanguageCopy.text("meeting.manage.downloadWAV", "Download audio (WAV)")) {
            prepareDownload(sourceID: sourceID, format: .wav, fromSettings: fromSettings)
        }
        .accessibilityIdentifier("meeting.download.source.\(sourceID).wav")
        .disabled(downloadUnavailable)
    }

    private func prepareDownload(sourceID: String? = nil, format: MeetingAudioDownloadFormat = .original,
                                 fromSettings: Bool) {
        guard !downloadUnavailable else { return }
        isExporting = true
        exportError = nil
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let download = try await MeetingAudioDownload.prepare(record: meeting, in: context,
                    sourceID: sourceID, format: format)
                if fromSettings { settingsAudioDownload = download }
                else { audioDownload = download }
            } catch is CancellationError {
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func duration(_ samples: Int64) -> String {
        let seconds = samples / MeetingMediaTimeline.sampleRate
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    private func localDuration(_ milliseconds: Int64) -> String {
        let seconds = milliseconds / 1_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(key, defaultValue: AppLanguage.current == .english ? english : korean,
                              language: .current, comment: "Source-isolated meeting track navigation and export.")
    }
}

private extension MeetingTrackGroupDetailView {
    var summaryLanguage: String {
        MeetingSummaryLanguages.requestedLanguageTag(sourceLanguageTag: meeting.processingSourceLanguageTag,
            savedSummaryLanguageTag: meeting.summaryLanguageTag)
    }


    var processingSettings: some View {
        NavigationStack {
            Form {
                Section(MeetingLanguageCopy.text("meeting.document.summary", "Summary")) {
                    if !MeetingSummaryLanguages.available.isEmpty {
                        MeetingLanguagePicker(title: MeetingLanguageCopy.summaryTitle,
                            selection: Binding(get: { summaryLanguage }, set: { value in saveSummarySettings { meeting.summaryLanguageTag = value } }),
                            options: MeetingSummaryLanguages.available, identifier: "meeting.detail.summaryLanguage")
                    } else {
                        LabeledContent(MeetingLanguageCopy.summaryTitle, value: MeetingLanguageOption(id: summaryLanguage).displayName(locale: AppLanguage.current.locale))
                    }
                    MeetingSummaryFormatControls(
                        format: Binding(get: { meeting.summaryFormat }, set: { value in saveSummarySettings { meeting.summaryFormat = value } }),
                        instructions: $customInstructionsDraft)
                    Text(MeetingLanguageCopy.text("meeting.group.summaryScope", "Regenerate one summary from all source transcripts. It does not retranscribe audio or change individual source summaries. Your existing summary stays available unless generation succeeds."))
                        .font(.caption).foregroundStyle(.secondary)
                    MeetingSummaryEntry(isProcessing: false) {
                        guard commitCustomInstructions() else { return }
                        showingSettingsSummaryModels = true
                    }
                    .disabled(meeting.summaryFormat == .custom && customInstructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section(MeetingLanguageCopy.text("meeting.settings.transcription", "Transcription")) {
                    Text(MeetingLanguageCopy.text("meeting.group.sourceSettings", "Source language and retranscription are managed separately for every recording. Open a source, then its meeting settings to choose a language and explicitly retranscribe. No recording is changed by the group settings."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(tracks) { track in
                        NavigationLink { MeetingDetailView(meeting: track) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.audioTrackDisplayName)
                                Text(MeetingLanguageOption(id: track.languageTag).displayName(locale: AppLanguage.current.locale))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("meeting.settings.source.\(track.meetingID)")
                    }
                }
                Section(MeetingLanguageCopy.text("meeting.settings.recordings", "Audio recordings")) {
                    ForEach(tracks) { track in
                        HStack {
                            NavigationLink { MeetingDetailView(meeting: track) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.audioTrackDisplayName)
                                    Text(track.createdAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("meeting.settings.recording.\(track.meetingID)")
                            Menu {
                                sourceDownloadButtons(sourceID: track.meetingID, fromSettings: true)
                            } label: {
                                Image(systemName: "arrow.down.to.line")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(track.audioTrackDisplayName) · \(MeetingLanguageCopy.text("meeting.manage.download", "Download audio"))")
                            .accessibilityIdentifier("meeting.download.source.\(track.meetingID).menu")
                            .disabled(downloadUnavailable)
                        }
                    }
                    allSourcesDownloadButton(fromSettings: true)
                    if isExporting { ProgressView(MeetingLanguageCopy.text("meeting.settings.exporting", "Preparing recording download")) }
                }
                if let exportError {
                    Section { Text(exportError).foregroundStyle(AppTheme.destructive) }
                }
                if let summaryError {
                    Section { Text(summaryError).foregroundStyle(AppTheme.destructive).accessibilityIdentifier("meeting.settings.error") }
                }
            }
            .navigationTitle(MeetingLanguageCopy.text("meeting.settings.title", "Meeting settings"))
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(MeetingLanguageCopy.text("meeting.settings.done", "Done")) {
                    if commitCustomInstructions() { showingSettings = false }
                }
            } }
        }
        .meetingAudioDownload($settingsAudioDownload) { error in
            exportError = error.localizedDescription
        }
        .sheet(isPresented: $showingSettingsSummaryModels) {
            MeetingSummaryView(meeting: meeting) {
                summaryUpdatedAt = meeting.updatedAt
                documentTab = .summary
                showingSettings = false
            }
        }
    }

    @discardableResult
    func commitCustomInstructions() -> Bool {
        guard customInstructionsDraft != customInstructionsOriginal else { return true }
        do {
            try MeetingRecordCommitter.persist(record: meeting, save: { try context.save() }) {
                meeting.summaryCustomInstructions = customInstructionsDraft
                meeting.updatedAt = Date()
            }
            customInstructionsOriginal = customInstructionsDraft
            return true
        } catch {
            summaryError = error.localizedDescription
            return false
        }
    }

    func saveSummarySettings(_ mutate: () -> Void) {
        do {
            try MeetingRecordCommitter.persist(record: meeting, save: { try context.save() }) {
                mutate()
                meeting.updatedAt = Date()
            }
        } catch { summaryError = error.localizedDescription }
    }


    func openCitation(_ citation: MeetingSummaryCitation) {
        guard let track = tracks.first(where: { $0.meetingID == citation.trackID }),
              let result = track.result, result.transcriptRevision == citation.transcriptRevision,
              let segment = result.segments.first(where: { $0.id == citation.segmentID || $0.stableLineageID == citation.segmentID }) else {
            summaryError = MeetingLanguageCopy.text("meeting.summary.citationUnavailable", "This transcript source has changed or is unavailable. Regenerate the summary to refresh its references.")
            return
        }
        if player.isPlaying { player.pause() }
        documentTab = .transcript
        let rowID = MeetingConversationTimeline.Row.ID(trackID: track.meetingID, localID: segment.stableLineageID)
        if timeline.rows.contains(where: { $0.id == rowID }) {
            citationTarget = rowID
            citationRequest = UUID()
        } else {
            sourceDestination = CitationDestination(track: track, citation: citation)
        }
    }
}
