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

    @Test("acknowledged reports remove only included event and metric snapshots")
    func acknowledgedReportsKeepUnsentDiagnostics() throws {
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
            events: [event(code: 1, at: 10)],
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
        let preview = try #require(DiagnosticReportPreview(data: data))
        #expect(Data(preview.text.utf8) == data)
        #expect(preview.app == report.app)
        #expect(preview.device == report.device)
        #expect(preview.events == report.events)

        #expect(report.reportVersion == UserDiagnosticReport.currentVersion)
        #expect(!report.app.bundleIdentifier.isEmpty)
        #expect(!report.device.modelIdentifier.isEmpty)
        #expect(report.settings?.isEmpty == false)
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
    @Test("successful delivery retains older unsent incidents and later repeated errors")
    func deliveredReportLeavesUnsentAndLaterErrorsQueued() async throws {
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
            error: NSError(domain: "DiagnosticReportServiceTests", code: 99),
            component: "diagnostics",
            operation: "older-unsent"
        )
        recorder.record(
            error: NSError(domain: "DiagnosticReportServiceTests", code: 1),
            component: "diagnostics",
            operation: "first"
        )
        let delivered = try #require(await service.prepareAttachment())
        let request = DiagnosticExportRequest(
            data: delivered.data,
            events: delivered.events,
            metricPayloads: delivered.metricPayloads,
            metricPayloadIDs: delivered.metricPayloadIDs
        )
        let preview = try #require(request.preview)
        // This repeats the sent incident's signature after preparation. The
        // preparation boundary must prevent coalescing it into the report event.
        recorder.record(
            error: NSError(domain: "DiagnosticReportServiceTests", code: 1),
            component: "diagnostics",
            operation: "first"
        )
        #expect(request.data == delivered.data)
        #expect(Data(preview.text.utf8) == request.data)
        #expect(preview.events.count == 1)
        service.acknowledgeDeliveredReport(.init(
            data: request.data,
            events: request.events,
            metricPayloads: request.metricPayloads,
            metricPayloadIDs: request.metricPayloadIDs
        ))

        let queued = recorder.snapshot().events
        #expect(queued.compactMap(\.error?.code) == [99, 1])
        #expect(queued.last?.repeatCount == 1)

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
        let prepared = try #require(await service.prepareAttachment())
        let request = DiagnosticExportRequest(
            data: prepared.data,
            events: prepared.events,
            metricPayloads: prepared.metricPayloads,
            metricPayloadIDs: prepared.metricPayloadIDs
        )
        #expect(request.preview != nil)
        let beforeCancellation = recorder.snapshot()
        service.discardPreparedReport()
        #expect(recorder.snapshot() == beforeCancellation)

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

    @Test("error reports retain source and error-time locale metadata")
    func reportsRetainSourceAndErrorTimeLocale() async throws {
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
            error: NSError(domain: "DetailedDiagnostics", code: 41),
            component: "diagnostics",
            operation: "captureContext",
            file: "todoTests/DiagnosticFixture.swift",
            line: 867,
            function: "reportsRetainSourceAndErrorTimeLocale()"
        )

        let event = try #require(recorder.snapshot().events.last)
        #expect(event.source?.file == "todoTests/DiagnosticFixture.swift")
        #expect(event.source?.line == 867)
        #expect(event.source?.function == "reportsRetainSourceAndErrorTimeLocale()")
        let runtime = try #require(event.runtime)
        let locale = try #require(runtime.locale)
        #expect(locale.identifier == Locale.current.identifier)
        #expect(locale.regionCode == Locale.current.region?.identifier)
        #expect(locale.timeZoneIdentifier == TimeZone.current.identifier)
        #expect(locale.timeZoneOffsetSeconds == TimeZone.current.secondsFromGMT())
        #expect(event.settings?["hasOnboarded"] != nil)

        let data = try #require(await service.reportAttachment())
        let report = try decodedReport(data)
        #expect(report.reportVersion == UserDiagnosticReport.currentVersion)
        #expect(report.events.first?.runtime?.locale == locale)
        #expect(report.device.locale.identifier == Locale.current.identifier)
        #expect(report.device.locale.regionCode == Locale.current.region?.identifier)
        #expect(report.device.locale.timeZoneOffsetSeconds == TimeZone.current.secondsFromGMT())
        #expect(report.settings == event.settings)
    }

    @Test("pre-locale runtime snapshots remain decodable")
    func preLocaleRuntimeSnapshotsRemainDecodable() throws {
        let data = Data(
            """
            {
              "appVersion": "1.0",
              "build": "1",
              "systemVersion": "iOS Version 18.0",
              "appState": "active",
              "processUptimeSeconds": 12.5,
              "thermalState": "nominal",
              "isLowPowerModeEnabled": false,
              "memoryFootprintBytes": 100,
              "availableDiskBytes": 200
            }
            """.utf8
        )

        let runtime = try JSONDecoder().decode(DiagnosticRuntimeState.self, from: data)
        #expect(runtime.operatingSystemBuild == nil)
        #expect(runtime.locale == nil)
    }

    @Test("diagnostic settings use live mail preference keys and credential state")
    func diagnosticSettingsUseLiveMailPreferenceKeysAndCredentialState() throws {
        let suiteName = "DiagnosticReportServiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let gmailAccount = "diagnostic-gmail@example.com"
        let outlookAccount = "diagnostic-outlook@example.com"
        defer {
            try? IMAPCredentialStore.delete(for: gmailAccount)
            try? OutlookIMAPCredentialStore.delete(for: outlookAccount)
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(gmailAccount, forKey: "pieroot.todo.imap.account")
        defaults.set(true, forKey: "pieroot.todo.imap.backgroundEnabled")
        defaults.set(outlookAccount, forKey: "pieroot.todo.outlook.account")
        defaults.set(true, forKey: "pieroot.todo.outlook.backgroundEnabled")
        try IMAPCredentialStore.save(
            appPassword: "gmail-test-password",
            for: gmailAccount,
            backgroundEnabled: true
        )
        try OutlookIMAPCredentialStore.save(
            appPassword: "outlook-test-password",
            for: outlookAccount,
            backgroundEnabled: true
        )

        let settings = DiagnosticEnvironment.settingsSnapshot(defaults)

        #expect(settings["imapBackgroundEnabled"] == true)
        #expect(settings["outlookBackgroundEnabled"] == true)
        #expect(settings["gmailAccountLinked"] == true)
        #expect(settings["gmailCredentialStored"] == true)
        #expect(settings["gmailCredentialRejected"] == false)
        #expect(settings["outlookAccountLinked"] == true)
        #expect(settings["outlookCredentialStored"] == true)
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
            runtime: nil,
            settings: nil
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
            let didStart = condition.withLock { started }
            if didStart {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition.withLock { started }
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
