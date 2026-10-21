import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Read-only, explicitly requested HealthKit history. Initialization and history reads never prompt.
///
/// SDK prerequisites (iPhoneOS27.0.sdk): HKWorkout/HKSampleQuery/HKHealthStore are iOS 8+,
/// Mac Catalyst 13+; the async authorization overload is iOS/Mac Catalyst 15+.
/// Medication dose events, user-annotated medication queries, concept identifiers and displayText
/// are iOS/Mac Catalyst 26+. Catalyst is SDK-supported, but actual access is device-dependent.
/// Signing requires the HealthKit capability/entitlement and NSHealthShareUsageDescription.
/// No update usage description, clinical-record entitlement or background delivery is needed.
@MainActor
final class HealthHistoryReader: HealthHistoryReading {
    #if canImport(HealthKit)
    private lazy var store = HKHealthStore()
    private static let sampleCap = 10_000
    private static let medicationCap = 512
    #endif

    /// A permission-free capability probe for hiding unsupported entry points.
    static var availableCategories: [HealthHistoryCategory] {
        HealthHistoryCategory.allCases.filter { categoryUnavailableReason(for: $0) == nil }
    }

    func unavailableReason(for category: HealthHistoryCategory) -> String? {
        Self.categoryUnavailableReason(for: category)
    }

