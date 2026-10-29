import SwiftUI
import Combine
import SwiftData

/// Derived parent-time playback and conversation, with original source records retained.
struct MeetingTrackGroupDetailView: View {
    let meeting: MeetingRecord
    @Query private var tracks: [MeetingRecord]
    @State private var isExporting = false
    @State private var archiveURL: URL?
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
            conversationSections
            if meeting.result?.actionDrafts.isEmpty == false {
                MeetingActionDraftSection(record: meeting,
                    sourceLabel: copy("meeting.actions.conversation", korean: "전체 대화 맥락", english: "Whole-conversation context"))
            }
            ForEach(tracks) { track in
                MeetingActionDraftSection(record: track, sourceLabel: track.audioTrackDisplayName)
            }
            sourceSection
        }
        .appListStyle()
        .navigationTitle("회의 기록")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { exportTracks() } label: {
                    Label(copy("meeting.audioTrack.exportAll", korean: "모든 트랙 원본 내보내기", english: "Export all original tracks"), systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("meeting.audioTrack.exportAll")
                .disabled(isExporting || tracks.isEmpty)
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
        .sheet(isPresented: Binding(get: { archiveURL != nil }, set: { if !$0 { archiveURL = nil } })) {
            if let archiveURL { ActivityShareSheet(items: [archiveURL]) }
        }
        .alert(copy("meeting.audioTrack.exportErrorTitle", korean: "음성 트랙 내보내기 실패", english: "Audio track export failed"),
               isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
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
                    .onChange(of: activeRowID) { _, id in
                        guard let id else { return }
                        if reduceMotion { proxy.scrollTo(id, anchor: .center) }
                        else {
                            withAnimation(AppTheme.motion(reduceMotion: reduceMotion)) {
                                proxy.scrollTo(id, anchor: .center)
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
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                let startsTurn = timeline.speakerPresentation[row.id]?.startsTurn ?? true
                conversationRow(row, startsTurn: startsTurn)
                    .padding(.top, row.id != rows.first?.id && startsTurn ? AppTheme.Spacing.compact : 0)
                    .id(row.id)
            }
        }
        .padding(.vertical, AppTheme.Spacing.compact)
    }



    private func conversationRow(_ row: MeetingConversationTimeline.Row, startsTurn: Bool) -> some View {
        let sample = player.playbackMilliseconds * (MeetingMediaTimeline.sampleRate / 1_000)
        let isActive = (player.isPlaying || player.isPaused)
            && row.startSample.map { $0 <= sample } == true
            && row.endSample.map { sample < $0 } == true
        let timeRange = row.startSample.flatMap { start in row.endSample.map { "\(duration(start))–\(duration($0))" } }
            ?? "\(localDuration(row.localStartMs))–\(localDuration(row.localEndMs))"
        let presentation = timeline.speakerPresentation[row.id]
        let speakerLabel = MeetingSpeakerLabelFormatter.label(for: presentation?.speakerIDs ?? row.speakerIDs,
            profiles: speakerProfiles[row.id.trackID] ?? [:],
            state: presentation?.isInherited == true ? .provisional : .final,
            kind: presentation?.kind ?? .speaker)
        return VStack(alignment: .leading, spacing: 4) {
            if startsTurn {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact) {
                    Text(speakerLabel)
                        .font(.caption).foregroundStyle(AppTheme.secondaryText)
                    Spacer(minLength: AppTheme.Spacing.compact)
                    Text(timeRange).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(row.text).fontWeight(isActive ? .semibold : .regular).textSelection(.enabled)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact) {
                    Text(row.text).fontWeight(isActive ? .semibold : .regular).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(timeRange).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.horizontal, AppTheme.Spacing.item)
        .background(isActive ? AppTheme.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { seek(to: row) }
        .accessibilityElement(children: .combine)
        .accessibilityValue(MeetingSpeakerLabelFormatter.accessibilityValue(
            speakerLabel: speakerLabel, source: sourceNames[row.id.trackID],
            inherited: presentation?.isInherited == true))
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : .isButton)
        .accessibilityIdentifier("meeting.conversation.saved.\(row.id.trackID).\(row.id.localID)")
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
            if isExporting { ProgressView("음성을 내보내는 중").font(.caption) }
        }
    }

    private var sourceSection: some View {
        Section(copy("meeting.audioTrack.section", korean: "음성 트랙", english: "Audio tracks")) {
            ForEach(tracks) { track in
                NavigationLink { MeetingDetailView(meeting: track) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(track.audioTrackDisplayName).font(.subheadline.weight(.semibold))
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

    private func exportTracks() {
        let id = meeting.meetingID
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let payloads = try tracks.map { record -> MeetingAudioTrackExport in
                    guard let manifest = record.audioManifest else { throw MeetingAudioExporter.ExportError.format }
                    return MeetingAudioTrackExport(meetingID: record.meetingID, sourceKind: record.audioTrackKind ?? .legacyMixed,
                        sourceLabel: record.audioTrackSourceLabel, sessionStartSample: record.audioTrackStartSample, manifest: manifest)
                }
                archiveURL = try await Task.detached(priority: .userInitiated) {
                    try MeetingAudioExporter.exportTrackArchive(meetingID: id, tracks: payloads)
                }.value
            } catch {
                exportError = copy("meeting.audioTrack.exportFailed", korean: "원본 음성 트랙을 내보내지 못했습니다. 저장된 원음은 유지됩니다.",
                    english: "The original audio tracks could not be exported. Saved audio is unchanged.")
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
