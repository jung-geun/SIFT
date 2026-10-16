import SwiftUI

// MARK: - Live pipeline progress (전사 → AI 검수 → 요약)

/// Compact pipeline indicator. It tracks only stages that are actually running:
/// automatic post-processing reuses the saved transcript (검수 → 요약), while
/// "다시 전사" runs speech-to-text first (`showsTranscription`) and presents
/// 전사 → 검수 → 요약.
struct MeetingProcessingStatusView: View {
    let phase: MeetingProcessingReporter.Phase
    var showsTranscription: Bool = false
    var offlineTranscription: Bool = false
    var transcriptionProgress: MeetingTranscriptionProgress?

    private enum StageState { case done, active, pending, skipped }

    var body: some View {
        if case .idle = phase {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if showsTranscription {
                        stage(
                            AppLanguage.localized("meeting.stage.transcript", defaultValue: "전사", language: .current, comment: "Meeting processing stage."),
                            systemImage: "waveform",
                            state: transcribeState
                        )
                        connector
                    }
                    stage(
                        AppLanguage.localized("meeting.stage.proofread", defaultValue: "AI 검수", language: .current, comment: "Meeting processing stage."),
                        systemImage: "sparkles.rectangle.stack",
                        state: proofreadState
                    )
                    connector
                    stage(
                        AppLanguage.localized("meeting.stage.summary", defaultValue: "요약", language: .current, comment: "Meeting processing stage."),
                        systemImage: "text.alignleft",
                        state: summarizeState
                    )
                }
                statusLine
                if case .transcribing = phase, let transcriptionProgress {
                    MeetingTranscriptionProgressView(progress: transcriptionProgress)
                }
            }
            .padding(.vertical, 4)
        }
    }

    nonisolated static func compactCompletionText(
        for outcome: MeetingProcessingReporter.ProofreadOutcome,
        language: AppLanguage = .current
    ) -> String? {
        switch outcome {
        case .changed, .unchanged:
            return nil
        case .failed:
            return AppLanguage.localized("meeting.processing.proofreadFailed", defaultValue: "AI 검수 실패 · 원문으로 요약 완료", language: language, comment: "Meeting processing completion status.")
        case .skipped(let reason):
            switch reason {
            case .disabled:
                return AppLanguage.localized("meeting.processing.proofreadSkipped", defaultValue: "AI 검수를 건너뜀 · 요약 완료", language: language, comment: "Meeting processing completion status.")
            case .unavailable:
                return AppLanguage.localized("meeting.processing.aiUnavailable", defaultValue: "온디바이스 AI를 사용할 수 없어 검수를 건너뜀 · 요약 완료", language: language, comment: "Meeting processing completion status.")
            case .modelNotLoaded:
                return AppLanguage.localized("meeting.processing.modelNotLoaded", defaultValue: "AI 모델을 자동으로 불러오지 않아 검수를 건너뜀 · 요약 완료", language: language, comment: "Meeting processing completion status.")
            case .emptyTranscript:
                return AppLanguage.localized("meeting.processing.emptyTranscript", defaultValue: "전사 내용이 없어 AI 검수를 건너뜀", language: language, comment: "Meeting processing completion status.")
            }
        }
    }

    private var transcribeState: StageState {
        switch phase {
        case .transcribing: .active
        case .proofreading, .summarizing, .completed: .done
        case .idle: .pending
        }
    }

    private var proofreadState: StageState {
        switch phase {
        case .proofreading: .active
        case .summarizing: .done
        case .completed(let proofread, _):
            switch proofread {
            case .skipped, .failed: .skipped
            case .changed, .unchanged: .done
            }
        case .transcribing, .idle: .pending
        }
    }

    private var summarizeState: StageState {
        switch phase {
        case .summarizing: .active
        case .completed: .done
        case .transcribing, .proofreading, .idle: .pending
        }
    }

    @ViewBuilder
    private func stage(_ title: String, systemImage: String, state: StageState) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(fill(for: state))
                    .frame(width: 30, height: 30)
                switch state {
                case .active:
                    ProgressView().controlSize(.small).tint(.white)
                case .done:
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                case .skipped:
                    Image(systemName: "minus").font(.caption.bold()).foregroundStyle(.white)
                case .pending:
                    Image(systemName: systemImage).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(state == .pending ? .secondary : .primary)
        }
    }

    private func fill(for state: StageState) -> Color {
        switch state {
        case .done: .green
        case .active: .accentColor
        case .skipped: .orange
        case .pending: Color(.systemGray5)
        }
    }

    private var connector: some View {
        Rectangle().fill(Color(.systemGray4)).frame(height: 1).frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .transcribing:
            label(offlineTranscription
                ? AppLanguage.localized("meeting.processing.offlineTranscribing", defaultValue: AppLanguage.current == .english ? "Transcribing saved audio with on-device Whisper" : "기기 내 Whisper로 저장된 음성을 다시 전사하는 중", language: .current, comment: "WhisperKit saved audio processing stage.")
                : AppLanguage.localized("meeting.processing.retranscribing", defaultValue: "저장된 음성을 다시 전사하는 중이에요", language: .current, comment: "Meeting processing status."), engine: "")
        case .proofreading(let engine):
            label(AppLanguage.localized("meeting.processing.proofreading", defaultValue: "AI가 전사를 검수하는 중이에요", language: .current, comment: "Meeting processing status."), engine: engine)
        case .summarizing(let engine):
            label(AppLanguage.localized("meeting.processing.summarizing", defaultValue: "요약을 정리하는 중이에요", language: .current, comment: "Meeting processing status."), engine: engine)
        case .completed(let proofread, let analysisEngine):
            switch proofread {
            case .changed(let count, let engine):
                let text = AppLanguage.localizedCount(
                    "meeting.processing.corrected",
                    count: count,
                    defaultValue: AppLanguage.current == .english
                        ? (count == 1 ? "Proofreading complete · %lld correction" : "Proofreading complete · %lld corrections")
                        : "검수 완료 · %lld곳 교정",
                    language: .current,
                    comment: "Meeting processing status."
                )
                label(text, engine: engine)
            case .unchanged(let engine):
                label(AppLanguage.localized("meeting.processing.unchanged", defaultValue: "검수 완료 · 수정할 내용이 없었어요", language: .current, comment: "Meeting processing status."), engine: engine)
            case .skipped(let reason):
                Text(skipMessage(reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let engine, _):
                label(AppLanguage.localized("meeting.processing.proofreadFailed", defaultValue: "AI 검수 실패 · 원문으로 요약 완료", language: .current, comment: "Meeting processing status."), engine: engine ?? analysisEngine)
            }
        }
    }

    private func skipMessage(_ reason: MeetingProcessingReporter.SkipReason) -> String {
        switch reason {
        case .disabled:
            return AppLanguage.localized("meeting.processing.proofreadSkipped", defaultValue: "AI 검수를 건너뜀 · 요약 완료", language: .current, comment: "Meeting processing skip status.")
        case .unavailable:
            return AppLanguage.localized("meeting.processing.aiUnavailable", defaultValue: "온디바이스 AI를 사용할 수 없어 검수를 건너뜀 · 요약 완료", language: .current, comment: "Meeting processing skip status.")
        case .modelNotLoaded:
            return AppLanguage.localized("meeting.processing.modelNotLoaded", defaultValue: "AI 모델을 자동으로 불러오지 않아 검수를 건너뜀 · 요약 완료", language: .current, comment: "Meeting processing skip status.")
        case .emptyTranscript:
            return AppLanguage.localized("meeting.processing.emptyTranscript", defaultValue: "전사 내용이 없어 AI 검수를 건너뜀", language: .current, comment: "Meeting processing skip status.")
        }
    }

    @ViewBuilder
    private func label(_ text: String, engine: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.caption).foregroundStyle(.secondary)
            if !engine.isEmpty {
                Text(engine)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

/// Estimates apply only to the active ASR stage. Loading and downstream work
/// remain indeterminate rather than borrowing an invented percentage or speed.
struct MeetingTranscriptionProgressView: View {
    let progress: MeetingTranscriptionProgress

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 6) {
                Text(stageTitle).font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("meeting.transcription.stage")
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                Text(String(format: text("meeting.progress.duration", "Audio %@", "음성 길이 %@"),
                            MeetingTranscriptionProgress.timestamp(progress.totalMilliseconds)))
                if progress.stage == .recognizing || progress.stage == .preparingAudio {
                    Text(String(format: text("meeting.progress.position", "Confirmed audio position %@ / %@", "음성 확인 위치 %@ / %@"),
                                MeetingTranscriptionProgress.timestamp(progress.completedMilliseconds),
                                MeetingTranscriptionProgress.timestamp(progress.totalMilliseconds)))
                        .accessibilityIdentifier("meeting.transcription.position")
                }
                Text(String(format: text("meeting.progress.elapsed", "Elapsed %@", "경과 %@"),
                            duration(progress.elapsed(at: timeline.date))))
                if let remaining = progress.estimatedRemaining(at: timeline.date) {
                    Text(String(format: text("meeting.progress.estimate", "About %@ left for transcription · estimated finish %@", "전사 예상 잔여 약 %@ · %@ 완료 예상"),
                                duration(remaining), timeline.date.addingTimeInterval(remaining).formatted(
                                    .dateTime.hour().minute().locale(AppLanguage.current.locale))))
                        .accessibilityIdentifier("meeting.transcription.estimate")
                    Text(text("meeting.progress.estimateScope", "Based on this run's speed; excludes speaker detection, proofreading and summary.", "현재 처리 속도 기준이며 화자 분석·AI 검수·요약 시간은 제외합니다."))
                } else if progress.stage == .recognizing {
                    Text(text("meeting.progress.measuring", "Measuring transcription speed; a time estimate will appear after enough audio is confirmed.", "전사 속도를 측정하는 중입니다. 음성 구간이 충분히 확인되면 예상 시간을 표시합니다."))
                }
                if progress.stage == .recognizing {
                    Text(String(format: text("meeting.progress.lastUpdate", "Last confirmed progress %@ ago", "최근 진행 확인 %@ 전"),
                                duration(max(0, timeline.date.timeIntervalSince(progress.lastActivityAt)))))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stageTitle: String {
        switch progress.stage {
        case .waiting: text("meeting.progress.waiting", "Waiting for on-device audio processing", "기기 내 음성 처리 대기 중")
        case .loadingModel: text("meeting.progress.model", "Verifying and loading the transcription model", "전사 모델 검증·불러오는 중")
        case .preparingAudio: text("meeting.progress.audio", "Preparing saved audio", "저장된 음성 준비 중")
        case .recognizing: text("meeting.progress.recognizing", "Recognizing speech and aligning timestamps", "음성 인식·시간 정렬 중")
        case .validating: text("meeting.progress.validating", "Checking and saving the transcript", "전사 결과 검사·저장 중")
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        MeetingTranscriptionProgress.timestamp(Int64(max(0, min(seconds, Double(Int64.max / 1_000))) * 1_000))
    }

    private func text(_ key: String, _ english: String, _ korean: String) -> String {
        AppLanguage.localized(key, defaultValue: AppLanguage.current == .english ? english : korean,
                              language: .current, comment: "Measured local transcription progress; estimate is not a completion guarantee.")
    }
}