    private static func categoryUnavailableReason(for category: HealthHistoryCategory) -> String? {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            #if targetEnvironment(macCatalyst)
            return HealthCopy.text("health.reader.unavailable.catalyst", "HealthKit reports that health data is unavailable on this Mac (Mac Catalyst).", "HealthKit에 따르면 이 Mac(Mac Catalyst)에서는 건강 데이터를 사용할 수 없습니다.")
            #else
            return HealthCopy.text("health.reader.unavailable.device", "HealthKit reports that health data is unavailable on this device.", "HealthKit에 따르면 이 기기에서는 건강 데이터를 사용할 수 없습니다.")
            #endif
        }
        if category == .medication {
            guard #available(iOS 26.0, macCatalyst 26.0, *) else {
                return HealthCopy.text("health.reader.unavailable.medication", "Medication history requires iOS or Mac Catalyst 26.0 or later: earlier systems do not expose HealthKit medication dose events and tracked-medication queries.", "복약 기록을 읽으려면 iOS 또는 Mac Catalyst 26.0 이상이 필요합니다. 이전 버전에서는 HealthKit 복약 이벤트 및 추적 중인 약 조회 API를 제공하지 않습니다.")
            }
        }
        return nil
        #else
        return HealthCopy.text("health.reader.unavailable.framework", "This platform does not include the HealthKit framework.", "이 플랫폼에는 HealthKit 프레임워크가 포함되어 있지 않습니다.")
        #endif
    }

    /// Called only by the parent's explicit category-connect action, never by history().
    /// Successful completion means the request completed, NOT that read access was granted.
    func requestRead(for category: HealthHistoryCategory) async throws {
        try Task.checkCancellation()
        if let reason = unavailableReason(for: category) { throw HealthHistoryError.unavailable(reason) }
        #if canImport(HealthKit)
        let types: Set<HKObjectType>
        switch category {
        case .workout:
            types = [HKObjectType.workoutType()]
        case .medication:
            guard #available(iOS 26.0, macCatalyst 26.0, *) else {
                throw ReaderError.medicationUnavailable
            }
            types = [HKObjectType.medicationDoseEventType(), HKObjectType.userAnnotatedMedicationType()]
        }
        // authorizationStatus(for:) describes SHARING permission, not read permission; do not use it.
        // HealthKit owns the authorization sheet; cancelling this task cannot dismiss that sheet.
        try await store.requestAuthorization(toShare: [], read: types)
        try Task.checkCancellation()
        #endif
    }

    func history(for category: HealthHistoryCategory, from: Date, through: Date) async throws -> [HealthHistoryRecord] {
        try Task.checkCancellation()
        if let reason = unavailableReason(for: category) { throw HealthHistoryError.unavailable(reason) }
        guard from.timeIntervalSinceReferenceDate.isFinite,
              through.timeIntervalSinceReferenceDate.isFinite, from <= through else {
            throw ReaderError.invalidRange
        }
        #if canImport(HealthKit)
        // Explicit inclusive start-date bounds: unlike overlap predicates, no earlier workout leaks in.
        let range = NSPredicate(format: "%K >= %@ AND %K <= %@",
                                HKPredicateKeyPathStartDate, from as NSDate,
                                HKPredicateKeyPathStartDate, through as NSDate)
        let records: [HealthHistoryRecord]
        switch category {
        case .workout:
            let samples = try await samples(type: HKObjectType.workoutType(), predicate: range)
            records = try samples.map { sample in
                try Task.checkCancellation()
                guard let workout = sample as? HKWorkout else { throw ReaderError.invalidResponse }
                let source = workout.sourceRevision.source
                return HealthHistoryRecord(id: workout.uuid.uuidString, category: .workout,
                    kindKey: "workout:\(workout.workoutActivityType.rawValue)",
                    title: Self.workoutTitle(workout.workoutActivityType), startDate: workout.startDate,
                    sourceID: source.bundleIdentifier, sourceName: source.name)
            }
        case .medication:
            guard #available(iOS 26.0, macCatalyst 26.0, *) else {
                throw ReaderError.medicationUnavailable
            }
            records = try await medicationHistory(in: range)
        }
        try Task.checkCancellation()
        // The parent also checks its epoch before publication after disconnect/reconnect.
        return records
        #else
        throw HealthHistoryError.unavailable(HealthCopy.text("health.reader.unavailable.framework", "This platform does not include the HealthKit framework.", "이 플랫폼에는 HealthKit 프레임워크가 포함되어 있지 않습니다."))
        #endif
    }

    #if canImport(HealthKit)
    private func samples(type: HKSampleType, predicate: NSPredicate) async throws -> [HKSample] {
        let operation = HealthHistoryQuery<HKSample>(store: store, cap: Self.sampleCap,
            label: HealthCopy.text("health.reader.query.history", "Health history", "건강 기록"))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                // One sentinel sample distinguishes an exact-cap result from truncated history.
                let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: Self.sampleCap + 1,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                    operation.receive(error: error) { values in
                        guard let samples else { throw ReaderError.invalidResponse }
                        values = samples
                        return true
                    }
                }
                operation.start(query, continuation: continuation)
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            operation.cancel()
        }
    }

    @available(iOS 26.0, macCatalyst 26.0, *)
    private func medications() async throws -> [HKUserAnnotatedMedication] {
        let operation = HealthHistoryQuery<HKUserAnnotatedMedication>(store: store, cap: Self.medicationCap,
            label: HealthCopy.text("health.reader.query.medicationNames", "Medication name lookup", "약 이름 조회"))
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                // This API has no date-range predicate: it is a bounded identity/name lookup only.
                // Include archived medications, which can still have events in the requested range.
                let query = HKUserAnnotatedMedicationQuery(predicate: nil, limit: Self.medicationCap + 1) { _, medication, done, error in
                    operation.receive(error: error) { values in
                        if let medication { values.append(medication) }
                        return done
                    }
                }
                operation.start(query, continuation: continuation)
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            operation.cancel()
        }
    }

    @available(iOS 26.0, macCatalyst 26.0, *)
    private func medicationHistory(in range: NSPredicate) async throws -> [HealthHistoryRecord] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            range, HKQuery.predicateForMedicationDoseEvent(status: .taken)
        ])
        let events = try await samples(type: HKObjectType.medicationDoseEventType(), predicate: predicate)
        guard !events.isEmpty else { return [] }
        let tracked = try await medications()
        var names: [HKHealthConceptIdentifier: String] = [:]
        for medication in tracked {
            let nickname = Self.displayName(medication.nickname ?? "")
            let name = nickname.isEmpty ? Self.displayName(medication.medication.displayText) : nickname
            if !name.isEmpty { names[medication.medication.identifier] = name }
        }
        var keys: [HKHealthConceptIdentifier: String] = [:]
        var records: [HealthHistoryRecord] = []
        records.reserveCapacity(events.count)
        for sample in events {
            try Task.checkCancellation()
            guard let event = sample as? HKMedicationDoseEvent else { throw ReaderError.invalidResponse }
            // Defensive exact match also excludes future statuses, skipped, snoozed, notLogged,
            // notInteracted and notificationNotSent. No schedule/quantity/unit is projected.
            guard event.logStatus == .taken else { continue }
            let concept = event.medicationConceptIdentifier
            let key: String
            if let existing = keys[concept] {
                key = existing
            } else {
                // The public identifier exposes a domain, but NO raw UUID/string value.
                // Preserve the opaque NSSecureCoding identifier losslessly, not description,
                // hashValue, a drug name or a clinical code that could conflate unrelated entries.
                // NSSecureCoding promises persistence, not canonical bytes: cross-read/OS key
                // stability is inferred, not SDK-guaranteed. An encoding change may split a
                // candidate identity; hashing these bytes would not fix that limitation.
                let archive = try NSKeyedArchiver.archivedData(withRootObject: concept, requiringSecureCoding: true)
                key = "medication-concept:\(archive.base64EncodedString())"
                keys[concept] = key
            }
            let source = event.sourceRevision.source
            records.append(HealthHistoryRecord(id: event.uuid.uuidString, category: .medication,
                kindKey: key, title: names[concept] ?? HealthCopy.text("health.reader.medication.recorded", "Recorded medication", "기록된 복약"), startDate: event.startDate,
                sourceID: source.bundleIdentifier, sourceName: source.name, wasTaken: true))
        }
        return records
    }

    private static func displayName(_ text: String) -> String {
        // Use only HealthKit's user-facing name/nickname, never diagnostic descriptions.
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func workoutTitle(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return HealthCopy.text("health.reader.workout.walking", "Walking", "걷기")
        case .running: return HealthCopy.text("health.reader.workout.running", "Running", "달리기")
        case .cycling: return HealthCopy.text("health.reader.workout.cycling", "Cycling", "사이클링")
        case .swimming: return HealthCopy.text("health.reader.workout.swimming", "Swimming", "수영")
        case .hiking: return HealthCopy.text("health.reader.workout.hiking", "Hiking", "하이킹")
        case .yoga: return HealthCopy.text("health.reader.workout.yoga", "Yoga", "요가")
        case .pilates: return HealthCopy.text("health.reader.workout.pilates", "Pilates", "필라테스")
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            return HealthCopy.text("health.reader.workout.strength", "Strength training", "근력 운동")
        case .highIntensityIntervalTraining:
            return HealthCopy.text("health.reader.workout.intervals", "Interval training", "인터벌 트레이닝")
        case .dance: return HealthCopy.text("health.reader.workout.dance", "Dance", "댄스")
        case .rowing: return HealthCopy.text("health.reader.workout.rowing", "Rowing", "로잉")
        case .elliptical: return HealthCopy.text("health.reader.workout.elliptical", "Elliptical workout", "일립티컬 운동")
        case .mindAndBody: return HealthCopy.text("health.reader.workout.mindAndBody", "Mind and body workout", "심신 운동")
        default: return HealthCopy.text("health.reader.workout.recorded", "Recorded workout", "기록된 운동")
        }
    }
    #endif
}

