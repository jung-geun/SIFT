import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import todo

@Suite("Grouped capture persistence")
@MainActor
struct MeetingAudioTrackPersistenceTests {
    @Test("deferred capture recovery preserves chosen languages without fabricating Apple evidence", arguments: [false, true])
    func deferredLanguageRecovery(automatic: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        let child = artifact.tracks[0]
        let recovery = PendingMeetingCaptureRecovery(
            meetingID: child.meetingID, languageTag: "bn-BD", timezoneIdentifier: "UTC",
            manifest: child.audioManifest, provisionalResult: MeetingResult(segments: []), errorMessage: nil,
            parentMeetingID: artifact.meetingID, sourceKind: child.sourceKind,
            sourceLabel: child.sourceLabel, sessionStartSample: child.sessionStartSample,
            summaryLanguageTag: "ar-SA", deferredTranscription: true, automaticLanguageDetection: automatic)
        try MeetingCaptureRecoveryStore.write(recovery, rootURL: root)
        let restored = try #require(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.first)
        #expect(restored.automaticLanguageDetection == automatic)
        let store = root.appendingPathComponent("deferred.store")
        do {
            let context = ModelContext(try diskContainer(at: store))
            try MeetingCaptureRecoveryPersister.persist(restored, in: context, rootURL: root)
        }
        let context = ModelContext(try diskContainer(at: store))
        let saved = try record(child.meetingID, in: context)
        #expect(saved.languageTag == "bn-BD")
        #expect(saved.summaryLanguageTag == "ar-SA")
        #expect(saved.automaticLanguageDetection == automatic)
        #expect(try record(artifact.meetingID, in: context).automaticLanguageDetection == automatic)
        #expect(saved.asrSource == .savedAudio)
        #expect(saved.appleRawResult == nil)
        #expect(saved.result?.segments.isEmpty == true)
        #expect(saved.audioManifest == child.audioManifest)
        #expect(saved.status == .transcriptFinalizationFailed)
    }

    @Test("group and independent source namespaces preserve language mode across disk reopen", arguments: [false, true])
    func groupedDiskReopen(automatic: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        let store = root.appendingPathComponent("meetings.store")
        do {
            let container = try diskContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let parent = try persist(artifact, automatic: automatic, in: context)
            #expect(parent.audioManifest == nil)
            #expect(parent.rawResult == nil)
            #expect(parent.result?.segments.isEmpty == true)
            #expect(parent.diarization == nil)
            #expect(parent.status == (automatic ? .transcriptFinalizationFailed : .finalizingTranscript))
        }
        let reopened = try diskContainer(at: store)
        let context = ModelContext(reopened)
        let parent = try record(artifact.meetingID, in: context)
        let children = try MeetingAudioTrackStore.tracks(for: parent, in: context)
        #expect(parent.automaticLanguageDetection == automatic)
        #expect(children.allSatisfy { $0.automaticLanguageDetection == automatic })
        #expect(children.allSatisfy { $0.asrSource == (automatic ? .savedAudio : .apple) })
        if automatic { #expect(children.allSatisfy { $0.appleRawResultData == nil }) }
        #expect(children.map(\.meetingID) == artifact.tracks.map(\.meetingID))
        #expect(children.map(\.audioTrackKind) == [.microphone, .application])
        #expect(children.map(\.audioTrackStartSample) == [0, 8_000])
        #expect(children.map(\.result) == artifact.tracks.map { Optional($0.provisionalResult) })
        #expect(children.map(\.audioManifest) == artifact.tracks.map { Optional($0.audioManifest) })
        #expect(children[0].result?.segments[0].speakerIDs == ["speaker-1"])
        #expect(children[1].result?.segments[0].speakerIDs == ["speaker-1"])
        #expect(parent.manifestData.isEmpty)
        #expect(parent.result?.segments.isEmpty == true)
    }

    @Test("real read-only store save failure rolls back all group inserts and keeps journals")
    func realGroupedSaveFailure() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        let store = root.appendingPathComponent("read-only.store")
        let legacyID = UUID().uuidString.lowercased()
        let legacy = try track(root: root, id: legacyID, kind: .legacyMixed, text: "old completed recording")
        for child in artifact.tracks { try MeetingCaptureRecoveryStore.write(recovery(child, parentID: artifact.meetingID), rootURL: root) }
        var before: MeetingRecord.PersistenceSnapshot?
        do {
            let container = try diskContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let row = MeetingRecord(meetingID: legacyID)
            try row.update(result: legacy.provisionalResult, status: .ready)
            try row.update(audioManifest: legacy.audioManifest)
            context.insert(row)
            try context.save()
            before = row.persistenceSnapshot()
        }
        do {
            let container = try diskContainer(at: store, allowsSave: false)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            // Invoke the production save closure, not a pre-save test throw.
            #expect(throws: Error.self) { _ = try persist(artifact, in: context) }
            let rows = try context.fetch(FetchDescriptor<MeetingRecord>())
            #expect(rows.count == 1)
            #expect(rows.first?.persistenceSnapshot() == before)
            #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.count == 2)
        }
        let reopened = try diskContainer(at: store)
        let rows = try ModelContext(reopened).fetch(FetchDescriptor<MeetingRecord>())
        #expect(rows.count == 1)
        #expect(rows.first?.meetingID == legacyID)
        #expect(rows.first?.persistenceSnapshot() == before)
    }

