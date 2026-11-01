import Foundation
import CryptoKit

enum MeetingSummaryFormat: String, Codable, CaseIterable, Sendable {
    case minutes, interview, clientMeeting, brief, custom

    func displayName(language: AppLanguage = .current) -> String {
        let fallback: String
        switch self {
        case .minutes: fallback = "Meeting minutes"
        case .interview: fallback = "Interview"
        case .clientMeeting: fallback = "Client meeting"
        case .brief: fallback = "Brief summary"
        case .custom: fallback = "Custom"
        }
        return AppLanguage.localized("meeting.summary.format.\(rawValue)", defaultValue: fallback,
                                     language: language, comment: "Meeting summary format")
    }

    var analysisGuidance: String {
        switch self {
        case .minutes: return "Organize minutes into summary, topics, decisions, actions, and openQuestions, only where supported."
        case .interview: return "Organize interview notes into overview, questionsAndAnswers, insights, and followUps, only where supported."
        case .clientMeeting: return "Organize client notes into overview, requirements, decisions, actions, and openQuestions, only where supported."
        case .brief: return "Use a concise keyPoints section with only the most important supported facts."
        case .custom: return "Use the user's requested organization where compatible with evidence and safety requirements."
        }
    }
}

struct MeetingSummaryCitation: nonisolated Codable, Hashable, Sendable {
    var trackID: String
    var segmentID: String
    var transcriptRevision: Int
}

struct MeetingSummaryItem: nonisolated Codable, Hashable, Sendable, Identifiable {
    var id: String
    var text: String
    var citations: [MeetingSummaryCitation]
    var isTask: Bool? = nil
}

struct MeetingSummarySection: nonisolated Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var items: [MeetingSummaryItem]
}

struct ProviderMeetingSummaryItem: nonisolated Codable, Hashable, Sendable {
    var text: String
    var sourceSegmentIDs: [String]
    var isTask: Bool? = nil
}

struct ProviderMeetingSummarySection: nonisolated Codable, Hashable, Sendable {
    var id: String
    var title: String
    var items: [ProviderMeetingSummaryItem]
}

/// Classification belongs to the displayed sentence, never to overlapping evidence.
/// Older saved summaries use only exact saved identity or explicit pending-work
/// language in their own text; no transcript/citation guessing or model requests.
enum MeetingSummaryTaskClassification {
    nonisolated static func isTask(_ item: MeetingSummaryItem, in section: MeetingSummarySection,
                                   result: MeetingResult) -> Bool {
        if let isTask = item.isTask { return isTask }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !matches(nonTaskStatus, text) else { return false }
        if ["actions", "followUps"].contains(section.id) { return true }
        let title = section.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if actionSectionTitles.contains(title) { return true }
        if result.actionDrafts.contains(where: { $0.title == item.text }) { return true }
        return matches(pendingWork, text)
    }

    private nonisolated static let actionSectionTitles: Set<String> = [
        "actions", "action items", "tasks", "follow-ups", "follow ups", "next steps",
        "할 일", "할일", "작업", "실행 항목", "액션 아이템", "후속 조치", "후속 작업",
        "タスク", "アクションアイテム", "対応事項", "次のステップ", "フォローアップ",
        "待办事项", "行动项", "后续行动", "后续事项", "下一步",
        "tareas", "acciones", "próximos pasos", "seguimiento",
        "tâches", "actions à réaliser", "prochaines étapes", "suivi",
        "attività da svolgere", "azioni", "prossimi passi", "attività successive",
        "aufgaben", "aktionspunkte", "nächste schritte", "folgemaßnahmen"
    ]

