import SwiftUI
import SwiftData

/// An explicit per-request choice; never changes the automatic summary provider.
struct MeetingSummaryEntry: View {
    let isProcessing: Bool
    let onPresent: () -> Void

    var body: some View {
        Button(action: onPresent) {
            Label(MeetingLanguageCopy.text("meeting.summary.regenerate", "Regenerate summary"), systemImage: "arrow.clockwise")
        }
        .disabled(isProcessing)
        .accessibilityIdentifier("meeting.summary.open")
    }
}

struct MeetingSummaryView: View {
    let meeting: MeetingRecord
    let onSuccess: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var regionalAvailability = OpenAIRegionalAvailability.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var connection = OpenAIConnection.shared
    @AppStorage(OpenAIPrivacy.consentKey(for: .meetings)) private var allowsOpenAIMeetings = false
    @Query private var tracks: [MeetingRecord]
    @State private var selectedModel: MeetingSummaryModel?
    @State private var accountModels: [OpenAIAvailableModel] = []
    @State private var isCheckingModels = false
    @State private var catalogFailed = false
    @State private var requestTask: Task<Void, Never>?
    @State private var isRequesting = false
    @State private var errorMessage: String?
    @State private var notice: String?

    init(meeting: MeetingRecord, onSuccess: @escaping () -> Void) {
        self.meeting = meeting
        self.onSuccess = onSuccess
        let parentID = meeting.meetingID
        _tracks = Query(filter: #Predicate<MeetingRecord> { $0.parentMeetingID == parentID },
                        sort: [SortDescriptor(\MeetingRecord.audioTrackStartSample), SortDescriptor(\MeetingRecord.createdAt)])
    }

    private var remoteAvailable: Bool {
        regionalAvailability.isAvailable
            && SettingsStore.betaProviderAccess().openAIEnabled
            && connection.activeProfile != nil
    }

    private var isMeetingAvailable: Bool { meeting.modelContext === context && !meeting.isDeleted }

    private var hasTranscript: Bool {
        guard isMeetingAvailable else { return false }
        if meeting.isAudioTrackGroup {
            return !tracks.isEmpty && tracks.allSatisfy {
                $0.modelContext === context && !$0.isDeleted && $0.status == .ready && $0.result != nil
            } && tracks.contains { hasText($0) }
        }
        return meeting.status != .finalizingTranscript && hasText(meeting)
    }

    private func hasText(_ record: MeetingRecord) -> Bool {
        guard record.modelContext === context, !record.isDeleted else { return false }
        return record.result?.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
    }

