import Combine
import Foundation
import SwiftData

/// Applies stable speaker evidence to a transcript. Manual assignments win;
/// timed-run boundaries keep known, overlapping and unknown text turns separate.
enum MeetingSpeakerLabelApplier {
    struct Application {
        let result: MeetingResult
        let raw: MeetingResult?
        let didSplit: Bool
    }

    static func apply(
        meetingID: String,
        current: MeetingResult,
        raw: MeetingResult?,
        intervals: [MeetingSpeakerInterval],
        coveredThroughSample: Int64,
        manualAssignments: [String: [String]]
    ) throws -> Application {
        var segments: [MeetingSegment] = []
        var children: [String: [MeetingSegment]] = [:]
        var labels: [String: [String]] = [:]
        for segment in current.segments {
            let lineage = segment.stableLineageID
            var labeled = segment
            if let manual = manualAssignments[lineage] {
                labeled.speakerIDs = manual
            } else {
                let start = segment.startMs * MeetingSpeakerAlignment.samplesPerMillisecond
                let end = segment.endMs * MeetingSpeakerAlignment.samplesPerMillisecond
                let relevant = intervals.filter { $0.startSample < end && $0.endSample > start }
                if let runs = segment.timedRuns, !runs.isEmpty {
                    let runLabels = MeetingSpeakerAlignment.assign(
                        runs: runs, intervals: relevant, coveredThroughSample: coveredThroughSample
                    )
                    let turns = MeetingSpeakerAlignment.turns(
                        textLength: segment.text.utf16.count,
                        startMs: segment.startMs, endMs: segment.endMs,
                        runs: runs, labels: runLabels
                    )
                    if turns.count > 1, let split = split(segment, turns: turns) {
                        children[lineage] = split
                        segments.append(contentsOf: split)
                        continue
                    }
                    labeled.speakerIDs = turns.first?.speakerIDs ?? []
                } else {
                    labeled.speakerIDs = MeetingSpeakerAlignment.assignSegment(
                        startMs: segment.startMs, endMs: segment.endMs,
                        intervals: relevant, coveredThroughSample: coveredThroughSample
                    )
                }
            }
            labels[lineage] = labeled.speakerIDs
            segments.append(labeled)
        }

        let updated: MeetingResult
        if children.isEmpty {
            var copy = current
            copy.segments = segments
            updated = try copy.validated()
        } else {
            // One new revision; stale summary and drafts are invalidated.
            updated = try MeetingRevisionEditor.editSegments(meetingID: meetingID, in: current, segments: segments)
        }

        guard let raw else { return Application(result: updated, raw: nil, didSplit: !children.isEmpty) }
        if raw.hasSameTranscript(as: current) {
            return Application(result: updated, raw: updated, didSplit: !children.isEmpty)
        }
        let originals = Dictionary(current.segments.map { ($0.stableLineageID, $0) }, uniquingKeysWith: { first, _ in first })
        var rawSegments: [MeetingSegment] = []
        for segment in raw.segments {
            let lineage = segment.stableLineageID
            if let split = children[lineage], let original = originals[lineage],
               original.text == segment.text, original.startMs == segment.startMs,
               original.endMs == segment.endMs, original.timedRuns == segment.timedRuns {
                rawSegments.append(contentsOf: split.map { child in
                    MeetingSegment(
                        id: MeetingCanonicalID.replacementSegment(
                            meetingID: meetingID, transcriptRevision: raw.transcriptRevision,
                            startMs: child.startMs, endMs: child.endMs, text: child.text,
                            lineageID: child.stableLineageID
                        ),
                        lineageID: child.stableLineageID, startMs: child.startMs, endMs: child.endMs,
                        speakerIDs: child.speakerIDs, text: child.text, isFinal: child.isFinal,
                        confidence: child.confidence, timedRuns: child.timedRuns
                    )
                })
            } else {
                var copy = segment
                if let label = labels[lineage] { copy.speakerIDs = label }
                rawSegments.append(copy)
            }
        }
        var updatedRaw = raw
        updatedRaw.segments = rawSegments.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
        return Application(result: updated, raw: try updatedRaw.validated(), didSplit: !children.isEmpty)
    }

