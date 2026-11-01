import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The presenting view owns post-commit processing. Closing this sheet can
/// cancel conversion, but can never erase a successfully saved meeting.
struct MeetingAudioImportSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var whisperModel = MeetingWhisperModelController.shared
    @ObservedObject private var localModel = OnDeviceLLMService.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var selectedURL: URL?
    @ObservedObject private var languagePreferences = MeetingLanguagePreferences.shared
    @State private var summaryLanguageOptions: [MeetingLanguageOption] = []
    #if targetEnvironment(macCatalyst)
    @StateObject private var nativeFilePicker = MeetingAudioFilePicker()
    @State private var selectedFile: MeetingAudioImportSelection?
    @State private var selectionID = UUID()
    @State private var readingFile = false
    @State private var dropTargeted = false
    @State private var fileSelectionError: String?
    @State private var selectionProgress: Progress?
    #else
    @State private var showingFilePicker = false
    #endif
    @State private var importTask: Task<Void, Never>?
    @State private var progress = 0.0
    @State private var cancelling = false
    @State private var errorMessage: String?
    @State private var cancelled = false
    @State private var operationID: UUID?

    /// Called exactly once after local audio and the retryable record commit.
    /// Do not throw from this handoff or delete audio on later ASR failure.
    let onImported: @MainActor (MeetingRecord) -> Void

    private var importing: Bool { importTask != nil }

    private var languageTag: String {
        languagePreferences.sourceSelection(options: MeetingTranscriptionLanguages.whisper)
    }

    private var summaryLanguageTag: String {
        languagePreferences.summarySelection(options: summaryLanguageOptions)
    }

    private var automaticLanguageDetection: Bool { languagePreferences.automaticLanguageDetection }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(copy("meeting.audioImport.explanation", fallback: "오디오 파일을 선택해 로컬 회의로 복사합니다. 원본은 변경하지 않습니다. 변환과 전사는 이 기기에서 실행하며 마이크 권한이나 서버 업로드가 필요하지 않습니다."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        errorMessage = nil
                        cancelled = false
                        #if targetEnvironment(macCatalyst)
                        fileSelectionError = nil
                        nativeFilePicker.choose { result in
                            switch result {
                            case .success(let url):
                                if let url { selectFile(urls: [url]) }
                            case .failure(let error): fileSelectionError = error.localizedDescription
                            }
                        }
                        #else
                        showingFilePicker = true
                        #endif
                    } label: {
                        Label(copy("meeting.audioImport.chooseFile", fallback: "오디오 파일 선택"), systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("meeting.audioImport.chooseFile")
                    .disabled(importing || selectingFile)
                    #if targetEnvironment(macCatalyst)
                    Button(action: pasteFile) {
                        Label(copy("meeting.audioImport.pasteFile", fallback: "오디오 파일 붙여넣기"), systemImage: "document.on.clipboard")
                    }
                    .accessibilityIdentifier("meeting.audioImport.pasteFile")
                    .disabled(importing || selectingFile)
                    Text(copy("meeting.audioImport.dropHint", fallback: "Finder에서 파일 하나를 여기로 끌어 놓거나, 복사 후 ⌘V로 붙여넣으세요."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("meeting.audioImport.dropHint")
                        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                        .padding(8)
                        .contentShape(Rectangle())
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.tint, style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1, dash: [6, 4]))
                                .opacity(dropTargeted ? 1 : 0.35)
                                .allowsHitTesting(false)
                        }
                        .overlay {
                            MeetingAudioFileInput(enabled: !importing && !selectingFile,
                                drop: receiveDrop, targeted: { dropTargeted = $0 })
                        }
                    if readingFile {
                        ProgressView(copy("meeting.audioImport.readingFile", fallback: "파일 확인 중…"))
                    }
                    if let fileSelectionError {
                        Text(verbatim: fileSelectionError)
                            .foregroundStyle(AppTheme.destructive)
                            .accessibilityIdentifier("meeting.audioImport.selectionError")
                    }
                    #endif
                    if let selectedURL {
                        Text(verbatim: selectedURL.lastPathComponent)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("meeting.audioImport.fileName")
                    }
                    Text(copy("meeting.audioImport.formats", fallback: "이 기기가 지원하는 M4A, MP3, WAV, AIFF, CAF, FLAC 등의 오디오를 최대 6시간까지 가져옵니다."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    MeetingLanguagePicker(title: MeetingLanguageCopy.sourceTitle,
                        selection: Binding(get: { languageTag }, set: { languagePreferences.selectSource($0) }),
                        options: MeetingTranscriptionLanguages.whisper, identifier: "meeting.audioImport.language",
                        automaticLanguageDetection: Binding(get: { automaticLanguageDetection },
                            set: { languagePreferences.selectAutomaticDetection($0) }),
                        automaticDetectionAvailable: whisperModel.isInstalled)
                        .disabled(importing)
                    if !summaryLanguageOptions.isEmpty {
                        MeetingLanguagePicker(title: MeetingLanguageCopy.summaryTitle,
                            selection: Binding(get: { summaryLanguageTag }, set: { languagePreferences.selectSummary($0) }),
                            options: summaryLanguageOptions, identifier: "meeting.audioImport.summaryLanguage")
                            .disabled(importing)
                    }
                    MeetingAIAccuracyNotice()
                    if automaticLanguageDetection { MeetingAutomaticLanguageNotice() }
                    if !whisperModel.isInstalled {
                        Text(copy("meeting.audioImport.modelNotice", fallback: "Whisper 모델이 설치되지 않았습니다. 음성을 저장하고 설정 → 회의에서 모델을 설치한 뒤 전사할 수 있습니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("meeting.audioImport.modelRequired")
                    }
                }
                Section {
                    if importing {
                        ProgressView(value: progress) {
                            Text(cancelling
                                 ? copy("meeting.audioImport.cancelling", fallback: "취소하고 가져온 파일을 정리하는 중…")
                                 : copy("meeting.audioImport.importing", fallback: "오디오 가져오는 중…"))
                        }
                        .accessibilityIdentifier("meeting.audioImport.progress")
                        Button(copy("meeting.audioImport.cancel", fallback: "가져오기 취소"), role: .cancel) { cancelImport() }
                            .disabled(cancelling)
                            .accessibilityIdentifier("meeting.audioImport.cancel")
                    } else {
                        Button(copy("meeting.audioImport.start", fallback: "이 기기로 가져오기")) { startImport() }
                            .disabled(selectedURL == nil || selectingFile || (!automaticLanguageDetection && languageTag.isEmpty))
                            .accessibilityIdentifier("meeting.audioImport.start")
                    }
                    if cancelled {
                        Text(copy("meeting.audioImport.cancelled", fallback: "가져오기를 취소했습니다. 원본 파일은 변경하지 않았습니다."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .foregroundStyle(AppTheme.destructive)
                            .accessibilityIdentifier("meeting.audioImport.error")
                    }
                }
            }
            .appFormStyle()
            #if targetEnvironment(macCatalyst)
            .background(MeetingAudioFileInput(enabled: !importing && !selectingFile, paste: pasteFile))
            #endif
            .navigationTitle(copy("meeting.audioImport.title", fallback: "오디오 가져오기"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy("action.close", fallback: "닫기")) { dismiss() }
                        .disabled(importing)
                }
            }
        }
        #if !targetEnvironment(macCatalyst)
        .fileImporter(isPresented: $showingFilePicker,
                      allowedContentTypes: MeetingAudioImportService.allowedContentTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                selectedURL = urls.first
                errorMessage = nil
            case .failure(let error):
                // System picker cancellation is not an import failure.
                let cocoa = error as NSError
                if cocoa.domain != NSCocoaErrorDomain || cocoa.code != NSUserCancelledError {
                    errorMessage = MeetingAudioImportService.Failure.unavailableInput.localizedDescription
                }
            }
        }
        #endif
        .interactiveDismissDisabled(importing)
        .task {
            refreshSummaryLanguageOptions()
            await whisperModel.refresh()
        }
        .onChange(of: localModel.loadedModelIdentifier) { _, _ in refreshSummaryLanguageOptions() }
        .onChange(of: localModel.modelID) { _, _ in refreshSummaryLanguageOptions() }
        .onChange(of: BetaFeaturePolicy().routingDecision(for: .meetingAnalysis)) { _, _ in refreshSummaryLanguageOptions() }
        .onDisappear {
            importTask?.cancel()
            #if targetEnvironment(macCatalyst)
            nativeFilePicker.cancel()
            selectionID = UUID()
            selectionProgress?.cancel()
            selectionProgress = nil
            selectedFile = nil
            #endif
        }
    }

    private var selectingFile: Bool {
        #if targetEnvironment(macCatalyst)
        readingFile || nativeFilePicker.isPresented
        #else
        false
        #endif
    }

    #if targetEnvironment(macCatalyst)
    private func pasteFile() {
        guard !importing, !selectingFile else { return }
        let urls = nativeFilePicker.copiedFileURLs()
        if urls.isEmpty {
            fileSelectionError = MeetingAudioImportSelection.Failure.noCopiedFile.localizedDescription
        } else { selectFile(urls: urls) }
    }

    private func selectFile(urls: [URL]) {
        guard !importing, !readingFile else { return }
        do {
            let selection = try MeetingAudioImportSelection(urls: urls)
            selectedFile = selection
            selectedURL = selection.url
            errorMessage = nil
            fileSelectionError = nil
            cancelled = false
        } catch { fileSelectionError = error.localizedDescription }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !importing, !selectingFile else { return false }
        guard providers.count == 1 else {
            fileSelectionError = MeetingAudioImportSelection.Failure.singleFileRequired.localizedDescription
            return false
        }
        let token = UUID()
        selectionID = token
        readingFile = true
        fileSelectionError = nil
        let receive: @Sendable (URL?, Bool, Error?) -> Void = { url, inPlace, error in
            // Finder advertises audio, not public.file-url. Retain the original
            // read grant inside the callback, never an expired temporary URL.
            let result: Result<MeetingAudioImportSelection, Error> = Result {
                guard error == nil, inPlace, let url else { throw MeetingAudioImportService.Failure.unavailableInput }
                return try MeetingAudioImportSelection(urls: [url])
            }
            Task { @MainActor in
                guard selectionID == token else { return }
                readingFile = false
                selectionProgress = nil
                switch result {
                case .success(let selection):
                    selectedFile = selection
                    selectedURL = selection.url
                    errorMessage = nil
                    fileSelectionError = nil
                    cancelled = false
                case .failure(let error): fileSelectionError = error.localizedDescription
                }
            }
        }
        let provider = providers[0]
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                receive(url, true, error)
            }
        } else if let audioType = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .audio) == true }) {
            selectionProgress = provider.loadInPlaceFileRepresentation(forTypeIdentifier: audioType, completionHandler: receive)
        } else {
            receive(nil, false, MeetingAudioImportService.Failure.unsupportedAudio)
        }
        return true
    }
    #endif

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current,
                              comment: "Local audio import controls and status.")
    }

    private func refreshSummaryLanguageOptions() {
        summaryLanguageOptions = MeetingSummaryLanguages.available
    }

    private func cancelImport() {
        cancelling = true
        importTask?.cancel()
    }

    private func startImport() {
        guard let selectedURL, !importing, automaticLanguageDetection || !languageTag.isEmpty else { return }
        let chosenLanguages = (source: languageTag.isEmpty ? summaryLanguageTag : languageTag,
                               summary: summaryLanguageTag, automatic: automaticLanguageDetection)
        let token = UUID()
        operationID = token
        progress = 0
        cancelling = false
        cancelled = false
        errorMessage = nil
        #if targetEnvironment(macCatalyst)
        let selection = selectedFile
        #endif
        importTask = Task { @MainActor in
            defer {
                #if targetEnvironment(macCatalyst)
                withExtendedLifetime(selection) {}
                #endif
                importTask = nil
                cancelling = false
                operationID = nil
            }
            do {
                let record = try await MeetingAudioImportService.importFile(
                    at: selectedURL, languageTag: chosenLanguages.source,
                    automaticLanguageDetection: chosenLanguages.automatic,
                    summaryLanguageTag: chosenLanguages.summary, in: modelContext,
                    progress: { value in
                        Task { @MainActor in
                            guard operationID == token else { return }
                            progress = max(progress, value)
                        }
                    }
                )
                onImported(record)
                dismiss()
            } catch is CancellationError {
                cancelled = true
            } catch {
                // Service errors deliberately omit file paths and decoder text.
                errorMessage = (error as? MeetingAudioImportService.Failure)?.localizedDescription
                    ?? MeetingAudioImportService.Failure.storageFailed.localizedDescription
            }
        }
    }
}
