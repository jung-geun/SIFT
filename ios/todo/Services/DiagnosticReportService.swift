import Foundation
import Combine
import OSLog
import CryptoKit
#if canImport(MetricKit)
import MetricKit
#endif

/// Content-free diagnostic event. User content, audio, transcripts, and task data are never recorded here.
nonisolated struct DiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    var lastTimestamp: Date?
    var repeatCount: Int
    let component: String
    let operation: String
    let source: DiagnosticSource?
    let error: DiagnosticErrorFrame?
    let underlyingErrors: [DiagnosticErrorFrame]
    let runtime: DiagnosticRuntimeState?
    /// Feature settings at the error timestamp. Optional for pre-v3 archives.
    let settings: [String: Bool]?

}

nonisolated struct DiagnosticReportArchive: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var events: [DiagnosticEvent]
    var metricPayloads: [String]
    /// Stable local identity paired one-to-one with `metricPayloads`.
    var metricPayloadIDs: [UUID]
    var ingestedPayloadDigests: [String]

    init(
        version: Int = currentVersion,
        events: [DiagnosticEvent] = [],
        metricPayloads: [String] = [],
        metricPayloadIDs: [UUID]? = nil,
        ingestedPayloadDigests: [String] = []
    ) {
        self.version = version
        self.events = events
        self.metricPayloads = metricPayloads
        self.metricPayloadIDs = metricPayloadIDs?.count == metricPayloads.count
            ? metricPayloadIDs!
            : metricPayloads.map { _ in UUID() }
        self.ingestedPayloadDigests = ingestedPayloadDigests
    }

    private enum CodingKeys: String, CodingKey {
        case version, events, metricPayloads, metricPayloadIDs, ingestedPayloadDigests
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion,
            events: try values.decodeIfPresent([DiagnosticEvent].self, forKey: .events) ?? [],
            metricPayloads: try values.decodeIfPresent([String].self, forKey: .metricPayloads) ?? [],
            metricPayloadIDs: try values.decodeIfPresent([UUID].self, forKey: .metricPayloadIDs),
            ingestedPayloadDigests: try values.decodeIfPresent([String].self, forKey: .ingestedPayloadDigests) ?? []
        )
    }
}

