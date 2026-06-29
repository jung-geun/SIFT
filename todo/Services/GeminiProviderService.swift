import Foundation

// MARK: - Shared schedule JSON contract

enum ScheduleLLMAdapter {
    static let systemPrompt = Prompts.Schedule.systemInstruction

    static func buildScheduleInput(
        todos: [Todo],
        persona: PersonaContext,
        events: [CalendarService.CalendarEventSummary]
    ) -> String {
        let memory = MemoryService.shared

        let availability: String
        if let hour = memory.productiveHour {
            let end = min(23, hour + 8)
            availability = String(format: "%02d:00-%02d:00", hour, end)
        } else {
            availability = "09:00-22:00"
        }

        let bioValue = persona.types.isEmpty
            ? persona.description
            : persona.types.map { $0.displayName }.joined(separator: ", ")

        let personaDict: [String: Any] = [
            "occupations": persona.types.map { $0.displayName },
            "detailed_status": persona.description,
            "bio": bioValue,
            "availability": availability
        ]

        let tasks: [[String: Any]] = todos.enumerated().map { index, todo in
            let source: String
            switch todo.todoSource {
            case .manual:
                source = "memo_app"
            case .email:
                source = "email"
            case .calendar:
                source = "calendar"
            }
            return [
                "task_id": "T\(index + 1)",
                "title": todo.title,
                "memo": todo.notes,
                "source": source,
                "deadline": todo.dueDate.map { AppDateFormat.llmString(from: $0) } as Any,
                "estimated_duration_minutes": todo.estimatedDurationMinutes
            ]
        }

        let input: [String: Any] = [
            "current_time": AppDateFormat.llmString(from: Date()),
            "user_persona": personaDict,
            "tasks": tasks,
            "calendar_events": events.map { [
                "title": $0.title,
                "start_time": AppDateFormat.llmString(from: $0.startDate),
                "end_time": AppDateFormat.llmString(from: $0.endDate)
            ] }
        ]
        let data = (try? JSONSerialization.data(withJSONObject: input, options: .prettyPrinted)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func parseScheduleResponseV9(
        text: String,
        todos: [Todo],
        persona: PersonaContext,
        engine: PriorityEngine
    ) -> [PriorityResult]? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.range(of: "{"),
              let last = trimmed.range(of: "}", options: .backwards)
        else {
            return nil
        }
        trimmed = String(trimmed[first.lowerBound..<last.upperBound])

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scheduledTasks = json["scheduled_tasks"] as? [[String: Any]]
        else {
            return nil
        }

        let weights = ScheduleWeights.adaptive()
        let tokenToTodoID = Dictionary(
            uniqueKeysWithValues: todos.enumerated().map { ("T\($0.offset + 1)", $0.element.id) }
        )
        var results: [PriorityResult] = []

        for taskDict in scheduledTasks {
            guard let taskID = taskDict["task_id"] as? String else {
                continue
            }
            guard let todoID = tokenToTodoID[taskID] ?? UUID(uuidString: taskID) else {
                continue
            }

            let scoring = taskDict["scoring"] as? [String: Any] ?? [:]
            let axes = AxisScores(
                deadlineProximity: max(0, min(10, (scoring["deadline_proximity"] as? Double) ?? 2.0)),
                urgency: max(0, min(10, (scoring["urgency"] as? Double) ?? 5.0)),
                importance: max(0, min(10, (scoring["task_importance"] as? Double) ?? 5.0)),
                chaining: max(0, min(10, (scoring["task_chaining"] as? Double) ?? 2.0))
            )
            let score = ScheduleScorer.normalizedScore(axes, weights: weights)

            let reasoning = taskDict["reasoning"] as? [String: Any] ?? [:]
            let summary = reasoning["summary"] as? String ?? ""
            let chainingDetail = reasoning["chaining_detail"] as? String ?? ""

            var recommendedTime: Date? = nil
            if let schedule = taskDict["recommended_schedule"] as? [String: Any],
               let startISO = schedule["start_time"] as? String,
               !startISO.isEmpty {
                recommendedTime = AppDateFormat.parseLLMDate(startISO)
            }

            let personaKeywords = persona.weightedKeywords
            let personaFit: Bool
            if let todo = todos.first(where: { $0.id == todoID }) {
                personaFit = !personaKeywords.isEmpty && (
                    todo.tags.contains(where: { personaKeywords.contains($0) }) ||
                    personaKeywords.contains(where: { todo.title.localizedCaseInsensitiveContains($0) })
                )
            } else {
                personaFit = false
            }

            results.append(PriorityResult(
                todoID: todoID,
                score: score,
                reason: String(summary.prefix(80)),
                detail: summary,
                needsNotification: axes.deadlineProximity >= 7.0 || axes.urgency >= 7.0,
                recommendedTime: recommendedTime,
                personaFit: personaFit,
                engine: engine,
                axes: axes,
                chainingDetail: chainingDetail
            ))
        }

        return results.isEmpty ? nil : results
    }
}

// MARK: - Gemini provider service

struct GeminiProviderService: Sendable {
    static let keychainService = "pieroot.todo.gemini"
    static let apiKeyAccount = "api_key"
    static let defaultModelID = "gemini-2.0-flash"

    var session: URLSession = .shared

    static var storedAPIKey: String? {
        guard let raw = KeychainStore.get(service: keychainService, account: apiKeyAccount) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteAPIKey()
            return
        }
        KeychainStore.set(service: keychainService, account: apiKeyAccount, value: trimmed)
    }

    static func deleteAPIKey() {
        KeychainStore.deleteAny(service: keychainService, account: apiKeyAccount)
    }

