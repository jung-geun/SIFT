import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The presenting view owns post-commit processing. Closing this sheet can
/// cancel conversion, but can never erase a successfully saved meeting.
struct MeetingAudioImportSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var whisperModel = MeetingWhisperModelController.shared
    @State private var selectedURL: URL?
    @State private var languageTag = AppLanguage.current.speechLanguageTag
    @State private var showingFilePicker = false
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
                        showingFilePicker = true
                    } label: {
                        Label(copy("meeting.audioImport.chooseFile", fallback: "오디오 파일 선택"), systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("meeting.audioImport.chooseFile")
                    .disabled(importing)
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
                    Picker(copy("meeting.audioImport.language", fallback: "전사 언어"), selection: $languageTag) {
                        ForEach(AppLanguage.supported) { language in
                            Text(language.displayName).tag(language.speechLanguageTag)
                        }
                    }
                    .disabled(importing)
                    .accessibilityIdentifier("meeting.audioImport.language")
                    if !whisperModel.isInstalled {
                        Text(copy("meeting.audioImport.modelNotice", fallback: "오프라인 Whisper 모델이 없습니다. 음성은 저장할 수 있으며 베타 설정에서 모델을 설치한 후 회의에서 전사를 다시 시도할 수 있습니다. 전사문을 임의로 만들지 않습니다."))
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
                            .disabled(selectedURL == nil)
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
            .navigationTitle(copy("meeting.audioImport.title", fallback: "오디오 가져오기"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy("action.close", fallback: "닫기")) { dismiss() }
                        .disabled(importing)
                }
            }
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
        }
        .interactiveDismissDisabled(importing)
        .task { await whisperModel.refresh() }
        .onDisappear { importTask?.cancel() }
    }

    private func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current,
                              comment: "Local audio import controls and status.")
    }

    private func cancelImport() {
        cancelling = true
        importTask?.cancel()
    }

    private func startImport() {
        guard let selectedURL, !importing else { return }
        let token = UUID()
        operationID = token
        progress = 0
        cancelling = false
        cancelled = false
        errorMessage = nil
        importTask = Task { @MainActor in
            defer {
                importTask = nil
                cancelling = false
                operationID = nil
            }
            do {
                let record = try await MeetingAudioImportService.importFile(
                    at: selectedURL, languageTag: languageTag, in: modelContext,
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