    private var needsCustomInstructions: Bool {
        meeting.summaryFormat == .custom
            && meeting.summaryCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var summaryLanguage: String {
        MeetingSummaryLanguages.requestedLanguageTag(sourceLanguageTag: meeting.processingSourceLanguageTag,
            savedSummaryLanguageTag: meeting.summaryLanguageTag)
    }

    private func isAvailable(_ model: MeetingSummaryModel) -> Bool {
        guard let tier = model.openAITier else { return FoundationModelsAvailability.isAvailable }
        return remoteAvailable && accountModels.contains { $0.id == tier.modelID }
    }

    private var canRequest: Bool {
        guard let selectedModel else { return false }
        return isAvailable(selectedModel) && (selectedModel.openAITier == nil || allowsOpenAIMeetings)
            && hasTranscript && !needsCustomInstructions && !isRequesting
    }

    var body: some View {
        NavigationStack {
            Group {
                if isMeetingAvailable {
                    Form {
                        modelSection
                        Section {
                            Text(meeting.audioTrackDisplayName).font(.headline)
                            LabeledContent(MeetingLanguageCopy.summaryTitle,
                                value: MeetingLanguageOption(id: summaryLanguage).displayName(locale: AppLanguage.current.locale))
                            LabeledContent(MeetingLanguageCopy.text("meeting.openai.format", "Summary format"),
                                value: meeting.summaryFormat.displayName())
                            if !meeting.summaryCustomInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                DisclosureGroup(MeetingLanguageCopy.text("meeting.openai.instructions", "Custom instructions")) {
                                    Text(meeting.summaryCustomInstructions).textSelection(.enabled)
                                }
                            }
                            if let selectedModel {
                                Text(selectedModel.openAITier == nil
                                    ? MeetingLanguageCopy.text("meeting.summary.localPrivacy", "Processes this meeting’s transcript on this device. Nothing is sent to OpenAI.")
                                    : MeetingLanguageCopy.text(meeting.isAudioTrackGroup ? "meeting.openai.groupSharingNotice" : "meeting.openai.sharingNotice",
                                        meeting.isAudioTrackGroup
                                            ? "Sends all source transcripts in this meeting, source names and speaker labels needed for citations, summary language, format, and custom instructions to OpenAI. Audio, vocabulary, other meetings, and previous summaries are not sent."
                                            : "Sends only this meeting’s transcript, summary language, format, and custom instructions to OpenAI. Audio, vocabulary, other meetings, and the previous summary are not sent."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(MeetingLanguageCopy.text("meeting.openai.replacementNotice", "A successful request replaces the saved summary and review-only task candidates. Errors or cancellation keep the previous result. Review citations in Summary before relying on the result."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if selectedModel?.openAITier != nil { OpenAIConsentSection(scope: .meetings) }
                        Section {
                            if let selectedModel, !isAvailable(selectedModel) {
                                Text(unavailableReason(selectedModel)).font(.caption).foregroundStyle(.secondary)
                            }
                            if !hasTranscript {
                                Text(MeetingLanguageCopy.text("meeting.openai.transcriptRequired", "Finish transcription before sending. Every source in a multi-source meeting must be ready; no sources are omitted."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if needsCustomInstructions {
                                Text(MeetingLanguageCopy.text("meeting.openai.customInstructionsRequired", "Enter custom instructions in meeting settings before sending."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button(MeetingLanguageCopy.text("meeting.summary.regenerate", "Regenerate summary"), action: request)
                                .disabled(!canRequest).accessibilityIdentifier("meeting.summary.request")
                            if isRequesting {
                                ProgressView(MeetingLanguageCopy.text("meeting.summary.progress", "Regenerating summary"))
                                    .accessibilityIdentifier("meeting.summary.progress")
                                Button(MeetingLanguageCopy.text("meeting.openai.cancel", "Cancel request"), role: .cancel) {
                                    requestTask?.cancel()
                                }.accessibilityIdentifier("meeting.summary.cancel")
                            }
                        }
                        if let notice {
                            Section { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("meeting.summary.notice") }
                        }
                        if let errorMessage {
                            Section { Text(errorMessage).foregroundStyle(AppTheme.destructive).accessibilityIdentifier("meeting.summary.error") }
                        }
                    }.appFormStyle()
                } else {
                    ContentUnavailableView {
                        Label(MeetingLanguageCopy.text("meeting.summary.regenerate", "Regenerate summary"), systemImage: "doc.text")
                    } description: {
                        Text(MeetingLanguageCopy.text("meeting.openai.meetingUnavailable", "This meeting was deleted or is no longer available. The summary was not replaced."))
                    }.accessibilityIdentifier("meeting.summary.meetingUnavailable")
                }
            }
            .navigationTitle(MeetingLanguageCopy.text("meeting.summary.regenerate", "Regenerate summary"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized("action.close", defaultValue: "Close", language: .current)) {
                        requestTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .task(id: "\(connection.sessionGeneration)-\(remoteAvailable)") { await loadAccountModels() }
        .onChange(of: remoteAvailable) { _, available in
            if !available, selectedModel?.openAITier != nil { invalidateRequest() }
        }
        .onChange(of: connection.sessionGeneration) { _, _ in
            if selectedModel?.openAITier != nil { invalidateRequest() }
        }
        .onChange(of: allowsOpenAIMeetings) { _, allowed in
            if !allowed, selectedModel?.openAITier != nil { invalidateRequest() }
        }
        .onChange(of: isMeetingAvailable) { _, available in if !available { invalidateRequest() } }
        .onDisappear { requestTask?.cancel() }
    }

    private var modelSection: some View {
        Section {
            ForEach(MeetingSummaryModel.allCases) { model in
                Button {
                    selectedModel = model
                    errorMessage = nil
                    notice = nil
                } label: {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.item) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                            Text(model.displayName).font(.body.weight(.medium)).foregroundStyle(.primary)
                            Text(model.openAITier == nil
                                ? MeetingLanguageCopy.text("meeting.summary.localCost", "On device · No additional charge")
                                : MeetingLanguageCopy.text("meeting.summary.remoteCost", "Online · ChatGPT plan limits apply"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: selectedModel == model ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedModel == model ? Color.accentColor : Color.secondary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(isRequesting)
                .accessibilityIdentifier("meeting.summary.model.\(model.rawValue)")
                .accessibilityAddTraits(selectedModel == model ? [.isSelected] : [])
            }
            if isCheckingModels {
                ProgressView(MeetingLanguageCopy.text("meeting.summary.checkingModels", "Checking account models…"))
            }
        } header: {
            Text(MeetingLanguageCopy.text("meeting.summary.chooseModel", "Choose a model"))
        } footer: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                Text(MeetingLanguageCopy.text("meeting.summary.estimatedTime", "Estimate: seconds to minutes; long meetings can take longer."))
                Text(MeetingLanguageCopy.text("meeting.summary.estimateLimits", "Time depends on transcript length, device and service conditions. This app cannot determine your account’s exact charges or remaining quota."))
            }
        }
    }

    private func unavailableReason(_ model: MeetingSummaryModel) -> String {
        guard let tier = model.openAITier else {
            return FoundationModelsAvailability.unavailableExplanation
                ?? MeetingLanguageCopy.text("meeting.summary.modelUnavailable", "This model is not currently available.")
        }
        if !remoteAvailable {
            return MeetingLanguageCopy.text("meeting.openai.unavailable", "ChatGPT is unavailable. Enable the OpenAI provider, connect an account, and use an available region before requesting a summary.")
        }
        if isCheckingModels { return MeetingLanguageCopy.text("meeting.summary.checkingModels", "Checking account models…") }
        if catalogFailed { return MeetingLanguageCopy.text("meeting.summary.catalogFailed", "Could not check account models. Reopen to try again.") }
        return OpenAIRequestError.modelUnavailable(tier.modelID).localizedDescription
    }

    private func loadAccountModels() async {
        accountModels = []
        catalogFailed = false
        guard remoteAvailable else { return }
        isCheckingModels = true
        defer { isCheckingModels = false }
        let generation = connection.sessionGeneration
        do {
            let models = try await OpenAIProviderService().availableModels()
            try Task.checkCancellation()
            guard generation == connection.sessionGeneration, remoteAvailable else { return }
            accountModels = models
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, generation == connection.sessionGeneration else { return }
            catalogFailed = true
        }
    }

    private func invalidateRequest() {
        requestTask?.cancel()
        if isRequesting {
            notice = MeetingLanguageCopy.text("meeting.openai.cancelled", "Request cancelled. The previous summary has been kept.")
        }
    }

    private func request() {
        guard canRequest, let model = selectedModel else { return }
        errorMessage = nil
        notice = nil
        isRequesting = true
        requestTask = Task {
            defer { isRequesting = false; requestTask = nil }
            do {
                try await LLMDebugLogger.withOpenAITrace(operation: "meeting.request",
                    includeContent: ProcessInfo.processInfo.environment["PIEROOT_LLM_DEBUG"] == "1") {
                    LLMDebugLogger.openAIEvent("meeting.record.validate", "model=\(model.rawValue)")
                    guard isMeetingAvailable else { throw MeetingPostProcessor.Failure.superseded }
                    if meeting.isAudioTrackGroup {
                        LLMDebugLogger.openAIEvent("meeting.group.start")
                        _ = try await MeetingGroupSummaryService.generate(parent: meeting, in: context, dependencies: .summary(model: model))
                    } else {
                        LLMDebugLogger.openAIEvent("meeting.single.start")
                        _ = try await MeetingPostProcessor.refineAndAnalyze(record: meeting, context: context,
                            allowRefine: false, allowModelLoad: false, requireGeneratedSummary: true, dependencies: .summary(model: model))
                    }
                    LLMDebugLogger.openAIEvent("meeting.commit.completed")
                    guard isMeetingAvailable else { return }
                    onSuccess()
                    dismiss()
                }
            } catch is CancellationError {
                if isMeetingAvailable {
                    notice = MeetingLanguageCopy.text("meeting.openai.cancelled", "Request cancelled. The previous summary has been kept.")
                }
            } catch {
                guard !Task.isCancelled, isMeetingAvailable else { return }
                switch error {
                case MeetingSummaryEvidence.Failure.instructionsTooLong:
                    errorMessage = MeetingLanguageCopy.text("meeting.summary.error.instructionsTooLong", "Shorten the custom instructions, then try again. The previous summary has been kept.")
                case MeetingNarrativePipeline.AnalysisError.inputTooLarge:
                    errorMessage = MeetingLanguageCopy.text("meeting.summary.error.inputTooLarge", "This meeting or its custom instructions exceed the selected model's input limit. Shorten the instructions or choose another model. The previous summary has been kept.")
                case is MeetingNarrativePipeline.AnalysisError:
                    errorMessage = MeetingLanguageCopy.text("meeting.error.summaryUnavailable", "No usable summary was produced. The previous summary has been kept. Try again or choose another model.")
                default:
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
