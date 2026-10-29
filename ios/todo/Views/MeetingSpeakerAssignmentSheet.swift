import SwiftUI

/// Speaker presentation derived once per record change, not per frame.
struct MeetingSpeakerDisplay: Equatable {
    var profiles: [String: MeetingSpeakerProfile] = [:]
    var sortedProfiles: [MeetingSpeakerProfile] = []
    /// Unlabeled segments without word timing that contain several speakers.
    var mixedSegmentIDs: Set<String> = []
    var statusText: String?
    var attribution: MeetingTranscriptAttribution?
    var segments: [MeetingSegment] = []
    var continuity: [MeetingConversationTimeline.Row.ID: MeetingSpeakerContinuity.Presentation] = [:]

    init() {}

    init(record: MeetingRecord) {
        let result = record.result
        segments = result?.segments ?? []
        continuity = MeetingConversationTimeline.individual(record).speakerPresentation
        attribution = MeetingTranscriptAttribution(meetingID: record.meetingID, result: result ?? MeetingResult(),
            profiles: record.diarization?.profiles ?? [])
        guard let payload = record.diarization else {
            if record.diarizationData != nil {
                statusText = MeetingDiarizationPostProcessor.Outcome.unreadablePayload.userMessage
            }
            return
        }
        let resolved = attribution?.applyingNames(to: payload.profiles) ?? payload.profiles
        profiles = Dictionary(resolved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sortedProfiles = resolved.sorted { ($0.ordinal, $0.id) < ($1.ordinal, $1.id) }
        if let result = record.result, !payload.intervals.isEmpty {
            let perMillisecond = MeetingSpeakerAlignment.samplesPerMillisecond
            for segment in result.segments where segment.speakerIDs.isEmpty && (segment.timedRuns?.isEmpty ?? true) {
                let start = segment.startMs * perMillisecond
                let end = segment.endMs * perMillisecond
                var overlap: [String: Int64] = [:]
                for interval in payload.intervals where interval.startSample < end && interval.endSample > start {
                    overlap[interval.speakerID, default: 0] += min(end, interval.endSample) - max(start, interval.startSample)
                }
                if overlap.values.filter({ $0 >= 200 * perMillisecond }).count > 1 { mixedSegmentIDs.insert(segment.id) }
            }
        }
        let english = AppLanguage.current == .english
        switch payload.status {
        case .completed:
            statusText = String(
                format: AppLanguage.localized(
                    "meeting.diarization.completed",
                    defaultValue: english ? "Speakers detected on this device: %lld" : "기기에서 확인한 화자: %lld명",
                    language: .current, comment: "Completed saved-audio speaker analysis with the detected speaker count."
                ),
                locale: AppLanguage.current.locale,
                Int64(Set(payload.intervals.map(\.speakerID)).count)
            )
        case .finalizing, .interrupted:
            statusText = AppLanguage.localized(
                "meeting.diarization.interruptedState",
                defaultValue: english
                    ? "Speaker detection was interrupted. Run it again from the menu."
                    : "화자 분석이 중단되었습니다. 메뉴에서 다시 분석하세요.",
                language: .current, comment: "Saved-audio speaker analysis was interrupted."
            )
        case .failed:
            statusText = AppLanguage.localized(
                "meeting.diarization.failedState",
                defaultValue: english
                    ? "Speaker detection failed. Previous speaker results were kept; try again from the menu."
                    : "화자 분석에 실패했습니다. 이전 결과는 유지되며 메뉴에서 다시 시도할 수 있습니다.",
                language: .current, comment: "Saved-audio speaker analysis failed."
            )
        case .modelUnavailable:
            statusText = AppLanguage.localized(
                "meeting.diarization.modelUnavailableState",
                defaultValue: english
                    ? "Install the speaker model in Settings → Meeting, then detect speakers again."
                    : "설정 → 회의에서 화자 모델을 설치한 뒤 화자를 다시 분석하세요.",
                language: .current, comment: "Saved-audio speaker analysis skipped without an installed model."
            )
        case .notProcessed, .runningLive:
            statusText = nil
        }
    }
}

/// Choose, rename or add speakers for one transcript segment. Edits never
/// change transcript text or its revision.
struct MeetingSpeakerAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let segment: MeetingSegment
    let profiles: [MeetingSpeakerProfile]
    let onAssign: ([String]) -> Void
    let onRename: (String, String) -> Void
    let onCreate: (String) -> Void

