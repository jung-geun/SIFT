import SwiftUI
import SwiftData

struct MeetingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.userVocabulary) private var userVocabulary
    @Query(filter: #Predicate<MeetingRecord> { $0.parentMeetingID == nil }, sort: \MeetingRecord.updatedAt, order: .reverse) private var meetings: [MeetingRecord]
    @StateObject private var coordinator = MeetingCaptureCoordinator()
    @State private var languageTag = AppLanguage.current.speechLanguageTag
    @State private var consentAccepted = false
    @State private var microphoneRequested = true
    @State private var appAudioRequested = false
    @State private var sourceChangeInProgress = false
    @State private var showingDisclosure = false
    @State private var currentMeetingID: String?
    @State private var pendingStartID: String?
    @State private var pendingStartTask: Task<Void, Never>?
    @State private var finalizingCaptureID: String?
    @State private var stopTasks: [String: Task<Void, Never>] = [:]
    @State private var showingConsentWithdrawal = false
    @State private var helpTopic: MeetingHelpTopic?
    @StateObject private var processingReporter = MeetingProcessingReporter()
    @ScaledMetric(relativeTo: .body) private var liveTranscriptViewportHeight = 220
    @State private var showingDiagnosticReports = false
    @State private var showingAudioImport = false
    @State private var importingMeetingID: String?
    @State private var diarizingMeetingID: String?
    @State private var interruptedSpeakerMeetingID: String?
    @State private var speakerPassTask: Task<MeetingDiarizationPostProcessor.Outcome, Error>?
    @State private var isCancellingSpeakers = false
    @ObservedObject private var diarizationActivity = MeetingDiarizationActivity.shared
    @ObservedObject private var speakerPrewarmer = MeetingLiveSpeakerPrewarmer.shared
    @ObservedObject private var speakerModel = MeetingDiarizationModelController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var meetingScreenVisible = false

    private var showsSourceControlsBeforeRecording: Bool {
        switch coordinator.status {
        case .recording, .paused, .stopping, .finalizingTranscript, .extractingActions: false
        default: true
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(copy("meeting.section.new", fallback: "새 회의")) {
                    Picker(copy("meeting.language.label", fallback: "언어"), selection: $languageTag) {
                        ForEach(AppLanguage.supported) { language in
                            Text(language.displayName).tag(language.speechLanguageTag)
                        }
                    }

                    .pickerStyle(.menu)

                    settingToggle(
                        title: "녹음 고지 및 동의 확인",
                        isOn: Binding(
                            get: { consentAccepted },
                            set: { accepted in
                                consentAccepted = accepted
                                if !accepted { cancelPendingStart() }
                            }
                        ),
                        helpTopic: .recordingConsent
                    )


                    if showsSourceControlsBeforeRecording {
                        captureSourceControls
                    }

                    captureControls
                    if coordinator.status != .recording && coordinator.status != .paused {
                        if speakerPrewarmer.phase == .preparing {
                            Text(copy("meeting.diarization.prewarming", fallback: AppLanguage.current == .english
                                ? "Preparing speaker model before recording"
                                : "녹음 전 화자 모델 준비 중"))
                                .font(.caption)
                                .accessibilityIdentifier("meeting.diarization.prewarm.state")
                        } else if speakerPrewarmer.phase == .ready {
                            Text(copy("meeting.diarization.prewarmReady", fallback: AppLanguage.current == .english
                                ? "Speaker model ready for live detection"
                                : "실시간 화자 분석 모델 준비됨"))
                                .font(.caption)
                                .accessibilityIdentifier("meeting.diarization.prewarm.state")
                        }
                    }
                }

                if processingReporter.phase != .idle {
                    Section(copy("meeting.section.processing", fallback: "회의 정리")) {
                        MeetingProcessingStatusView(
                            phase: processingReporter.phase,
                            showsTranscription: processingReporter.includesTranscription,
                            offlineTranscription: settings.meetingAdvancedTranscriptionEnabled,
                            transcriptionProgress: processingReporter.transcriptionProgress
                        )
                    }
                }
                if let diarizingMeetingID {
                    Section(copy("meeting.diarization.section", fallback: AppLanguage.current == .english ? "Speaker detection" : "화자 분석")) {
                        ProgressView(
                            copy(
                                "meeting.diarization.progress",
                                fallback: AppLanguage.current == .english
                                    ? "Detecting speakers from saved audio"
                                    : "저장된 음성에서 화자를 확인하는 중"
                            ),
                            value: diarizationActivity.progress[diarizingMeetingID] ?? 0
                        )
                        .accessibilityIdentifier("meeting.diarization.state")
                        Button(copy(
                            "meeting.diarization.cancel",
                            fallback: AppLanguage.current == .english ? "Stop speaker detection" : "화자 분석 중지",
                            comment: "Stop only the saved-audio speaker analysis; recording and transcript remain saved."
                        )) {
                            isCancellingSpeakers = true
                            speakerPassTask?.cancel()
                            Task { await MeetingDiarizationPostProcessor.cancel(meetingID: diarizingMeetingID) }
                        }
                        .accessibilityIdentifier("meeting.diarization.cancel")
                        .disabled(isCancellingSpeakers)
                    }
                }
                if let interruptedMeeting {
                    Section(copy("meeting.diarization.section", fallback: AppLanguage.current == .english ? "Speaker detection" : "화자 분석")) {
                        Text(copy(
                            "meeting.diarization.interruptedState",
                            fallback: AppLanguage.current == .english
                                ? "Speaker detection was interrupted. Run it again from the menu."
                                : "화자 분석이 중단되었습니다. 메뉴에서 다시 분석하세요."
                        ))
                        .accessibilityIdentifier("meeting.diarization.state")
                        NavigationLink(copy(
                            "meeting.diarization.openToRetry",
                            fallback: AppLanguage.current == .english ? "Open meeting to retry" : "다시 분석할 회의 열기"
                        )) {
                            MeetingDetailView(meeting: interruptedMeeting)
                        }
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
                        Text(copy("meeting.audioTrack.independentCapture", fallback: AppLanguage.current == .english
                            ? "Sources are saved and processed separately. App or screen audio can still contain several participants; speaker IDs belong only to their track."
                            : "소스별로 원음과 전사·화자를 따로 저장합니다. 앱·화면 오디오 안에는 여러 참가자의 소리가 섞일 수 있으며 화자 ID는 해당 트랙 안에서만 사용합니다."))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(coordinator.liveTracks) { track in
                            liveTrackTranscript(track)
                        }
                    }
                }
                if coordinator.status == .recording || coordinator.status == .paused {
                    Section {
                        captureSourceControls
                    }
                }

                if !meetings.isEmpty {
                    Section(copy("meeting.section.deviceMeetings", fallback: "이 기기의 회의")) {
                        ForEach(meetings) { meeting in
                            NavigationLink {
                                MeetingDetailView(meeting: meeting)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meeting.result?.title.isEmpty == false ? meeting.result!.title
                                         : (meeting.importedAudioFileName ?? copy("meeting.title.untitled", fallback: "회의")))
                                    Text(meeting.updatedAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("meeting.row.\(meeting.meetingID)")
                        }
                        .onDelete(perform: deleteMeetings)
                    }
                }
            }
            .navigationTitle(copy("meeting.navigationTitle", fallback: "회의"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAudioImport = true
                    } label: {
                        Label(copy("meeting.audioImport.title", fallback: "오디오 가져오기"), systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("meeting.audioImport.open")
                    .disabled(!showsSourceControlsBeforeRecording || pendingStartID != nil
                              || finalizingCaptureID != nil || importingMeetingID != nil
                              || processingReporter.isBusy || diarizingMeetingID != nil)
                }
            }
            .onChange(of: consentAccepted) { _, accepted in
                guard !accepted, pendingStartTask == nil,
                      coordinator.status == .recording || coordinator.status == .paused
                else { return }
                showingConsentWithdrawal = true
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
                    beginStopping()
                }
            } message: {
                Text(copy(
                    "meeting.alert.consentWithdrawal.message",
                    fallback: "동의를 철회하면 녹음과 실시간 전사가 중지됩니다. 지금까지 기록된 회의는 보존됩니다."
                ))
            }
            .alert(
                copy("meeting.alert.processingError.title", fallback: "회의 처리 오류"),
                isPresented: Binding(
                    get: { coordinator.failure != nil },
                    set: { isPresented in
                        guard !isPresented else { return }
                        Task { @MainActor in
                            await Task.yield()
                            coordinator.dismissFailure()
                        }
                    }
                )
            ) {
                if coordinator.reportableError != nil {
                    Button(copy("meeting.action.reportDiagnostic", fallback: "오류 보고")) {
                        showingDiagnosticReports = true
                    }
                }
                Button(copy("확인", fallback: "확인"), role: .cancel) {}
            } message: {
                Text(coordinator.failure ?? copy("meeting.error.unknown", fallback: "알 수 없는 오류"))
            }
            .sheet(isPresented: $showingDiagnosticReports) {
                NavigationStack {
                    DiagnosticReportView(
                        pendingError: DiagnosticReportService.shared.collectionEnabled ? nil : coordinator.reportableError,
                        showsCloseButton: true
                    )
                }
            }
            .sheet(isPresented: $showingAudioImport) {
                MeetingAudioImportSheet { record in
                    importingMeetingID = record.meetingID
                    Task { @MainActor in
                        defer { importingMeetingID = nil }
                        do {
                            let outcome = try await MeetingOfflineTranscriptionOrchestrator().run(
                                record: record, context: modelContext, languageTag: record.languageTag,
                                reporter: processingReporter)
                            processingReporter.set(.idle)
                            guard outcome == .committed else { return }
                            await processCapturedTrack(record, captureEnabledAtStart: settings.effectiveMeetingDiarizationEnabled)
                        } catch {
                            processingReporter.reset()
                            if !(error is CancellationError) {
                                coordinator.reportFailure(error, message: offlineFailureMessage(for: record))
                            }
                        }
                    }
                }
            }
        }
        .onAppear { meetingScreenVisible = true }
        .onDisappear {
            cancelPendingStart()
            meetingScreenVisible = false
            Task { await speakerPrewarmer.releaseUnused() }
        }
        .onChange(of: settings.meetingDiarizationEnabled) { _, enabled in
            guard meetingScreenVisible else { return }
            Task {
                guard meetingScreenVisible else { return }
                if enabled { await speakerPrewarmer.prepareIfAvailable() }
                else { await speakerPrewarmer.releaseUnused() }
            }
        }
        .onChange(of: speakerModel.isInstalled) { _, installed in
            guard installed, meetingScreenVisible else { return }
            Task {
                guard meetingScreenVisible else { return }
                await speakerPrewarmer.prepareIfAvailable()
            }
        }
        .task {
            await coordinator.refreshMicrophoneRoutes()
            await persistPendingCaptureRecoveries()
            // Keep the saved-audio pass alive across tab switches; it owns the
            // execution gate until it finishes before prewarming can begin.
            let resumed = Task { await MeetingDiarizationPostProcessor.resumeInterrupted(in: modelContext) }
            await resumed.value
            guard !Task.isCancelled, meetingScreenVisible else { return }
            await speakerModel.refresh()
            guard !Task.isCancelled, meetingScreenVisible else { return }
            await speakerPrewarmer.prepareIfAvailable()
        }
    }
    private func copy(_ key: String, fallback: String, comment: String = "Meeting user-facing copy.") -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current, comment: comment)
    }
    private var interruptedMeeting: MeetingRecord? {
        guard let id = interruptedSpeakerMeetingID,
              let record = try? modelContext.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })).first,
              record.diarization?.status == .interrupted else { return nil }
        return record
    }

    @ViewBuilder private func liveTrackTranscript(_ track: MeetingLiveCaptureTrack) -> some View {
        let profiles = MeetingSpeakerLabelFormatter.liveProfiles(track.liveSpeakerOrdinals)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(track.sourceLabel ?? track.sourceKind.displayName()).font(.headline)
                Spacer()
                Text(duration(track.recordedAudioSamples * 1_000 / MeetingMediaTimeline.sampleRate))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("meeting.audioTrack.live.\(track.meetingID)")
            if let warning = track.liveTranscriptionWarning {
                Text(warning).font(.caption).foregroundStyle(AppTheme.warning)
            }
            if let warning = track.liveDiarizationWarning {
                Text(warning).font(.caption).foregroundStyle(AppTheme.warning)
            }
            switch track.liveSpeakerPhase {
            case .preparing:
                Text(copy("meeting.diarization.prewarming", fallback: AppLanguage.current == .english
                    ? "Preparing speaker model before recording" : "녹음 전 화자 모델 준비 중"))
                    .font(.caption).foregroundStyle(.secondary)
            case .waitingForInference:
                Text(copy("meeting.audioTrack.waitingForSpeakers", fallback: AppLanguage.current == .english
                    ? "Waiting for this track's first speaker analysis" : "이 트랙의 첫 화자 분석 대기 중"))
                    .font(.caption).foregroundStyle(.secondary)
            case .analyzing:
                Text(String(format: copy("meeting.diarization.live", fallback: AppLanguage.current == .english
                    ? "Provisional speakers on this device · %lld detected" : "기기 내 임시 화자 표시 · %lld명 감지"),
                            locale: AppLanguage.current.locale, Int64(profiles.count)))
                    .font(.caption).foregroundStyle(.secondary)
            case .inactive, .stopped: EmptyView()
            }
            if track.liveTranscriptRows.isEmpty {
                Text(copy("meeting.audioTrack.waitingForTranscript", fallback: AppLanguage.current == .english
                    ? "Waiting for speech from this source" : "이 소스의 음성 전사 대기 중"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(track.liveTranscriptRows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    if coordinator.recordingDiarizationEnabled {
                                        Text(MeetingSpeakerLabelFormatter.label(for: row.speakerIDs, profiles: profiles, state: .provisional))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(row.text).textSelection(.enabled)
                                }
                                .id(row.id)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("meeting.liveTranscript.\(track.meetingID).\(row.id)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: liveTranscriptViewportHeight)
                    .onChange(of: track.liveTranscriptRows.last) { _, row in
                        if let row { proxy.scrollTo(row.id, anchor: .bottom) }
                    }
                }
            }
        }
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

    @ViewBuilder private var captureSourceControls: some View {
        let active = coordinator.status == .recording || coordinator.status == .paused
        let enabled = !sourceChangeInProgress && (active || coordinator.status == .ready || coordinator.status == .failed || coordinator.status == .cancelled)
        Toggle(copy("meeting.source.microphone", fallback: AppLanguage.current == .english ? "Record microphone" : "마이크 녹음"),
               isOn: Binding(
                get: { active ? coordinator.microphoneEnabled : microphoneRequested },
                set: { requested in
                    if active {
                        sourceChangeInProgress = true
                        Task {
                            defer { sourceChangeInProgress = false }
                            do { try await coordinator.setMicrophoneEnabled(requested, consentConfirmed: consentAccepted) }
                            catch { coordinator.reportFailure(error) }
                        }
                    } else {
                        microphoneRequested = requested
                    }
                }
               ))
            .disabled(!enabled)
            .accessibilityIdentifier("meeting.source.microphone.toggle")

        if let warning = coordinator.microphoneWarning {
            Text(warning).font(.caption).foregroundStyle(AppTheme.warning)
                .accessibilityIdentifier("meeting.source.microphone.warning")
        }
        if !coordinator.usesSystemPickerMicrophone && !coordinator.microphoneRoutes.isEmpty && (active || microphoneRequested) {
            Picker(copy("meeting.source.microphone.route", fallback: AppLanguage.current == .english ? "Microphone input" : "마이크 입력 장치"),
                   selection: Binding<String?>(
                    get: { coordinator.selectedMicrophoneRouteID },
                    set: { route in
                        sourceChangeInProgress = true
                        Task {
                            defer { sourceChangeInProgress = false }
                            do { try await coordinator.selectMicrophoneRoute(id: route) }
                            catch { coordinator.reportFailure(error) }
                        }
                    }
                   )) {
                Text(copy("meeting.source.microphone.default", fallback: AppLanguage.current == .english ? "System default" : "시스템 기본 입력")).tag(nil as String?)
                ForEach(coordinator.microphoneRoutes) { route in
                    Text(route.name).tag(Optional(route.id))
                }
            }
            .disabled(!enabled)
            .accessibilityIdentifier("meeting.source.microphone.route")
        } else if !coordinator.usesSystemPickerMicrophone && !active && microphoneRequested {
            Text(copy("meeting.source.microphone.routeBeforeStart", fallback: AppLanguage.current == .english
                ? "System default; selectable inputs appear after the recording session starts."
                : "시스템 기본 입력 · 선택 가능한 장치는 녹음 세션 시작 후 표시됩니다."))
                .font(.caption).foregroundStyle(.secondary)
        }

        Toggle(copy(
            {
                #if targetEnvironment(macCatalyst)
                return "meeting.source.app"
                #else
                return "meeting.source.app.ios"
                #endif
            }(),
            fallback: AppLanguage.current == .english ? "Record other apps' full-screen audio" : "전체 화면의 다른 앱 소리 녹음"
        ),
               isOn: Binding(
                get: {
                    if !active { return appAudioRequested }
                    return coordinator.appAudioSources.contains {
                        switch $0.state {
                        case .selecting, .waitingForAudio, .receivingAudio: true
                        case .disabled, .unavailable: false
                        }
                    }
                },
                set: { requested in
                    if active {
                        sourceChangeInProgress = true
                        Task {
                            defer { sourceChangeInProgress = false }
                            do { try await coordinator.setAppAudioEnabled(requested, consentConfirmed: consentAccepted) }
                            catch { coordinator.reportFailure(error) }
                        }
                    } else { appAudioRequested = requested }
                }
               ))
            .disabled(!enabled || !consentAccepted || !appAudioAvailable)
            .accessibilityIdentifier("meeting.source.app.toggle")

        if !appAudioAvailable {
            Text(copy("meeting.source.app.unavailable", fallback: AppLanguage.current == .english
                ? "App audio requires supported iOS 27 hardware or Mac Catalyst system sharing. Microphone recording remains available."
                : "앱 오디오는 지원되는 iOS 27 실기기 또는 Mac Catalyst 화면 공유가 필요합니다. 마이크 녹음은 계속 사용할 수 있습니다."))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("meeting.source.app.availability")
        } else if active {
            #if targetEnvironment(macCatalyst)
            ForEach(coordinator.appAudioSources) { source in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.sourceLabel ?? source.sourceKind.displayName()).font(.subheadline)
                        Text(appAudioStatus(for: source.state)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(copy("meeting.audioTrack.stopSource", fallback: AppLanguage.current == .english ? "Stop source" : "소스 중지")) {
                        sourceChangeInProgress = true
                        Task {
                            defer { sourceChangeInProgress = false }
                            await coordinator.stopAppAudioSource(id: source.id)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!enabled)
                    .accessibilityIdentifier("meeting.audioTrack.stopSource.\(source.id)")
                }
            }
            Button(copy("meeting.audioTrack.addSource", fallback: AppLanguage.current == .english ? "Add another audio source" : "다른 오디오 소스 추가")) {
                sourceChangeInProgress = true
                Task {
                    defer { sourceChangeInProgress = false }
                    do { try await coordinator.addAppAudioSource(consentConfirmed: consentAccepted) }
                    catch is CancellationError { }
                    catch { coordinator.reportFailure(error) }
                }
            }
            .disabled(!enabled || !consentAccepted || coordinator.appAudioSources.count >= 4)
            .accessibilityIdentifier("meeting.audioTrack.addSource")
            #else
            Text(appAudioStatus(for: coordinator.appAudioState))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("meeting.source.app.state")
            #endif
        } else {
            #if targetEnvironment(macCatalyst)
            Text(copy("meeting.source.app.selectionOnStart", fallback: AppLanguage.current == .english
                ? "The system picker requests a source when recording starts; no screen video is saved. Use headphones to limit microphone bleed."
                : "녹음 시작 시 시스템 선택창에서 오디오 소스를 지정합니다. 화면 영상은 저장하지 않습니다. 마이크 유입을 줄이려면 헤드폰을 사용하세요."))
                .font(.caption).foregroundStyle(.secondary)
            #else
            Text(copy("meeting.source.app.selectionOnStart.ios", fallback: AppLanguage.current == .english
                ? "SIFT is the recording destination, not the audio source. Tap Share Entire Screen; iPhone cannot select another app here. Only audio is saved. Use headphones to limit microphone bleed."
                : "선택창의 SIFT는 녹음 결과를 받는 앱입니다. 'Share Entire Screen'을 누르세요. iPhone에서는 이곳에서 다른 앱을 선택할 수 없습니다. 화면 영상은 저장하지 않습니다. 마이크 유입을 줄이려면 헤드폰을 사용하세요."))
                .font(.caption).foregroundStyle(.secondary)
            #endif
        }
        if active {
            HStack {
                Text(copy("meeting.source.microphone.level", fallback: AppLanguage.current == .english ? "Microphone level" : "마이크 입력 레벨"))
                    .font(.caption2)
                ProgressView(value: min(1, sqrt(coordinator.microphoneRMS)))
                    .accessibilityIdentifier("meeting.source.microphone.level")
            }
            if appAudioAvailable {
                HStack {
                    Text(copy("meeting.source.app.level", fallback: AppLanguage.current == .english ? "App audio level" : "앱 오디오 입력 레벨"))
                        .font(.caption2)
                    ProgressView(value: min(1, sqrt(coordinator.appAudioRMS)))
                        .accessibilityIdentifier("meeting.source.app.level")
                }
            }
            Text(String(format: copy("meeting.source.buffers", fallback: AppLanguage.current == .english
                ? "Buffers received: microphone %lld · app %lld (silent buffers also count)"
                : "수신 버퍼: 마이크 %lld · 앱 %lld (무음 버퍼도 포함)"),
                        locale: AppLanguage.current.locale,
                        coordinator.microphoneAudioBufferCount, coordinator.appAudioBufferCount))
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("meeting.source.buffers")
        }
    }

    private var appAudioAvailable: Bool {
        if case .available = coordinator.appAudioAvailability { return true }
        return false
    }

    private func appAudioStatus(for state: MeetingAppAudioCapture.State) -> String {
        switch state {
        case .disabled:
            return copy("meeting.source.app.off", fallback: AppLanguage.current == .english ? "App audio off" : "앱 오디오 꺼짐")
        case .selecting:
            return copy("meeting.source.app.selecting", fallback: AppLanguage.current == .english ? "Waiting for system audio selection" : "시스템 오디오 선택 대기 중")
        case .waitingForAudio:
            return copy("meeting.source.app.waiting", fallback: AppLanguage.current == .english ? "Waiting for audio buffers" : "오디오 수신 대기 중")
        case .receivingAudio:
            return copy("meeting.source.app.receiving", fallback: AppLanguage.current == .english ? "Receiving audio buffers" : "오디오 버퍼 수신 중")
        case .unavailable(let reason):
            return reason
        }
    }

    @ViewBuilder private var captureControls: some View {
        switch coordinator.status {
        case .recording:
            Button(copy("meeting.action.pauseRecording", fallback: "일시 정지"), action: coordinator.pause)
                .accessibilityIdentifier("meeting.action.pauseRecording")
            Button(copy("meeting.action.stopRecording", fallback: "녹음 종료")) { beginStopping() }
                .tint(AppTheme.destructive)
                .accessibilityIdentifier("meeting.action.stopRecording")
        case .paused:
            Button(copy("meeting.action.continueRecording", fallback: "계속 녹음")) {
                do {
                    try coordinator.resume()
                } catch {
                    coordinator.reportFailure(error)
                }
            }
            .accessibilityIdentifier("meeting.action.continueRecording")
            Button(copy("meeting.action.stopRecording", fallback: "녹음 종료")) { beginStopping() }
                .tint(AppTheme.destructive)
                .accessibilityIdentifier("meeting.action.stopRecording")
        case .stopping, .finalizingTranscript, .extractingActions:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView()
                Text(coordinator.finalizationDetail.isEmpty
                     ? copy("meeting.processing.finalizing", fallback: "회의를 정리하는 중")
                     : coordinator.finalizationDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        default:
            Button(copy("녹음 시작", fallback: "녹음 시작")) { showingDisclosure = true }
                .accessibilityIdentifier("meeting.action.startRecording")
                .disabled(sourceChangeInProgress || finalizingCaptureID != nil || importingMeetingID != nil
                          || processingReporter.isBusy || diarizingMeetingID != nil || !consentAccepted
                          || (!microphoneRequested && !appAudioRequested))
        }
    }

    private func startRecording() {
        guard meetingScreenVisible, consentAccepted, pendingStartTask == nil,
              finalizingCaptureID == nil, !sourceChangeInProgress, microphoneRequested || appAudioRequested else { return }
        sourceChangeInProgress = true
        let id = UUID().uuidString.lowercased()
        interruptedSpeakerMeetingID = nil
        currentMeetingID = id
        pendingStartID = id
        processingReporter.reset()
        if let service = userVocabulary?.service {
            coordinator.setVocabularySnapshotProvider { await service.snapshot() }
        }
        pendingStartTask = Task {
            do {
                try await coordinator.start(
                    meetingID: id, languageTag: languageTag,
                    microphoneEnabled: microphoneRequested,
                    appAudioEnabled: appAudioRequested,
                    consentConfirmed: consentAccepted
                )
                if Task.isCancelled || !consentAccepted || !meetingScreenVisible {
                    await coordinator.cancel()
                    throw CancellationError()
                }
            } catch is CancellationError {
                // Consent withdrawal and dismissal are normal startup exits.
            } catch {
                if !Task.isCancelled, currentMeetingID == id { coordinator.reportFailure(error) }
            }
            guard pendingStartID == id else { return }
            if Task.isCancelled || !consentAccepted || !meetingScreenVisible || coordinator.status != .recording {
                if currentMeetingID == id, finalizingCaptureID != id { currentMeetingID = nil }
            }
            pendingStartTask = nil
            pendingStartID = nil
            sourceChangeInProgress = false
        }
    }

    private func cancelPendingStart() {
        guard let pendingStartTask else { return }
        // Startup may have opened the source router before its final hardware/route await.
        // Pause closes the capture gate synchronously while cancellation unwinds it.
        if coordinator.status == .recording { coordinator.pause() }
        pendingStartTask.cancel()
        if currentMeetingID == pendingStartID { currentMeetingID = nil }
        // Hold the start slot until the coordinator finishes cleaning up.
    }

    private func beginStopping() {
        guard let id = currentMeetingID, finalizingCaptureID == nil else { return }
        finalizingCaptureID = id
        stopTasks[id] = Task {
            await stopRecording(meetingID: id)
            stopTasks[id] = nil
        }
    }

    private func releaseCapture(_ id: String) {
        if finalizingCaptureID == id { finalizingCaptureID = nil }
        if currentMeetingID == id {
            currentMeetingID = nil
            consentAccepted = false
        }
    }


    private func stopRecording(meetingID id: String) async {
        let captureEnabledAtStart = coordinator.recordingDiarizationEnabled
        defer { releaseCapture(id) }
        let parent: MeetingRecord
        let records: [MeetingRecord]
        do {
            let artifact = try await coordinator.stopCapture()
            guard currentMeetingID == id, artifact.meetingID == id else { return }
            parent = try MeetingInitialCapturePersister.persist(
                artifact: artifact, languageTag: languageTag,
                timezoneIdentifier: TimeZone.current.identifier, in: modelContext
            )
            records = try MeetingAudioTrackStore.tracks(for: parent, in: modelContext)
        } catch {
            await coordinator.failFinalization(error)
            return
        }
        // Capture the persisted provisional bases before any suspended analyzer
        // can race a manual edit. A changed child is superseded independently.
        let bases = Dictionary(uniqueKeysWithValues: records.map { ($0.meetingID, $0.resultData) })
        if Task.isCancelled {
            await coordinator.failFinalization(CancellationError())
            return
        }
        var finalizationFailure: Error?
        do { try await coordinator.finalizeTranscript() }
        catch {
            finalizationFailure = error
            await coordinator.failFinalization(error)
        }
        if Task.isCancelled {
            await coordinator.failFinalization(CancellationError())
            return
        }

        var processable = [MeetingRecord]()
        for record in records {
            guard isCurrent(record), let expectedData = bases[record.meetingID] else { continue }
            do {
                let baseline = try coordinator.transcriptionResult(for: record.meetingID)
                let failure = coordinator.transcriptionFailure(for: record.meetingID) ?? finalizationFailure
                if let failure { coordinator.reportFailure(failure) }
                let committed = try MeetingCaptureTranscriptPersister.persist(
                    record: record, baseline: baseline, failed: failure != nil,
                    expectedResultData: expectedData, in: modelContext)
                clearCaptureRecovery(meetingID: record.meetingID)
                if committed { processable.append(record) }
            } catch {
                // Keep this child's recovery marker. Siblings still commit.
                coordinator.reportFailure(copy("meeting.error.saveRecord", fallback: "회의 기록 저장에 실패했습니다. 저장 재시도"))
            }
        }
        refreshTrackGroup(parent)
        coordinator.completeFinalization()

        let queuedBases = Dictionary(uniqueKeysWithValues: processable.map { ($0.meetingID, $0.persistenceSnapshot()) })
        let offlineRequested = settings.meetingAdvancedTranscriptionEnabled
            ? await MeetingWhisperModelStore.shared.isInstalled() : false
        // Inference remains bounded: one saved-audio ASR/final-speaker/AI pass at
        // a time, after every live child has released its reservation.
        for record in processable {
            guard !Task.isCancelled else { break }
            guard isCurrent(record), record.persistenceSnapshot() == queuedBases[record.meetingID] else { continue }
            if offlineRequested {
                do {
                    let outcome = try await MeetingOfflineTranscriptionOrchestrator().run(
                        record: record, context: modelContext, expectedSource: queuedBases[record.meetingID],
                        reporter: processingReporter)
                    processingReporter.set(.idle)
                    guard outcome == .committed else { continue }
                } catch {
                    processingReporter.reset()
                    if Task.isCancelled || error is CancellationError { break }
                    coordinator.reportFailure(error, message: offlineFailureMessage(for: record))
                }
            }
            guard !Task.isCancelled, isCurrent(record), record.status == .ready else {
                refreshTrackGroup(parent)
                continue
            }
            await processCapturedTrack(record, captureEnabledAtStart: captureEnabledAtStart)
            refreshTrackGroup(parent)
        }
        processingReporter.reset()
        refreshTrackGroup(parent)
    }

    private func offlineFailureMessage(for record: MeetingRecord) -> String {
        if record.status == .ready, record.result?.segments.isEmpty == false {
            return copy("meeting.error.offlineRetained", fallback: AppLanguage.current == .english
                ? "Saved-audio transcription failed. The recording and earlier transcript are safe. Enabled follow-up processing will use that transcript. You can retry offline transcription from the meeting menu."
                : "저장 음성의 오프라인 전사에 실패했습니다. 녹음과 기존 전사는 보존되어 있으며, 활성화된 후속 처리는 기존 전사를 사용합니다. 회의 메뉴에서 오프라인 전사를 다시 시도할 수 있습니다.")
        }
        return copy("meeting.error.offlineAudioSaved", fallback: AppLanguage.current == .english
            ? "Offline transcription failed. The audio is saved, but a complete transcript is not available yet. Retry from the meeting menu."
            : "오프라인 전사에 실패했습니다. 음성은 저장되어 있지만 완성된 전사는 아직 없습니다. 회의 메뉴에서 전사를 다시 시도하세요.")
    }

    private func clearCaptureRecovery(meetingID: String) {
        do {
            try MeetingCaptureRecoveryStore.remove(meetingID: meetingID)
            coordinator.acknowledgeRecoveredCapture(meetingID: meetingID)
        } catch {
            coordinator.reportFailure(copy("meeting.error.cleanupRecovery", fallback: "회의 복구 표시를 정리하지 못했습니다. 다음 실행에서 다시 확인합니다."))
        }
    }

    private func isCurrent(_ record: MeetingRecord) -> Bool {
        let id = record.meetingID
        return (try? modelContext.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })).first)?
            .persistentModelID == record.persistentModelID
    }

    private func refreshTrackGroup(_ parent: MeetingRecord) {
        guard isCurrent(parent) else { return }
        do { try MeetingAudioTrackStore.refresh(parent: parent, in: modelContext) }
        catch { coordinator.reportFailure(copy("meeting.error.saveRecord", fallback: "회의 기록 저장에 실패했습니다. 저장 재시도")) }
    }

    private func processCapturedTrack(_ record: MeetingRecord, captureEnabledAtStart: Bool) async {
        // Stable speaker labels before AI proofreading and summary: the live model
        // is already released, so only the final-pass model is resident here.
        if captureEnabledAtStart {
            diarizingMeetingID = record.meetingID
            isCancellingSpeakers = false
            let speakerTask = Task {
                try await MeetingDiarizationPostProcessor.run(
                    record: record,
                    context: modelContext,
                    liveTimeline: coordinator.liveTimeline(for: record.meetingID),
                    captureEnabledAtStart: captureEnabledAtStart
                )
            }
            speakerPassTask = speakerTask
            let outcome: MeetingDiarizationPostProcessor.Outcome
            do {
                outcome = try await speakerTask.value
            } catch {
                outcome = .failed(.inferenceFailed)
            }
            speakerPassTask = nil
            diarizingMeetingID = nil
            isCancellingSpeakers = false
            interruptedSpeakerMeetingID = outcome == .interrupted ? record.meetingID : nil
            if let message = outcome.userMessage { coordinator.reportFailure(message) }
        }

        guard !Task.isCancelled, isCurrent(record) else { return }
        do {
            _ = try await MeetingPostProcessor.refineAndAnalyze(
                record: record,
                context: modelContext,
                allowRefine: SettingsStore.shared.meetingAutoRefineEnabled,
                allowModelLoad: false,
                reporter: processingReporter,
                dependencies: makeVocabularyMeetingDependencies(userVocabulary?.service)
            )
        } catch MeetingPostProcessor.Failure.superseded {
            processingReporter.reset()
        } catch is CancellationError {
            processingReporter.reset()
        } catch {
            coordinator.reportFailure(
                copy(
                    "meeting.error.processingSave",
                    fallback: "AI 검수 또는 요약을 저장하지 못했습니다. 회의 상단의 다시 정리 메뉴에서 다시 시도할 수 있습니다."
                )
            )
        }
    }

    private func persistPendingCaptureRecoveries() async {
        let scan = MeetingCaptureRecoveryStore.scan()
        var recoveredIDs = [String]()
        // Establish every readable child before any model await exposes the
        // group to navigation/export or lets deletion invalidate cached journals.
        for recovery in scan.recoveries {
            if let currentMeetingID,
               recovery.parentMeetingID == currentMeetingID || recovery.meetingID == currentMeetingID { continue }
            do {
                try MeetingCaptureRecoveryPersister.persist(recovery, in: modelContext)
                coordinator.acknowledgeRecoveredCapture(meetingID: recovery.meetingID)
                recoveredIDs.append(recovery.meetingID)
            } catch {
                coordinator.reportFailure(copy("meeting.error.recoverySave", fallback: "복구한 회의 저장에 실패했습니다. 저장 재시도"))
            }
        }
        let queuedRecoveryBases = recoveredIDs.reduce(into: [String: MeetingRecord.PersistenceSnapshot]()) { snapshots, id in
            if let record = try? modelContext.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })).first {
                snapshots[id] = record.persistenceSnapshot()
            }
        }
        let offlineRequested = settings.meetingAdvancedTranscriptionEnabled
            ? await MeetingWhisperModelStore.shared.isInstalled() : false
        if offlineRequested {
            for id in recoveredIDs {
                guard !Task.isCancelled else { break }
                do {
                    let descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })
                    guard let record = try modelContext.fetch(descriptor).first,
                          record.status == .transcriptFinalizationFailed,
                          record.persistenceSnapshot() == queuedRecoveryBases[id] else { continue }
                    let outcome = try await MeetingOfflineTranscriptionOrchestrator().run(
                        record: record, context: modelContext, expectedSource: queuedRecoveryBases[id],
                        reporter: processingReporter)
                    processingReporter.set(.idle)
                    guard outcome == .committed else { continue }
                    try MeetingAudioTrackStore.refreshParent(of: record, in: modelContext)
                    await processCapturedTrack(record, captureEnabledAtStart: settings.effectiveMeetingDiarizationEnabled)
                    try MeetingAudioTrackStore.refreshParent(of: record, in: modelContext)
                } catch {
                    processingReporter.reset()
                    if Task.isCancelled || error is CancellationError { break }
                    coordinator.reportFailure(copy("meeting.error.recoverySave", fallback: "복구한 회의 저장에 실패했습니다. 저장 재시도"))
                }
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
                stopTasks[meeting.meetingID]?.cancel()
                do {
                    let tracks = meeting.isAudioTrackGroup ? try MeetingAudioTrackStore.tracks(for: meeting, in: modelContext) : []
                    for record in tracks + [meeting] {
                        if diarizingMeetingID == record.meetingID { speakerPassTask?.cancel() }
                        await MeetingOfflineTranscriptionOrchestrator.cancel(meetingID: record.meetingID)
                        await MeetingDiarizationPostProcessor.cancel(meetingID: record.meetingID)
                    }
                    // Drain every in-flight child before removing its namespace.
                    if let stopTask = stopTasks[meeting.meetingID] { await stopTask.value }
                } catch {
                    coordinator.reportFailure(copy("meeting.audioTrack.deleteFailed", fallback: AppLanguage.current == .english
                        ? "The meeting tracks could not be deleted. Try again." : "회의 트랙을 삭제하지 못했습니다. 다시 시도하세요."))
                    continue
                }
                if currentMeetingID == meeting.meetingID {
                    if finalizingCaptureID == meeting.meetingID { coordinator.completeFinalization() }
                    await coordinator.cancel()
                    releaseCapture(meeting.meetingID)
                }
                do { try MeetingAudioTrackDeletion.delete(parent: meeting, in: modelContext) }
                catch {
                    coordinator.reportFailure(copy("meeting.audioTrack.deleteFailed", fallback: AppLanguage.current == .english
                        ? "The meeting tracks could not be deleted. Try again." : "회의 트랙을 삭제하지 못했습니다. 다시 시도하세요."))
                }
            }
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
