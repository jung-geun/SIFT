import Foundation

// MARK: - Shared schedule JSON contract

enum ScheduleLLMAdapter {
    static func systemPrompt(language: AppLanguage = .current) -> String {
        Prompts.Schedule.systemInstruction(language: language)
    }

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

        let eligibleTodos = todos.filter { $0.triage == .todo }
        let tasks: [[String: Any]] = eligibleTodos.enumerated().map { index, todo in
            let source: String
            switch todo.todoSource {
            case .manual:
                source = "memo_app"
            case .email:
                source = "email"
            case .calendar:
                source = "calendar"
            case .meeting:
                source = "meeting"
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
        engine: PriorityEngine,
        language: AppLanguage = .current
    ) -> [PriorityResult]? {
        let scheduledTasks = scheduledTaskDictionaries(from: text)
        guard !scheduledTasks.isEmpty else { return nil }

        let weights = ScheduleWeights.adaptive()
        let tokenToTodoID = Dictionary(
            uniqueKeysWithValues: todos.enumerated().map { ("T\($0.offset + 1)", $0.element.id) }
        )
        var results: [PriorityResult] = []
        var seenTodoIDs = Set<UUID>()

        for taskDict in scheduledTasks {
            guard let taskID = taskDict["task_id"] as? String else {
                continue
            }
            guard let todoID = tokenToTodoID[taskID] ?? UUID(uuidString: taskID) else {
                continue
            }
            guard seenTodoIDs.insert(todoID).inserted else {
                continue
            }

            let scoring = taskDict["scoring"] as? [String: Any] ?? [:]
            let axes = AxisScores(
                deadlineProximity: scoreValue(scoring["deadline_proximity"], defaultValue: 2.0),
                urgency: scoreValue(scoring["urgency"], defaultValue: 5.0),
                importance: scoreValue(scoring["task_importance"], defaultValue: 5.0),
                chaining: scoreValue(scoring["task_chaining"], defaultValue: 2.0)
            )
            let score = ScheduleScorer.normalizedScore(axes, weights: weights)

            let reasoning = taskDict["reasoning"] as? [String: Any] ?? [:]
            let summary = (reasoning["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let chainingDetail = (reasoning["chaining_detail"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackReason = todos.first(where: { $0.id == todoID })?.dueDate == nil
                ? AppLanguage.localized(
                    "priority.reason.modelScore",
                    defaultValue: language == .english ? "Sorted by model scores" : "모델 점수 기반 정렬",
                    language: language,
                    comment: "Priority reason shown when no model explanation is available and no deadline exists."
                )
                : AppLanguage.localized(
                    "priority.reason.deadlineImportance",
                    defaultValue: language == .english ? "Sorted by deadline and importance" : "마감과 중요도 기준 정렬",
                    language: language,
                    comment: "Priority reason shown when no model explanation is available and a deadline exists."
                )
            let reasonText = !summary.isEmpty ? summary : (!chainingDetail.isEmpty ? chainingDetail : fallbackReason)
            let detailText: String
            if !chainingDetail.isEmpty && chainingDetail != reasonText {
                detailText = String(chainingDetail.prefix(160))
            } else {
                detailText = ""
            }

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
                reason: String(reasonText.prefix(80)),
                detail: detailText,
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

    private static func scheduledTaskDictionaries(from text: String) -> [[String: Any]] {
        if let fullJSON = topLevelJSONObject(from: text),
           let data = fullJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scheduledTasks = json["scheduled_tasks"] as? [[String: Any]] {
            return scheduledTasks
        }

        return partialScheduledTaskDictionaries(from: text)
    }

    private static func topLevelJSONObject(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.range(of: "{"),
              let last = trimmed.range(of: "}", options: .backwards),
              first.lowerBound <= last.lowerBound else {
            return nil
        }
        return String(trimmed[first.lowerBound..<last.upperBound])
    }

    private static func partialScheduledTaskDictionaries(from text: String) -> [[String: Any]] {
        guard let keyRange = text.range(of: "\"scheduled_tasks\""),
              let arrayStart = text[keyRange.upperBound...].firstIndex(of: "[") else {
            return []
        }

        var tasks: [[String: Any]] = []
        var objectStart: String.Index?
        var depth = 0
        var inString = false
        var isEscaped = false
        var index = text.index(after: arrayStart)

        while index < text.endIndex {
            let char = text[index]
            if inString {
                if isEscaped {
                    isEscaped = false
                } else if char == "\\" {
                    isEscaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    if depth == 0 { objectStart = index }
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0, let startIndex = objectStart {
                        let objectText = String(text[startIndex...index])
                        if let data = objectText.data(using: .utf8),
                           let task = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            tasks.append(task)
                        }
                        objectStart = nil
                    }
                } else if char == "]", depth == 0 {
                    break
                }
            }
            index = text.index(after: index)
        }

        return tasks
    }

    private static func scoreValue(_ value: Any?, defaultValue: Double) -> Double {
        let number: Double
        if let value = value as? Double {
            number = value
        } else if let value = value as? Int {
            number = Double(value)
        } else if let value = value as? NSNumber {
            number = value.doubleValue
        } else {
            number = defaultValue
        }
        return max(0, min(10, number))
    }
}

// MARK: - Gemini provider service

struct GeminiProviderService: Sendable {
    nonisolated static let keychainService = "pieroot.todo.gemini"
    nonisolated static let apiKeyAccount = "api_key"
    static let defaultModelID = "gemini-2.0-flash"

    private let transport: any GeminiHTTPTransport

    init(session: URLSession = .shared) {
        self.transport = URLSessionGeminiHTTPTransport(session: session)
    }

    init(transport: any GeminiHTTPTransport) {
        self.transport = transport
    }

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

    func rankTodos(
        todos: [Todo],
        events: [CalendarService.CalendarEventSummary],
        persona: PersonaContext,
        language: AppLanguage = .current
    ) async throws -> [PriorityResult] {
        let (apiKey, modelID) = try preflight()
        _ = apiKey
        let prompt = ScheduleLLMAdapter.buildScheduleInput(todos: todos, persona: persona, events: events)
        let raw = try await generateJSON(
            systemInstruction: ScheduleLLMAdapter.systemPrompt(language: language),
            userPrompt: prompt,
            modelID: modelID
        )
        guard let results = ScheduleLLMAdapter.parseScheduleResponseV9(
            text: raw,
            todos: todos,
            persona: persona,
            engine: .gemini,
            language: language
        ) else {
            throw IntelligenceRoutingError.parseFailed(
                provider: .gemini,
                reason: "Gemini 응답을 우선순위 JSON으로 해석하지 못했습니다."
            )
        }
        return results
    }

    func analyzeEmail(
        _ msg: GmailMessage,
        now: Date,
        language: AppLanguage = .current
    ) async throws -> EmailExtraction? {
        let (_, modelID) = try preflight(requireEmailConsent: true)
        guard !msg.subject.isEmpty else { return nil }
        let instructions = language == .english
            ? "Extract an explicit future email deadline. Return JSON with dueDateISO, isAllDay, sender, senderEmail, keywordScore, deadlineSentence, notes. Return an empty dueDateISO when no explicit deadline exists."
            : "메일에 명시된 미래 마감일을 추출하세요. dueDateISO, isAllDay, sender, senderEmail, keywordScore, deadlineSentence, notes JSON만 반환하세요. 명시적 마감일이 없으면 dueDateISO를 빈 문자열로 반환하세요."
        let prompt = "현재 시각: \(AppDateFormat.llmString(from: now))\n발신자: \(msg.from)\n제목: \(msg.subject)\n본문:\n\(String(msg.body.prefix(8_000)))"
        let raw = try await generateJSON(
            systemInstruction: instructions,
            userPrompt: prompt,
            modelID: modelID
        )
        return Self.parseEmailExtraction(raw, message: msg, now: now, language: language)
    }

    func summarizeEmail(
        subject: String,
        body: String,
        language: AppLanguage = .current
    ) async throws -> EmailSummaryResult {
        let (_, modelID) = try preflight(requireEmailConsent: true)
        let instructions = language == .english
            ? "Summarize this email. Return JSON with summary, keyPoints, and actionItems."
            : "이메일을 요약하세요. summary, keyPoints, actionItems 키를 가진 JSON만 반환하세요."
        let prompt = "제목: \(subject)\n본문:\n\(String(body.prefix(8_000)))"
        let raw = try await generateJSON(
            systemInstruction: instructions,
            userPrompt: prompt,
            modelID: modelID
        )
        guard let result = Self.parseSummary(raw) else {
            throw IntelligenceRoutingError.parseFailed(
                provider: .gemini,
                reason: "Gemini 이메일 요약 응답을 해석하지 못했습니다."
            )
        }
        return result
    }

    private static func parseEmailExtraction(
        _ raw: String,
        message: GmailMessage,
        now: Date,
        language: AppLanguage
    ) -> EmailExtraction? {
        guard let object = jsonDictionary(from: raw),
              let iso = object["dueDateISO"] as? String,
              !iso.isEmpty,
              let dueDate = AppDateFormat.parseMailDate(iso),
              dueDate > now else { return nil }
        let normalized = AppDateFormat.normalizedAllDayDeadline(
            dueDate,
            calendar: AppDateFormat.sourceCalendar(for: iso)
        )
        let sender = (object["sender"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? message.from
        let senderEmail = (object["senderEmail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sentence = (object["deadlineSentence"] as? String) ?? ""
        let notes = (object["notes"] as? String) ?? sentence
        return EmailExtraction(
            dueDate: normalized.date,
            isAllDay: (object["isAllDay"] as? Bool) == true || normalized.isAllDay,
            sender: sender,
            senderEmail: senderEmail,
            keywordScore: object["keywordScore"] as? Int ?? 1,
            deadlineSentence: sentence,
            notes: notes.isEmpty
                ? (language == .english ? "Detected by Gemini." : "Gemini가 감지한 마감일입니다.")
                : notes
        )
    }


    func analyzeMeeting(
        meetingID: String,
        result: MeetingResult,
        glossaryHint: String = "",
        language: AppLanguage
    ) async throws -> MeetingResult {
        let (apiKey, modelID) = try preflight()
        _ = apiKey
        let context = Self.meetingPromptContext(
            segments: result.segments,
            glossaryHint: glossaryHint,
            language: language
        )
        guard !context.included.isEmpty else { return result }
        let prompt = """
        \(context.glossaryBlock)[전사 구간]
        \(context.numbered.joined(separator: "\n"))

        \(Prompts.MeetingAnalysisLocal.requestSuffix(language: language))
        """
        let raw = try await generateJSON(
            systemInstruction: Prompts.MeetingAnalysisLocal.systemInstruction(language: language),
            userPrompt: prompt,
            modelID: modelID
        )
        guard let json = Self.jsonDictionary(from: raw) else {
            throw IntelligenceRoutingError.parseFailed(
                provider: .gemini,
                reason: "Gemini 회의 분석 응답을 해석하지 못했습니다."
            )
        }
        var updated = result
        updated.title = (json["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        updated.summary = (json["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        updated.decisions = (json["decisions"] as? [String] ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        updated.unresolvedQuestions = (json["unresolved_questions"] as? [String] ?? json["unresolvedQuestions"] as? [String] ?? [])
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var actions: [MeetingActionDraft] = []
        for item in (json["actions"] as? [[String: Any]] ?? []) {
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  let number = item["sourceSegmentNumber"] as? Int,
                  number > 0,
                  number <= context.included.count else { continue }
            let segment = context.included[number - 1]
            let due = (item["dueDateISO"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            actions.append(
                MeetingActionDraft(
                    title: title,
                    notes: (item["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    dueAtISO8601: due?.isEmpty == true ? nil : due,
                    sourceSegmentIDs: [segment.id],
                    confidence: 0.7,
                    requiresReview: true,
                    meetingID: meetingID
                )
            )
        }
        updated.actionDrafts = actions
        return updated
    }

    private func preflight(
        requireEmailConsent: Bool = false
    ) throws -> (apiKey: String, modelID: String) {
        guard BetaFeaturePolicy().authorizes(.gemini, for: .standardAnalysis) else {
            throw IntelligenceRoutingError.backendUnavailable(
                provider: .gemini,
                reason: RuleFallbackReason.providerDisabled.rawValue
            )
        }
        if requireEmailConsent,
           !SettingsStore.shared.get("pieroot.todo.providerEmailAnalysisEnabled", defaultValue: false) {
            throw IntelligenceRoutingError.backendNotConfigured(
                provider: .gemini,
                reason: RuleFallbackReason.consentMissing.rawValue
            )
        }
        guard let apiKey = Self.storedAPIKey else {
            throw IntelligenceRoutingError.backendNotConfigured(
                provider: .gemini,
                reason: "Gemini API key is missing"
            )
        }
        let modelID = Self.storedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw IntelligenceRoutingError.backendNotConfigured(
                provider: .gemini,
                reason: "Gemini model is missing"
            )
        }
        return (apiKey, modelID)
    }

    private func generateJSON(
        systemInstruction: String,
        userPrompt: String,
        modelID: String
    ) async throws -> String {
        guard let apiKey = Self.storedAPIKey else {
            throw IntelligenceRoutingError.backendNotConfigured(
                provider: .gemini,
                reason: "Gemini API key is missing"
            )
        }
        LLMDebugLogger.request(
            provider: "Gemini",
            operation: "generateJSON",
            metadata: ["modelID: \(modelID)", "responseMimeType: application/json"],
            systemPrompt: systemInstruction,
            userPrompt: userPrompt
        )
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelID):generateContent") else {
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
            "systemInstruction": ["parts": [["text": systemInstruction]]],
            "contents": [["role": "user", "parts": [["text": userPrompt]]]],
            "generationConfig": ["temperature": 0.1, "responseMimeType": "application/json"]
        ])

        do {
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw IntelligenceRoutingError.generationFailed(provider: .gemini, reason: "Gemini 응답이 HTTP가 아닙니다.")
            }
            guard (200...299).contains(http.statusCode) else {
                let rawBody = String(data: data, encoding: .utf8) ?? ""
                let snippet = String(rawBody.prefix(200))
                let reason = [401, 403].contains(http.statusCode)
                    ? "HTTP 401/403"
                    : (http.statusCode == 429 ? "HTTP 429" : (snippet.isEmpty ? "HTTP \(http.statusCode)" : "HTTP \(http.statusCode): \(snippet)"))
                throw IntelligenceRoutingError.generationFailed(provider: .gemini, reason: reason)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw IntelligenceRoutingError.parseFailed(provider: .gemini, reason: "Gemini 응답에 JSON 텍스트가 없습니다.")
            }
            LLMDebugLogger.response(provider: "Gemini", operation: "generateJSON", text: text)
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch let routingError as IntelligenceRoutingError {
            throw routingError
        } catch {
            throw IntelligenceRoutingError.generationFailed(provider: .gemini, reason: error.localizedDescription)
        }
    }

    private static func parseSummary(_ raw: String) -> EmailSummaryResult? {
        guard let json = jsonDictionary(from: raw) else { return nil }
        let summary = (json["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPoints = (json["keyPoints"] as? [String] ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let actionItems = (json["actionItems"] as? [String] ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !summary.isEmpty || !keyPoints.isEmpty || !actionItems.isEmpty else { return nil }
        return EmailSummaryResult(summary: summary, keyPoints: keyPoints, actionItems: actionItems)
    }

    private static func jsonDictionary(from raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"),
              let last = trimmed.lastIndex(of: "}"),
              first <= last else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(trimmed[first...last].utf8)) as? [String: Any]
    }

    private struct MeetingPromptContext {
        let numbered: [String]
        let included: [MeetingSegment]
        let glossaryBlock: String
    }

    private static func meetingPromptContext(
        segments: [MeetingSegment],
        glossaryHint: String,
        language: AppLanguage
    ) -> MeetingPromptContext {
        var numbered = [String]()
        var included = [MeetingSegment]()
        var used = 0
        for segment in segments {
            let line = "\(included.count + 1). \(segment.text)"
            if used + line.count > 6_000, !included.isEmpty { break }
            included.append(segment)
            numbered.append(line)
            used += line.count
        }
        let trimmedHint = glossaryHint.trimmingCharacters(in: .whitespacesAndNewlines)
        let glossaryBlock = trimmedHint.isEmpty ? "" : "[사용자 단어장]\n\(trimmedHint)\n\n"
        return MeetingPromptContext(numbered: numbered, included: included, glossaryBlock: glossaryBlock)
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

        let language = AppLanguage.current
        var results: [PriorityResult] = []
        results.reserveCapacity(capped.count)

        for (offset, todo) in capped.enumerated() {
            let title = todo.title.isEmpty
                ? AppLanguage.localized(
                    "todo.noTitle",
                    defaultValue: language == .english ? "(No Title)" : "(제목 없음)",
                    language: language,
                    comment: "Placeholder title shown for a to-do without a title."
                )
                : todo.title
            let index = offset + 1
            progress?(.requesting(
                index: index,
                total: capped.count,
                title: title,
                provider: PriorityEngine.gemini.rawValue
            ))
            do {
                guard var first = try await providerService.rankTodos(
                    todos: [todo],
                    events: events,
                    persona: persona,
                    language: language
                ).first else {
                    throw IntelligenceRoutingError.parseFailed(
                        provider: .gemini,
                        reason: "Gemini 응답을 우선순위 JSON으로 해석하지 못했습니다."
                    )
                }
                progress?(.received(
                    index: index,
                    total: capped.count,
                    title: title,
                    provider: PriorityEngine.gemini.rawValue
                ))
                first.requestedProviderRawValue = PersonaAIProvider.gemini.rawValue
                debugLogParsedResult(first, todo: todo, index: index, total: capped.count)
                progress?(.applying(index: index, total: capped.count, title: title))
                progress?(.result(first, index: index, total: capped.count, title: title))
                results.append(first)
            } catch is CancellationError {
                throw CancellationError()
            } catch let routingError as IntelligenceRoutingError {
                switch routingError {
                case .backendNotConfigured:
                    throw routingError
                default:
                    let fallbackReason = routingError.errorDescription(language: language)
                    progress?(.fallback(
                        from: PriorityEngine.gemini.rawValue,
                        to: PriorityEngine.heuristic.rawValue,
                        reason: fallbackReason
                    ))
                    let fallback = try await heuristic.prioritize(todos: [todo], events: events, persona: persona, progress: nil)
                    if var first = fallback.first {
                        first.requestedProviderRawValue = PersonaAIProvider.gemini.rawValue
                        first.fallbackReason = fallbackReason
                        debugLogParsedResult(first, todo: todo, index: index, total: capped.count)
                        progress?(.applying(index: index, total: capped.count, title: title))
                        progress?(.result(first, index: index, total: capped.count, title: title))
                        results.append(first)
                    }
                }
            } catch {
                let fallbackReason = userFacingFallbackReason(from: error, language: language)
                progress?(.fallback(
                    from: PriorityEngine.gemini.rawValue,
                    to: PriorityEngine.heuristic.rawValue,
                    reason: fallbackReason
                ))
                let fallback = try await heuristic.prioritize(todos: [todo], events: events, persona: persona, progress: nil)
                if var first = fallback.first {
                    first.requestedProviderRawValue = PersonaAIProvider.gemini.rawValue
                    first.fallbackReason = fallbackReason
                    debugLogParsedResult(first, todo: todo, index: index, total: capped.count)
                    progress?(.applying(index: index, total: capped.count, title: title))
                    progress?(.result(first, index: index, total: capped.count, title: title))
                    results.append(first)
                }
            }
        }

        return results
    }

    private func userFacingFallbackReason(from error: Error, language: AppLanguage) -> String {
        if let routingError = error as? IntelligenceRoutingError {
            return routingError.errorDescription(language: language)
        }
        return AppLanguage.localized(
            "intelligence.gemini.fallback",
            defaultValue: language == .english
                ? "Gemini could not complete the request, so heuristic prioritization was used."
                : "Gemini 요청을 완료하지 못해 휴리스틱 우선순위를 사용했습니다.",
            language: language,
            comment: "Fallback explanation shown when Gemini prioritization fails and heuristic prioritization is used."
        )
    }

    private func debugLogParsedResult(_ result: PriorityResult, todo: Todo, index: Int, total: Int) {
        let axes = result.axes.map {
            String(format: "deadline=%.1f urgency=%.1f importance=%.1f chaining=%.1f", $0.deadlineProximity, $0.urgency, $0.importance, $0.chaining)
        } ?? "none"
        let dueDate = todo.dueDate.map { AppDateFormat.llmString(from: $0) } ?? "nil"
        let recommended = result.recommendedTime.map { AppDateFormat.llmString(from: $0) } ?? "nil"
        LLMDebugLogger.event(
            provider: "Gemini",
            operation: "rankTodos",
            title: "ParsedResult \(index)/\(total)",
            details: "score=\(String(format: "%.3f", result.score)) task=\(todo.title.isEmpty ? "(제목 없음)" : todo.title) due=\(dueDate) axes=[\(axes)] notify=\(result.needsNotification) recommended=\(recommended) reason=\(result.reason) detail=\(result.detail.isEmpty ? "(empty)" : result.detail) fallback=\(result.fallbackReason.isEmpty ? "(none)" : result.fallbackReason)"
        )
    }
}
