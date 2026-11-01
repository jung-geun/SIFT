import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Explicit ChatGPT meeting summaries")
@MainActor
struct MeetingOpenAISummaryTests {
    @Test("whole transcript and every synthesis use the selected GPT model with original citations",
          arguments: [MeetingSummaryModel.gptLuna, .gptSol])
    func fullTranscriptCitationsAndProvenance(model: MeetingSummaryModel) async throws {
        let fixture = MeetingOpenAIFixture()
        let tier = try #require(model.openAITier)
        let expectedModelID = model == .gptLuna ? "gpt-6-luna" : "gpt-6.1-sol"
        let segments = (0..<12).map { index in
            MeetingSegment(id: "source-\(index)", startMs: Int64(index * 1_000), endMs: Int64((index + 1) * 1_000),
                text: "Fact \(index): " + String(repeating: "evidence ", count: 450))
        }
        var original = MeetingResult(transcriptRevision: 4, title: "PRIVATE OLD TITLE", segments: segments)
        original.summary = "PRIVATE OLD SUMMARY"
        let citations = Dictionary(uniqueKeysWithValues: segments.enumerated().map { index, segment in
            (segment.id, MeetingSummaryCitation(trackID: "track-\(index % 2)", segmentID: "original-\(index)", transcriptRevision: 7))
        })
        let outcome = try await MeetingAnalysisEngine().analyzeWithOpenAI(
            meetingID: "parent", result: original, sourceLanguageTag: "mul", summaryLanguageTag: "fr-FR",
            language: .english, summaryFormat: .minutes, customInstructions: "Focus on decisions",
            citationSources: citations, sourceLanguageTags: ["en-US", "ko-KR"], provider: fixture.provider(), tier: tier)
        let inputs = try fixture.transport.inputs()
        #expect(inputs.count > 2)
        #expect(inputs.contains { $0.isSynthesis })
        #expect(inputs.filter { !$0.isSynthesis }.flatMap(\.transcript).map(\.text).joined() == segments.map(\.text).joined())
        #expect(inputs.allSatisfy { $0.vocabulary.isEmpty && $0.customInstructions == "Focus on decisions" && $0.summaryLanguageTag == "fr-FR" })
        #expect(fixture.transport.bodies.allSatisfy { body in
            guard let prompt = body["input"] as? [[String: String]], let text = prompt.first(where: { $0["role"] == "user" })?["content"] else { return false }
            return text.utf8.count <= 24_000 && !text.contains("PRIVATE OLD") && body["model"] as? String == expectedModelID
        })
        #expect(outcome.engineSource == .openAI)
        #expect(outcome.summaryKind == .generated)
        #expect(!outcome.usedOnDeviceLLM)
        #expect(outcome.executionPath == .beta(.openAI))
        #expect(outcome.result.segments == original.segments)
        #expect(outcome.result.transcriptRevision == original.transcriptRevision)
        let actual = Set(outcome.result.summarySections?.flatMap(\.items).flatMap(\.citations) ?? [])
        #expect(actual == Set(citations.values))
        try outcome.authorizationCheck?()
        fixture.generation = UUID()
        #expect(throws: CancellationError.self) { try outcome.authorizationCheck?() }
    }


    #if targetEnvironment(simulator)
    @Test("explicit Apple unavailability fails instead of committing a fallback summary")
    func unavailableApplePreservesPreviousSummary() async throws {
        let (context, record) = try persistedMeeting()
        let before = record.persistenceSnapshot()
        do {
            _ = try await MeetingPostProcessor.refineAndAnalyze(record: record, context: context,
                allowRefine: false, allowModelLoad: false, requireGeneratedSummary: true,
                dependencies: .summary(model: .appleIntelligence))
            Issue.record("Unavailable Apple Intelligence must not produce a fallback summary")
        } catch IntelligenceRoutingError.backendUnavailable(let provider, let reason) {
            #expect(provider == .foundationModels)
            #expect(reason == RuleFallbackReason.unavailable.rawValue)
        }
        #expect(record.persistenceSnapshot() == before)
    }

    @Test("explicit Apple group dependency propagates unavailability")
    func unavailableAppleGroupDoesNotSelectAnotherProvider() async throws {
        let request = MeetingGroupSummaryService.Request(meetingID: "parent",
            result: MeetingResult(segments: [MeetingSegment(id: "source-1", startMs: 0, endMs: 1_000, text: "Evidence")]),
            citationSources: ["source-1": MeetingSummaryCitation(trackID: "track", segmentID: "original-1", transcriptRevision: 2)],
            sourceLanguageTag: "en-US", sourceLanguageTags: ["en-US"], summaryLanguageTag: "fr-FR",
            format: .minutes, customInstructions: "", language: .english)
        do {
            _ = try await MeetingGroupSummaryService.Dependencies.summary(model: .appleIntelligence).analyze(request)
            Issue.record("Unavailable Apple Intelligence must not select a group-summary fallback")
        } catch IntelligenceRoutingError.backendUnavailable(let provider, let reason) {
            #expect(provider == .foundationModels)
            #expect(reason == RuleFallbackReason.unavailable.rawValue)
        }
    }
    #endif

    @Test("incomplete or partially invalid remote documents never overwrite previous notes",
          arguments: ["missingActions", "invalidCitation", "empty", "interrupted"])
    func invalidResponsePreservesSummary(mode: String) async throws {
        let fixture = MeetingOpenAIFixture()
        fixture.transport.mode = mode
        let (context, record) = try persistedMeeting()
        let before = record.persistenceSnapshot()
        await #expect(throws: (any Error).self) {
            try await MeetingPostProcessor.refineAndAnalyze(record: record, context: context,
                allowRefine: false, allowModelLoad: false, requireGeneratedSummary: true,
                dependencies: dependencies(fixture))
        }
        #expect(record.persistenceSnapshot() == before)
    }

    @Test("a failed synthesis is not silently replaced by chunk output")
    func synthesisFailurePropagates() async throws {
        let fixture = MeetingOpenAIFixture()
        fixture.transport.mode = "invalidSynthesis"
        let segments = (0..<8).map { index in
            MeetingSegment(id: "s\(index)", startMs: Int64(index), endMs: Int64(index + 1),
                text: String(repeating: "Source evidence ", count: 500))
        }
        await #expect(throws: OpenAIRequestError.invalidResponse) {
            try await MeetingAnalysisEngine().analyzeWithOpenAI(meetingID: "meeting", result: MeetingResult(segments: segments),
                sourceLanguageTag: "en", summaryLanguageTag: "en", provider: fixture.provider())
        }
        #expect(try fixture.transport.inputs().contains { $0.isSynthesis })
    }

    @Test("account change during preparation cannot send a later chunk to a different account")
    func accountSwitchBetweenChunksStopsDisclosure() async throws {
        let fixture = MeetingOpenAIFixture()
        fixture.onPrepare = {
            // One operation preparation, one first-request preparation, then
            // the next request attempts to refresh into a different account.
            if fixture.preparations == 3 { fixture.generation = UUID() }
        }
        let segments = (0..<6).map { index in
            MeetingSegment(id: "s\(index)", startMs: Int64(index), endMs: Int64(index + 1),
                text: String(repeating: "Transcript ", count: 500))
        }
        await #expect(throws: CancellationError.self) {
            try await MeetingAnalysisEngine().analyzeWithOpenAI(meetingID: "meeting", result: MeetingResult(segments: segments),
                sourceLanguageTag: "en", summaryLanguageTag: "en", provider: fixture.provider())
        }
        #expect(fixture.transport.bodies.count == 1)
    }

    @Test("revocation after inference remains fenced until the atomic save",
          arguments: ["consent", "provider", "region", "account"])
    func revokedBeforeCommitPreservesSummary(revocation: String) async throws {
        let fixture = MeetingOpenAIFixture()
        let (context, record) = try persistedMeeting()
        let before = record.persistenceSnapshot()
        await #expect(throws: (any Error).self) {
            try await MeetingPostProcessor.refineAndAnalyze(record: record, context: context,
                allowRefine: false, allowModelLoad: false, requireGeneratedSummary: true,
                dependencies: dependencies(fixture, afterAnalysis: {
                    switch revocation {
                    case "consent": fixture.consent.revoke()
                    case "provider": fixture.enabled = false
                    case "region": fixture.regionAllowed = false
                    default: fixture.generation = UUID()
                    }
                }))
        }
        #expect(record.persistenceSnapshot() == before)
    }

    @Test("source edits settings changes deletion and cancellation supersede remote responses",
          arguments: ["transcript", "settings", "deletion", "cancel"])
    func staleAndCancelledResponseCannotCommit(change: String) async throws {
        let fixture = MeetingOpenAIFixture()
        let (context, record) = try persistedMeeting()
        var expected = record.persistenceSnapshot()
        let operation = Task { @MainActor in
            try await MeetingPostProcessor.refineAndAnalyze(record: record, context: context,
                allowRefine: false, allowModelLoad: false, requireGeneratedSummary: true,
                dependencies: dependencies(fixture, afterAnalysis: {
                    switch change {
                    case "transcript":
                        var edited = try #require(record.result)
                        edited.segments[0].text = "User edit"
                        edited.transcriptRevision += 1
                        try record.update(result: edited, status: .ready)
                    case "settings": record.summaryCustomInstructions = "New instructions"
                    case "deletion": context.delete(record)
                    default: withUnsafeCurrentTask { $0?.cancel() }
                    }
                    if change != "cancel" { try context.save() }
                    if change != "deletion" { expected = record.persistenceSnapshot() }
                }))
        }
        if change == "cancel" {
            await #expect(throws: CancellationError.self) { try await operation.value }
        } else {
            await #expect(throws: MeetingPostProcessor.Failure.superseded) { try await operation.value }
        }
        if change == "deletion" {
            #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        } else { #expect(record.persistenceSnapshot() == expected) }
    }

    @Test("successful remote persistence changes only analysis and failed save rolls it back", arguments: [false, true])
    func atomicSummaryCommit(failSave: Bool) async throws {
        let fixture = MeetingOpenAIFixture()
        let (context, record) = try persistedMeeting()
        let before = record.persistenceSnapshot()
        let raw = record.rawResultData
        let original = try #require(record.result)
        let dependencies = dependencies(fixture, failSave: failSave)
        if failSave {
            await #expect(throws: MeetingOpenAITestError.saveFailed) {
                try await MeetingPostProcessor.refineAndAnalyze(record: record, context: context,
                    allowRefine: false, allowModelLoad: false, requireGeneratedSummary: true, dependencies: dependencies)
            }
            #expect(record.persistenceSnapshot() == before)
        } else {
            _ = try await MeetingPostProcessor.refineAndAnalyze(record: record, context: context,
                allowRefine: false, allowModelLoad: false, requireGeneratedSummary: true, dependencies: dependencies)
            #expect(record.summaryKindRaw == "generated")
            #expect(record.summaryEngineLabel == "openai")
            #expect(record.summaryFallbackReasonRaw == nil)
            #expect(record.summaryResultLanguageTag == "fr-FR")
            #expect(record.result?.summary != original.summary)
            #expect(record.result?.segments == original.segments)
            #expect(record.result?.transcriptRevision == original.transcriptRevision)
        }
        #expect(record.rawResultData == raw)
    }

    @Test("no meeting consent means no authentication preparation or network")
    func consentRequiredBeforeDisclosure() async throws {
        let fixture = MeetingOpenAIFixture()
        fixture.consent.revoke()
        let result = MeetingResult(segments: [MeetingSegment(id: "s1", startMs: 0, endMs: 1_000, text: "Private transcript")])
        await #expect(throws: OpenAIRequestError.consentRequired) {
            try await MeetingAnalysisEngine().analyzeWithOpenAI(meetingID: "meeting", result: result,
                sourceLanguageTag: "en", summaryLanguageTag: "en", provider: fixture.provider())
        }
        #expect(fixture.preparations == 0)
        #expect(fixture.transport.bodies.isEmpty)
    }

    @Test("remote group save accepts generated provenance and preserves source namespaces", arguments: [false, true])
    func groupSummaryCommitAndRevocation(revoke: Bool) async throws {
        let fixture = MeetingOpenAIFixture()
        let container = try ModelContainer(for: MeetingRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let parent = MeetingRecord(languageTag: "en-US", summaryLanguageTag: "fr-FR")
        try parent.update(result: MeetingResult(title: "Previous group title", summary: "Previous group summary"), status: .ready)
        let tracks = try (0..<2).map { index in
            let track = MeetingRecord(languageTag: "en-US")
            track.parentMeetingID = parent.meetingID
            track.audioTrackKindRaw = MeetingAudioTrackKind.microphone.rawValue
            try track.replaceTranscriptionBase(MeetingResult(transcriptRevision: index + 2, segments: [
                MeetingSegment(id: "same-local-id", startMs: 0, endMs: 1_000, text: "Source \(index) evidence")
            ]), status: .ready)
            context.insert(track)
            return track
        }
        parent.audioTrackIDs = tracks.map(\.meetingID)
        context.insert(parent)
        try context.save()
        let parentBefore = parent.persistenceSnapshot()
        let tracksBefore = tracks.map { $0.persistenceSnapshot() }
        let dependencies = MeetingGroupSummaryService.Dependencies(analyze: { request in
            let outcome = try await MeetingAnalysisEngine().analyzeWithOpenAI(
                meetingID: request.meetingID, result: request.result,
                sourceLanguageTag: request.sourceLanguageTag, summaryLanguageTag: request.summaryLanguageTag,
                summaryFormat: request.format, customInstructions: request.customInstructions,
                citationSources: request.citationSources, sourceLanguageTags: request.sourceLanguageTags,
                provider: fixture.provider())
            if revoke { fixture.consent.revoke() }
            return outcome
        }, save: { try $0.save() })
        if revoke {
            await #expect(throws: OpenAIRequestError.consentRequired) {
                try await MeetingGroupSummaryService.generate(parent: parent, in: context, dependencies: dependencies)
            }
            #expect(parent.persistenceSnapshot() == parentBefore)
        } else {
            #expect(try await MeetingGroupSummaryService.generate(parent: parent, in: context, dependencies: dependencies))
            #expect(parent.summaryKindRaw == "generated")
            #expect(parent.summaryEngineLabel == "openai")
            #expect(parent.summaryResultLanguageTag == "fr-FR")
            #expect(parent.result?.segments.isEmpty == true)
            #expect(parent.result?.actionDrafts.isEmpty == true)
            let citations = Set(parent.result?.summarySections?.flatMap(\.items).flatMap(\.citations) ?? [])
            #expect(citations == Set(tracks.map {
                MeetingSummaryCitation(trackID: $0.meetingID, segmentID: "same-local-id", transcriptRevision: $0.transcriptRevision)
            }))
            #expect(try MeetingGroupSummaryService.isSummaryCurrent(parent: parent, in: context))
        }
        #expect(tracks.map { $0.persistenceSnapshot() } == tracksBefore)
    }

    private func dependencies(_ fixture: MeetingOpenAIFixture,
                              failSave: Bool = false,
                              afterAnalysis: @escaping @MainActor () throws -> Void = {}) -> MeetingPostProcessor.Dependencies {
        .init(snapshot: { .empty },
              refine: { _, _, _, _, _, _ in throw MeetingOpenAITestError.unexpectedRefinement },
              analyze: { id, result, hint, source, output, language, format, custom in
                  #expect(hint.isEmpty)
                  let outcome = try await MeetingAnalysisEngine().analyzeWithOpenAI(
                      meetingID: id, result: result, sourceLanguageTag: source, summaryLanguageTag: output,
                      language: language, summaryFormat: format, customInstructions: custom, provider: fixture.provider())
                  try afterAnalysis()
                  return outcome
              }, save: {
                  if failSave { throw MeetingOpenAITestError.saveFailed }
                  try $0.save()
              }, learnCorrections: { _, _ in Issue.record("Remote retry must not learn corrections") })
    }

    private func persistedMeeting() throws -> (ModelContext, MeetingRecord) {
        let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let record = MeetingRecord(languageTag: "en-US", summaryLanguageTag: "fr-FR")
        var result = MeetingResult(transcriptRevision: 3, title: "Old title", segments: [
            MeetingSegment(id: "s1", startMs: 0, endMs: 1_000, text: "The report ships on Friday.")
        ])
        result.summary = "Old summary"
        try record.replaceTranscriptionBase(result, status: .ready)
        context.insert(record)
        try context.save()
        return (context, record)
    }
}