    static var storedModelID: String {
        let raw = UserDefaults.standard.string(forKey: "pieroot.todo.geminiModelID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultModelID : raw
    }

    func generateJSON(systemInstruction: String, userPrompt: String, modelID: String) async throws -> String {
        guard let apiKey = Self.storedAPIKey else {
            throw IntelligenceRoutingError.backendNotConfigured(
                provider: .gemini,
                reason: "Gemini API key is missing"
            )
        }

        let chosenModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultModelID
            : modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(chosenModelID):generateContent") else {
            throw IntelligenceRoutingError.generationFailed(
                provider: .gemini,
                reason: "Gemini URL 구성이 잘못되었습니다."
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "systemInstruction": [
                "parts": [["text": systemInstruction]]
            ],
            "contents": [[
                "role": "user",
                "parts": [["text": userPrompt]]
            ]],
            "generationConfig": [
                "temperature": 0.1,
                "responseMimeType": "application/json"
            ]
        ])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw IntelligenceRoutingError.generationFailed(
                    provider: .gemini,
                    reason: "Gemini 응답이 HTTP가 아닙니다."
                )
            }

            guard (200...299).contains(http.statusCode) else {
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                let snippet = String(rawBody.prefix(200))
                let reason: String
                switch http.statusCode {
                case 401, 403:
                    reason = "HTTP 401/403"
                case 429:
                    reason = "HTTP 429"
                default:
                    reason = snippet.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(snippet)"
                }
                throw IntelligenceRoutingError.generationFailed(provider: .gemini, reason: reason)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let candidate = candidates.first,
                  let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IntelligenceRoutingError.parseFailed(
                    provider: .gemini,
                    reason: "Gemini 응답에 JSON 텍스트가 없습니다."
                )
            }
            return text
        } catch let routingError as IntelligenceRoutingError {
            throw routingError
        } catch {
            throw IntelligenceRoutingError.generationFailed(
                provider: .gemini,
                reason: error.localizedDescription
            )
        }
    }
}

// MARK: - Gemini priority engine

final class GeminiIntelligenceEngine: IntelligenceService {
    private let providerService: GeminiProviderService
    private let heuristic = HeuristicEngine()

    init(providerService: GeminiProviderService = GeminiProviderService()) {
        self.providerService = providerService
    }

    func prioritize(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        progress: IntelligenceProgressHandler?
    ) async throws -> [PriorityResult] {
        let active = todos
            .filter { !$0.isCompleted }
            .sorted {
                switch ($0.dueDate, $1.dueDate) {
                case (let lhs?, let rhs?):
                    if lhs != rhs { return lhs < rhs }
                    return $0.createdAt < $1.createdAt
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return $0.createdAt < $1.createdAt
                }
            }
        let capped = Array(active.prefix(20))
        guard !capped.isEmpty else { return [] }

        let modelID = GeminiProviderService.storedModelID
        var results: [PriorityResult] = []
        results.reserveCapacity(capped.count)

        for (offset, todo) in capped.enumerated() {
            let title = todo.title.isEmpty ? "(제목 없음)" : todo.title
            let index = offset + 1
            progress?(.requesting(
                index: index,
                total: capped.count,
                title: title,
                provider: PriorityEngine.gemini.rawValue
            ))
            do {
                let text = try await providerService.generateJSON(
                    systemInstruction: ScheduleLLMAdapter.systemPrompt,
                    userPrompt: ScheduleLLMAdapter.buildScheduleInput(todos: [todo], persona: persona, events: events),
                    modelID: modelID
                )
                progress?(.received(
                    index: index,
                    total: capped.count,
                    title: title,
                    provider: PriorityEngine.gemini.rawValue
                ))
                guard let parsed = ScheduleLLMAdapter.parseScheduleResponseV9(
                    text: text,
                    todos: [todo],
                    persona: persona,
                    engine: .gemini
                ), var first = parsed.first else {
                    throw IntelligenceRoutingError.parseFailed(
                        provider: .gemini,
                        reason: "Gemini 응답을 우선순위 JSON으로 해석하지 못했습니다."
                    )
                }
                first.requestedProviderRawValue = PersonaAIProvider.gemini.rawValue
                progress?(.applying(index: index, total: capped.count, title: title))
                progress?(.result(first, index: index, total: capped.count, title: title))
                results.append(first)
            } catch let routingError as IntelligenceRoutingError {
                switch routingError {
                case .backendNotConfigured:
                    throw routingError
                default:
                    progress?(.fallback(
                        from: PriorityEngine.gemini.rawValue,
                        to: PriorityEngine.heuristic.rawValue,
                        reason: routingError.localizedDescription
                    ))
                    let fallback = try await heuristic.prioritize(todos: [todo], events: events, persona: persona, progress: nil)
                    if var first = fallback.first {
                        first.requestedProviderRawValue = PersonaAIProvider.gemini.rawValue
                        first.fallbackReason = routingError.localizedDescription
                        progress?(.applying(index: index, total: capped.count, title: title))
                        progress?(.result(first, index: index, total: capped.count, title: title))
                        results.append(first)
                    }
                }
            } catch {
                progress?(.fallback(
                    from: PriorityEngine.gemini.rawValue,
                    to: PriorityEngine.heuristic.rawValue,
                    reason: error.localizedDescription
                ))
                let fallback = try await heuristic.prioritize(todos: [todo], events: events, persona: persona, progress: nil)
                if var first = fallback.first {
                    first.requestedProviderRawValue = PersonaAIProvider.gemini.rawValue
                    first.fallbackReason = error.localizedDescription
                    progress?(.applying(index: index, total: capped.count, title: title))
                    progress?(.result(first, index: index, total: capped.count, title: title))
                    results.append(first)
                }
            }
        }

        return results
    }
}