/// Persists a bounded, local-only diagnostic ring buffer. The archive exists only after explicit user consent.
nonisolated final class DiagnosticReportStore {
    static var defaultURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiagnosticReports", isDirectory: true)
        return directory.appendingPathComponent("diagnostic-report-v1.json")
    }

    private let fileURL: URL
    private let maxEvents: Int
    private let maxMetricPayloads: Int
    private let maxPayloadDigests: Int

    init(
        fileURL: URL,
        maxEvents: Int = 150,
        maxMetricPayloads: Int = 5,
        maxPayloadDigests: Int = 32
    ) {
        self.fileURL = fileURL
        self.maxEvents = maxEvents
        self.maxMetricPayloads = maxMetricPayloads
        self.maxPayloadDigests = maxPayloadDigests
    }

    func load() -> DiagnosticReportArchive {
        guard let data = try? Data(contentsOf: fileURL) else {
            return DiagnosticReportArchive()
        }
        if let archive = try? JSONDecoder().decode(DiagnosticReportArchive.self, from: data),
           archive.version == DiagnosticReportArchive.currentVersion {
            return archive
        }
        if let legacy = try? JSONDecoder().decode(LegacyArchiveV1.self, from: data),
           legacy.version == 1 {
            return DiagnosticReportArchive(
                events: legacy.events.map {
                    DiagnosticEvent(
                        timestamp: $0.timestamp,
                        lastTimestamp: nil,
                        repeatCount: 1,
                        component: $0.component,
                        operation: $0.operation,
                        source: nil,
                        error: DiagnosticErrorFrame(
                            relation: "root",
                            domain: $0.errorDomain ?? "unknown",
                            code: $0.errorCode ?? 0,
                            type: $0.errorType,
                            localizedDescription: "",
                            failureReason: nil,
                            userInfoKeys: []
                        ),
                        underlyingErrors: [],
                        runtime: nil,
                        settings: nil
                    )
                },
                metricPayloads: legacy.metricPayloads
            )
        }
        return DiagnosticReportArchive()
    }

    func append(_ event: DiagnosticEvent, coalescingWindow: TimeInterval = 60) -> DiagnosticReportArchive {
        var archive = load()
        if let last = archive.events.last,
           last.component == event.component,
           last.operation == event.operation,
           last.error?.domain == event.error?.domain,
           last.error?.code == event.error?.code,
           event.timestamp.timeIntervalSince(last.lastTimestamp ?? last.timestamp) <= coalescingWindow {
            let index = archive.events.index(before: archive.events.endIndex)
            archive.events[index].repeatCount += 1
            archive.events[index].lastTimestamp = event.timestamp
        } else {
            archive.events.append(event)
            archive.events = Array(archive.events.suffix(maxEvents))
        }
        persist(archive)
        return archive
    }

    func ingestMetricPayloads(_ redacted: [String], digests: [String]) -> DiagnosticReportArchive {
        var archive = load()
        for (payload, digest) in zip(redacted, digests) where !archive.ingestedPayloadDigests.contains(digest) {
            archive.metricPayloads.append(payload)
            archive.metricPayloadIDs.append(UUID())
            archive.ingestedPayloadDigests.append(digest)
        }
        let retainedPayloads = Array(
            zip(archive.metricPayloads, archive.metricPayloadIDs)
                .suffix(maxMetricPayloads)
        )
        archive.metricPayloads = retainedPayloads.map(\.0)
        archive.metricPayloadIDs = retainedPayloads.map(\.1)
        archive.ingestedPayloadDigests = Array(archive.ingestedPayloadDigests.suffix(maxPayloadDigests))
        persist(archive)
        return archive
    }

    /// Removes diagnostics no newer than a successfully delivered report.
    /// The preparation boundary makes later errors their own event, so they stay
    /// queued. Payload digests remain so Apple does not re-ingest a payload.
    func acknowledgeReportedDiagnostics(
        through: Date,
        metricPayloadIDs: [UUID]
    ) -> DiagnosticReportArchive {
        var archive = load()
        archive.events.removeAll {
            ($0.lastTimestamp ?? $0.timestamp) <= through
        }
        let reportedPayloadIDs = Set(metricPayloadIDs)
        let retainedPayloads = zip(archive.metricPayloads, archive.metricPayloadIDs)
            .filter { !reportedPayloadIDs.contains($0.1) }
        archive.metricPayloads = retainedPayloads.map(\.0)
        archive.metricPayloadIDs = retainedPayloads.map(\.1)
        persist(archive)
        return archive
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist(_ archive: DiagnosticReportArchive) {
        guard let data = try? JSONEncoder().encode(archive) else { return }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var mutableDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableDirectory.setResourceValues(values)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path
            )
        } catch {
            return
        }
    }

    private struct LegacyArchiveV1: Decodable {
        let version: Int
        let events: [LegacyEventV1]
        let metricPayloads: [String]
    }

    private struct LegacyEventV1: Decodable {
        let timestamp: Date
        let component: String
        let operation: String
        let errorDomain: String?
        let errorCode: Int?
        let errorType: String?
    }
}

