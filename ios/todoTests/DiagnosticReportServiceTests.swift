import Foundation
import Testing
@testable import todo

@Suite("Diagnostic report archive", .serialized)
@MainActor
struct DiagnosticReportServiceTests {
    @Test("archive is bounded, coalesces repeated failures, and deduplicates metrics")
    func archiveIsBoundedAndCoalescesRepeatedFailures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DiagnosticReportStore(
            fileURL: directory.appendingPathComponent("diagnostics.json"),
            maxEvents: 2,
            maxMetricPayloads: 1,
            maxPayloadDigests: 2
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = store.append(event(code: 1, at: 1))
        _ = store.append(event(code: 2, at: 2))
        _ = store.append(event(code: 3, at: 3))
        let bounded = store.load().events
        #expect(bounded.count == 2)
        #expect(bounded.compactMap(\.error?.code) == [2, 3])

        _ = store.append(event(code: 3, at: 30))
        let coalesced = store.load().events
        #expect(coalesced.count == 2)
        #expect(coalesced.last?.repeatCount == 2)
        #expect(coalesced.last?.lastTimestamp == Date(timeIntervalSince1970: 30))

        let metrics = store.ingestMetricPayloads(
            ["first", "first", "second"],
            digests: ["digest-1", "digest-1", "digest-2"]
        )
        #expect(metrics.metricPayloads == ["second"])
        #expect(metrics.ingestedPayloadDigests == ["digest-1", "digest-2"])

        store.clear()
        #expect(store.load() == DiagnosticReportArchive())
    }

    @Test("acknowledged reports retain only diagnostics recorded afterward")
    func acknowledgedReportsKeepOnlyNewDiagnostics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = DiagnosticReportStore(
            fileURL: directory.appendingPathComponent("diagnostics.json")
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = store.append(event(code: 1, at: 10))
        _ = store.ingestMetricPayloads(["metric"], digests: ["metric-digest"])
        _ = store.append(event(code: 2, at: 20))
        _ = store.ingestMetricPayloads(["later-metric"], digests: ["later-metric-digest"])

        let remaining = store.acknowledgeReportedDiagnostics(
            through: Date(timeIntervalSince1970: 15),
            metricPayloadIDs: [try #require(store.load().metricPayloadIDs.first)]
        )
        #expect(remaining.events.compactMap(\.error?.code) == [2])
        #expect(remaining.metricPayloads == ["later-metric"])
        #expect(
            remaining.ingestedPayloadDigests
                == ["metric-digest", "later-metric-digest"]
        )
    }

    @Test("version one archives migrate to the current schema")
    func versionOneArchiveMigrates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("diagnostics.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = LegacyArchiveFixture(
            version: 1,
            events: [
                LegacyEventFixture(
                    timestamp: Date(timeIntervalSince1970: 1),
                    component: "calendar.eventkit",
                    operation: "remove",
                    errorDomain: "EKCADErrorDomain",
                    errorCode: 1010,
                    errorType: "NSError"
                )
            ],
            metricPayloads: ["metric"]
        )
        try JSONEncoder().encode(legacy).write(to: fileURL)

