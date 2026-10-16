import Foundation

// MARK: - Shared schedule JSON contract

enum ScheduleLLMAdapter {
    static func systemPrompt(language: AppLanguage = .current) -> String {
        Prompts.Schedule.systemInstruction(language: language)
    }

    static func buildScheduleInput(
        todos: [Todo],
        persona: PersonaContext,
        events: [CalendarService.CalendarEventSummary],
        allowsPrivateCalendarTitles: Bool,
        usesBehaviorAvailability: Bool = true,
        includeCalendarTitles: Bool = true
    ) -> String {
        let memory = MemoryService.shared

        let availability: String
        if usesBehaviorAvailability, let hour = memory.productiveHour {
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

        let eligibleTodos = todos.lazy.filter(\.isEligibleForAutomaticPriority)
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
            "calendar_events": events.map { event in
                let isPrivate = event.marker.map {
                    $0.origin == .siftEmail || $0.origin == .siftMeeting || $0.origin == .siftRecommendation
                } ?? false
                return [
                    "title": !includeCalendarTitles || (!allowsPrivateCalendarTitles && isPrivate) ? "Busy" : event.title,
                    "start_time": AppDateFormat.llmString(from: event.startDate),
                    "end_time": AppDateFormat.llmString(from: event.endDate)
                ]
            }
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
        var tokenToTodoID: [String: UUID] = [:]
        var todosByID: [UUID: Todo] = [:]
        tokenToTodoID.reserveCapacity(todos.count)
        todosByID.reserveCapacity(todos.count)
        for todo in todos where todo.isEligibleForAutomaticPriority {
            tokenToTodoID["T\(tokenToTodoID.count + 1)"] = todo.id
            if todosByID[todo.id] == nil { todosByID[todo.id] = todo }
        }
        var results: [PriorityResult] = []
        var seenTodoIDs = Set<UUID>()

        for taskDict in scheduledTasks {
            guard let taskID = taskDict["task_id"] as? String else {
                continue
            }
            guard let todoID = tokenToTodoID[taskID] ?? UUID(uuidString: taskID),
                  let todo = todosByID[todoID] else {
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
            let fallbackReason = todo.dueDate == nil
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
            let personaFit = !personaKeywords.isEmpty && (
                todo.tags.contains(where: { personaKeywords.contains($0) }) ||
                personaKeywords.contains(where: { todo.title.localizedCaseInsensitiveContains($0) })
            )

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