    @Test("existing sibling and parent snapshots survive recovery save failure")
    func siblingRecoveryRollback() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        let container = try memoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let first = recovery(artifact.tracks[0], parentID: artifact.meetingID)
        let second = recovery(artifact.tracks[1], parentID: artifact.meetingID)
        try MeetingCaptureRecoveryStore.write(first, rootURL: root)
        try MeetingCaptureRecoveryStore.write(second, rootURL: root)
        try MeetingCaptureRecoveryPersister.persist(first, in: context, rootURL: root)
        let parent = try record(artifact.meetingID, in: context)
        let sibling = try record(first.meetingID, in: context)
        let parentBefore = parent.persistenceSnapshot()
        let siblingBefore = sibling.persistenceSnapshot()
        #expect(throws: TrackPersistenceTestError.saveFailed) {
            try MeetingCaptureRecoveryPersister.persist(second, in: context, rootURL: root,
                save: { _ in throw TrackPersistenceTestError.saveFailed })
        }
        #expect(parent.persistenceSnapshot() == parentBefore)
        #expect(sibling.persistenceSnapshot() == siblingBefore)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).count == 2)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.map(\.meetingID) == [second.meetingID])
        try MeetingCaptureRecoveryPersister.persist(second, in: context, rootURL: root)
        #expect(try MeetingAudioTrackStore.tracks(for: parent, in: context).count == 2)
    }

    @Test("sibling failure and stale journal do not mix transcript or overwrite phase two")
    func committedChildAndFailedSibling() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        let store = root.appendingPathComponent("committed.store")
        let stale = recovery(artifact.tracks[0], parentID: artifact.meetingID)
        let failed = recovery(artifact.tracks[1], parentID: artifact.meetingID)
        var committed: MeetingRecord.PersistenceSnapshot?
        do {
            let container = try diskContainer(at: store)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let parent = try persist(artifact, in: context)
            let child = try record(stale.meetingID, in: context)
            var final = artifact.tracks[0].provisionalResult
            final.transcriptRevision = 2
            final.summary = "durable phase two"
            try child.replaceTranscriptionBase(final, status: .ready, source: .offline,
                modelRevision: "pinned", detectedLanguages: ["en"])
            child.refinementEngineLabel = "user-vocabulary"
            try MeetingAudioTrackStore.refresh(parent: parent, in: context)
            committed = child.persistenceSnapshot()
        }
        try MeetingCaptureRecoveryStore.write(stale, rootURL: root)
        try MeetingCaptureRecoveryStore.write(failed, rootURL: root)
        let reopened = try diskContainer(at: store)
        let context = ModelContext(reopened)
        context.autosaveEnabled = false
        try MeetingCaptureRecoveryPersister.persist(failed, in: context, rootURL: root)
        try MeetingCaptureRecoveryPersister.persist(stale, in: context, rootURL: root)
        let child = try record(stale.meetingID, in: context)
        let sibling = try record(failed.meetingID, in: context)
        let parent = try record(artifact.meetingID, in: context)
        #expect(child.persistenceSnapshot() == committed)
        #expect(sibling.status == .transcriptFinalizationFailed)
        #expect(sibling.result == artifact.tracks[1].provisionalResult)
        #expect(parent.status == .ready)
        #expect(parent.result?.segments.isEmpty == true)
        #expect(parent.rawResult == nil && parent.audioManifest == nil && parent.diarization == nil)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.isEmpty)
        // Replaying an already removed journal is idempotent as well.
        try MeetingCaptureRecoveryPersister.persist(stale, in: context, rootURL: root)
        #expect(child.persistenceSnapshot() == committed)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).count == 3)
    }

    @Test("legacy JSON without track metadata preserves a completed standalone record")
    func legacyMarkerCompatibility() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try track(root: root, kind: .legacyMixed, text: "legacy transcript")
        // Encode the actual pre-group wire shape, not a new marker with nulls.
        let marker = LegacyMarker(meetingID: child.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC",
            manifest: child.audioManifest, provisionalResult: MeetingResult(title: "stale"), errorMessage: nil)
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent(child.meetingID).appendingPathComponent("capture-recovery.json"))
        let scan = MeetingCaptureRecoveryStore.scan(rootURL: root)
        let pending = try #require(scan.recoveries.first)
        #expect(scan.unreadableMarkerNames.isEmpty)
        #expect(pending.parentMeetingID == nil && pending.sourceKind == nil && pending.sessionStartSample == nil)
        #expect(!pending.automaticLanguageDetection)
        let container = try memoryContainer()
        let context = ModelContext(container)
        let row = MeetingRecord(meetingID: child.meetingID)
        #expect(!row.automaticLanguageDetection)
        // A current record's mode and detected evidence outrank the legacy journal.
        row.automaticLanguageDetection = true
        row.asrDetectedLanguages = ["en", "ko"]
        try row.update(result: child.provisionalResult, status: .ready)
        try row.update(audioManifest: child.audioManifest)
        #expect(row.rawResult == nil)
        context.insert(row)
        try context.save()
        let before = row.persistenceSnapshot()
        try MeetingCaptureRecoveryPersister.persist(pending, in: context, rootURL: root)
        #expect(row.persistenceSnapshot() == before)
        #expect(row.parentMeetingID == nil && row.audioTrackIDs.isEmpty)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.isEmpty)
    }

    @Test("legacy records cannot become a colliding group or child")
    func legacyNamespaceCollisions() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        for occupiedID in [artifact.meetingID, artifact.tracks[0].meetingID] {
            let container = try memoryContainer()
            let context = ModelContext(container)
            let legacy = MeetingRecord(meetingID: occupiedID)
            try legacy.update(result: MeetingResult(title: "old", segments: [
                MeetingSegment(id: "old", startMs: 0, endMs: 1_000, text: "keep me")
            ]), status: .ready)
            try legacy.update(audioManifest: artifact.tracks[0].audioManifest)
            context.insert(legacy)
            try context.save()
            let before = legacy.persistenceSnapshot()
            let pending = recovery(artifact.tracks[0], parentID: artifact.meetingID)
            try MeetingCaptureRecoveryStore.write(pending, rootURL: root)
            #expect(throws: Error.self) { _ = try persist(artifact, in: context) }
            #expect(throws: Error.self) { try MeetingCaptureRecoveryPersister.persist(pending, in: context, rootURL: root) }
            #expect(legacy.persistenceSnapshot() == before)
            #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).count == 1)
            #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.count == 1)
        }
    }

    @Test("duplicate IDs, occupied namespaces and unsafe audio paths are rejected before inserts")
    func invalidArtifacts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        let child = artifact.tracks[0]
        let container = try memoryContainer()
        let context = ModelContext(container)
        let duplicate = MeetingCaptureArtifact(meetingID: artifact.meetingID, tracks: [child, child])
        let groupIsChild = MeetingCaptureArtifact(meetingID: child.meetingID, tracks: [child])
        for invalid in [duplicate, groupIsChild] {
            #expect(throws: Error.self) { _ = try persist(invalid, in: context) }
            #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        }
        for relative in ["../escape", "/\(child.meetingID)/audio", "\(child.meetingID)/../audio", "\(child.meetingID)//audio", "\(artifact.tracks[1].meetingID)/audio"] {
            let manifest = MeetingAudioManifest(relativeDirectory: relative, sampleRate: 16_000,
                totalSamples: child.audioManifest.totalSamples, parts: child.audioManifest.parts)
            let invalid = MeetingCaptureTrackArtifact(meetingID: child.meetingID, sourceKind: child.sourceKind,
                sourceLabel: nil, sessionStartSample: 0, directoryURL: child.directoryURL,
                audioManifest: manifest, provisionalResult: child.provisionalResult)
            #expect(throws: Error.self) {
                _ = try persist(MeetingCaptureArtifact(meetingID: artifact.meetingID, tracks: [invalid]), in: context)
            }
            #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
        }
        let parent = try persist(artifact, in: context)
        let before = parent.persistenceSnapshot()
        #expect(throws: Error.self) { _ = try persist(artifact, in: context) }
        #expect(parent.persistenceSnapshot() == before)
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).count == 3)
        // Previously Dictionary(uniqueKeysWithValues:) trapped on malformed IDs.
        parent.audioTrackIDs.append(child.meetingID)
        #expect(throws: Error.self) { _ = try MeetingAudioTrackStore.tracks(for: parent, in: context) }
    }

    @Test("active journal recovers readable writer parts with overlap into a durable group")
    func activeReadablePrefixWithOverlap() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parentID = UUID().uuidString.lowercased()
        let childID = UUID().uuidString.lowercased()
        let audio = root.appendingPathComponent(childID).appendingPathComponent("audio")
        let writer = try MeetingFLACPartWriter(directory: audio)
        try MeetingCaptureRecoveryStore.markActive(meetingID: childID, parentMeetingID: parentID, sourceKind: .application,
            sourceLabel: "local source", sessionStartSample: 8_000, languageTag: "en-US", timezoneIdentifier: "UTC",
            directoryURL: audio, rootURL: root)
        let chunk = try pcmBuffer(frames: 16_000)
        for _ in 0..<Int(MeetingMediaTimeline.ownedSamplesPerPart / 16_000) { try writer.append(chunk) }
        try writer.append(chunk)
        _ = try writer.finish()
        // A kill can leave an unreadable next part. Keep the complete prefix.
        try Data("not a FLAC".utf8).write(to: audio.appendingPathComponent("part-02.flac"))
        let scan = MeetingCaptureRecoveryStore.scan(rootURL: root)
        let pending = try #require(scan.recoveries.first)
        #expect(scan.unreadableMarkerNames.isEmpty)
        #expect(pending.manifest.parts.count == 2)
        #expect(pending.manifest.totalSamples == MeetingMediaTimeline.ownedSamplesPerPart + 16_000)
        #expect(pending.manifest.parts[1].partStartSample == MeetingMediaTimeline.ownedSamplesPerPart - MeetingMediaTimeline.overlapSamples)
        #expect(pending.manifest.parts[1].ownedStartSample == MeetingMediaTimeline.ownedSamplesPerPart)
        #expect(pending.provisionalResult.segments.isEmpty)
        let cursor = try MeetingLogicalAudioCursor(manifest: pending.manifest, rootURL: root)
        try cursor.seek(toLogicalSample: MeetingMediaTimeline.ownedSamplesPerPart - 8_000)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        var count: Int64 = 0
        while let buffer = try cursor.nextPCMBuffer(maxFrames: 4_096, outputFormat: format) { count += Int64(buffer.frameLength) }
        #expect(count == 24_000)
        let store = root.appendingPathComponent("active.store")
        do {
            let container = try diskContainer(at: store)
            let context = ModelContext(container)
            try MeetingCaptureRecoveryPersister.persist(pending, in: context, rootURL: root)
        }
        let reopened = try diskContainer(at: store)
        let context = ModelContext(reopened)
        let parent = try record(parentID, in: context)
        let child = try #require(MeetingAudioTrackStore.tracks(for: parent, in: context).first)
        #expect(child.audioManifest == pending.manifest)
        #expect(child.audioTrackStartSample == 8_000)
        #expect(parent.audioManifest == nil && parent.result?.segments.isEmpty == true)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.isEmpty)
    }

    @Test("automatic and legacy active/stopped journals preserve mode and locales durably", arguments: [false, true], [false, true])
    func automaticJournalRoundtrip(stopped: Bool, automatic: Bool) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        let child = artifact.tracks[0]
        try MeetingCaptureRecoveryStore.markActive(meetingID: child.meetingID, parentMeetingID: artifact.meetingID,
            sourceKind: child.sourceKind, sourceLabel: child.sourceLabel, sessionStartSample: child.sessionStartSample,
            languageTag: "ko-KR", timezoneIdentifier: "UTC", directoryURL: child.directoryURL,
            summaryLanguageTag: "fr-FR", deferredTranscription: !automatic, automaticLanguageDetection: true, rootURL: root)
        if !automatic {
            // Simulate the old wire shape, not a current marker with false set.
            let markerURL = root.appendingPathComponent(child.meetingID).appendingPathComponent("active-capture.json")
            var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
            legacy.removeValue(forKey: "automaticLanguageDetection")
            try JSONSerialization.data(withJSONObject: legacy).write(to: markerURL)
        }
        if stopped {
            let marker = try MeetingCaptureRecoveryStore.markStopped(meetingID: child.meetingID,
                audioManifest: child.audioManifest, provisionalResult: MeetingResult(), rootURL: root)
            #expect(marker.automaticLanguageDetection == automatic)
        }
        let pending = try #require(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.first)
        #expect(pending.automaticLanguageDetection == automatic)
        let store = root.appendingPathComponent("automatic.store")
        do {
            let context = ModelContext(try diskContainer(at: store))
            try MeetingCaptureRecoveryPersister.persist(pending, in: context, rootURL: root)
        }
        let context = ModelContext(try diskContainer(at: store))
        let saved = try record(child.meetingID, in: context)
        #expect(saved.automaticLanguageDetection == automatic)
        #expect(saved.languageTag == "ko-KR")
        #expect(saved.summaryLanguageTag == "fr-FR")
        #expect(saved.asrSource == .savedAudio)
        #expect(saved.appleRawResultData == nil)
        #expect(saved.status == .transcriptFinalizationFailed)
        #expect(saved.audioManifest == pending.manifest)
        #expect(try record(artifact.meetingID, in: context).automaticLanguageDetection == automatic)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.isEmpty)
    }

    @Test("active recovery stops at unreadable full-boundary tail and does not bridge a partial part")
    func activeTailAndGap() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for fullFirstPart in [false, true] {
            let childID = UUID().uuidString.lowercased()
            let audio = root.appendingPathComponent(childID).appendingPathComponent("audio")
            let writer = try MeetingFLACPartWriter(directory: audio)
            try MeetingCaptureRecoveryStore.markActive(meetingID: childID, parentMeetingID: UUID().uuidString.lowercased(),
                sourceKind: .microphone, sourceLabel: nil, sessionStartSample: 0, languageTag: "en-US", timezoneIdentifier: "UTC",
                directoryURL: audio, rootURL: root)
            let chunk = try pcmBuffer(frames: 16_000)
            let chunks = fullFirstPart ? Int(MeetingMediaTimeline.ownedSamplesPerPart / 16_000) : 1
            for _ in 0..<chunks { try writer.append(chunk) }
            _ = try writer.finish()
            try Data("unfinished FLAC header".utf8).write(to: audio.appendingPathComponent("part-01.flac"))
            let pending = try #require(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.first { $0.meetingID == childID })
            #expect(pending.manifest.parts.count == 1)
            #expect(pending.manifest.totalSamples == Int64(chunks) * 16_000)
            #expect((pending.errorMessage != nil) == fullFirstPart)
            let tail = audio.appendingPathComponent("part-01.flac")
            #expect(try Data(contentsOf: tail) == Data("unfinished FLAC header".utf8))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(childID)
                .appendingPathComponent("active-capture.json").path))
            if fullFirstPart {
                // The readable prefix may be saved, but its native tail failure
                // must survive the active -> stopped journal transition.
                try MeetingCaptureRecoveryStore.write(pending, rootURL: root)
                let saved = try #require(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries
                    .first { $0.meetingID == childID })
                #expect(saved.errorMessage == pending.errorMessage)
                #expect(try Data(contentsOf: tail) == Data("unfinished FLAC header".utf8))
            }
        }
    }

    @Test("symlink escapes and invalid child timeline metadata cannot create a group")
    func symlinkAndTimelineRejection() throws {
        let root = try temporaryRoot()
        let outside = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let child = try track(root: outside, kind: .microphone, text: "outside")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(child.meetingID),
            withDestinationURL: outside.appendingPathComponent(child.meetingID))
        #expect(throws: Error.self) {
            try MeetingCaptureRecoveryStore.markActive(meetingID: child.meetingID, parentMeetingID: UUID().uuidString.lowercased(),
                sourceKind: .microphone, sourceLabel: nil, sessionStartSample: 0, languageTag: "en-US", timezoneIdentifier: "UTC",
                directoryURL: root.appendingPathComponent(child.audioManifest.relativeDirectory), rootURL: root)
        }
        let container = try memoryContainer()
        let context = ModelContext(container)
        let linked = MeetingCaptureTrackArtifact(meetingID: child.meetingID, sourceKind: child.sourceKind, sourceLabel: nil,
            sessionStartSample: 0, directoryURL: root.appendingPathComponent(child.audioManifest.relativeDirectory),
            audioManifest: child.audioManifest, provisionalResult: child.provisionalResult)
        #expect(throws: Error.self) {
            _ = try persist(MeetingCaptureArtifact(meetingID: UUID().uuidString.lowercased(), tracks: [linked]), in: context)
        }
        for start in [Int64(-1), MeetingMediaTimeline.maximumSamples] {
            let invalid = MeetingCaptureTrackArtifact(meetingID: child.meetingID, sourceKind: child.sourceKind, sourceLabel: nil,
                sessionStartSample: start, directoryURL: child.directoryURL, audioManifest: child.audioManifest,
                provisionalResult: child.provisionalResult)
            #expect(throws: Error.self) {
                _ = try persist(MeetingCaptureArtifact(meetingID: UUID().uuidString.lowercased(), tracks: [invalid]), in: context)
            }
        }
        #expect(try context.fetch(FetchDescriptor<MeetingRecord>()).isEmpty)
    }

    @Test("stopped journal supersedes active prefix and failed replay preserves both marker bytes")
    func stoppedJournalRollback() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try capture(root: root)
        let child = artifact.tracks[0]
        try MeetingCaptureRecoveryStore.markActive(meetingID: child.meetingID, parentMeetingID: artifact.meetingID,
            sourceKind: child.sourceKind, sourceLabel: child.sourceLabel, sessionStartSample: child.sessionStartSample,
            languageTag: "en-US", timezoneIdentifier: "UTC", directoryURL: child.directoryURL, rootURL: root)
        let stopped = try MeetingCaptureRecoveryStore.markStopped(meetingID: child.meetingID,
            audioManifest: child.audioManifest, provisionalResult: child.provisionalResult,
            errorMessage: "stopped", rootURL: root)
        let directory = root.appendingPathComponent(child.meetingID)
        let activeURL = directory.appendingPathComponent("active-capture.json")
        let stoppedURL = directory.appendingPathComponent("capture-recovery.json")
        let activeBytes = try Data(contentsOf: activeURL)
        let stoppedBytes = try Data(contentsOf: stoppedURL)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: root).recoveries.first?.provisionalResult == child.provisionalResult)
        let container = try memoryContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let parent = try persist(artifact, in: context)
        let row = try record(child.meetingID, in: context)
        row.refinementEngineLabel = "stale provenance"
        row.offlineASRFailureRaw = MeetingOfflineASRFailure.modelUnavailable.rawValue
        try context.save()
        let rowBefore = row.persistenceSnapshot()
        let parentBefore = parent.persistenceSnapshot()
        #expect(throws: TrackPersistenceTestError.saveFailed) {
            try MeetingCaptureRecoveryPersister.persist(stopped, in: context, rootURL: root,
                save: { _ in throw TrackPersistenceTestError.saveFailed })
        }
        #expect(row.persistenceSnapshot() == rowBefore)
        #expect(parent.persistenceSnapshot() == parentBefore)
        #expect(try Data(contentsOf: activeURL) == activeBytes)
        #expect(try Data(contentsOf: stoppedURL) == stoppedBytes)
        try MeetingCaptureRecoveryPersister.persist(stopped, in: context, rootURL: root)
        #expect(row.status == .transcriptFinalizationFailed)
        #expect(row.result == child.provisionalResult)
        #expect(parent.status == .finalizingTranscript)
        #expect(parent.result?.segments.isEmpty == true && parent.audioManifest == nil)
        #expect(!FileManager.default.fileExists(atPath: activeURL.path))
        #expect(!FileManager.default.fileExists(atPath: stoppedURL.path))
    }

    @Test("active recovery accepts an aliased root but rejects an escaping child symlink")
    func aliasedRootRecovery() throws {
        let host = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: host) }
        let realRoot = host.appendingPathComponent("real-root")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let alias = host.appendingPathComponent("alias-root")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realRoot)
        let child = try track(root: realRoot, kind: .microphone, text: "readable")
        let parentID = UUID().uuidString.lowercased()
        try MeetingCaptureRecoveryStore.markActive(meetingID: child.meetingID, parentMeetingID: parentID,
            sourceKind: child.sourceKind, sourceLabel: nil, sessionStartSample: 0,
            languageTag: "en-US", timezoneIdentifier: "UTC",
            directoryURL: alias.appendingPathComponent(child.audioManifest.relativeDirectory), rootURL: alias)
        // Retain the genuine journal but move its child outside the root. A
        // root alias is valid; a child namespace alias is not.
        let escapedID = UUID().uuidString.lowercased()
        let escaped = try track(root: realRoot, id: escapedID, kind: .application, text: "outside")
        try MeetingCaptureRecoveryStore.markActive(meetingID: escapedID, parentMeetingID: parentID,
            sourceKind: escaped.sourceKind, sourceLabel: nil, sessionStartSample: 0,
            languageTag: "en-US", timezoneIdentifier: "UTC", directoryURL: escaped.directoryURL, rootURL: realRoot)
        let outside = host.appendingPathComponent("outside-child")
        try FileManager.default.moveItem(at: realRoot.appendingPathComponent(escapedID), to: outside)
        try FileManager.default.createSymbolicLink(at: realRoot.appendingPathComponent(escapedID), withDestinationURL: outside)
        let scan = MeetingCaptureRecoveryStore.scan(rootURL: alias)
        #expect(scan.recoveries.map(\.meetingID) == [child.meetingID])
        #expect(scan.unreadableMarkerNames == [escapedID])
        let pending = try #require(scan.recoveries.first)
        #expect(pending.manifest == child.audioManifest)
        let container = try memoryContainer()
        let context = ModelContext(container)
        try MeetingCaptureRecoveryPersister.persist(pending, in: context, rootURL: alias)
        #expect(try record(child.meetingID, in: context).audioManifest == child.audioManifest)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: alias).recoveries.isEmpty)
        #expect(MeetingCaptureRecoveryStore.scan(rootURL: alias).unreadableMarkerNames == [escapedID])
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("track-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func memoryContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
    }

    private func diskContainer(at url: URL, allowsSave: Bool = true) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: AppDataContainer.meetingSchema, url: url,
            allowsSave: allowsSave, cloudKitDatabase: .none)
        return try ModelContainer(for: AppDataContainer.meetingSchema, configurations: configuration)
    }

    private func record(_ id: String, in context: ModelContext) throws -> MeetingRecord {
        try #require(context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.meetingID == id })).first)
    }

    private func persist(_ artifact: MeetingCaptureArtifact, automatic: Bool = false, in context: ModelContext) throws -> MeetingRecord {
        try MeetingInitialCapturePersister.persist(artifact: artifact, languageTag: "en-US", timezoneIdentifier: "UTC",
            automaticLanguageDetection: automatic, in: context)
    }

    private func capture(root: URL) throws -> MeetingCaptureArtifact {
        MeetingCaptureArtifact(meetingID: UUID().uuidString.lowercased(), tracks: [
            try track(root: root, kind: .microphone, text: "microphone only"),
            try track(root: root, kind: .application, start: 8_000, text: "application only")
        ])
    }

    private func track(root: URL, id: String = UUID().uuidString.lowercased(), kind: MeetingAudioTrackKind,
                       start: Int64 = 0, text: String) throws -> MeetingCaptureTrackArtifact {
        let audio = root.appendingPathComponent(id).appendingPathComponent("audio")
        let writer = try MeetingFLACPartWriter(directory: audio)
        try writer.append(pcmBuffer(frames: 16_000))
        _ = try writer.finish()
        let result = MeetingResult(title: text, segments: [
            MeetingSegment(id: "\(id)-speech", startMs: 0, endMs: 1_000, speakerIDs: ["speaker-1"], text: text)
        ])
        return MeetingCaptureTrackArtifact(meetingID: id, sourceKind: kind, sourceLabel: kind == .application ? "local source" : nil,
            sessionStartSample: start, directoryURL: audio, audioManifest: writer.manifest(relativeDirectory: "\(id)/audio"),
            provisionalResult: result)
    }

    private func pcmBuffer(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.int16ChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = Int16(index % 1_000) }
        return buffer
    }

    private func recovery(_ child: MeetingCaptureTrackArtifact, parentID: String) -> PendingMeetingCaptureRecovery {
        PendingMeetingCaptureRecovery(meetingID: child.meetingID, languageTag: "en-US", timezoneIdentifier: "UTC",
            manifest: child.audioManifest, provisionalResult: child.provisionalResult, errorMessage: "capture failed",
            parentMeetingID: parentID, sourceKind: child.sourceKind, sourceLabel: child.sourceLabel,
            sessionStartSample: child.sessionStartSample)
    }
}

private struct LegacyMarker: Encodable {
    let meetingID: String
    let languageTag: String
    let timezoneIdentifier: String
    let manifest: MeetingAudioManifest
    let provisionalResult: MeetingResult
    let errorMessage: String?
}

private enum TrackPersistenceTestError: Error { case saveFailed }