/// Thread-safe recording engine. Usable from any isolation domain.
nonisolated final class DiagnosticRecorder: @unchecked Sendable {
    static let shared = DiagnosticRecorder(
        store: DiagnosticReportStore(fileURL: DiagnosticReportStore.defaultURL),
        defaults: .standard
    )

    private let store: DiagnosticReportStore
    private let defaults: UserDefaults
    private let lock = NSLock()
    /// A prepared report creates a coalescing boundary so later repeated errors
    /// receive their own event and cannot be acknowledged with the older report.
    private var preparedReportBoundary: Date?

    init(store: DiagnosticReportStore, defaults: UserDefaults) {
        self.store = store
        self.defaults = defaults
    }

    var collectionEnabled: Bool {
        defaults.bool(forKey: DiagnosticReportService.collectionEnabledKey)
    }

    func setCollectionEnabled(_ enabled: Bool) {
        lock.lock()
        defaults.set(enabled, forKey: DiagnosticReportService.collectionEnabledKey)
        if !enabled {
            store.clear()
            preparedReportBoundary = nil
        }
        lock.unlock()
        postArchiveChanged(DiagnosticReportArchive())
    }

    func record(
        error: Error,
        component: String,
        operation: String,
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        guard collectionEnabled, !(error is CancellationError) else { return }
        let chain = DiagnosticErrorChain.frames(for: error)
        lock.lock()
        guard collectionEnabled else {
            lock.unlock()
            return
        }
        let event = DiagnosticEvent(
            timestamp: Date(),
            lastTimestamp: nil,
            repeatCount: 1,
            component: component,
            operation: operation,
            source: DiagnosticSource(file: file, line: line, function: function),
            error: chain.root,
            underlyingErrors: chain.underlying,
            runtime: DiagnosticEnvironment.runtimeState(),
            settings: DiagnosticEnvironment.settingsSnapshot()
        )
        let archive = store.append(
            event,
            coalescingWindow: preparedReportBoundary == nil ? 60 : 0
        )
        lock.unlock()
        postArchiveChanged(archive)
    }

    func ingest(metricPayloads: [String]) {
        guard collectionEnabled, !metricPayloads.isEmpty else { return }
        let redacted = metricPayloads.map(DiagnosticRedaction.metricPayload)
        let digests = redacted.map(Self.digest)
        lock.lock()
        guard collectionEnabled else {
            lock.unlock()
            return
        }
        let archive = store.ingestMetricPayloads(redacted, digests: digests)
        lock.unlock()
        postArchiveChanged(archive)
    }

    func ingestPastMetricPayloads() {
        #if canImport(MetricKit)
        ingest(metricPayloads: MXMetricManager.shared.pastDiagnosticPayloads.map {
            String(decoding: $0.jsonRepresentation(), as: UTF8.self)
        })
        #endif
    }

    func snapshot() -> DiagnosticReportArchive {
        lock.lock()
        defer { lock.unlock() }
        return store.load()
    }

    struct ReportSnapshot: Sendable {
        let archive: DiagnosticReportArchive
        let generatedAt: Date
    }

    func snapshotForReport() -> ReportSnapshot {
        lock.lock()
        let generatedAt = Date()
        let archive = store.load()
        if !archive.events.isEmpty {
            preparedReportBoundary = generatedAt
        }
        lock.unlock()
        return ReportSnapshot(archive: archive, generatedAt: generatedAt)
    }

    func discardPreparedReport() {
        lock.lock()
        preparedReportBoundary = nil
        lock.unlock()
    }

    func acknowledgeReportedDiagnostics(
        through: Date,
        metricPayloadIDs: [UUID]
    ) {
        lock.lock()
        let archive = store.acknowledgeReportedDiagnostics(
            through: through,
            metricPayloadIDs: metricPayloadIDs
        )
        preparedReportBoundary = nil
        lock.unlock()
        postArchiveChanged(archive)
    }
    func clear() {
        lock.lock()
        store.clear()
        preparedReportBoundary = nil
        lock.unlock()
        postArchiveChanged(DiagnosticReportArchive())
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func postArchiveChanged(_ archive: DiagnosticReportArchive) {
        NotificationCenter.default.post(
            name: .diagnosticReportArchiveChanged,
            object: nil,
            userInfo: [
                DiagnosticReportArchiveNotificationKey.eventCount: archive.events.count,
                DiagnosticReportArchiveNotificationKey.metricPayloadCount: archive.metricPayloads.count
            ]
        )
    }
}

nonisolated extension Notification.Name {
    static let diagnosticReportArchiveChanged = Notification.Name("pieroot.todo.diagnosticReportArchiveChanged")
}

nonisolated private enum DiagnosticReportArchiveNotificationKey {
    static let eventCount = "eventCount"
    static let metricPayloadCount = "metricPayloadCount"
}

typealias DiagnosticLogTailProvider = @Sendable () -> [DiagnosticLogEntry]

@MainActor
final class DiagnosticReportService: ObservableObject {
    static let shared = DiagnosticReportService()

    nonisolated static let collectionEnabledKey = "pieroot.todo.diagnosticReportCollectionEnabled"
    nonisolated static let supportEmail = "pieroot.02@gmail.com"

    @Published private(set) var eventCount = 0
    @Published private(set) var metricPayloadCount = 0

    private let recorder: DiagnosticRecorder
    private let logTailProvider: DiagnosticLogTailProvider
    private var logTailPreparation: (id: UUID, task: Task<[DiagnosticLogEntry], Never>)?
    private var recentLogCache: (date: Date, entries: [DiagnosticLogEntry])?
    private var countRevision = 0
    private var archiveChangedObserver: NSObjectProtocol?
    #if canImport(MetricKit)
    private let metricSubscriber = MetricKitDiagnosticSubscriber()
    private var metricSubscriberRegistered = false
    #endif

    init(
        recorder: DiagnosticRecorder = .shared,
        logTailProvider: @escaping DiagnosticLogTailProvider = { DiagnosticLogTail.recent() }
    ) {
        self.recorder = recorder
        self.logTailProvider = logTailProvider
        #if canImport(MetricKit)
        metricSubscriber.onDiagnostics = { [recorder] payloads in
            recorder.ingest(metricPayloads: payloads)
        }
        #endif
        archiveChangedObserver = NotificationCenter.default.addObserver(
            forName: .diagnosticReportArchiveChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let eventCount = notification.userInfo?[DiagnosticReportArchiveNotificationKey.eventCount] as? Int,
                let metricPayloadCount = notification.userInfo?[DiagnosticReportArchiveNotificationKey.metricPayloadCount] as? Int
            else {
                Task { @MainActor [weak self] in
                    await self?.refreshCounts()
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                countRevision += 1
                updateCounts(eventCount: eventCount, metricPayloadCount: metricPayloadCount)
            }
        }
        Task { [weak self] in
            await self?.refreshCounts()
        }
    }

    convenience init(store: DiagnosticReportStore, defaults: UserDefaults) {
        self.init(recorder: DiagnosticRecorder(store: store, defaults: defaults))
    }

    deinit {
        if let archiveChangedObserver {
            NotificationCenter.default.removeObserver(archiveChangedObserver)
        }
    }

    var collectionEnabled: Bool {
        recorder.collectionEnabled
    }

    var hasShareableReport: Bool {
        collectionEnabled && (eventCount > 0 || metricPayloadCount > 0)
    }

    func configure() {
        #if canImport(MetricKit)
        if collectionEnabled, !metricSubscriberRegistered {
            MXMetricManager.shared.add(metricSubscriber)
            metricSubscriberRegistered = true
        } else if !collectionEnabled, metricSubscriberRegistered {
            MXMetricManager.shared.remove(metricSubscriber)
            metricSubscriberRegistered = false
        }
        #endif
        if collectionEnabled {
            let recorder = recorder
            Task.detached {
                recorder.ingestPastMetricPayloads()
            }
        }
        Task { [weak self] in
            await self?.refreshCounts()
        }
    }

    func setCollectionEnabled(_ enabled: Bool) {
        recorder.setCollectionEnabled(enabled)
        if !enabled {
            logTailPreparation?.task.cancel()
            logTailPreparation = nil
            recentLogCache = nil
        }
        configure()
    }

    /// Starts the slow local-log scan before the user taps Send.
    func prepareReport() {
        Task { [weak self] in
            guard let self else { return }
            let archive = await archiveSnapshot()
            guard collectionEnabled, !archive.events.isEmpty || !archive.metricPayloads.isEmpty else { return }
            startLogTailPreparationIfNeeded()
        }
    }

    /// A report payload plus the cutoff used to keep only later diagnostics
    /// queued after delivery.
    struct PreparedReport: Sendable {
        let data: Data
        let generatedAt: Date
        let metricPayloads: [String]
        let metricPayloadIDs: [UUID]
    }

    func prepareAttachment() async -> PreparedReport? {
        guard collectionEnabled else { return nil }
        let snapshot = await reportSnapshot()
        let archive = snapshot.archive
        let generatedAt = snapshot.generatedAt
        let scopedEvents = archive.events.last.map { [$0] } ?? []
        // MetricKit diagnostics arrive asynchronously and are not attributable to
        // the incident that opened this report. Keep them local rather than
        // attaching stale system diagnostics to a just-occurred error report.
        let scopedMetricPayloads: [String] = []
        let scopedMetricPayloadIDs: [UUID] = []
        guard collectionEnabled, !scopedEvents.isEmpty else {
            return nil
        }
        let device = DiagnosticEnvironment.deviceInfo()
        let app = DiagnosticEnvironment.appInfo()
        let settings = scopedEvents[0].settings
        let logs = await recentLogsForReport()
        guard collectionEnabled else { return nil }

        let data = await Task.detached(priority: .userInitiated) {
            let report = UserDiagnosticReport(
                reportVersion: UserDiagnosticReport.currentVersion,
                generatedAt: generatedAt,
                app: app,
                device: device,
                settings: settings,
                events: scopedEvents,
                metricPayloads: scopedMetricPayloads,
                recentLogs: logs.filter {
                    $0.date >= scopedEvents[0].timestamp
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(report)
        }.value
        guard collectionEnabled, let data else {
            discardPreparedReport()
            return nil
        }
        return PreparedReport(
            data: data,
            generatedAt: generatedAt,
            metricPayloads: scopedMetricPayloads,
            metricPayloadIDs: scopedMetricPayloadIDs
        )
    }

    /// Call only after Mail reports `.sent` or a share activity completes.
    /// Cancellation leaves all diagnostics queued.
    func acknowledgeDeliveredReport(_ report: PreparedReport) {
        guard collectionEnabled else { return }
        recorder.acknowledgeReportedDiagnostics(
            through: report.generatedAt,
            metricPayloadIDs: report.metricPayloadIDs
        )
        recentLogCache = nil
    }

    func discardPreparedReport() {
        recorder.discardPreparedReport()
        recentLogCache = nil
    }

    func reportAttachment() async -> Data? {
        let report = await prepareAttachment()
        discardPreparedReport()
        return report?.data
    }

    func clearLocalReports() {
        recorder.clear()
        logTailPreparation?.task.cancel()
        logTailPreparation = nil
        recentLogCache = nil
    }

    private func refreshCounts() async {
        let revision = countRevision
        let archive = await archiveSnapshot()
        guard countRevision == revision else { return }
        updateCounts(archive)
    }

    private func updateCounts(_ archive: DiagnosticReportArchive) {
        updateCounts(
            eventCount: archive.events.count,
            metricPayloadCount: archive.metricPayloads.count
        )
    }

    private func updateCounts(eventCount: Int, metricPayloadCount: Int) {
        self.eventCount = eventCount
        self.metricPayloadCount = metricPayloadCount
    }

    private func archiveSnapshot() async -> DiagnosticReportArchive {
        let recorder = recorder
        return await Task.detached(priority: .userInitiated) {
            recorder.snapshot()
        }.value
    }
    private func reportSnapshot() async -> DiagnosticRecorder.ReportSnapshot {
        let recorder = recorder
        return await Task.detached(priority: .userInitiated) {
            recorder.snapshotForReport()
        }.value
    }

    private func startLogTailPreparationIfNeeded() {
        let now = Date()
        if let cache = recentLogCache, now.timeIntervalSince(cache.date) < 30 {
            return
        }

        guard logTailPreparation == nil else { return }
        let provider = logTailProvider
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) {
            provider()
        }
        logTailPreparation = (id: id, task: task)
        Task { [weak self] in
            let entries = await task.value
            guard let self, self.logTailPreparation?.id == id else { return }
            self.logTailPreparation = nil
            guard self.collectionEnabled else { return }
            self.recentLogCache = (date: Date(), entries: entries)
        }
    }

    private func recentLogsForReport() async -> [DiagnosticLogEntry] {
        let now = Date()
        if let cache = recentLogCache, now.timeIntervalSince(cache.date) < 30 {
            return cache.entries
        }
        startLogTailPreparationIfNeeded()
        guard let preparation = logTailPreparation else { return [] }
        let entries = await preparation.task.value
        guard collectionEnabled else {
            if logTailPreparation?.id == preparation.id {
                logTailPreparation = nil
            }
            return []
        }
        if logTailPreparation?.id == preparation.id {
            logTailPreparation = nil
            recentLogCache = (date: Date(), entries: entries)
        }
        return entries
    }
}

nonisolated struct UserDiagnosticReport: Codable {
    /// Version 4 includes settings captured at the error timestamp when the
    /// event was recorded by the current app version.
    static let currentVersion = 4

    let reportVersion: Int
    let generatedAt: Date
    let app: DiagnosticAppInfo
    let device: DiagnosticDeviceInfo
    let settings: [String: Bool]?
    let events: [DiagnosticEvent]
    let metricPayloads: [String]
    let recentLogs: [DiagnosticLogEntry]
}

#if canImport(MetricKit)
private final class MetricKitDiagnosticSubscriber: NSObject, MXMetricManagerSubscriber {
    var onDiagnostics: (([String]) -> Void)?

    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        onDiagnostics?(payloads.map { String(decoding: $0.jsonRepresentation(), as: UTF8.self) })
    }
}
#endif