    /// Children keep the original words; runs are rebased onto each child's text.
    private static func split(_ segment: MeetingSegment, turns: [MeetingSpeakerTextTurn]) -> [MeetingSegment]? {
        let units = Array(segment.text.utf16)
        var result: [MeetingSegment] = []
        for turn in turns {
            var lower = turn.utf16Start
            var upper = turn.utf16End
            while lower < upper, isWhitespace(units[lower]) { lower += 1 }
            while upper > lower, isWhitespace(units[upper - 1]) { upper -= 1 }
            guard lower < upper, turn.startMs < turn.endMs else { return nil }
            let runs = turn.runs.compactMap { run -> MeetingTimedTextRun? in
                let start = max(run.utf16Offset, lower)
                let end = min(run.utf16Offset + run.utf16Length, upper)
                guard end > start else { return nil }
                return MeetingTimedTextRun(utf16Offset: start - lower, utf16Length: end - start,
                                           startMs: run.startMs, endMs: run.endMs)
            }
            let lineage = MeetingCanonicalID.speakerTurnLineage(
                parentLineageID: segment.stableLineageID, startMs: turn.startMs, endMs: turn.endMs
            )
            result.append(MeetingSegment(
                id: lineage, lineageID: lineage, startMs: turn.startMs, endMs: turn.endMs,
                speakerIDs: turn.speakerIDs, text: String(decoding: units[lower..<upper], as: UTF16.self),
                isFinal: segment.isFinal, confidence: segment.confidence, timedRuns: runs
            ))
        }
        return result
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace
    }
}

/// Stable speaker identities for one meeting.
enum MeetingSpeakerProfileBook {
    static let maximumActiveSpeakers = 8

    /// Legacy free-text labels keep their identifier; the old text becomes the
    /// display name and is protected as a manual assignment.
    static func legacySeed(result: MeetingResult) throws -> (profiles: [MeetingSpeakerProfile], manualAssignments: [String: [String]]) {
        var order: [String] = []
        var manual: [String: [String]] = [:]
        for segment in result.segments where !segment.speakerIDs.isEmpty {
            for id in segment.speakerIDs where !order.contains(id) { order.append(id) }
            manual[segment.stableLineageID] = Array(Set(segment.speakerIDs)).sorted()
        }
        guard order.count <= maximumActiveSpeakers else { throw MeetingSpeakerEditError.tooManySpeakers }
        let profiles = order.enumerated().map { MeetingSpeakerProfile(id: $0.element, ordinal: $0.offset + 1, displayName: $0.element) }
        return (profiles, manual)
    }

    static func activeIDs(intervals: [MeetingSpeakerInterval], manualAssignments: [String: [String]]) -> Set<String> {
        Set(intervals.map(\.speakerID)).union(manualAssignments.values.flatMap { $0 })
    }

