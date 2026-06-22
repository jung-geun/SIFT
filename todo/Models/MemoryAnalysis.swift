import Foundation
import SwiftData

@Model
final class MemoryAnalysis {
    var id: UUID = UUID()
    var summary: String = ""
    var insights: [String] = []
    var fastTags: [String] = []
    var overdueRate: Double = 0.0
    var productiveHour: Int?
    var createdAt: Date = Date()
    
    init(summary: String, insights: [String], fastTags: [String], overdueRate: Double, productiveHour: Int? = nil) {
        self.summary = summary
        self.insights = insights
        self.fastTags = fastTags
        self.overdueRate = overdueRate
        self.productiveHour = productiveHour
    }
}