nonisolated private enum ReaderError: LocalizedError {
    case invalidRange, invalidResponse, medicationUnavailable
    case truncated(String, Int)

    var errorDescription: String? {
        switch self {
        case .invalidRange:
            return HealthCopy.text("health.reader.error.range", "Health history requires a finite date range with the start no later than the end.", "건강 기록 조회에는 시작일이 종료일보다 늦지 않은 유효한 날짜 범위가 필요합니다.")
        case .invalidResponse:
            return HealthCopy.text("health.reader.error.response", "HealthKit returned an unexpected query response; no history was published.", "HealthKit이 예상하지 못한 조회 응답을 반환하여 기록을 반영하지 않았습니다.")
        case .medicationUnavailable:
            return HealthCopy.text("health.reader.error.medicationUnavailable", "Medication history requires iOS or Mac Catalyst 26.0 or later.", "복약 기록을 읽으려면 iOS 또는 Mac Catalyst 26.0 이상이 필요합니다.")
        case .truncated(let label, let cap):
            return String(format: HealthCopy.text("health.reader.error.truncated.format", "The %@ query exceeds the %ld-record safety limit. No partial results were published.", "%@ 조회가 안전 한도인 %ld건을 초과했습니다. 불완전한 조회 결과는 반영하지 않았습니다."), locale: AppLanguage.current.locale, label, cap)
        }
    }
}

#if canImport(HealthKit)
/// HKQuery handlers run on arbitrary queues. All mutable state, including start vs. cancel,
/// is lock-protected. Stopping a query suppresses callbacks, so cancellation must resume its
/// continuation itself. Each operation owns a single query; concurrent readers cannot stop siblings.
nonisolated private final class HealthHistoryQuery<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let store: HKHealthStore
    private let cap: Int
    private let label: String
    private var query: HKQuery?
    private var continuation: CheckedContinuation<[Element], Error>?
    private var values: [Element] = []
    private var finished = false

    private typealias Resolution = (HKQuery?, CheckedContinuation<[Element], Error>, Result<[Element], Error>)

    init(store: HKHealthStore, cap: Int, label: String) {
        self.store = store
        self.cap = cap
        self.label = label
    }

    func start(_ query: HKQuery, continuation: CheckedContinuation<[Element], Error>) {
        let cancelled = lock.withLock {
            guard !finished else { return true }
            self.query = query
            self.continuation = continuation
            // SDK guarantees asynchronous handlers. Serialize execute with cancellation so
            // stop cannot race ahead of execute and leave a cancelled query running.
            store.execute(query)
            return false
        }
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    func receive(error: Error?, update: (inout [Element]) throws -> Bool) {
        let resolution: Resolution? = lock.withLock {
            guard !finished else { return nil }
            // Authorization/query errors always propagate, never become empty evidence.
            if let error { return finishLocked(.failure(error)) }
            do {
                let done = try update(&values)
                guard values.count <= cap else {
                    return finishLocked(.failure(ReaderError.truncated(label, cap)))
                }
                return done ? finishLocked(.success(values)) : nil
            } catch {
                return finishLocked(.failure(error))
            }
        }
        deliver(resolution)
    }

    func cancel() {
        let resolution = lock.withLock { finishLocked(.failure(CancellationError())) }
        deliver(resolution)
    }

    /// Called only under lock. A cancellation before start is remembered even without a waiter.
    private func finishLocked(_ result: Result<[Element], Error>) -> Resolution? {
        guard !finished else { return nil }
        finished = true
        let pending = continuation
        let active = query
        continuation = nil
        query = nil
        values = []
        guard let pending else { return nil }
        return (active, pending, result)
    }

    private func deliver(_ resolution: Resolution?) {
        guard let (query, continuation, result) = resolution else { return }
        if let query { store.stop(query) }
        continuation.resume(with: result)
    }
}
#endif
