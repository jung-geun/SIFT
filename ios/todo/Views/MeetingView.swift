import SwiftUI
import SwiftData

struct MeetingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.userVocabulary) private var userVocabulary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \MeetingRecord.updatedAt, order: .reverse) private var meetings: [MeetingRecord]
    @ObservedObject private var settingsStore = SettingsStore.shared
    @StateObject private var coordinator = MeetingCaptureCoordinator()
    @State private var languageTag = AppLanguage.current == .english ? "en-US" : "ko-KR"
    @State private var consentAccepted = false
    @State private var showingDisclosure = false
    @State private var currentMeetingID: String?
    @State private var showingConsentWithdrawal = false
    @State private var helpTopic: MeetingHelpTopic?
    @State private var voiceProcessingEnabled = SettingsStore.shared.effectiveMeetingVoiceProcessingEnabled
    @State private var autoRefineEnabled = SettingsStore.shared.meetingAutoRefineEnabled
    @StateObject private var processingReporter = MeetingProcessingReporter()
    @ScaledMetric(relativeTo: .body) private var liveTranscriptViewportHeight = 220

    var body: some View {
        NavigationStack {
            List {
                Section(copy("meeting.section.new", fallback: "새 회의")) {
                    Picker(copy("meeting.language.label", fallback: "언어"), selection: $languageTag) {
                        Text(copy("meeting.language.korean", fallback: "한국어")).tag("ko-KR")
                        Text(copy("meeting.language.english", fallback: "영어")).tag("en-US")
                    }

                    .pickerStyle(.segmented)

                    settingToggle(
                        title: "녹음 고지 및 동의 확인",
                        isOn: $consentAccepted,
                        helpTopic: .recordingConsent
                    )

                    if settingsStore.betaFeaturesEnabled {
                        settingToggle(
                            title: "음성 노이즈 감소",
                            isOn: $voiceProcessingEnabled,
                            helpTopic: .voiceProcessing,
                            isDisabled: coordinator.status == .recording || coordinator.status == .paused
                        )
                        .onChange(of: voiceProcessingEnabled) { _, enabled in
                            SettingsStore.shared.meetingVoiceProcessingEnabled = enabled
                        }
                    }

                    settingToggle(
                        title: "전사 자동 교정",
                        isOn: $autoRefineEnabled,
                        helpTopic: .autoRefine
                    )
                    .onChange(of: autoRefineEnabled) { _, enabled in
                        SettingsStore.shared.meetingAutoRefineEnabled = enabled
                    }

                    captureControls
                }

                if processingReporter.phase != .idle {
                    Section(copy("meeting.section.processing", fallback: "회의 정리")) {
                        MeetingProcessingStatusView(phase: processingReporter.phase)
                    }
                }

                if coordinator.status == .recording || coordinator.status == .paused || coordinator.status == .stopping {
                    Section(copy("meeting.section.recording", fallback: "녹음 중")) {
                        HStack {
                            Circle().fill(AppTheme.destructive).frame(width: 10, height: 10)
                            Text(copy("meeting.transcript.temporary", fallback: "임시 전사"))
                            Spacer()
                            Text(duration(coordinator.elapsedMediaMs)).monospacedDigit()
                        }
                        if coordinator.recordedAudioSamples > 0 {
                            Text(String(
                                format: copy(
                                    "meeting.capture.recordingProgress",
                                    fallback: "원본 녹음 저장 중 · FLAC · %@ · part %lld",
                                    comment: "Meeting recording progress with elapsed duration and part number."
                                ),
                                locale: AppLanguage.current.locale,
                                duration(coordinator.recordedAudioSamples * 1_000 / MeetingMediaTimeline.sampleRate),
                                Int64(coordinator.recordedAudioPartCount)
                            ))
                                .font(.caption)
                                .foregroundStyle(AppTheme.success)
                        } else {
                            Text(copy("meeting.capture.recordingPreparing", fallback: "원본 녹음 파일을 준비 중"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let warning = coordinator.liveTranscriptionWarning {
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(AppTheme.warning)
                        }
                        if !coordinator.liveTranscriptEntries.isEmpty {
                            ScrollViewReader { proxy in
                                ScrollView(.vertical) {
                                    LazyVStack(alignment: .leading, spacing: 12) {
                                        ForEach(coordinator.liveTranscriptEntries) { entry in
                                            let speakerLabel = entry.speakerIDs.isEmpty
                                                ? copy("meeting.speaker.unknown", fallback: "화자 미확정")
                                                : entry.speakerIDs.joined(separator: ", ")
                                            let speakerColor: Color = entry.speakerIDs.isEmpty ? .secondary : AppTheme.accent
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: 6) {
                                                    Text("\(duration(entry.startMs))–\(duration(entry.endMs))")
                                                        .font(.caption.monospacedDigit())
                                                        .foregroundStyle(.secondary)
                                                    Text(speakerLabel)
                                                        .font(.caption)
                                                        .foregroundStyle(speakerColor)
                                                }
                                                Text(entry.text)
                                            }
                                            .id(entry.id)
                                        }
                                    }
                                }
                                .frame(height: min(liveTranscriptViewportHeight, 320))
                                .onChange(of: coordinator.liveTranscriptEntries.last) { _, latest in
                                    guard let latest else { return }
                                    if reduceMotion {
                                        proxy.scrollTo(latest.id, anchor: .bottom)
                                    } else {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            proxy.scrollTo(latest.id, anchor: .bottom)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if !meetings.isEmpty {
                    Section(copy("meeting.section.deviceMeetings", fallback: "이 기기의 회의")) {
                        ForEach(meetings) { meeting in
                            NavigationLink {
                                MeetingDetailView(meeting: meeting)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meeting.result?.title.isEmpty == false ? meeting.result!.title : copy("meeting.title.untitled", fallback: "회의"))
                                    Text(meeting.updatedAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: deleteMeetings)
                    }
                }
            }
            .navigationTitle(copy("meeting.navigationTitle", fallback: "회의"))
            .onChange(of: consentAccepted) { _, accepted in
                guard !accepted,
                      coordinator.status == .recording || coordinator.status == .paused
                else { return }
                showingConsentWithdrawal = true
            }
            .onChange(of: settingsStore.betaFeaturesEnabled) { _, _ in
                voiceProcessingEnabled = settingsStore.effectiveMeetingVoiceProcessingEnabled
            }
            .alert(copy("meeting.alert.recordingNotice.title", fallback: "녹음 안내"), isPresented: $showingDisclosure) {
                Button(copy("취소", fallback: "취소"), role: .cancel) {}
                Button(copy("녹음 시작", fallback: "녹음 시작")) { startRecording() }
            } message: {
                Text(copy(
                    "meeting.alert.recordingNotice.message",
                    fallback: "다른 사람의 음성이 녹음됩니다. 시작 전에 필요한 고지와 동의를 확인하세요. 이 회의는 기기 내 처리로 시작합니다."
                ))
            }
            .alert(item: $helpTopic) { topic in
                Alert(
                    title: Text(topic.title),
                    message: Text(topic.message),
                    dismissButton: .default(Text(copy("확인", fallback: "확인")))
                )
            }
            .alert(copy("meeting.alert.consentWithdrawal.title", fallback: "동의 철회"), isPresented: $showingConsentWithdrawal) {
                Button(copy("meeting.action.continueRecording", fallback: "계속 녹음"), role: .cancel) {
                    consentAccepted = true
                }
                Button(copy("meeting.action.stopRecording", fallback: "녹음 중지")) {
                    Task { await stopRecording() }
                }
            } message: {
                Text(copy(
                    "meeting.alert.consentWithdrawal.message",
                    fallback: "동의를 철회하면 녹음과 실시간 전사가 중지됩니다. 지금까지 기록된 회의는 보존됩니다."
                ))
            }
            .alert(copy("meeting.alert.recordingError.title", fallback: "녹음 오류"), isPresented: Binding(get: { coordinator.failure != nil }, set: { if !$0 { coordinator.dismissFailure() } })) {
                Button(copy("확인", fallback: "확인"), role: .cancel) {}
            } message: {
                Text(coordinator.failure ?? copy("meeting.error.unknown", fallback: "알 수 없는 오류"))
            }
        }
        .task { persistPendingCaptureRecoveries() }
    }
    private func copy(_ key: String, fallback: String, comment: String = "Meeting user-facing copy.") -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: comment)
    }


    private func settingToggle(
        title: String,
        isOn: Binding<Bool>,
        helpTopic: MeetingHelpTopic,
        isDisabled: Bool = false
    ) -> some View {
        let localizedTitle: String = {
            let key: String
            switch helpTopic {
            case .recordingConsent: key = "meeting.setting.recordingConsent"
            case .voiceProcessing: key = "meeting.setting.voiceProcessing"
            case .autoRefine: key = "meeting.setting.autoRefine"
            }
            return AppLanguage.localized(key, defaultValue: title, language: .current, comment: "Meeting setting label.")
        }()
        return HStack(spacing: 8) {
            Text(localizedTitle)
            Button {
                self.helpTopic = helpTopic
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                String(
                    format: AppLanguage.localized(
                        "meeting.setting.explanation",
                        defaultValue: "%@ 설명",
                        language: .current,
                        comment: "Meeting setting explanation button."
                    ),
                    localizedTitle
                )
            )
            Spacer(minLength: 12)
            Toggle(localizedTitle, isOn: isOn)
                .labelsHidden()
                .disabled(isDisabled)
        }
    }

    @ViewBuilder private var captureControls: some View {
        switch coordinator.status {
        case .recording:
            Button(copy("meeting.action.pauseRecording", fallback: "일시 정지"), action: coordinator.pause)
            Button(copy("meeting.action.stopRecording", fallback: "녹음 종료")) { Task { await stopRecording() } }
                .tint(AppTheme.destructive)
        case .paused:
            Button(copy("meeting.action.continueRecording", fallback: "계속 녹음")) { try? coordinator.resume() }
            Button(copy("meeting.action.stopRecording", fallback: "녹음 종료")) { Task { await stopRecording() } }
                .tint(AppTheme.destructive)
        case .stopping, .finalizingTranscript, .extractingActions:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: coordinator.finalizationProgress)
                Text(coordinator.finalizationDetail.isEmpty
                     ? copy("meeting.processing.finalizing", fallback: "회의를 정리하는 중")
                     : coordinator.finalizationDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        default:
            Button(copy("녹음 시작", fallback: "녹음 시작")) { showingDisclosure = true }
                .disabled(!consentAccepted)
        }
    }

    private func startRecording() {
        let id = UUID().uuidString.lowercased()
        currentMeetingID = id
        processingReporter.reset()
        if let service = userVocabulary?.service {
            coordinator.setVocabularySnapshotProvider { await service.snapshot() }
        }
        Task {
            do {
                try await coordinator.start(meetingID: id, languageTag: languageTag)
            } catch {
                coordinator.reportFailure(error)
            }
        }
    }

    private func stopRecording() async {
        let record: MeetingRecord
        do {
            let artifact = try await coordinator.stopCapture()
            guard let id = currentMeetingID else { return }
            let provisional = MeetingProvisionalResultBuilder.make(
                meetingID: id,
                entries: coordinator.liveTranscriptEntries,
                elapsedMediaMs: coordinator.elapsedMediaMs
            )
            record = try MeetingInitialCapturePersister.persist(
                meetingID: id,
                languageTag: languageTag,
                timezoneIdentifier: TimeZone.current.identifier,
                provisionalResult: provisional,
                manifest: artifact.audioManifest,
                in: modelContext
            )
        } catch {
            coordinator.failFinalization(error)
            return
        }

        do {
            try await coordinator.finalizeTranscript()
            let baseResult = MeetingProvisionalResultBuilder.make(
                meetingID: record.meetingID,
                entries: coordinator.liveTranscriptEntries,
                elapsedMediaMs: coordinator.elapsedMediaMs
            )
            try MeetingRecordCommitter.persist(
                record: record,
                save: { try modelContext.save() },
                mutate: { try record.replaceTranscriptionBase(baseResult, status: .ready) }
            )
        } catch {
            coordinator.failFinalization(error)
            do {
                try MeetingFinalizationFailurePersister.persist(
                    record: record,
                    in: modelContext
                )
                try MeetingCaptureRecoveryStore.remove(meetingID: record.meetingID)
                coordinator.acknowledgeRecoveredCapture(meetingID: record.meetingID)
            } catch {
                coordinator.reportFailure(copy("meeting.error.saveRecord", fallback: "회의 기록 저장에 실패했습니다. 저장 재시도"))
            }
            currentMeetingID = nil
            consentAccepted = false
            return
        }

        coordinator.completeFinalization()
        do {
            try MeetingCaptureRecoveryStore.remove(meetingID: record.meetingID)
            coordinator.acknowledgeRecoveredCapture(meetingID: record.meetingID)
        } catch {
            coordinator.reportFailure(copy("meeting.error.cleanupRecovery", fallback: "회의 복구 표시를 정리하지 못했습니다. 다음 실행에서 다시 확인합니다."))
        }

        do {
            _ = try await MeetingPostProcessor.refineAndAnalyze(
                record: record,
                context: modelContext,
                allowRefine: SettingsStore.shared.meetingAutoRefineEnabled,
                allowModelLoad: false,
                reporter: processingReporter,
                dependencies: makeVocabularyMeetingDependencies(userVocabulary?.service)
            )
        } catch {
            coordinator.reportFailure(
                copy(
                    "meeting.error.processingSave",
                    fallback: "AI 검수 또는 요약을 저장하지 못했습니다. 회의 상단의 다시 정리 메뉴에서 다시 시도할 수 있습니다."
                )
            )
        }
        currentMeetingID = nil
        consentAccepted = false
    }

    private func persistPendingCaptureRecoveries() {
        let scan = MeetingCaptureRecoveryStore.scan()
        for recovery in scan.recoveries {
            guard recovery.meetingID != coordinator.recoveredCapture?.meetingID else { continue }
            do {
                try MeetingCaptureRecoveryPersister.persist(recovery, in: modelContext)
                coordinator.acknowledgeRecoveredCapture(meetingID: recovery.meetingID)
            } catch {
                coordinator.reportFailure(copy("meeting.error.recoverySave", fallback: "복구한 회의 저장에 실패했습니다. 저장 재시도"))
            }
        }
        if !scan.unreadableMarkerNames.isEmpty {
            coordinator.reportFailure(copy("meeting.error.unreadableRecovery", fallback: "복구할 수 없는 회의 녹음이 있어 원본 파일을 보존했습니다."))
        }
    }

    private func deleteMeetings(at offsets: IndexSet) {
        let selected = offsets.map { meetings[$0] }
        Task {
            for meeting in selected {
                if currentMeetingID == meeting.meetingID {
                    await coordinator.cancel()
                }
                let directory = AppDataContainer.meetingDirectory()
                    .appendingPathComponent(meeting.meetingID, isDirectory: true)
                try? FileManager.default.removeItem(at: directory)
                modelContext.delete(meeting)
            }
            try? modelContext.save()
        }
    }

    private func duration(_ milliseconds: Int64) -> String {
        String(format: "%02lld:%02lld", milliseconds / 60_000, (milliseconds / 1_000) % 60)
    }
}

private enum MeetingHelpTopic: Identifiable {
    case recordingConsent
    case voiceProcessing
    case autoRefine

    var id: Self { self }

    var title: String {
        let key: String
        let fallback: String
        switch self {
        case .recordingConsent:
            key = "meeting.help.recordingConsent.title"; fallback = "녹음 고지 및 동의"
        case .voiceProcessing:
            key = "meeting.help.voiceProcessing.title"; fallback = "음성 노이즈 감소"
        case .autoRefine:
            key = "meeting.help.autoRefine.title"; fallback = "전사 자동 교정"
        }
        return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "Meeting setting help title.")
    }

    var message: String {
        let key: String
        let fallback: String
        switch self {
        case .recordingConsent:
            key = "meeting.help.recordingConsent.message"; fallback = "기본값은 기기 내 처리입니다. 녹음은 이 기기에만 저장되며, 선택한 항목만 할 일 검토함으로 추가됩니다."
        case .voiceProcessing:
            key = "meeting.help.voiceProcessing.message"; fallback = "베타 기능입니다. Apple 음성 처리(에코 제거·잡음 억제)를 적용합니다. 끄면 가공하지 않은 원본 입력으로 녹음합니다."
        case .autoRefine:
            key = "meeting.help.autoRefine.message"; fallback = "녹음 완료·재전사 후 온디바이스 AI(Apple Intelligence)로 전사의 오인식·오탈자를 자동 교정해 요약 품질을 높입니다. 끄면 원문을 그대로 요약합니다."
        }
        return AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: "Meeting setting help message.")
    }
}