    /// Maps newly detected speakers onto reference identities; unmatched ones get
    /// a fresh UUID and the lowest vacant ordinal among active speakers, or stay
    /// unknown when all eight ordinals are taken. Names never move to a new ID.
    static func assemble(
        detected: [MeetingSpeakerInterval],
        reference: [MeetingSpeakerInterval],
        referenceProfiles: [MeetingSpeakerProfile],
        existingProfiles: [MeetingSpeakerProfile],
        manualAssignments: [String: [String]],
        voiceEvidence: MeetingSpeakerVoiceEvidence? = nil
    ) -> (intervals: [MeetingSpeakerInterval], profiles: [MeetingSpeakerProfile]) {
        let referenceByID = Dictionary(referenceProfiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var mapping = MeetingSpeakerIdentityMatcher.match(
            new: detected, reference: reference,
            referenceOrdinals: referenceByID.mapValues(\.ordinal), voiceEvidence: voiceEvidence
        )
        var profiles = Dictionary(existingProfiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let manualIDs = Set(manualAssignments.values.flatMap { $0 })
        var used = Set(manualIDs.compactMap { profiles[$0]?.ordinal })
        for id in Set(mapping.values) { if let ordinal = profiles[id]?.ordinal { used.insert(ordinal) } }
        func vacantOrdinal() -> Int? { (1...maximumActiveSpeakers).first { !used.contains($0) } }

        // Adopted live identities keep their live number unless it is taken.
        let adopted = Set(mapping.values).filter { profiles[$0] == nil }
            .sorted { (referenceByID[$0]?.ordinal ?? Int.max, $0) < (referenceByID[$1]?.ordinal ?? Int.max, $1) }
        for id in adopted {
            let preferred = referenceByID[id]?.ordinal
            let ordinal = preferred.flatMap { used.contains($0) || !(1...maximumActiveSpeakers).contains($0) ? nil : $0 } ?? vacantOrdinal()
            guard let ordinal else {
                mapping = mapping.filter { $0.value != id }
                continue
            }
            used.insert(ordinal)
            profiles[id] = MeetingSpeakerProfile(id: id, ordinal: ordinal, displayName: nil)
        }
        for id in MeetingSpeakerIdentityMatcher.firstAppearanceOrder(detected) where mapping[id] == nil {
            guard let ordinal = vacantOrdinal() else { continue }
            let newID = UUID().uuidString.lowercased()
            used.insert(ordinal)
            profiles[newID] = MeetingSpeakerProfile(id: newID, ordinal: ordinal, displayName: nil)
            mapping[id] = newID
        }
        let intervals = detected.compactMap { interval in
            mapping[interval.speakerID].map {
                MeetingSpeakerInterval(speakerID: $0, startSample: interval.startSample, endSample: interval.endSample)
            }
        }.sorted { ($0.startSample, $0.endSample, $0.speakerID) < ($1.startSample, $1.endSample, $1.speakerID) }
        // Unnamed identities nobody references are noise; named ones are kept.
        let referenced = Set(intervals.map(\.speakerID)).union(manualIDs)
        let kept = profiles.values.filter { referenced.contains($0.id) || $0.displayName != nil }
        return (intervals, kept.sorted { ($0.ordinal, $0.id) < ($1.ordinal, $1.id) })
    }

    /// Manual assignments follow the transcript lineage: kept lineages keep them,
    /// a new lineage inherits the union only when every overlapping former segment
    /// was manually assigned, and removed lineages are pruned.
    static func carryManualAssignments(
        _ manual: [String: [String]],
        from old: MeetingResult,
        to new: MeetingResult
    ) -> [String: [String]] {
        let oldLineages = Set(old.segments.map(\.stableLineageID))
        var carried: [String: [String]] = [:]
        for segment in new.segments {
            let lineage = segment.stableLineageID
            if oldLineages.contains(lineage) {
                if let ids = manual[lineage] { carried[lineage] = ids }
                continue
            }
            let overlapping = old.segments.filter { $0.startMs < segment.endMs && $0.endMs > segment.startMs }
            guard !overlapping.isEmpty,
                  overlapping.allSatisfy({ manual[$0.stableLineageID] != nil }) else { continue }
            carried[lineage] = Array(Set(overlapping.flatMap { manual[$0.stableLineageID] ?? [] })).sorted()
        }
        return carried
    }
}

@MainActor
enum MeetingDiarizationCommitter {
    enum Outcome: Equatable {
        case committed(didSplit: Bool)
        case superseded
    }

    /// Commits only if the payload generation, audio manifest and transcript
    /// content (excluding speaker labels) still match the replayed source.
    static func commit(
        record: MeetingRecord,
        generation: UUID,
        manifestDigest: String,
        sourceDigest: String,
        evidence: MeetingDiarizationReplay.Evidence,
        liveTimeline: MeetingLiveSpeakerTimeline?,
        save: () throws -> Void
    ) throws -> Outcome {
        guard let payload = record.diarization, payload.generation == generation,
              let manifest = record.audioManifest,
              (try? MeetingDiarizationFingerprint.manifest(manifest)) == manifestDigest,
              let current = record.result,
              (try? MeetingDiarizationFingerprint.source(current)) == sourceDigest
        else { return .superseded }

        let lineages = Set(current.segments.map(\.stableLineageID))
        let manual = payload.manualAssignments.filter { lineages.contains($0.key) }
        let reference: [MeetingSpeakerInterval]
        let referenceProfiles: [MeetingSpeakerProfile]
        if !payload.intervals.isEmpty {
            reference = payload.intervals
            referenceProfiles = payload.profiles
        } else if let liveTimeline {
            reference = liveTimeline.intervals
            referenceProfiles = liveTimeline.ordinals.map { MeetingSpeakerProfile(id: $0.key, ordinal: $0.value, displayName: nil) }
        } else {
            reference = []
            referenceProfiles = []
        }
        let assembly = MeetingSpeakerProfileBook.assemble(
            detected: evidence.intervals, reference: reference, referenceProfiles: referenceProfiles,
            existingProfiles: payload.profiles, manualAssignments: manual, voiceEvidence: evidence.voiceEvidence
        )
        let application = try MeetingSpeakerLabelApplier.apply(
            meetingID: record.meetingID, current: current, raw: record.rawResult,
            intervals: assembly.intervals, coveredThroughSample: evidence.coveredThroughSample,
            manualAssignments: manual
        )
        var completed = payload
        completed.status = .completed
        completed.failureCode = nil
        completed.sourceTranscriptRevision = application.result.transcriptRevision
        completed.sourceContentDigest = try MeetingDiarizationFingerprint.source(application.result)
        completed.modelRevision = MeetingDiarizationModelStore.installationRevision
        completed.preset = MeetingDiarizationPreset.finalPass.sdkPresetName
        completed.coveredThroughSample = evidence.coveredThroughSample
        completed.intervals = assembly.intervals
        completed.profiles = assembly.profiles
        completed.manualAssignments = manual
        let status = record.status
        try MeetingRecordCommitter.persist(record: record, save: save) {
            try record.update(result: application.result, status: status)
            if let raw = application.raw { try record.snapshotRawBase(raw) }
            try record.update(diarization: completed)
        }
        return .committed(didSplit: application.didSplit)
    }
}

/// Foreground progress of saved-audio speaker passes, keyed by meeting ID.
@MainActor
final class MeetingDiarizationActivity: ObservableObject {
    static let shared = MeetingDiarizationActivity()
    @Published private(set) var progress: [String: Double] = [:]

    func isRunning(_ meetingID: String) -> Bool { progress[meetingID] != nil }
    fileprivate func set(_ meetingID: String, _ value: Double?) { progress[meetingID] = value }
}

@MainActor
enum MeetingDiarizationPostProcessor {
    enum Outcome: Equatable {
        case disabled
        case modelUnavailable
        case busy
        case unreadablePayload
        case completed(didSplit: Bool)
        case superseded
        case interrupted
        case failed(MeetingDiarizationFailure)
    }

    private struct Run {
        let id: UUID
        let task: Task<Outcome, Error>
    }
    private static var runs: [String: Run] = [:]
    private static var finishedWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private static var resumedThisLaunch = false

    static func isRunning(meetingID: String) -> Bool { runs[meetingID] != nil }

    /// Cancels queued or replaying work and waits for all bookkeeping and gate release.
    static func cancel(meetingID: String) async {
        guard let run = runs[meetingID] else { return }
        run.task.cancel()
        await withCheckedContinuation { finishedWaiters[meetingID, default: []].append($0) }
    }

    /// Replays the saved recording with the final preset and commits stable labels.
    /// Recording, transcript and prior speaker results survive every failure.
    static func run(
        record: MeetingRecord,
        context: ModelContext,
        liveTimeline: MeetingLiveSpeakerTimeline? = nil,
        persistsRunningState: Bool = true,
        store: MeetingDiarizationModelStore = .shared,
        captureEnabledAtStart: Bool? = nil
    ) async throws -> Outcome {
        try await run(
            record: record, context: context, liveTimeline: liveTimeline,
            persistsRunningState: persistsRunningState, captureEnabledAtStart: captureEnabledAtStart,
            gate: .shared, isInstalled: { await store.isInstalled() },
            replay: { manifest, referenceIntervals, progress in
                try await MeetingDiarizationReplay.run(
                    manifest: manifest, referenceIntervals: referenceIntervals, store: store, progress: progress
                )
            }
        )
    }

    /// Injectable model operations keep race tests independent of model files and inference.
    static func run(
        record: MeetingRecord,
        context: ModelContext,
        liveTimeline: MeetingLiveSpeakerTimeline? = nil,
        persistsRunningState: Bool = true,
        captureEnabledAtStart: Bool? = nil,
        gate: MeetingDiarizationExecutionGate,
        isInstalled: @escaping @Sendable () async -> Bool,
        replay: @escaping @Sendable (MeetingAudioManifest, [MeetingSpeakerInterval], @escaping @Sendable (Double) -> Void) async throws -> MeetingDiarizationReplay.Evidence
    ) async throws -> Outcome {
        guard captureEnabledAtStart ?? SettingsStore.shared.effectiveMeetingDiarizationEnabled,
              let manifest = record.audioManifest, let source = record.result else { return .disabled }
        guard record.diarizationData == nil || record.diarization != nil else { return .unreadablePayload }
        let meetingID = record.meetingID
        guard runs[meetingID] == nil else { return .busy }
        let manifestDigest = try MeetingDiarizationFingerprint.manifest(manifest)
        let sourceDigest = try MeetingDiarizationFingerprint.source(source)
        let sourceGeneration = record.diarization?.generation
        let runID = UUID()
        let activity = MeetingDiarizationActivity.shared
        let task = Task { @MainActor () throws -> Outcome in
            var generation: UUID?
            do {
                try Task.checkCancellation()
                let installed = await isInstalled()
                try Task.checkCancellation()
                // Do not hold any seed or model instance across either await.
                guard let latest = fetch(meetingID, in: context) else { return .superseded }
                guard try matches(latest, manifestDigest: manifestDigest, sourceDigest: sourceDigest,
                                  generation: sourceGeneration) else { return .superseded }
                guard latest.diarizationData == nil || latest.diarization != nil else { return .unreadablePayload }
                if !installed {
                    guard let latestSource = latest.result else { return .superseded }
                    var payload = try seed(record: latest, source: latestSource,
                                           manifestDigest: manifestDigest, sourceDigest: sourceDigest)
                    payload.status = .modelUnavailable
                    payload.failureCode = MeetingDiarizationFailure.modelUnavailable.rawValue
                    try MeetingRecordCommitter.persist(record: latest, save: { try context.save() }) {
                        try latest.update(diarization: payload)
                    }
                    return .modelUnavailable
                }

                // A warm idle meeting screen must not make a requested saved-audio
                // analysis appear busy. Wait for any in-flight Core ML load to
                // terminate before handing this gate to the final pass.
                await MeetingLiveSpeakerPrewarmer.shared.releaseUnused()
                guard await gate.beginFinal() else {
                    try Task.checkCancellation()
                    return .busy
                }
                defer { gate.endFinal() }
                try Task.checkCancellation()
                guard let latest = fetch(meetingID, in: context) else { return .superseded }
                guard try matches(latest, manifestDigest: manifestDigest, sourceDigest: sourceDigest,
                                  generation: sourceGeneration) else { return .superseded }
                guard latest.diarizationData == nil || latest.diarization != nil else { return .unreadablePayload }
                guard let latestSource = latest.result, let latestManifest = latest.audioManifest else { return .superseded }
                var payload = try seed(record: latest, source: latestSource,
                                       manifestDigest: manifestDigest, sourceDigest: sourceDigest)
                let newGeneration = UUID()
                payload.generation = newGeneration
                // A resumed pass stays interrupted on disk so a crash cannot loop on launch.
                payload.status = persistsRunningState ? .finalizing : .interrupted
                payload.failureCode = nil
                payload.manifestDigest = manifestDigest
                payload.sourceTranscriptRevision = latestSource.transcriptRevision
                payload.sourceContentDigest = sourceDigest
                try MeetingRecordCommitter.persist(record: latest, save: { try context.save() }) {
                    try latest.update(diarization: payload)
                }
                generation = newGeneration
                let referenceIntervals = payload.intervals.isEmpty ? liveTimeline?.intervals ?? [] : payload.intervals

                let replayTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try await replay(latestManifest, referenceIntervals) { value in
                        Task { @MainActor in
                            if runs[meetingID]?.id == runID { activity.set(meetingID, value) }
                        }
                    }
                }
                let evidence = try await withTaskCancellationHandler {
                    try await replayTask.value
                } onCancel: {
                    replayTask.cancel()
                }
                try Task.checkCancellation()
                guard let latest = fetch(meetingID, in: context) else { return .superseded }
                switch try MeetingDiarizationCommitter.commit(
                    record: latest, generation: newGeneration, manifestDigest: manifestDigest,
                    sourceDigest: sourceDigest, evidence: evidence, liveTimeline: liveTimeline,
                    save: { try context.save() }
                ) {
                case .committed(let didSplit): return .completed(didSplit: didSplit)
                case .superseded:
                    mark(meetingID, generation: newGeneration, status: .interrupted, failure: nil, in: context)
                    return .superseded
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    if let generation {
                        mark(meetingID, generation: generation, status: .interrupted, failure: nil, in: context)
                    } else if let latest = fetch(meetingID, in: context),
                              latest.diarizationData == nil || latest.diarization != nil,
                              (try? matches(latest, manifestDigest: manifestDigest, sourceDigest: sourceDigest,
                                            generation: sourceGeneration)) == true,
                              let latestSource = latest.result {
                        // Seed even a first-ever canceled pass so it remains retryable.
                        // Re-read edits, and never replace a newer manual generation.
                        var payload = try seed(record: latest, source: latestSource,
                                               manifestDigest: manifestDigest, sourceDigest: sourceDigest)
                        payload.status = .interrupted
                        payload.failureCode = nil
                        try MeetingRecordCommitter.persist(record: latest, save: { try context.save() }) {
                            try latest.update(diarization: payload)
                        }
                    }
                    return .interrupted
                }
                guard let generation else { throw error }
                let failure = error as? MeetingDiarizationFailure ?? .inferenceFailed
                mark(meetingID, generation: generation, status: .failed, failure: failure, in: context)
                return .failed(failure)
            }
        }
        // Reserve the meeting and publish queued activity before the first suspension.
        runs[meetingID] = Run(id: runID, task: task)
        activity.set(meetingID, 0)
        defer {
            runs[meetingID] = nil
            activity.set(meetingID, nil)
            for waiter in finishedWaiters.removeValue(forKey: meetingID) ?? [] { waiter.resume() }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func matches(
        _ record: MeetingRecord, manifestDigest: String, sourceDigest: String, generation: UUID?
    ) throws -> Bool {
        guard let manifest = record.audioManifest, let source = record.result else { return false }
        return try MeetingDiarizationFingerprint.manifest(manifest) == manifestDigest
            && MeetingDiarizationFingerprint.source(source) == sourceDigest
            && record.diarization?.generation == generation
    }

    /// Foreground resume, once per launch, of passes the process lost mid-run.
    static func resumeInterrupted(in context: ModelContext, store: MeetingDiarizationModelStore = .shared) async {
        guard !resumedThisLaunch, SettingsStore.shared.effectiveMeetingDiarizationEnabled,
              await store.isInstalled(), !Task.isCancelled, !resumedThisLaunch else { return }
        resumedThisLaunch = true
        let records = (try? context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
        for record in records where record.diarization?.status == .finalizing && runs[record.meetingID] == nil {
            _ = try? await run(record: record, context: context, persistsRunningState: false, store: store)
        }
    }

    /// Payload preserved across runs, or a first payload that protects legacy labels.
    static func seed(
        record: MeetingRecord,
        source: MeetingResult,
        manifestDigest: String,
        sourceDigest: String
    ) throws -> MeetingDiarizationPayload {
        if let existing = record.diarization { return existing }
        let legacy = try MeetingSpeakerProfileBook.legacySeed(result: source)
        return MeetingDiarizationPayload(
            status: .notProcessed, generation: UUID(), manifestDigest: manifestDigest,
            sourceTranscriptRevision: source.transcriptRevision, sourceContentDigest: sourceDigest,
            modelRevision: "", preset: "", coveredThroughSample: 0, intervals: [],
            profiles: legacy.profiles, manualAssignments: legacy.manualAssignments, failureCode: nil
        )
    }

    private static func mark(
        _ meetingID: String,
        generation: UUID,
        status: MeetingDiarizationStatus,
        failure: MeetingDiarizationFailure?,
        in context: ModelContext
    ) {
        guard let record = fetch(meetingID, in: context),
              var payload = record.diarization, payload.generation == generation else { return }
        payload.status = status
        payload.failureCode = failure?.rawValue
        try? MeetingRecordCommitter.persist(record: record, save: { try context.save() }) {
            try record.update(diarization: payload)
        }
    }

    private static func fetch(_ meetingID: String, in context: ModelContext) -> MeetingRecord? {
        let descriptor = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == meetingID })
        return try? context.fetch(descriptor).first
    }
}