    // Narrow summary-language cues, not a natural-language understanding substitute.
    // A completed/negated/history sentence must not become a task because its
    // section says Actions or it happens to match an old draft title.
    private nonisolated static let nonTaskStatus = try! NSRegularExpression(pattern:
        #"(?i)((?<!미)완료(?!되지|하지)|취소|철회|불필요|필요\s*없|필요하지\s*않|불명확하지\s*않|하지\s*않기로|(?:검토|공유|작성|제출|저장|구현|정리|통합)했|보냈|이미\s*.*(?:전달|공유|제출|처리)|과거에|이전에|당시|(?<!not )(?<!not yet )\bcompleted\b|\b(?:cancelled|canceled|delivered|already sent|no longer|no need|not required|previously|formerly|will not|won't|must not|shall not|do not|don't|not a task|not unclear|no unresolved)\b|完了|取り消|不要|過去|已完成|已取消|无需|不需要|completad[oa]s?|cancelad[oa]s?|no es necesario|terminé[e]?s?|annulé[e]?s?|pas nécessaire|completat[oaie]|annullat[oaie]|non necessario|abgeschlossen|erledigt|storniert|nicht erforderlich)"#)
    private nonisolated static let pendingWork = try! NSRegularExpression(pattern:
        #"(?i)(불명확|미해결|미완료|완료되지|추가\s*.*필요|(?:기술|최종|향후|개발|구현)\s*목표|해야\s*(?:한|할|함|합|하|해|될|된다)|하기로\s*(?:했|합|함)|할\s*예정|\b(?:needs? to|must|shall|please|to do|pending|unresolved|unclear|next step|technical goal|implementation goal|future goal|not yet completed)\b|\bwill\s+(?:send|prepare|write|review|implement|integrate|resolve|clarify|deliver|follow up)\b|未解決|未対応|不明確|必要がある|する予定|技術目標|待解决|尚未|不明确|需要|计划|技术目标|pendiente|sin resolver|debe|próximo objetivo|à faire|non résolu|doit|objectif technique|da fare|irrisolt|deve|obiettivo tecnico|ausstehend|ungeklärt|muss|technisches ziel)"#)

    private nonisolated static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// Provider-independent coverage and evidence rules. A long segment is split at
/// Character boundaries without changing its source identity or dropping text.
enum MeetingSummaryEvidence {
    enum Failure: Error { case instructionsTooLong }
    nonisolated static func chunks(_ segments: [MeetingSegment], characterBudget: Int) -> [[MeetingSegment]] {
        let budget = max(64, characterBudget)
        var chunks: [[MeetingSegment]] = []
        var current: [MeetingSegment] = []
        var used = 0
        for segment in segments {
            var start = segment.text.startIndex
            repeat {
                var end = start
                var textCost = 0
                while end < segment.text.endIndex {
                    let character = segment.text[end]
                    let cost = character.unicodeScalars.reduce(0) { total, scalar in
                        switch scalar.value {
                        case 0...31, 60: return total + 6
                        case 34, 47, 92: return total + 2
                        case 0...127: return total + 1
                        case 128...2047: return total + 2
                        case 2048...65535: return total + 3
                        default: return total + 4
                        }
                    }
                    // A single extended grapheme can exceed the budget. Keep
                    // it intact rather than dropping or corrupting source text.
                    if textCost + cost > budget - 48, end > start { break }
                    textCost += cost
                    end = segment.text.index(after: end)
                }
                var piece = segment
                piece.text = String(segment.text[start..<end])
                let cost = textCost + 48
                if !current.isEmpty, used + cost > budget {
                    chunks.append(current)
                    current = []
                    used = 0
                }
                current.append(piece)
                used += cost
                start = end
            } while start < segment.text.endIndex
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    nonisolated static func sourceFingerprint(_ result: MeetingResult) -> String {
        struct Source: Encodable { let revision: Int; let segments: [MeetingSegment] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Source(revision: result.transcriptRevision, segments: result.segments))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func validatedItems(
        _ items: [(text: String, numbers: [Int], isTask: Bool?)], included: [MeetingSegment]
    ) -> [ProviderMeetingSummaryItem] {
        items.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !item.numbers.isEmpty,
                  item.numbers.allSatisfy({ $0 > 0 && $0 <= included.count }) else { return nil }
            var seen = Set<String>()
            return ProviderMeetingSummaryItem(text: text,
                sourceSegmentIDs: item.numbers.map { included[$0 - 1].id }.filter { seen.insert($0).inserted },
                isTask: item.isTask)
        }
    }

    /// Aggregate all chunk output, retaining every validated item and its exact
    /// evidence rather than asking a final limited-context call to lose the tail.
    nonisolated static func aggregate(_ extractions: [ProviderMeetingExtraction]) -> ProviderMeetingExtraction {
        var sections: [ProviderMeetingSummarySection] = []
        for extraction in extractions {
            for section in extraction.summarySections ?? [] {
                if let index = sections.firstIndex(where: { $0.id == section.id }) {
                    for item in section.items where !sections[index].items.contains(item) {
                        sections[index].items.append(item)
                    }
                } else { sections.append(section) }
            }
        }
        return ProviderMeetingExtraction(
            title: extractions.first(where: { !$0.title.isEmpty })?.title ?? "",
            summary: sections.flatMap(\.items).map(\.text).joined(separator: "\n"),
            decisions: extractions.flatMap(\.decisions),
            unresolvedQuestions: extractions.flatMap(\.unresolvedQuestions),
            actionDrafts: extractions.flatMap(\.actionDrafts), summarySections: sections)
    }

    /// Reduce bounded groups of extracted facts hierarchically. Every synthesis
    /// reference resolves through input-note IDs to the original transcript IDs.
    @MainActor
    static func synthesize(_ extractions: [ProviderMeetingExtraction], budget: Int,
        generate: ([MeetingSegment], Bool) async throws -> ProviderMeetingExtraction
    ) async throws -> ProviderMeetingExtraction {
        guard extractions.count > 1 else { return aggregate(extractions) }
        let firstPass = aggregate(extractions)
        // Chunk-local proposals are not tasks until reconciled against the whole meeting.
        var fallback = firstPass
        fallback.actionDrafts = []
        var current = firstPass
        for _ in 0..<12 {
            let sections = current.summarySections ?? []
            var sources: [String: [String]] = [:]
            var originals: [String: (sectionID: String, title: String, item: ProviderMeetingSummaryItem)] = [:]
            var notes: [MeetingSegment] = []
            for section in sections {
                for item in section.items {
                    let id = "note-\(notes.count)"
                    originals[id] = (section.id, section.title, item)
                    sources[id] = item.sourceSegmentIDs
                    notes.append(MeetingSegment(id: id, startMs: Int64(notes.count),
                        endMs: Int64(notes.count + 1), text: "[\(section.id)] \(item.text)"))
                }
            }
            // Carry proposed work even when the selected summary format omitted
            // an actions section. It remains evidence, not an accepted task.
            for action in current.actionDrafts {
                let id = "note-\(notes.count)"
                sources[id] = action.sourceSegmentIDs
                notes.append(MeetingSegment(id: id, startMs: Int64(notes.count),
                    endMs: Int64(notes.count + 1), text: "[proposedAction] \(action.title)\n\(action.notes)"))
            }
            guard !notes.isEmpty else { return fallback }
            let batches = chunks(notes, characterBudget: budget)
            var combined: [ProviderMeetingExtraction] = []
            for batch in batches {
                try Task.checkCancellation()
                var output: ProviderMeetingExtraction
                do {
                    output = try await generate(batch, true)
                    try Task.checkCancellation()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    // Refinement is optional: already-generated cited facts
                    // remain truthful even when combining cannot run.
                    return fallback
                }
                output.actionDrafts = output.actionDrafts.compactMap { action in
                    guard !action.sourceSegmentIDs.isEmpty,
                          action.sourceSegmentIDs.allSatisfy({ sources[$0] != nil }) else { return nil }
                    var action = action
                    var seen = Set<String>()
                    action.sourceSegmentIDs = action.sourceSegmentIDs.flatMap { sources[$0] ?? [] }
                        .filter { seen.insert($0).inserted }
                    return action.sourceSegmentIDs.isEmpty ? nil : action
                }
                output.summarySections = (output.summarySections ?? []).compactMap { section in
                    let items = section.items.compactMap { item -> ProviderMeetingSummaryItem? in
                        guard !item.sourceSegmentIDs.isEmpty,
                              item.sourceSegmentIDs.allSatisfy({ sources[$0] != nil }) else { return nil }
                        var seen = Set<String>()
                        let evidence = item.sourceSegmentIDs.flatMap { sources[$0] ?? [] }.filter { seen.insert($0).inserted }
                        return ProviderMeetingSummaryItem(text: item.text, sourceSegmentIDs: evidence, isTask: item.isTask)
                    }
                    guard !items.isEmpty else { return nil }
                    return ProviderMeetingSummarySection(id: section.id, title: section.title, items: items)
                }
                if output.summarySections?.isEmpty != false {
                    output = aggregate(batch.compactMap { note in
                        guard let original = originals[note.id] else { return nil }
                        return ProviderMeetingExtraction(title: current.title, summary: "", decisions: [],
                            unresolvedQuestions: [], actionDrafts: [], summarySections: [
                                ProviderMeetingSummarySection(id: original.sectionID, title: original.title, items: [original.item])])
                    })
                }
                combined.append(output)
            }
            let next = aggregate(combined)
            if batches.count == 1 { return next }
            // Do not loop forever if the provider copies notes rather than
            // consolidating them. No false claim that a prefix is the meeting.
            let nextItems = (next.summarySections?.reduce(0) { $0 + $1.items.count } ?? 0) + next.actionDrafts.count
            let previousBytes = notes.reduce(0) { $0 + $1.text.utf8.count + 48 }
            let nextBytes = (next.summarySections ?? []).reduce(0) { total, section in
                total + section.items.reduce(0) { $0 + $1.text.utf8.count + section.id.utf8.count + 51 }
            } + next.actionDrafts.reduce(0) { $0 + $1.title.utf8.count + $1.notes.utf8.count + 68 }
            guard nextItems < notes.count || nextBytes < previousBytes else { return fallback }
            current = next
        }
        return fallback
    }
}
