import Foundation
import SwiftData
import Testing
@testable import todo

// MARK: - AI 검수 결과 diff (FM 불필요, 결정론적)
//
// 교정 전(raw) ↔ 교정 후(current) 전사를 비교해 무엇이 바뀌었는지 계산하는
// 순수 로직 검증. 시뮬레이터에서 AFM/MLX 없이 실행 가능.

@Suite("MeetingProofread 교정 diff")
struct MeetingProofreadTests {

    private func seg(_ start: Int64, _ text: String) -> MeetingSegment {
        MeetingSegment(id: "seg-\(start)", startMs: start, endMs: start + 1_000, text: text)
    }

    private func result(_ segments: [MeetingSegment], revision: Int = 0) -> MeetingResult {
        MeetingResult(transcriptRevision: revision, segments: segments)
    }

    @Test("바뀐 구간만 교정 목록에 포함")
    func onlyChangedSegments() {
        let raw = result([seg(0, "쿠버네이트 배포"), seg(1_000, "회의를 시작합니다")])
        let current = result([seg(0, "쿠버네티스 배포"), seg(1_000, "회의를 시작합니다")], revision: 1)
        let corrections = MeetingProofread.corrections(raw: raw, current: current)
        #expect(corrections.count == 1)
        #expect(corrections.first?.before == "쿠버네이트 배포")
        #expect(corrections.first?.after == "쿠버네티스 배포")
    }

    @Test("변경 없으면 빈 목록")
    func noChanges() {
        let raw = result([seg(0, "동일한 문장")])
        let current = result([seg(0, "동일한 문장")], revision: 1)
        #expect(MeetingProofread.corrections(raw: raw, current: current).isEmpty)
    }

