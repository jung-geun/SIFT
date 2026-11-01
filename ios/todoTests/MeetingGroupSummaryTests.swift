import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Whole-group meeting summaries")
@MainActor
struct MeetingGroupSummaryTests {
    @Test("all sources retain original current-ID citations despite colliding local IDs and unknown alignment")
    func crossTrackCitations() async throws {
        let fixture = try Fixture()
        fixture.second.audioTrackKindRaw = MeetingAudioTrackKind.legacyMixed.rawValue
        fixture.second.audioTrackStartSample = 0
        try fixture.context.save()
        var observed: MeetingGroupSummaryService.Request?
        let dependencies = MeetingGroupSummaryService.Dependencies(analyze: { request in
            observed = request
            return analysis(request)
        }, save: { try $0.save() })
        try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context, dependencies: dependencies)
        let request = try #require(observed)
        #expect(request.result.segments.count == 2)
        #expect(Set(request.result.segments.map(\.id)).count == 2)
        #expect(request.result.segments.contains { $0.text.contains("alignment to other sources is UNKNOWN") })
        #expect(request.result.segments.allSatisfy { $0.text.contains("speaker identity local to this source: speaker-1") })
        let citations = fixture.parent.result?.summarySections?.flatMap(\.items).flatMap(\.citations) ?? []
        #expect(Set(citations.map(\.trackID)) == Set([fixture.first.meetingID, fixture.second.meetingID]))
        #expect(citations.allSatisfy { $0.segmentID == "shared-local-id" && $0.transcriptRevision == 3 })
        #expect(fixture.parent.result?.segments.isEmpty == true)
        #expect(fixture.parent.result?.actionDrafts.isEmpty == true)
        #expect(fixture.parent.audioManifest == nil && fixture.parent.rawResult == nil && fixture.parent.diarization == nil)
        #expect(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context))
    }

    @Test("mixed supported source languages retain every concrete provider capability", arguments: ["en-GB", "fr-FR"])
    func mixedSupportedLanguages(secondLanguage: String) async throws {
        let fixture = try Fixture()
        fixture.second.languageTag = secondLanguage
        try fixture.context.save()
        var requestedLanguages: [String] = []
        try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
            dependencies: .init(analyze: { request in
                requestedLanguages = request.sourceLanguageTags
                #expect(Set(request.sourceLanguageTags) == Set(["en-US", secondLanguage]))
                if secondLanguage == "en-GB" {
                    #expect(Locale(identifier: request.sourceLanguageTag).language.languageCode?.identifier == "en")
                    try MeetingSummaryLanguages.requireLocalModelSupport(
                        modelID: "mlx-community/MiniCPM5-1B-4bit", sourceLanguageTag: request.sourceLanguageTag,
                        summaryLanguageTag: request.summaryLanguageTag)
                } else {
                    #expect(request.sourceLanguageTag == "mul")
                }
                #expect(request.summaryLanguageTag == "en-US")
                for tag in request.sourceLanguageTags {
                    try MeetingSummaryLanguages.requireLocalModelSupport(
                        modelID: "mlx-community/Qwen3.5-2B-MLX-4bit", sourceLanguageTag: tag,
                        summaryLanguageTag: request.summaryLanguageTag)
                }
                return analysis(request)
            }, save: { try $0.save() }))
        #expect(requestedLanguages.count == 2)
        #expect(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context))
    }

    @Test("automatic multilingual output requires a concrete choice but regional aliases share their language")
    func automaticSummaryLanguage() async throws {
        let fixture = try Fixture()
        fixture.parent.automaticLanguageDetection = true
        fixture.parent.summaryLanguageTag = ""
        fixture.second.languageTag = "en-GB"
        try fixture.context.save()
        try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
            dependencies: .init(analyze: { request in
                #expect(Locale(identifier: request.summaryLanguageTag).language.languageCode?.identifier == "en")
                try MeetingSummaryLanguages.requireLocalModelSupport(
                    modelID: "mlx-community/MiniCPM5-1B-4bit", sourceLanguageTag: request.sourceLanguageTag,
                    summaryLanguageTag: request.summaryLanguageTag)
                return analysis(request)
            }, save: { try $0.save() }))
        let outputLanguage = try #require(fixture.parent.summaryResultLanguageTag)
        #expect(Locale(identifier: outputLanguage).language.languageCode?.identifier == "en")
        let prior = fixture.parent.resultData
        fixture.second.languageTag = "fr-FR"
        try fixture.context.save()
        await #expect(throws: MeetingGroupSummaryService.Failure.summaryLanguageRequired) {
            try await generate(fixture)
        }
        #expect(fixture.parent.resultData == prior)
    }

    @Test("automatic Chinese output preserves script and requires a choice across writing systems")
    func automaticSummaryLanguageScripts() async throws {
        let fixture = try Fixture()
        fixture.parent.automaticLanguageDetection = true
        fixture.parent.summaryLanguageTag = ""
        fixture.first.languageTag = "zh-Hans-CN"
        fixture.second.languageTag = "zh-Hant-TW"
        try fixture.context.save()
        let prior = fixture.parent.resultData
        var analysisCalls = 0
        let dependencies = MeetingGroupSummaryService.Dependencies(analyze: { request in
            analysisCalls += 1
            #expect(Set(request.sourceLanguageTags) == Set(["zh-Hans-CN", "zh-Hans-SG"]))
            for tag in [request.sourceLanguageTag, request.summaryLanguageTag] {
                let language = Locale(identifier: tag).language
                #expect(language.languageCode?.identifier == "zh")
                #expect(language.script?.identifier == "Hans")
            }
            for tag in request.sourceLanguageTags {
                try MeetingSummaryLanguages.requireLocalModelSupport(
                    modelID: "mlx-community/MiniCPM5-1B-4bit", sourceLanguageTag: tag,
                    summaryLanguageTag: request.summaryLanguageTag)
            }
            return analysis(request)
        }, save: { try $0.save() })
        await #expect(throws: MeetingGroupSummaryService.Failure.summaryLanguageRequired) {
            try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
                dependencies: dependencies)
        }
        #expect(analysisCalls == 0)
        #expect(fixture.parent.resultData == prior)

        fixture.second.languageTag = "zh-Hans-SG"
        try fixture.context.save()
        try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
            dependencies: dependencies)
        #expect(analysisCalls == 1)
        let outputLanguage = try #require(fixture.parent.summaryResultLanguageTag)
        #expect(Locale(identifier: outputLanguage).language.script?.identifier == "Hans")
        #expect(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context))
    }

    @Test("ready silent automatic sources do not block audible language capability", arguments: [false, true])
    func silentAutomaticSource(whitespace: Bool) async throws {
        let fixture = try Fixture()
        fixture.parent.automaticLanguageDetection = true
        fixture.first.automaticLanguageDetection = true
        fixture.first.asrDetectedLanguages = []
        let silentSegments = whitespace ? [MeetingSegment(id: "silent", startMs: 0, endMs: 1_000, text: " \n ")] : []
        try fixture.first.update(result: MeetingResult(transcriptRevision: 4, segments: silentSegments), status: .ready)
        #expect(fixture.first.processingSourceLanguageTag == "und")
        try fixture.context.save()
        #expect(try MeetingGroupSummaryService.canGenerate(parent: fixture.parent, in: fixture.context))
        try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
            dependencies: .init(analyze: { request in
                #expect(request.sourceLanguageTags == ["en-US"])
                #expect(request.result.segments.count == 1)
                #expect(Set(request.citationSources.values.map(\.trackID)) == Set([fixture.second.meetingID]))
                for tag in request.sourceLanguageTags {
                    try MeetingSummaryLanguages.requireLocalModelSupport(
                        modelID: "mlx-community/Qwen3.5-2B-MLX-4bit", sourceLanguageTag: tag,
                        summaryLanguageTag: request.summaryLanguageTag)
                }
                return analysis(request)
            }, save: { try $0.save() }))
        #expect(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context))
        // Silent children are not excluded from source fencing or invalidation.
        fixture.first.audioTrackStartSample += 1
        try fixture.context.save()
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context)))
        fixture.first.update(status: .finalizingTranscript)
        #expect(!(try MeetingGroupSummaryService.canGenerate(parent: fixture.parent, in: fixture.context)))
    }

    @Test("refresh preserves current analysis and does not write merely to refresh")
    func refreshPreservesSummary() async throws {
        let fixture = try Fixture()
        try await generate(fixture)
        let before = fixture.parent.persistenceSnapshot()
        var saves = 0
        try MeetingAudioTrackStore.refresh(parent: fixture.parent, in: fixture.context, save: { _ in saves += 1 })
        #expect(fixture.parent.persistenceSnapshot() == before)
        #expect(saves == 0)
    }

    @Test("refresh storage failure leaves previous analysis bytes and membership intact")
    func refreshRollback() async throws {
        let fixture = try Fixture()
        try await generate(fixture)
        fixture.second.audioTrackStartSample += 1
        try fixture.context.save()
        let before = fixture.parent.persistenceSnapshot()
        #expect(throws: SaveFailure.rejected) {
            try MeetingAudioTrackStore.refresh(parent: fixture.parent, in: fixture.context,
                save: { _ in throw SaveFailure.rejected })
        }
        #expect(fixture.parent.persistenceSnapshot() == before)
    }

    @Test("transcript, membership, source order, alignment and source language invalidate evidence", arguments: Change.sourceChanges)
    func refreshInvalidates(change: Change) async throws {
        let fixture = try Fixture()
        try await generate(fixture)
        try change.apply(fixture)
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context)))
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.parent, in: fixture.context) == .invalid)
        try MeetingAudioTrackStore.refresh(parent: fixture.parent, in: fixture.context)
        #expect(fixture.parent.result?.summary.isEmpty == true)
        #expect(fixture.parent.result?.summarySections == nil)
        #expect(fixture.parent.result?.summarySourceFingerprint == nil)
        #expect(fixture.parent.result?.title == "Whole meeting")
        #expect(fixture.parent.result?.segments.isEmpty == true)
    }

    @Test("output settings preserve prior evidence through refresh and failed regeneration", arguments: Change.outputSettingsChanges)
    func outputSettingsPreserveSummary(change: Change) async throws {
        let fixture = try Fixture()
        try await generate(fixture)
        try change.apply(fixture)
        let prior = fixture.parent.persistenceSnapshot()
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context)))
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.parent, in: fixture.context) == .current)
        try MeetingAudioTrackStore.refresh(parent: fixture.parent, in: fixture.context)
        #expect(fixture.parent.persistenceSnapshot() == prior)

        let reopened = ModelContext(fixture.container)
        let parentID = fixture.parent.meetingID
        let parent = try #require(try reopened.fetch(FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.meetingID == parentID })).first)
        try MeetingAudioTrackStore.refresh(parent: parent, in: reopened)
        #expect(parent.persistenceSnapshot() == prior)
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: parent, in: reopened)))
        await #expect(throws: SaveFailure.rejected) {
            try await MeetingGroupSummaryService.generate(parent: parent, in: reopened,
                dependencies: .init(analyze: { analysis($0) }, save: { _ in throw SaveFailure.rejected }))
        }
        #expect(parent.persistenceSnapshot() == prior)
        try await MeetingGroupSummaryService.generate(parent: parent, in: reopened,
            dependencies: .init(analyze: { analysis($0) }, save: { try $0.save() }))
        #expect(try MeetingGroupSummaryService.isSummaryCurrent(parent: parent, in: reopened))
    }

    @Test("legacy full hashes remain valid until settings change, then remain visible but cannot authorize import")
    func legacyFingerprintCompatibility() async throws {
        let fixture = try Fixture()
        try await generate(fixture)
        var result = try #require(fixture.parent.result)
        let fingerprint = try #require(result.summarySourceFingerprint)
        result.summarySourceFingerprint = String(try #require(fingerprint.split(separator: ":").last))
        try fixture.parent.update(result: result)
        try fixture.context.save()
        #expect(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context))
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.parent, in: fixture.context) == .current)

        try Change.format.apply(fixture)
        let prior = fixture.parent.persistenceSnapshot()
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context)))
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.parent, in: fixture.context) == .unverifiable)
        try MeetingAudioTrackStore.refresh(parent: fixture.parent, in: fixture.context)
        #expect(fixture.parent.persistenceSnapshot() == prior)

        var source = try #require(fixture.second.result)
        source.transcriptRevision += 1
        try fixture.second.update(result: source)
        try fixture.context.save()
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.parent, in: fixture.context) == .invalid)
        try MeetingAudioTrackStore.refresh(parent: fixture.parent, in: fixture.context)
        #expect(fixture.parent.result?.summary.isEmpty == true)
        #expect(fixture.parent.result?.summarySections == nil)
    }

    @Test("legacy prose without citation provenance remains visible but never becomes current")
    func unverifiableLegacySummary() async throws {
        let fixture = try Fixture()
        try await generate(fixture)
        var result = try #require(fixture.parent.result)
        result.summarySourceFingerprint = nil
        result.summarySections = nil
        try fixture.parent.update(result: result)
        try fixture.context.save()
        try Change.language.apply(fixture)
        let prior = fixture.parent.persistenceSnapshot()
        #expect(!(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context)))
        #expect(try MeetingGroupSummaryService.summaryEvidenceValidity(parent: fixture.parent, in: fixture.context) == .unverifiable)
        try MeetingAudioTrackStore.refresh(parent: fixture.parent, in: fixture.context)
        #expect(fixture.parent.persistenceSnapshot() == prior)
    }

    @Test("suspended analysis cannot overwrite edited, removed, reordered or newly configured sources", arguments: Change.allCases)
    func sourceRace(change: Change) async throws {
        let fixture = try Fixture()
        try await generate(fixture)
        let priorData = fixture.parent.resultData
        await #expect(throws: MeetingGroupSummaryService.Failure.superseded) {
            try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
                dependencies: .init(analyze: { request in
                    try change.apply(fixture)
                    return analysis(request)
                }, save: { try $0.save() }))
        }
        #expect(fixture.parent.resultData == priorData)
    }

    @Test("deletion during an analysis never resurrects a cached parent")
    func deletionRace() async throws {
        let fixture = try Fixture()
        let parentID = fixture.parent.meetingID
        await #expect(throws: MeetingGroupSummaryService.Failure.superseded) {
            try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
                dependencies: .init(analyze: { request in
                    fixture.context.delete(fixture.parent)
                    try fixture.context.save()
                    return analysis(request)
                }, save: { try $0.save() }))
        }
        #expect(try fixture.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == parentID })).isEmpty)
    }

    @Test("storage failure, cancellation, excerpts and title-only provider output keep prior valid analysis", arguments: FailedPass.allCases)
    func failedRegeneration(failure: FailedPass) async throws {
        let fixture = try Fixture()
        try await generate(fixture)
        let prior = fixture.parent.persistenceSnapshot()
        do {
            try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
                dependencies: .init(analyze: { request in
                    if failure == .cancelled { throw CancellationError() }
                    if failure == .titleOnly {
                        return MeetingAnalysisEngine.Outcome(result: MeetingResult(title: "Only a title"),
                            engineLabel: "test", usedOnDeviceLLM: true)
                    }
                    if failure == .sourceExcerpts {
                        return MeetingAnalysisEngine.Outcome(result: analysis(request).result,
                            engineLabel: "excerpts", usedOnDeviceLLM: false)
                    }
                    return analysis(request)
                }, save: { context in
                    if failure == .storage { throw SaveFailure.rejected }
                    try context.save()
                }))
            Issue.record("Expected failed group regeneration")
        } catch {
            #expect(fixture.parent.persistenceSnapshot() == prior)
            #expect(try MeetingGroupSummaryService.isSummaryCurrent(parent: fixture.parent, in: fixture.context))
        }
    }

    @Test("a suspended older pass cannot replace newer analysis or commit after task cancellation", arguments: [false, true])
    func suspendedCommit(cancel: Bool) async throws {
        let fixture = try Fixture()
        let gate = AnalysisGate()
        let running = Task { @MainActor in
            try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
                dependencies: .init(analyze: { request in
                    await gate.pause()
                    return analysis(request)
                }, save: { try $0.save() }))
        }
        await gate.waitUntilPaused()
        if cancel { running.cancel() }
        else { try await generate(fixture) }
        let expected = fixture.parent.persistenceSnapshot()
        gate.resume()
        if cancel {
            await #expect(throws: CancellationError.self) { _ = try await running.value }
        } else {
            await #expect(throws: MeetingGroupSummaryService.Failure.superseded) { _ = try await running.value }
        }
        #expect(fixture.parent.persistenceSnapshot() == expected)
    }

    @Test("any processing or failed child prevents a misleading whole-group summary")
    func readiness() throws {
        let fixture = try Fixture()
        #expect(try MeetingGroupSummaryService.canGenerate(parent: fixture.parent, in: fixture.context))
        for status in [MeetingStatus.recording, .finalizingTranscript, .extractingActions, .transcriptFinalizationFailed] {
            fixture.second.update(status: status)
            #expect(!(try MeetingGroupSummaryService.canGenerate(parent: fixture.parent, in: fixture.context)))
        }
    }

    private func generate(_ fixture: Fixture) async throws {
        try await MeetingGroupSummaryService.generate(parent: fixture.parent, in: fixture.context,
            dependencies: .init(analyze: { analysis($0) }, save: { try $0.save() }))
    }

    private func analysis(_ request: MeetingGroupSummaryService.Request) -> MeetingAnalysisEngine.Outcome {
        let items = request.result.segments.enumerated().map { index, segment in
            MeetingSummaryItem(id: "item-\(index)", text: "Evidence from source \(index + 1)",
                               citations: [request.citationSources[segment.id]!])
        }
        var result = MeetingResult(title: "Whole meeting", summary: "All sources")
        result.summarySections = [MeetingSummarySection(id: "minutes", title: "Minutes", items: items)]
        return MeetingAnalysisEngine.Outcome(result: result, engineLabel: "test", usedOnDeviceLLM: true)
    }

    enum FailedPass: CaseIterable, Sendable { case storage, cancelled, titleOnly, sourceExcerpts }
    enum SaveFailure: Error { case rejected }
    enum Change: CaseIterable, Sendable {
        case transcript, added, removed, order, alignment, format, custom, language, sourceLanguage

        static let sourceChanges: [Change] = [.transcript, .added, .removed, .order, .alignment, .sourceLanguage]
        static let outputSettingsChanges: [Change] = [.format, .custom, .language]

        @MainActor
        fileprivate func apply(_ fixture: Fixture) throws {
            switch self {
            case .transcript:
                var result = fixture.second.result!
                // Deliberately retain the revision counter: the full bytes matter.
                result.segments[0].text = "An edited statement"
                try fixture.second.update(result: result)
            case .added:
                let child = Fixture.child(parent: fixture.parent, text: "Another source")
                fixture.context.insert(child)
                fixture.parent.audioTrackIDs.append(child.meetingID)
            case .removed:
                fixture.parent.audioTrackIDs.removeAll { $0 == fixture.second.meetingID }
                fixture.context.delete(fixture.second)
            case .order: fixture.parent.audioTrackIDs.reverse()
            case .alignment: fixture.second.audioTrackStartSample += 1
            case .format: fixture.parent.summaryFormatRaw = MeetingSummaryFormat.interview.rawValue
            case .custom: fixture.parent.summaryCustomInstructions = "Focus on commitments"
            case .language: fixture.parent.summaryLanguageTag = "ko-KR"
            case .sourceLanguage: fixture.second.languageTag = "fr-FR"
            }
            try fixture.context.save()
        }
    }

    @MainActor
    fileprivate final class Fixture {
        let container: ModelContainer
        let context: ModelContext
        let parent: MeetingRecord
        let first: MeetingRecord
        let second: MeetingRecord

        init() throws {
            container = try ModelContainer(for: MeetingRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            context = ModelContext(container)
            context.autosaveEnabled = false
            parent = MeetingRecord(languageTag: "en-US", summaryLanguageTag: "en-US")
            first = Self.child(parent: parent, text: "First source statement")
            second = Self.child(parent: parent, text: "Second source commitment")
            second.audioTrackStartSample = 16_000
            parent.audioTrackIDs = [first.meetingID, second.meetingID]
            try parent.update(result: MeetingResult(title: "Original title"), status: .ready)
            context.insert(parent)
            context.insert(first)
            context.insert(second)
            try context.save()
        }

        static func child(parent: MeetingRecord, text: String) -> MeetingRecord {
            let record = MeetingRecord(languageTag: "en-US")
            record.parentMeetingID = parent.meetingID
            record.audioTrackKindRaw = MeetingAudioTrackKind.microphone.rawValue
            try! record.update(result: MeetingResult(transcriptRevision: 3, segments: [
                MeetingSegment(id: "shared-local-id", lineageID: "stable-lineage", startMs: 0, endMs: 1_000,
                               speakerIDs: ["speaker-1"], text: text)
            ]), status: .ready)
            return record
        }
    }
    @MainActor
    private final class AnalysisGate {
        private var paused = false
        private var continuation: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?

        func pause() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                paused = true
                observer?.resume()
                observer = nil
            }
        }

        func waitUntilPaused() async {
            if paused { return }
            await withCheckedContinuation { observer = $0 }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}
