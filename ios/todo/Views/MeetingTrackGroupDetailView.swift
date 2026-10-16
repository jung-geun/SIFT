import SwiftUI
import SwiftData

/// Each destination owns playback, editing and reprocessing of one source only.
struct MeetingTrackGroupDetailView: View {
    let meeting: MeetingRecord
    @Query private var tracks: [MeetingRecord]
    @State private var isExporting = false
    @State private var archiveURL: URL?
    @State private var exportError: String?

    init(meeting: MeetingRecord) {
        self.meeting = meeting
        let parentID = meeting.meetingID
        _tracks = Query(filter: #Predicate<MeetingRecord> { $0.parentMeetingID == parentID },
                        sort: [SortDescriptor(\MeetingRecord.audioTrackStartSample), SortDescriptor(\MeetingRecord.createdAt)])
    }

    var body: some View {
        List {
            Section(copy("meeting.audioTrack.section", korean: "음성 트랙", english: "Audio tracks")) {
                Text(copy("meeting.audioTrack.groupExplanation", korean: "각 음성 소스의 원음·전사·화자를 따로 저장합니다. 트랙을 열어 재생·편집·재처리하세요.",
                          english: "Each source has its own original audio, transcript and speakers. Open a track to play, edit or reprocess it."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(tracks) { track in
                    NavigationLink {
                        MeetingDetailView(meeting: track)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(track.audioTrackDisplayName).font(.headline)
                            if let title = track.result?.title, !title.isEmpty { Text(title).font(.subheadline) }
                            if let manifest = track.audioManifest {
                                Text(String(format: copy("meeting.audioTrack.offsetDuration", korean: "회의 시작 +%@ · 길이 %@",
                                    english: "Starts at +%@ · duration %@"),
                                    duration(track.audioTrackStartSample), duration(manifest.totalSamples)))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
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
                    }
                    .accessibilityIdentifier("meeting.audioTrack.row.\(track.meetingID)")
                }
                if tracks.isEmpty {
                    Text(copy("meeting.audioTrack.missing", korean: "이 회의의 저장된 트랙을 찾지 못했습니다.", english: "No saved tracks were found for this meeting."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(copy("meeting.audioTrack.navigation", korean: "회의 음성 트랙", english: "Meeting audio tracks"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { exportTracks() } label: { Label(copy("meeting.audioTrack.exportAll", korean: "모든 트랙 원본 내보내기", english: "Export all original tracks"), systemImage: "square.and.arrow.up") }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("meeting.audioTrack.exportAll")
                    .disabled(isExporting || tracks.isEmpty)
            }
        }
        .sheet(isPresented: Binding(get: { archiveURL != nil }, set: { if !$0 { archiveURL = nil } })) {
            if let archiveURL { ActivityShareSheet(items: [archiveURL]) }
        }
        .alert(copy("meeting.audioTrack.exportErrorTitle", korean: "음성 트랙 내보내기 실패", english: "Audio track export failed"),
               isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button(copy("확인", korean: "확인", english: "OK"), role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
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

    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(key, defaultValue: AppLanguage.current == .english ? english : korean,
                              language: .current, comment: "Source-isolated meeting track navigation and export.")
    }
}