    @State private var selection: Set<String>
    @State private var renamed: [String: String] = [:]
    @State private var newSpeakerName = ""
    @State private var renameTarget: MeetingSpeakerProfile?
    @State private var renameDraft = ""

    init(
        segment: MeetingSegment,
        profiles: [MeetingSpeakerProfile],
        onAssign: @escaping ([String]) -> Void,
        onRename: @escaping (String, String) -> Void,
        onCreate: @escaping (String) -> Void
    ) {
        self.segment = segment
        self.profiles = profiles
        self.onAssign = onAssign
        self.onRename = onRename
        self.onCreate = onCreate
        _selection = State(initialValue: Set(segment.speakerIDs))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(segment.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Section(copy("meeting.speaker.sheet.assigned", korean: "이 구간의 화자", english: "Speakers in this segment")) {
                    if profiles.isEmpty {
                        Text(copy(
                            "meeting.speaker.sheet.empty",
                            korean: "아직 확인된 화자가 없습니다. 아래에서 새 화자를 추가하세요.",
                            english: "No speakers yet. Add a new speaker below."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(profiles, id: \.id) { profile in
                        Button {
                            if selection.contains(profile.id) { selection.remove(profile.id) } else { selection.insert(profile.id) }
                        } label: {
                            HStack {
                                Text(name(of: profile))
                                Spacer()
                                if selection.contains(profile.id) {
                                    Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                                }
                            }
                        }
                        .accessibilityAddTraits(selection.contains(profile.id) ? .isSelected : [])
                        .swipeActions { renameButton(profile) }
                        .contextMenu { renameButton(profile) }
                    }
                }
                Section(copy("meeting.speaker.sheet.new", korean: "새 화자", english: "New speaker")) {
                    TextField(copy("meeting.speaker.sheet.name", korean: "이름", english: "Name"), text: $newSpeakerName)
                    Button(copy("meeting.speaker.sheet.create", korean: "새 화자로 지정", english: "Assign to a new speaker")) {
                        onCreate(newSpeakerName)
                        dismiss()
                    }
                    .disabled(newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .appListStyle()
            .navigationTitle(copy("meeting.speaker.sheet.title", korean: "화자 수정", english: "Edit Speakers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy("action.cancel", korean: "취소", english: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copy("action.save", korean: "저장", english: "Save")) {
                        onAssign(selection.sorted())
                        dismiss()
                    }
                }
            }
            .alert(
                copy("meeting.speaker.sheet.rename", korean: "화자 이름 변경", english: "Rename Speaker"),
                isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }),
                presenting: renameTarget
            ) { profile in
                TextField(copy("meeting.speaker.sheet.name", korean: "이름", english: "Name"), text: $renameDraft)
                Button(copy("action.save", korean: "저장", english: "Save")) {
                    let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    onRename(profile.id, name)
                    renamed[profile.id] = name
                }
                Button(copy("action.cancel", korean: "취소", english: "Cancel"), role: .cancel) {}
            }
        }
    }

    private func renameButton(_ profile: MeetingSpeakerProfile) -> some View {
        Button(copy("meeting.speaker.sheet.renameAction", korean: "이름 변경", english: "Rename")) {
            renameDraft = renamed[profile.id] ?? profile.displayName ?? ""
            renameTarget = profile
        }
    }

    private func name(of profile: MeetingSpeakerProfile) -> String {
        if let name = renamed[profile.id] { return name }
        return MeetingSpeakerLabelFormatter.name(for: profile.id, profiles: [profile.id: profile])
    }

    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: AppLanguage.current == .english ? english : korean,
            language: .current,
            comment: "Meeting speaker editing copy."
        )
    }
}
