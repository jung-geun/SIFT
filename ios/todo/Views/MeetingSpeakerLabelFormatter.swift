import Foundation

/// Display text for stable speaker IDs. IDs are never shown for model speakers;
/// legacy free-text labels without a profile are shown as stored.
enum MeetingSpeakerLabelFormatter {
    static func name(
        for speakerID: String,
        profiles: [String: MeetingSpeakerProfile],
        language: AppLanguage = .current
    ) -> String {
        guard let profile = profiles[speakerID] else { return speakerID }
        if let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return numbered(profile.ordinal, language: language)
    }

    static func numbered(_ ordinal: Int, language: AppLanguage = .current) -> String {
        String(
            format: AppLanguage.localized(
                "meeting.speaker.numbered",
                defaultValue: language == .english ? "Speaker %lld" : "화자 %lld",
                language: language,
                comment: "Default name of a detected meeting speaker by first-appearance number."
            ),
            locale: language.locale,
            Int64(ordinal)
        )
    }

    /// "화자 1 · 임시", "화자 1 + 화자 2 · 동시 발화", or "화자 미확정".
    static func label(
        for speakerIDs: [String],
        profiles: [String: MeetingSpeakerProfile],
        state: MeetingSpeakerLabelState,
        language: AppLanguage = .current
    ) -> String {
        guard !speakerIDs.isEmpty, state != .unknown else {
            return AppLanguage.localized(
                "meeting.speaker.unknown",
                defaultValue: language == .english ? "Speaker unknown" : "화자 미확정",
                language: language,
                comment: "Transcript row whose speaker is not determined."
            )
        }
        var parts = [speakerIDs.map { name(for: $0, profiles: profiles, language: language) }.joined(separator: " + ")]
        if speakerIDs.count > 1 {
            parts.append(AppLanguage.localized(
                "meeting.speaker.overlap",
                defaultValue: language == .english ? "Overlapping speech" : "동시 발화",
                language: language,
                comment: "Several speakers were active during the same words; text is not separated per speaker."
            ))
        }
        if state == .provisional {
            parts.append(AppLanguage.localized(
                "meeting.speaker.provisional",
                defaultValue: language == .english ? "Provisional" : "임시",
                language: language,
                comment: "Live speaker label that may change after the saved-audio pass."
            ))
        }
        return parts.joined(separator: " · ")
    }

    static func liveProfiles(_ ordinals: [String: Int]) -> [String: MeetingSpeakerProfile] {
        ordinals.reduce(into: [:]) { result, entry in
            result[entry.key] = MeetingSpeakerProfile(id: entry.key, ordinal: entry.value, displayName: nil)
        }
    }
}

extension MeetingDiarizationPostProcessor.Outcome {
    /// Non-fatal notice after a saved-audio pass; nil when nothing needs attention.
    var userMessage: String? {
        let english = AppLanguage.current == .english
        switch self {
        case .failed:
            return AppLanguage.localized(
                "meeting.diarization.finalFailed",
                defaultValue: english
                    ? "Speaker detection failed. The audio and transcript were saved; try again from the meeting detail."
                    : "화자 분석을 완료하지 못했습니다. 녹음과 전사는 저장되었습니다. 회의 기록에서 다시 시도할 수 있습니다.",
                language: .current,
                comment: "Non-fatal saved-audio speaker analysis error."
            )
        case .busy:
            return AppLanguage.localized(
                "meeting.diarization.busyRetry",
                defaultValue: english
                    ? "Speaker detection is busy with a recording or another meeting. Try again from the meeting detail."
                    : "녹음 또는 다른 회의의 화자 분석이 진행 중입니다. 회의 기록에서 다시 시도하세요.",
                language: .current,
                comment: "Saved-audio speaker analysis could not start because the model is in use."
            )
        case .superseded:
            return AppLanguage.localized(
                "meeting.diarization.changed",
                defaultValue: english
                    ? "The transcript or speakers changed during analysis, so the result was not applied. Run speaker detection again."
                    : "분석 중 전사 또는 화자 정보가 바뀌어 결과를 적용하지 않았습니다. 화자 분석을 다시 실행하세요.",
                language: .current,
                comment: "Speaker diarization result discarded after a concurrent edit."
            )
        case .unreadablePayload:
            return AppLanguage.localized(
                "meeting.diarization.unreadable",
                defaultValue: english
                    ? "Saved speaker data was created by a newer version and was left unchanged."
                    : "저장된 화자 정보가 더 새로운 버전에서 만들어져 변경하지 않았습니다.",
                language: .current,
                comment: "Unsupported speaker payload schema."
            )
        case .disabled, .modelUnavailable, .completed, .interrupted:
            return nil
        }
    }
}