private enum MeetingOpenAITestError: Error { case saveFailed, unexpectedRefinement }

private final class MeetingOpenAIConsent: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = true
    func allows(_ scope: OpenAIDataScope) -> Bool { lock.withLock { granted && scope == .meetings } }
    func revoke() { lock.withLock { granted = false } }
}

@MainActor
private final class MeetingOpenAIFixture {
    let transport = MeetingOpenAITransport()
    let consent = MeetingOpenAIConsent()
    var generation = UUID()
    var enabled = true
    var regionAllowed = true
    var preparations = 0
    var onPrepare: (() -> Void)?

    func provider() -> OpenAIProviderService {
        OpenAIProviderService(transport: transport, accessToken: { "synthetic-meeting-only" },
            generation: { self.generation }, consent: consent.allows,
            enabled: { self.enabled }, prepareSession: {
                self.preparations += 1
                self.onPrepare?()
            }, regionAllowed: { self.regionAllowed }, accountSubject: { nil })
    }
}

@MainActor
private final class MeetingOpenAITransport: OpenAIResponseTransport {
    struct Input: Decodable {
        struct Segment: Decodable { let number: Int; let text: String }
        let transcript: [Segment]
        let vocabulary: String
        let customInstructions: String
        let sourceLanguageTag: String
        let summaryLanguageTag: String
        let isSynthesis: Bool
    }
    var bodies: [[String: Any]] = []
    var mode = "valid"