        let archive = DiagnosticReportStore(fileURL: fileURL).load()
        #expect(archive.version == DiagnosticReportArchive.currentVersion)
        #expect(archive.events.count == 1)
        #expect(archive.events[0].repeatCount == 1)
        #expect(archive.events[0].error?.domain == "EKCADErrorDomain")
        #expect(archive.events[0].error?.code == 1010)
        #expect(archive.metricPayloads == ["metric"])
    }

    @Test("MetricKit payload paths are redacted")
    func redactsMetricKitFilesystemPaths() {
        let payload = #"{"path":"\/private\/var\/mobile\/Containers\/Data\/Application\/ABC\/file.swift","owner":"dev@example.com"}"#
        let redacted = DiagnosticRedaction.metricPayload(payload)

        #expect(!redacted.contains("/private/"))
        #expect(!redacted.contains("\\/private\\/"))
        #expect(!redacted.contains("dev@example.com"))
        #expect(redacted.contains("<redacted-path>"))
        #expect(redacted.contains("<redacted-email>"))
    }

    @Test("deep MetricKit payloads are truncated before recursive redaction overflows the stack")
    func truncatesDeepMetricKitPayloads() throws {
        let nestedFrames = (0..<80).reduce(#"{"binaryName":"todo.debug.dylib"}"#) { child, index in
            #"{"frame":\#(index),"subFrames":[\#(child)]}"#
        }
        let payload = #"{"crashDiagnostics":[{"callStackTree":\#(nestedFrames)}]}"#
        let redacted = DiagnosticRedaction.metricPayload(payload)

        #expect(redacted.contains("<truncated-depth>"))
        let data = try #require(redacted.data(using: .utf8))
        _ = try JSONSerialization.jsonObject(with: data)
    }

    @Test("collection requires consent and exports structured redacted diagnostics")
    func collectionRequiresConsentAndRevocationErasesArchive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let store = DiagnosticReportStore(fileURL: directory.appendingPathComponent("diagnostics.json"))
        let recorder = DiagnosticRecorder(store: store, defaults: defaults)
        let service = DiagnosticReportService(recorder: recorder)
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let nested = NSError(
            domain: "Underlying",
            code: 17,
            userInfo: [NSLocalizedDescriptionKey: "contact dev@example.com at /private/tmp/source.swift"]
        )
        let failure = NSError(
            domain: "SpeechAnalyzer",
            code: 71,
            userInfo: [
                NSLocalizedDescriptionKey: "failed at /Users/dev/project.swift",
                NSUnderlyingErrorKey: nested
            ]
        )

        recorder.record(error: failure, component: "meeting.transcription", operation: "analyze")
        #expect(recorder.snapshot().events.isEmpty)
        #expect(await service.reportAttachment() == nil)

        service.setCollectionEnabled(true)
        recorder.record(error: failure, component: "meeting.transcription", operation: "analyze")
        recorder.record(error: CancellationError(), component: "meeting.transcription", operation: "analyze")
        let archive = recorder.snapshot()
        #expect(archive.events.count == 1)
        #expect(archive.events[0].source != nil)
        #expect(archive.events[0].runtime != nil)
        #expect(archive.events[0].underlyingErrors.count == 1)

        let data = try #require(await service.reportAttachment())
        let report = try decodedReport(data)

        #expect(report.reportVersion == UserDiagnosticReport.currentVersion)
        #expect(report.app.installSource == "simulator")
        #expect(!report.app.bundleIdentifier.isEmpty)
        #expect(!report.device.modelIdentifier.isEmpty)
        #expect(!report.settings.isEmpty)
        #expect(report.events.count == 1)
        #expect(report.events[0].error?.domain == "SpeechAnalyzer")
        #expect(report.events[0].underlyingErrors.first?.domain == "Underlying")

        let reportString = try #require(String(data: data, encoding: .utf8))
        #expect(!reportString.contains("dev@example.com"))
        #expect(!reportString.contains("/private/tmp"))
        #expect(!reportString.contains("/Users/dev"))
        #expect(reportString.contains("<redacted-email>"))
        #expect(reportString.contains("<redacted-path>"))

        service.setCollectionEnabled(false)
        #expect(!service.collectionEnabled)
        #expect(recorder.snapshot() == DiagnosticReportArchive())
        #expect(await service.reportAttachment() == nil)
    }
    @Test("successful delivery acknowledges a report without dropping later errors")
    func deliveredReportLeavesOnlyLaterErrorsQueued() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let recorder = DiagnosticRecorder(
            store: DiagnosticReportStore(fileURL: directory.appendingPathComponent("diagnostics.json")),
            defaults: defaults
        )
        let service = DiagnosticReportService(
            recorder: recorder,
            logTailProvider: { [] }
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        service.setCollectionEnabled(true)
        recorder.record(
            error: NSError(domain: "DiagnosticReportServiceTests", code: 1),
            component: "diagnostics",
            operation: "first"
        )
        let delivered = try #require(await service.prepareAttachment())
        // This repeats the sent incident's signature after preparation. The
        // preparation boundary must prevent coalescing it into the report event.
        recorder.record(
            error: NSError(domain: "DiagnosticReportServiceTests", code: 1),
            component: "diagnostics",
            operation: "first"
        )
        service.acknowledgeDeliveredReport(delivered)

        let queued = recorder.snapshot().events
        #expect(queued.count == 1)
        #expect(queued[0].error?.code == 1)
        #expect(queued[0].repeatCount == 1)

        let nextData = try #require(await service.reportAttachment())
        let nextReport = try decodedReport(nextData)
        #expect(nextReport.events.count == 1)
        #expect(nextReport.events[0].error?.code == 1)
    }
    @Test("attachment contains only the latest diagnostic incident")
    func attachmentScopesToLatestDiagnosticIncident() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let recorder = DiagnosticRecorder(
            store: DiagnosticReportStore(fileURL: directory.appendingPathComponent("diagnostics.json")),
            defaults: defaults
        )
        let service = DiagnosticReportService(recorder: recorder, logTailProvider: { [] })
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        service.setCollectionEnabled(true)
        for code in 1...3 {
            recorder.record(
                error: NSError(domain: "DiagnosticReportServiceTests", code: code),
                component: "diagnostics",
                operation: "incident-\(code)"
            )
        }

        let data = try #require(await service.reportAttachment())
        let report = try decodedReport(data)
        #expect(report.events.count == 1)
        #expect(report.events[0].error?.code == 3)
        #expect(report.metricPayloads.isEmpty)
    }

    @Test("latest incident retains logs from its first occurrence")
    func latestIncidentRetainsLogsFromInitialOccurrence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let recorder = DiagnosticRecorder(
            store: DiagnosticReportStore(fileURL: directory.appendingPathComponent("diagnostics.json")),
            defaults: defaults
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        recorder.setCollectionEnabled(true)
        let error = NSError(domain: "DiagnosticReportServiceTests", code: 5)
        recorder.record(error: error, component: "diagnostics", operation: "coalesced")
        let initialTimestamp = try #require(recorder.snapshot().events.last?.timestamp)
        recorder.record(error: error, component: "diagnostics", operation: "coalesced")
        let repeatedTimestamp = try #require(recorder.snapshot().events.last?.lastTimestamp)
        let logs = [
            DiagnosticLogEntry(
                date: initialTimestamp.addingTimeInterval(-1),
                category: "diagnostics",
                level: "error",
                message: "older"
            ),
            DiagnosticLogEntry(
                date: initialTimestamp,
                category: "diagnostics",
                level: "error",
                message: "initial"
            ),
            DiagnosticLogEntry(
                date: repeatedTimestamp,
                category: "diagnostics",
                level: "error",
                message: "repeat"
            )
        ]
        let service = DiagnosticReportService(recorder: recorder, logTailProvider: { logs })

        let data = try #require(await service.reportAttachment())
        let report = try decodedReport(data)
        #expect(report.recentLogs.map(\.message) == ["initial", "repeat"])
    }

    @Test("canceling export leaves the prepared diagnostics queued")
    func canceledExportLeavesDiagnosticsQueued() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let recorder = DiagnosticRecorder(
            store: DiagnosticReportStore(fileURL: directory.appendingPathComponent("diagnostics.json")),
            defaults: defaults
        )
        let service = DiagnosticReportService(recorder: recorder, logTailProvider: { [] })
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        service.setCollectionEnabled(true)
        recorder.record(
            error: NSError(domain: "DiagnosticReportServiceTests", code: 3),
            component: "diagnostics",
            operation: "cancel"
        )
        _ = try #require(await service.prepareAttachment())

        #expect(recorder.snapshot().events.count == 1)
        let retained = try #require(await service.reportAttachment())
        #expect(try decodedReport(retained).events[0].error?.code == 3)
    }

    @Test("canceling an export restores normal error coalescing")
    func canceledExportRestoresNormalErrorCoalescing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let recorder = DiagnosticRecorder(
            store: DiagnosticReportStore(fileURL: directory.appendingPathComponent("diagnostics.json")),
            defaults: defaults
        )
        let service = DiagnosticReportService(recorder: recorder, logTailProvider: { [] })
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        service.setCollectionEnabled(true)
        let error = NSError(domain: "DiagnosticReportServiceTests", code: 4)
        recorder.record(error: error, component: "diagnostics", operation: "cancel-coalesce")
        _ = try #require(await service.prepareAttachment())
        service.discardPreparedReport()
        recorder.record(error: error, component: "diagnostics", operation: "cancel-coalesce")

        let events = recorder.snapshot().events
        #expect(events.count == 1)
        #expect(events[0].repeatCount == 2)
    }

    @Test("prepared log tail is reused when exporting")
    func preparedLogTailIsReusedWhenExporting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let recorder = DiagnosticRecorder(
            store: DiagnosticReportStore(fileURL: directory.appendingPathComponent("diagnostics.json")),
            defaults: defaults
        )
        let calls = DiagnosticLogTailCallCount()
        let service = DiagnosticReportService(
            recorder: recorder,
            logTailProvider: {
                calls.increment()
                return []
            }
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        service.setCollectionEnabled(true)
        recorder.record(
            error: NSError(domain: "DiagnosticReportServiceTests", code: 1),
            component: "diagnostics",
            operation: "prepare"
        )
        service.prepareReport()
        #expect(await calls.waitUntilCalled())
        #expect(calls.value == 1)

        _ = try #require(await service.reportAttachment())
        #expect(calls.value == 1)
    }

    @Test("revoking consent while preparing a report aborts the export")
    func revokingConsentWhilePreparingReportAbortsExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let recorder = DiagnosticRecorder(
            store: DiagnosticReportStore(fileURL: directory.appendingPathComponent("diagnostics.json")),
            defaults: defaults
        )
        let gate = DiagnosticLogTailGate()
        let service = DiagnosticReportService(
            recorder: recorder,
            logTailProvider: {
                gate.markStarted()
                gate.waitForRelease()
                return []
            }
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        service.setCollectionEnabled(true)
        recorder.record(
            error: NSError(domain: "DiagnosticReportServiceTests", code: 2),
            component: "diagnostics",
            operation: "revoke"
        )
        let export = Task { await service.reportAttachment() }
        #expect(await gate.waitUntilStarted())

        service.setCollectionEnabled(false)
        gate.release()

        #expect(await export.value == nil)
        #expect(recorder.snapshot() == DiagnosticReportArchive())
    }

    private func event(code: Int, at seconds: TimeInterval) -> DiagnosticEvent {
        DiagnosticEvent(
            timestamp: Date(timeIntervalSince1970: seconds),
            lastTimestamp: nil,
            repeatCount: 1,
            component: "meeting.capture",
            operation: "liveTranscription",
            source: nil,
            error: DiagnosticErrorFrame(
                relation: "root",
                domain: "ExampleError",
                code: code,
                type: "ExampleError",
                localizedDescription: "",
                failureReason: nil,
                userInfoKeys: []
            ),
            underlyingErrors: [],
            runtime: nil
        )
    }

    private func decodedReport(_ data: Data) throws -> UserDiagnosticReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UserDiagnosticReport.self, from: data)
    }
}

private final class DiagnosticLogTailCallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func waitUntilCalled() async -> Bool {
        for _ in 0..<200 {
            if value > 0 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return value > 0
    }
}

private final class DiagnosticLogTailGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func markStarted() {
        condition.lock()
        started = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForRelease() {
        condition.lock()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            condition.lock()
            let didStart = started
            condition.unlock()
            if didStart {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        condition.lock()
        defer { condition.unlock() }
        return started
    }
}

private struct LegacyArchiveFixture: Codable {
    let version: Int
    let events: [LegacyEventFixture]
    let metricPayloads: [String]
}

private struct LegacyEventFixture: Codable {
    let timestamp: Date
    let component: String
    let operation: String
    let errorDomain: String?
    let errorCode: Int?
    let errorType: String?
}
