import Foundation
import SwiftData

nonisolated enum BehaviorConfidence: String, Codable, CaseIterable, Sendable {
    case insufficient
    case low
    case medium
    case high

    nonisolated static func classify(effectiveSampleSize: Double) -> Self {
        switch effectiveSampleSize + 1e-9 {
        case ..<5: .insufficient
        case ..<20: .low
        case ..<50: .medium
        default: .high
        }
    }

    var label: String {
        label(language: .current)
    }

    func label(language: AppLanguage) -> String {
        switch self {
        case .insufficient: return language == .english ? "Insufficient data" : "데이터 부족"
        case .low: return language == .english ? "Low confidence" : "낮은 신뢰도"
        case .medium: return language == .english ? "Medium confidence" : "중간 신뢰도"
        case .high: return language == .english ? "High confidence" : "높은 신뢰도"
        }
    }

    var allowsPersonalization: Bool {
        self == .medium || self == .high
    }
}

nonisolated enum BehaviorMetric: String, Codable, Sendable {
    case completionConcentrationHour
    case currentCompletionShare
    case deletedCompletedShare
    case overdueCompletionRate
    case nearTermBacklog
    case deletedSnapshotCount
    case completionUndoRate
    case dueDateChangeRate
    case manualPriorityChangeRate
    case aiOverrideRate
    case completionTimeBucketConcentration
    case completionWeekdayConcentration
    case completionLatencyHours
    case dueDateAtCreationRate
    case dueDatePostponeRate
    case activeWithoutDueDateShare
}


nonisolated enum BehaviorDimension: String, Codable, Sendable {
    case completionTime, completionWeekday, deadlineAdherence, schedulingStyle
    case priorityControl, completionStability, backlog
}

nonisolated enum BehaviorLabel: String, Codable, Sendable {
    case morning, afternoon, evening, night, distributed
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday
    case deadlineConsistent, deadlinePressure, mixedDeadline
    case scheduleFirst, flexibleScheduling, frequentPostponement
    case manualPriorityPreference, completionRevisit, nearTermBacklogPressure
}

nonisolated struct BehaviorEvidence: Codable, Equatable, Sendable {
    let metricRawValue: String
    let value: Double
    let rawCount: Int
    let effectiveCount: Double
}

nonisolated struct BehaviorClassification: Codable, Equatable, Sendable {
    let dimension: BehaviorDimension
    let label: BehaviorLabel
    let confidence: BehaviorConfidence
    let evidence: [BehaviorEvidence]
}
nonisolated enum BehaviorTrend: String, Codable, Sendable {
    case unavailable
    case stable
    case increasing
    case decreasing
}

/// Immutable, content-free event input for behavior analysis.
nonisolated struct BehaviorEventSnapshot: Equatable, Sendable {
    let todoID: UUID
    let kind: TaskBehaviorEventType
    let timestamp: Date
    let actorRawValue: String
    let triageRawValue: String
    let todoCreatedAt: Date?
    let beforeCompletion: Bool?
    let afterCompletion: Bool?
    let beforeDueDate: Date?
    let afterDueDate: Date?
    let beforeManualPriority: Int?
    let afterManualPriority: Int?
}

/// Immutable, content-free Todo observation for behavior analysis.
nonisolated struct BehaviorTodoSnapshot: Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let completedAt: Date?
    let dueDate: Date?
    let isCompleted: Bool
    let triage: TodoTriage
    let tags: [String]
    let observationDate: Date
    let isDeleted: Bool
}

/// All ambient inputs required by the deterministic behavior analyzer.
nonisolated struct BehaviorAnalysisContext: Sendable {
    let now: Date
    let calendar: Calendar
    let events: [BehaviorEventSnapshot]
    let todos: [BehaviorTodoSnapshot]
    let behaviorProfile: BehaviorProfile
    let personaTypes: [PersonaType]

    init(
        now: Date,
        calendar: Calendar,
        events: [BehaviorEventSnapshot],
        todos: [BehaviorTodoSnapshot],
        behaviorProfile: BehaviorProfile = .empty(),
        personaTypes: [PersonaType] = []
    ) {
        self.now = now
        self.calendar = calendar
        self.events = events
        self.todos = todos
        self.behaviorProfile = behaviorProfile
        self.personaTypes = personaTypes
    }
}

nonisolated struct BehaviorInsight: Codable, Equatable, Identifiable, Sendable {
    let metric: BehaviorMetric
    let value: Double
    let numerator: Int
    let denominator: Int
    let effectiveSampleSize: Double
    let confidence: BehaviorConfidence
    let windowStart: Date
    let windowEnd: Date
    let previousValue: Double?
    let trend: BehaviorTrend
    let evidence: String

    var id: String { metric.rawValue }
}