    func inputs() throws -> [Input] {
        try bodies.map { body in
            let input = try #require(body["input"] as? [[String: String]])
            let text = try #require(input.first(where: { $0["role"] == "user" })?["content"])
            return try JSONDecoder().decode(Input.self, from: Data(text.utf8))
        }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(#"{"models":[{"slug":"gpt-6-luna","visibility":"list"},{"slug":"gpt-6.1-sol","visibility":"list"}]}"#.utf8),
         response(request, contentType: "application/json"))
    }

    func stream(for request: URLRequest) async throws -> OpenAIEventStream {
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        bodies.append(body)
        let input = try #require(inputs().last)
        let numbers = input.transcript.map(\.number)
        var object: [String: Any] = ["title": "Generated title", "actions": [], "sections": [
            ["id": "summary", "title": "Summary", "items": [
                ["text": "Supported meeting facts", "sourceSegmentNumbers": numbers]
            ]]
        ]]
        switch mode {
        case "missingActions": object.removeValue(forKey: "actions")
        case "invalidCitation": object["sections"] = [["id": "summary", "title": "Summary", "items": [
            ["text": "Valid fact", "sourceSegmentNumbers": numbers],
            ["text": "Unsupported fact", "sourceSegmentNumbers": [999_999]]
        ]]]
        case "empty": object["sections"] = []
        case "invalidSynthesis" where input.isSynthesis: object.removeValue(forKey: "sections")
        default: break
        }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let delta = try event(["type": "response.output_text.delta", "delta": text])
        let complete = try event(["type": "response.completed", "response": ["status": "completed"]])
        let lines = mode == "interrupted" ? [delta, ""] : [delta, "", complete, ""]
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return OpenAIEventStream(response: response(request, contentType: "text/event-stream"), lines: stream, cancel: {})
    }

    private func event(_ object: [String: Any]) throws -> String {
        "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func response(_ request: URLRequest, contentType: String) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType])!
    }
}
