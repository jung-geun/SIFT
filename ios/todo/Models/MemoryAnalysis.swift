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
}

nonisolated enum BehaviorTrend: String, Codable, Sendable {
    case unavailable
    case stable
    case increasing
    case decreasing
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
    static let currentVersion = 2

    let version: Int
    let windowStart: Date
    let windowEnd: Date
    let sampleCount: Int
    let effectiveSampleSize: Double
    let confidence: BehaviorConfidence
    let insights: [BehaviorInsight]

    static func empty(at date: Date = Date()) -> Self {
        BehaviorProfile(
            version: currentVersion,
            windowStart: date,
            windowEnd: date,
            sampleCount: 0,
            effectiveSampleSize: 0,
            confidence: .insufficient,
            insights: []
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
                    insights: []
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