    @Test("공백 정규화만 바뀌면 교정 표시를 만들지 않음")
    func whitespaceOnlyChangesAreNotCorrections() {
        let raw = result([seg(0, "같은   문장")])
        let current = result([seg(0, "같은 문장")], revision: 1)

        #expect(MeetingProofread.corrections(raw: raw, current: current).isEmpty)
        #expect(
            MeetingProofread.inlinePresentation(
                raw: raw,
                current: current,
                engineLabel: MeetingRefinementEngine.Source.appleIntelligence.rawValue,
                language: .korean
            ) == .unchanged(engineLabel: "Apple Intelligence 온디바이스")
        )
    }

    @Test("타임스탬프로 매칭 — 순서 뒤섞여도 정확")
    func matchesByTimestamp() {
        let raw = result([seg(0, "첫 구간"), seg(2_000, "둘째 구간 원본")])
        let current = result([seg(2_000, "둘째 구간 교정"), seg(0, "첫 구간")], revision: 1)
        let corrections = MeetingProofread.corrections(raw: raw, current: current)
        #expect(corrections.count == 1)
        #expect(corrections.first?.startMs == 2_000)
        #expect(corrections.first?.after == "둘째 구간 교정")
    }

    @Test("타임스탬프가 새로 생긴 구간(수동 분할)은 제외")
    func ignoresUnmatchedTimestamps() {
        let raw = result([seg(0, "원본 구간")])
        // 사용자가 분할해 500ms 지점의 새 구간 — raw에 없으므로 diff 대상 아님.
        let current = result([seg(0, "원본 구간"), seg(500, "분할된 새 구간")], revision: 1)
        #expect(MeetingProofread.corrections(raw: raw, current: current).isEmpty)
    }

    @Test("단어 단위 diff — 교체된 단어만 removed/added")
    func wordLevelDiff() {
        let tokens = MeetingProofread.diffTokens(before: "다음 쿠버네이트 배포를 논의", after: "다음 쿠버네티스 배포를 논의")
        // 같은 단어는 same, 바뀐 단어만 removed/added.
        #expect(tokens.contains(.removed("쿠버네이트")))
        #expect(tokens.contains(.added("쿠버네티스")))
        #expect(tokens.contains(.same("다음")))
        #expect(tokens.contains(.same("배포를")))
        #expect(tokens.contains(.same("논의")))
    }

    @Test("단어 삽입 diff — added만, removed 없음")
    func insertionDiff() {
        let tokens = MeetingProofread.diffTokens(before: "견적서를 보냅니다", after: "다음 주에 견적서를 보냅니다")
        #expect(tokens.contains(.added("다음")))
        #expect(tokens.contains(.added("주에")))
        #expect(!tokens.contains(where: { if case .removed = $0 { return true }; return false }))
    }
    @Test("inline presentation respects provenance and revisions")
    func inlinePresentationStates() throws {
        let raw = result([seg(0, "원문")])
        #expect(MeetingProofread.inlinePresentation(raw: nil, current: raw, engineLabel: MeetingRefinementEngine.Source.appleIntelligence.rawValue, language: .korean) == .hidden)
        #expect(MeetingProofread.inlinePresentation(raw: raw, current: raw, engineLabel: "", language: .korean) == .hidden)
        #expect(
            MeetingProofread.inlinePresentation(raw: raw, current: raw, engineLabel: MeetingRefinementEngine.Source.appleIntelligence.rawValue, language: .korean) ==
            .unchanged(engineLabel: "Apple Intelligence 온디바이스")
        )

        var correctedInput = raw.segments
        correctedInput[0].text = "교정문"
        let corrected = try MeetingRevisionEditor.editSegments(
            meetingID: "123e4567-e89b-12d3-a456-426614174000",
            in: raw,
            segments: correctedInput
        )
        let changed = MeetingProofread.inlinePresentation(
            raw: raw,
            current: corrected,
            engineLabel: MeetingRefinementEngine.Source.appleIntelligence.rawValue,
            language: .korean
        )
        guard case .changed("Apple Intelligence 온디바이스", let corrections) = changed else {
            Issue.record("Expected changed inline presentation")
            return
        }
        #expect(corrections[corrected.segments[0].id]?.before == "원문")
        #expect(corrections[corrected.segments[0].id]?.after == "교정문")

        var manuallyEdited = corrected
        manuallyEdited.transcriptRevision += 1
        #expect(
            MeetingProofread.inlinePresentation(
                raw: raw,
                current: manuallyEdited,
                engineLabel: MeetingRefinementEngine.Source.appleIntelligence.rawValue,
                language: .korean
            ) == .hidden
        )
    }

    @Test("stable lineage survives equal timing, order flips, and equal corrected text")
    func stableLineageMatching() throws {
        let raw = try result([
            MeetingSegment(id: "raw-a", startMs: 0, endMs: 1_000, text: "첫 원문"),
            MeetingSegment(id: "raw-z", startMs: 0, endMs: 1_000, text: "둘째 원문")
        ]).validated()
        var correctedInput = raw.segments
        correctedInput[0].text = "같은 교정문"
        correctedInput[1].text = "같은 교정문"
        let corrected = try MeetingRevisionEditor.editSegments(
            meetingID: "123e4567-e89b-12d3-a456-426614174000",
            in: raw,
            segments: correctedInput
        )

        #expect(Set(corrected.segments.map(\.id)).count == 2)
        #expect(Set(corrected.segments.compactMap(\.lineageID)) == ["raw-a", "raw-z"])
        guard case .changed(_, let corrections) = MeetingProofread.inlinePresentation(
            raw: raw,
            current: corrected,
            engineLabel: MeetingRefinementEngine.Source.appleIntelligence.rawValue,
            language: .korean
        ) else {
            Issue.record("Expected two lineage-backed corrections")
            return
        }
        #expect(corrections.count == 2)
        for segment in corrected.segments {
            #expect(corrections[segment.id]?.before == (segment.lineageID == "raw-a" ? "첫 원문" : "둘째 원문"))
            #expect(corrections[segment.id]?.after == "같은 교정문")
        }
    }

    @Test("legacy timing fallback hides ambiguous duplicate ranges")
    func legacyTimingFallback() {
        let uniqueRaw = result([
            MeetingSegment(id: "raw", startMs: 10, endMs: 20, text: "원문")
        ])
        let uniqueCurrent = result([
            MeetingSegment(id: "current", startMs: 10, endMs: 20, text: "교정")
        ], revision: 1)
        guard case .changed = MeetingProofread.inlinePresentation(
            raw: uniqueRaw,
            current: uniqueCurrent,
            engineLabel: MeetingRefinementEngine.Source.appleIntelligence.rawValue,
            language: .korean
        ) else {
            Issue.record("Expected safe unique-timing fallback")
            return
        }

        let ambiguousRaw = result([
            MeetingSegment(id: "raw-a", startMs: 10, endMs: 20, text: "원문 A"),
            MeetingSegment(id: "raw-b", startMs: 10, endMs: 20, text: "원문 B")
        ])
        let ambiguousCurrent = result([
            MeetingSegment(id: "current-a", startMs: 10, endMs: 20, text: "교정 A"),
            MeetingSegment(id: "current-b", startMs: 10, endMs: 20, text: "교정 B")
        ], revision: 1)
        #expect(
            MeetingProofread.inlinePresentation(
                raw: ambiguousRaw,
                current: ambiguousCurrent,
                engineLabel: MeetingRefinementEngine.Source.appleIntelligence.rawValue,
                language: .korean
            ) == .hidden
        )
    }

    @Test("record committer restores every persisted meeting field")
    @MainActor
    func recordCommitRollback() throws {
        let base = result([seg(0, "원문")])
        let record = MeetingRecord(
            meetingID: "123e4567-e89b-12d3-a456-426614174000",
            languageTag: "ko-KR",
            timezoneIdentifier: "UTC"
        )
        try record.replaceTranscriptionBase(base, status: .ready)
        record.refinementEngineLabel = MeetingRefinementEngine.Source.appleIntelligence.rawValue
        let before = record.persistenceSnapshot()

        #expect(throws: ProofreadTestError.saveFailed) {
            try MeetingRecordCommitter.persist(
                record: record,
                save: { throw ProofreadTestError.saveFailed },
                mutate: {
                    var changed = base
                    changed.summary = "저장되면 안 됨"
                    try record.update(result: changed, status: .transcriptFinalizationFailed)
                    record.refinementEngineLabel = ""
                }
            )
        }
        #expect(record.persistenceSnapshot() == before)
    }

    @Test("failed refinement commit analyzes and saves the raw base")
    @MainActor
    func failedRefinementCommitUsesRawBase() async throws {
        let meetingID = "123e4567-e89b-12d3-a456-426614174000"
        let base = result([MeetingSegment(id: "raw", startMs: 0, endMs: 1_000, text: "원문")])
        var correctedInput = base.segments
        correctedInput[0].text = "교정문"
        let corrected = try MeetingRevisionEditor.editSegments(
            meetingID: meetingID,
            in: base,
            segments: correctedInput
        )
        let configuration = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        let record = MeetingRecord(meetingID: meetingID, languageTag: "ko-KR", timezoneIdentifier: "UTC")
        try record.replaceTranscriptionBase(base, status: .ready)
        context.insert(record)
        try context.save()

        var saveCount = 0
        var learnedCount = 0
        var analyzedText = ""
        let dependencies = MeetingPostProcessor.Dependencies(
            snapshot: { .empty },
            refine: { _, _, _, _, _ in
                .applied(
                    result: corrected,
                    changed: true,
                    source: .appleIntelligence,
                    correctionPairs: [(from: "원문", to: "교정문")],
                    providerRan: true
                )
            },
            analyze: { _, input, _, _ in
                analyzedText = input.segments.first?.text ?? ""
                var analyzed = input
                analyzed.summary = "원문 요약"
                return MeetingAnalysisEngine.Outcome(
                    result: analyzed,
                    engineLabel: "테스트",
                    usedOnDeviceLLM: false
                )
            },
            save: { target in
                saveCount += 1
                if saveCount == 1 { throw ProofreadTestError.saveFailed }
                try target.save()
            },
            learnCorrections: { _, pairs in learnedCount += pairs.count }
        )
        let reporter = MeetingProcessingReporter()

        let outcome = try await MeetingPostProcessor.refineAndAnalyze(
            record: record,
            context: context,
            allowRefine: true,
            allowModelLoad: false,
            reporter: reporter,
            dependencies: dependencies
        )

        #expect(!outcome.refined)
        #expect(analyzedText == "원문")
        #expect(record.result?.segments.first?.text == "원문")
        #expect(record.result?.summary == "원문 요약")
        #expect(record.refinementEngineLabel.isEmpty)
        #expect(learnedCount == 0)
        guard case .completed(let proofread, _) = reporter.phase else {
            Issue.record("Expected completed processing state")
            return
        }
        #expect(MeetingProcessingStatusView.compactCompletionText(for: proofread, language: .korean) == "AI 검수 실패 · 원문으로 요약 완료")
    }

    @Test("successful refinement commit learns once and final-save failure rolls back")
    @MainActor
    func successfulRefinementAndFinalRollback() async throws {
        let meetingID = "123e4567-e89b-12d3-a456-426614174000"
        let base = result([MeetingSegment(id: "raw", startMs: 0, endMs: 1_000, text: "원문")])
        var correctedInput = base.segments
        correctedInput[0].text = "교정문"
        let corrected = try MeetingRevisionEditor.editSegments(
            meetingID: meetingID,
            in: base,
            segments: correctedInput
        )
        let configuration = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        let record = MeetingRecord(meetingID: meetingID, languageTag: "ko-KR", timezoneIdentifier: "UTC")
        try record.replaceTranscriptionBase(base, status: .ready)
        context.insert(record)
        try context.save()

        var saveCount = 0
        var learnedCount = 0
        let dependencies = MeetingPostProcessor.Dependencies(
            snapshot: { .empty },
            refine: { _, _, _, _, _ in
                .applied(
                    result: corrected,
                    changed: true,
                    source: .appleIntelligence,
                    correctionPairs: [(from: "원문", to: "교정문")],
                    providerRan: true
                )
            },
            analyze: { _, input, _, _ in
                var analyzed = input
                analyzed.summary = "저장 실패 요약"
                return MeetingAnalysisEngine.Outcome(
                    result: analyzed,
                    engineLabel: "테스트",
                    usedOnDeviceLLM: false
                )
            },
            save: { target in
                saveCount += 1
                if saveCount == 2 { throw ProofreadTestError.saveFailed }
                try target.save()
            },
            learnCorrections: { _, pairs in learnedCount += pairs.count }
        )

        await #expect(throws: ProofreadTestError.saveFailed) {
            _ = try await MeetingPostProcessor.refineAndAnalyze(
                record: record,
                context: context,
                allowRefine: true,
                allowModelLoad: false,
                dependencies: dependencies
            )
        }
        #expect(record.result?.segments.first?.text == "교정문")
        #expect(record.result?.summary.isEmpty == true)
        #expect(record.refinementEngineLabel == MeetingRefinementEngine.Source.appleIntelligence.rawValue)
        #expect(learnedCount == 1)
    }
    @Test("meeting language tag propagates to refinement and analysis dependencies")
    @MainActor
    func meetingLanguagePropagation() async throws {
        let meetingID = "123e4567-e89b-12d3-a456-426614174000"
        let base = result([MeetingSegment(id: "raw", startMs: 0, endMs: 1_000, text: "We will send it.")])
        let configuration = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        let record = MeetingRecord(meetingID: meetingID, languageTag: "en-US", timezoneIdentifier: "UTC")
        try record.replaceTranscriptionBase(base, status: .ready)
        context.insert(record)
        try context.save()

        var refinementLanguage: AppLanguage?
        var analysisLanguage: AppLanguage?
        let dependencies = MeetingPostProcessor.Dependencies(
            snapshot: { .empty },
            refine: { _, _, _, language, _ in
                refinementLanguage = language
                return .skipped(.unavailable)
            },
            analyze: { _, input, _, language in
                analysisLanguage = language
                return MeetingAnalysisEngine.Outcome(result: input, engineLabel: "Test", usedOnDeviceLLM: false)
            },
            save: { try $0.save() },
            learnCorrections: { _, _ in }
        )

        _ = try await MeetingPostProcessor.refineAndAnalyze(
            record: record,
            context: context,
            allowRefine: true,
            allowModelLoad: false,
            dependencies: dependencies
        )
        #expect(refinementLanguage == .english)
        #expect(analysisLanguage == .english)
    }

    @Test("base replacement resets provenance while summary updates preserve it")
    @MainActor
    func baseAndSummaryProvenance() throws {
        let record = MeetingRecord(
            meetingID: "123e4567-e89b-12d3-a456-426614174000",
            languageTag: "ko-KR",
            timezoneIdentifier: "UTC"
        )
        let old = result([seg(0, "이전")])
        try record.replaceTranscriptionBase(old, status: .ready)
        record.refinementEngineLabel = "stale"

        let replacement = result([seg(0, "새 원문")], revision: 3)
        try record.replaceTranscriptionBase(replacement, status: .transcriptFinalizationFailed)
        #expect(record.result == replacement)
        #expect(record.rawResult == replacement)
        #expect(record.status == .transcriptFinalizationFailed)
        #expect(record.refinementEngineLabel.isEmpty)

        record.refinementEngineLabel = MeetingRefinementEngine.Source.appleIntelligence.rawValue
        var summaryOnly = replacement
        summaryOnly.summary = "새 요약"
        try MeetingRecordCommitter.persist(
            record: record,
            save: {},
            mutate: {
                try record.update(
                    result: summaryOnly,
                    status: .transcriptFinalizationFailed
                )
            }
        )
        #expect(record.result?.summary == "새 요약")
        #expect(record.refinementEngineLabel == MeetingRefinementEngine.Source.appleIntelligence.rawValue)
        #expect(record.status == .transcriptFinalizationFailed)
    }

    @Test("refinement provenance stores stable IDs and maps legacy labels per language")
    @MainActor
    func stableSourceDisplayMapping() {
        let record = MeetingRecord(languageTag: "en-US")
        record.refinementEngineLabel = MeetingRefinementEngine.Source.appleIntelligence.rawValue
        let englishDisplay = record.refinementEngineDisplayName(language: .english)
        #expect(englishDisplay == "Apple Intelligence (On Device)", "English display: \(englishDisplay)")
        let koreanDisplay = record.refinementEngineDisplayName(language: .korean)
        #expect(koreanDisplay == "Apple Intelligence 온디바이스", "Korean display: \(koreanDisplay)")

        record.refinementEngineLabel = "온디바이스 LLM(Qwen)"
        #expect(record.refinementEngineDisplayName(language: .english) == "On-Device LLM (Qwen)")
        record.refinementEngineLabel = "legacy-provider"
        #expect(record.refinementEngineDisplayName(language: .english) == "Unknown Engine")
    }
    @Test("compact completion copy only supplements failed and skipped proofread")
    func compactCompletionCopy() {
        #expect(
            MeetingProcessingStatusView.compactCompletionText(
                for: .changed(count: 1, engine: "AFM")
            ) == nil
        )
        #expect(
            MeetingProcessingStatusView.compactCompletionText(
                for: .unchanged(engine: "AFM")
            ) == nil
        )
        #expect(
            MeetingProcessingStatusView.compactCompletionText(
                for: .failed(engine: "AFM", message: "failure"),
                language: .korean
            ) == "AI 검수 실패 · 원문으로 요약 완료"
        )
        #expect(
            MeetingProcessingStatusView.compactCompletionText(
                for: .skipped(reason: .disabled),
                language: .korean
            ) == "AI 검수를 건너뜀 · 요약 완료"
        )
    }
    @Test("refinement cancellation propagates without analysis")
    @MainActor
    func refinementCancellationPropagates() async throws {
        let meetingID = "123e4567-e89b-12d3-a456-426614174000"
        let base = result([MeetingSegment(id: "raw", startMs: 0, endMs: 1_000, text: "원문")])
        let configuration = ModelConfiguration(
            schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        let record = MeetingRecord(meetingID: meetingID, languageTag: "ko-KR", timezoneIdentifier: "UTC")
        try record.replaceTranscriptionBase(base, status: .ready)
        context.insert(record)
        try context.save()
        var analysisCalled = false
        let dependencies = MeetingPostProcessor.Dependencies(
            snapshot: { .empty },
            refine: { _, _, _, _, _ in throw CancellationError() },
            analyze: { _, input, _, _ in
                analysisCalled = true
                return MeetingAnalysisEngine.Outcome(result: input, engineLabel: "test", usedOnDeviceLLM: false)
            },
            save: { try $0.save() },
            learnCorrections: { _, _ in }
        )

        await #expect(throws: CancellationError.self) {
            _ = try await MeetingPostProcessor.refineAndAnalyze(
                record: record,
                context: context,
                allowRefine: true,
                allowModelLoad: false,
                dependencies: dependencies
            )
        }
        #expect(!analysisCalled)
        #expect(record.refinementFallbackReasonRaw == nil)
    }
}

private enum ProofreadTestError: Error {
    case saveFailed
}