nonisolated struct BehaviorProfile: Codable, Equatable, Sendable {
    static let currentVersion = 3

    let version: Int
    let windowStart: Date
    let windowEnd: Date
    let sampleCount: Int
    let effectiveSampleSize: Double
    let confidence: BehaviorConfidence
    let insights: [BehaviorInsight]
    let classifications: [BehaviorClassification]

    private enum CodingKeys: String, CodingKey {
        case version, windowStart, windowEnd, sampleCount, effectiveSampleSize
        case confidence, insights, classifications
    }

    private struct LossyClassification: Decodable {
        let value: BehaviorClassification?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let dimension = try? container.decode(BehaviorDimension.self, forKey: .dimension),
                  let label = try? container.decode(BehaviorLabel.self, forKey: .label),
                  let confidence = try? container.decode(BehaviorConfidence.self, forKey: .confidence),
                  let evidence = try? container.decode([BehaviorEvidence].self, forKey: .evidence)
            else {
                value = nil
                return
            }
            value = BehaviorClassification(
                dimension: dimension,
                label: label,
                confidence: confidence,
                evidence: evidence
            )
        }

        private enum CodingKeys: String, CodingKey {
            case dimension, label, confidence, evidence
        }
    }

    init(
        version: Int,
        windowStart: Date,
        windowEnd: Date,
        sampleCount: Int,
        effectiveSampleSize: Double,
        confidence: BehaviorConfidence,
        insights: [BehaviorInsight],
        classifications: [BehaviorClassification] = []
    ) {
        self.version = version
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.sampleCount = sampleCount
        self.effectiveSampleSize = effectiveSampleSize
        self.confidence = confidence
        self.insights = insights
        self.classifications = classifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        windowStart = try container.decode(Date.self, forKey: .windowStart)
        windowEnd = try container.decode(Date.self, forKey: .windowEnd)
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        effectiveSampleSize = try container.decode(Double.self, forKey: .effectiveSampleSize)
        confidence = try container.decode(BehaviorConfidence.self, forKey: .confidence)
        insights = try container.decode([BehaviorInsight].self, forKey: .insights)
        classifications = try container
            .decodeIfPresent([LossyClassification].self, forKey: .classifications)?
            .compactMap(\.value) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(windowStart, forKey: .windowStart)
        try container.encode(windowEnd, forKey: .windowEnd)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encode(effectiveSampleSize, forKey: .effectiveSampleSize)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(insights, forKey: .insights)
        try container.encode(classifications, forKey: .classifications)
    }

    static func empty(at date: Date = Date()) -> Self {
        BehaviorProfile(
            version: currentVersion,
            windowStart: date,
            windowEnd: date,
            sampleCount: 0,
            effectiveSampleSize: 0,
            confidence: .insufficient,
            insights: [],
            classifications: []
        )
    }

    func insight(for metric: BehaviorMetric) -> BehaviorInsight? {
        insights.first { $0.metric == metric }
    }
}

@Model
final class MemoryAnalysis {
    var id: UUID = UUID()
    var summary: String = ""
    var insights: [String] = []
    var fastTags: [String] = []
    var overdueRate: Double = 0.0
    /// Retained storage name for schema compatibility. Semantics are completion-record concentration.
    var productiveHour: Int?
    var recordTitle: String = ""
    var accessScopeSummary: String = ""
    var processorDescription: String = ""
    var createdAt: Date = Date()

    var analysisVersion: Int = BehaviorProfile.currentVersion
    var windowStart: Date?
    var windowEnd: Date?
    var sampleCount: Int = 0
    var effectiveSampleSize: Double = 0
    var confidenceRaw: String = BehaviorConfidence.insufficient.rawValue
    var behaviorProfileData: Data = Data()

    var confidence: BehaviorConfidence {
        BehaviorConfidence(rawValue: confidenceRaw) ?? .insufficient
    }

    var behaviorProfile: BehaviorProfile {
        get {
            guard !behaviorProfileData.isEmpty,
                  let profile = try? JSONDecoder().decode(BehaviorProfile.self, from: behaviorProfileData) else {
                return BehaviorProfile(
                    version: analysisVersion,
                    windowStart: windowStart ?? createdAt,
                    windowEnd: windowEnd ?? createdAt,
                    sampleCount: sampleCount,
                    effectiveSampleSize: effectiveSampleSize,
                    confidence: confidence,
                    insights: [],
                    classifications: []
                )
            }
            return profile
        }
        set {
            analysisVersion = newValue.version
            windowStart = newValue.windowStart
            windowEnd = newValue.windowEnd
            sampleCount = newValue.sampleCount
            effectiveSampleSize = newValue.effectiveSampleSize
            confidenceRaw = newValue.confidence.rawValue
            behaviorProfileData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    init(
        summary: String,
        insights: [String],
        fastTags: [String],
        overdueRate: Double,
        productiveHour: Int? = nil,
        recordTitle: String = "",
        accessScopeSummary: String = "",
        processorDescription: String = "",
        behaviorProfile: BehaviorProfile? = nil
    ) {
        self.summary = summary
        self.insights = insights
        self.fastTags = fastTags
        self.overdueRate = overdueRate
        self.productiveHour = productiveHour
        self.recordTitle = recordTitle
        self.accessScopeSummary = accessScopeSummary
        self.processorDescription = processorDescription
        if let behaviorProfile {
            self.behaviorProfile = behaviorProfile
        }
    }
}
