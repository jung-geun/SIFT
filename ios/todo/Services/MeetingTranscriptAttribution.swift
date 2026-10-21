import Foundation

/// A source-local, disposable projection. Nothing here is persisted or used to
/// join voice identities, including identities with the same display name.
nonisolated struct MeetingTranscriptAttribution: Equatable, Sendable {
    enum ActivityKind: String, Sendable {
        case completed, committed, requested
    }

    struct SpeakerName: Equatable, Sendable {
        let speakerID: String
        let name: String
        let aliases: [String]
        let sourceSegmentIDs: [String]
        let isManual: Bool
    }

    struct Activity: Identifiable, Equatable, Sendable {
        let id: String
        let personID: String
        let personName: String?
        let speakerID: String?
        let text: String
        let kind: ActivityKind
        let sourceSegmentIDs: [String]
    }

    let names: [SpeakerName]
    let activities: [Activity]
    private let activityIndices: [String: [Int]]
    private let sourceIDs: Set<String>

    init(meetingID: String, result: MeetingResult, profiles: [MeetingSpeakerProfile]) {
        let segments = result.segments.sorted { ($0.startMs, $0.endMs, $0.id) < ($1.startMs, $1.endMs, $1.id) }
        let blocked = Self.overlappingIDs(segments)
        var claims: [String: Claims] = [:]
        var parsed: [Parsed] = []
        let manual = profiles.reduce(into: [String: String]()) { output, profile in
            if let name = profile.displayName.map(Self.trim), !name.isEmpty, name != profile.id {
                output[profile.id] = name
            }
        }

        // Parse each segment once. Resolve references only after all introductions
        // have been read, so a later introduction can explain an earlier alias.
        for segment in segments {
            let speaker = segment.speakerIDs.count == 1 && !blocked.contains(segment.id)
                ? segment.speakerIDs[0] : nil
            let clauses = Self.clauses(in: segment.text)
            let quoted = Self.hasQuote(segment.text)
            var requests: [String] = []
            var actions: [ParsedAction] = []
            for clause in clauses where !quoted {
                if let speaker, !Self.matches(Pattern.question, clause), !Self.matches(Pattern.denial, clause) {
                    for name in Self.introductions(in: clause) where Self.validName(name) {
                        claims[speaker, default: Claims()].add(name, alias: false, evidence: [segment.id])
                    }
                    for alias in Self.captures(Pattern.alias, clause) where Self.validName(alias) {
                        claims[speaker, default: Claims()].add(alias, alias: true, evidence: [segment.id])
                    }
                }
                // Multi-speaker/overlapping speech cannot identify either the
                // person making a commitment or the person making a request.
                guard segment.speakerIDs.count <= 1, !blocked.contains(segment.id),
                      !Self.matches(Pattern.denial, clause) else { continue }
                if let request = Self.namedRequest(clause) {
                    requests.append(request)
                    actions.append(ParsedAction(text: clause, kind: .requested, actor: .named(request)))
                } else if !Self.matches(Pattern.question, clause), !Self.matches(Pattern.uncertain, clause) {
                    if let named = Self.namedStatement(clause) {
                        actions.append(ParsedAction(text: clause, kind: named.kind, actor: .named(named.name)))
                        if named.kind == .completed && Self.matches(Pattern.commitment, clause) {
                            actions.append(ParsedAction(text: clause, kind: .committed, actor: .named(named.name)))
                        }
                    } else if let speaker, Self.matches(Pattern.firstPerson, clause) {
                        if Self.matches(Pattern.commitment, clause) {
                            actions.append(ParsedAction(text: clause, kind: .committed, actor: .speaker(speaker)))
                        }
                        if Self.matches(Pattern.completed, clause) {
                            actions.append(ParsedAction(text: clause, kind: .completed, actor: .speaker(speaker)))
                        }
                    }
                }
            }
            parsed.append(Parsed(segment: segment, speaker: speaker, requests: requests, actions: actions))
        }

        // A vocative belongs to the listener, never the requesting speaker. A
        // clear adjacent acknowledgement is weaker evidence than self-ID.
        if parsed.count > 1 {
            let selfOwners = Self.owners(claims: claims, manual: manual)
            for index in 0..<(parsed.count - 1) {
                let request = parsed[index]
                let reply = parsed[index + 1]
                guard request.requests.count == 1,
                      let requester = request.speaker, let responder = reply.speaker,
                      requester != responder,
                      reply.segment.startMs >= request.segment.endMs,
                      reply.segment.startMs - request.segment.endMs <= 5_000,
                      Self.matches(Pattern.acknowledgement, reply.segment.text),
                      !Self.matches(Pattern.question, reply.segment.text),
                      !Self.matches(Pattern.denial, reply.segment.text),
                      !Self.hasQuote(reply.segment.text),
                      manual[responder] == nil,
                      claims[responder]?.primary.isEmpty ?? true,
                      claims[responder]?.aliases.isEmpty ?? true else { continue }
                let name = request.requests[0]
                let existing = selfOwners[Self.key(name)] ?? []
                guard existing.isEmpty || existing == [responder] else { continue }
                claims[responder, default: Claims()].addressed.append((name, [request.segment.id, reply.segment.id]))
            }
        }

        var resolvedNames: [SpeakerName] = []
        let speakerOrder = Array(Set(segments.flatMap(\.speakerIDs) + profiles.map(\.id))).sorted()
        for speaker in speakerOrder {
            let claim = claims[speaker] ?? Claims()
            let primary = Self.unique(claim.primary.map(\.0))
            let aliases = Self.unique(claim.aliases.map(\.0))
            let addressed = Self.unique(claim.addressed.map(\.0))
            let inferred: String?
            if primary.count == 1 { inferred = primary[0] }
            else if primary.isEmpty && aliases.count == 1 { inferred = aliases[0] }
            else if primary.isEmpty && aliases.isEmpty && addressed.count == 1 { inferred = addressed[0] }
            else { inferred = nil }
            guard let name = manual[speaker] ?? inferred else { continue }
            let acceptedAliases = primary.count <= 1 ? aliases.filter { Self.key($0) != Self.key(name) } : []
            let evidence = primary.count <= 1
                ? Self.uniqueIDs((claim.primary + claim.aliases + claim.addressed).flatMap(\.1)) : []
            resolvedNames.append(SpeakerName(speakerID: speaker, name: name, aliases: acceptedAliases,
                                             sourceSegmentIDs: evidence, isManual: manual[speaker] != nil))
        }
        names = resolvedNames
        let bySpeaker = Dictionary(uniqueKeysWithValues: resolvedNames.map { ($0.speakerID, $0) })
        var byName: [String: Set<String>] = [:]
        for name in resolvedNames {
            for spelling in [name.name] + name.aliases {
                byName[Self.key(spelling), default: []].insert(name.speakerID)
            }
        }
        // Conflicting self-identifications still reserve their spellings. They
        // must not accidentally become a supposedly unambiguous external actor.
        let claimedOwners = Self.owners(claims: claims, manual: manual)
        var built: [Activity] = []
        var indices: [String: [Int]] = [:]
        for item in parsed {
            for (offset, action) in item.actions.enumerated() {
                let speaker: String?
                let personName: String?
                let personID: String
                switch action.actor {
                case .speaker(let id):
                    speaker = id
                    personName = bySpeaker[id]?.name
                    personID = Self.scoped(meetingID, "speaker", id)
                case .named(let name):
                    let key = Self.key(name)
                    let owners = byName[key] ?? []
                    let allOwners = claimedOwners[key] ?? []
                    if owners.count == 1, allOwners.isSubset(of: owners), let id = owners.first {
                        speaker = id
                        personName = bySpeaker[id]?.name
                        personID = Self.scoped(meetingID, "speaker", id)
                    } else if owners.isEmpty && allOwners.isEmpty {
                        speaker = nil
                        personName = name
                        personID = Self.scoped(meetingID, "named", key)
                    } else {
                        speaker = nil
                        personName = nil
                        personID = Self.scoped(meetingID, "unresolved", "\(item.segment.id):\(offset)")
                    }
                }
                let activity = Activity(
                    id: Self.scoped(meetingID, "activity", "\(item.segment.id):\(offset):\(action.kind.rawValue)"),
                    personID: personID, personName: personName, speakerID: speaker,
                    text: action.text, kind: action.kind, sourceSegmentIDs: [item.segment.id]
                )
                indices[item.segment.id, default: []].append(built.count)
                built.append(activity)
            }
        }
        activities = built
        activityIndices = indices
        sourceIDs = Set(segments.map(\.id))
    }

    /// Evidence IDs are mandatory. A model-proposed name alone is not evidence;
    /// nor can a mixed-actor source segment verify one of its actors arbitrarily.
    func assignee(for draft: MeetingActionDraft) -> String? {
        guard !draft.sourceSegmentIDs.isEmpty,
              draft.sourceSegmentIDs.allSatisfy(sourceIDs.contains) else { return nil }
        let indices = Set(draft.sourceSegmentIDs.flatMap { activityIndices[$0] ?? [] })
        guard !indices.isEmpty else { return nil }
        let relevant = indices.map { activities[$0] }
        guard relevant.contains(where: { $0.kind != .completed }),
              relevant.allSatisfy({ $0.personName != nil }),
              Set(relevant.map(\.personID)).count == 1,
              let actor = relevant.first, let name = actor.personName else { return nil }
        if let proposed = draft.assignee.map(Self.trim), !proposed.isEmpty {
            var accepted = [name]
            if let speaker = actor.speakerID, let identity = names.first(where: { $0.speakerID == speaker }) {
                accepted += identity.aliases
            }
            guard accepted.contains(where: { Self.key($0) == Self.key(proposed) }) else { return nil }
        }
        return name
    }

    /// Display overlay only; callers retain their original persisted profiles.
    func applyingNames(to profiles: [MeetingSpeakerProfile]) -> [MeetingSpeakerProfile] {
        let inferred = Dictionary(uniqueKeysWithValues: names.map { ($0.speakerID, $0.name) })
        return profiles.map { profile in
            var copy = profile
            if profile.displayName.map({ Self.trim($0).isEmpty || Self.trim($0) == profile.id }) ?? true {
                copy.displayName = inferred[profile.id] ?? profile.displayName
            }
            return copy
        }
    }

    private struct Claims {
        var primary: [(String, [String])] = []
        var aliases: [(String, [String])] = []
        var addressed: [(String, [String])] = []

        mutating func add(_ name: String, alias: Bool, evidence: [String]) {
            if alias { aliases.append((name, evidence)) }
            else { primary.append((name, evidence)) }
        }
    }

    private enum Actor { case speaker(String), named(String) }
    private struct ParsedAction { let text: String; let kind: ActivityKind; let actor: Actor }
    private struct Parsed {
        let segment: MeetingSegment
        let speaker: String?
        let requests: [String]
        let actions: [ParsedAction]
    }

    // All regular expressions are compiled once, not per utterance/activity.
    private enum Pattern {
        static let name = #"[\p{L}\p{M}][\p{L}\p{M}'’\-]{0,23}(?:[ \-][\p{L}\p{M}][\p{L}\p{M}'’\-]{0,23}){0,2}"#
        static let introduction = regex(
            #"(?:^|[,，]\s*)(?:my name is\s+("# + name + #")(?=\s*[,，.!?;]|$)|i(?: am|['’]m)\s+("# + name + #")(?=\s*[,，.!?;]|$)|(?:저는|제가|나는|내가|전|제 이름은)\s*([\p{L}\p{M}]{2,16}?)(?:입니다|이에요|예요|이라고 합니다|라고 합니다)(?=\s|[,，.!?;]|$))"#
        )
        static let alias = regex(
            #"(?:^|[,，]\s*)(?:call me\s+("# + name + #")(?=\s*[,，.!?;]|$)|(?:저를\s*)?([\p{L}\p{M}]{2,16}?)(?:이라고|라고)\s*불러\s*주세요|(?:제\s*)?별명은\s*([\p{L}\p{M}]{2,16}?)(?:입니다|이에요|예요))"#
        )
        static let question = regex(#"[?？]|(?:했나요|했습니까|했니|인가요|일까요|할까요)|^\s*(?:did|have|has|is|are|was|were|who|what|why|whether)\b"#)
        static let denial = regex(#"\b(?:not|never|no|didn['’]t|don['’]t|doesn['’]t|haven['’]t|hasn['’]t|hadn['’]t|won['’]t|wouldn['’]t|can['’]t|cannot|couldn['’]t|denied|deny)\b|(?:않|못|아니|안\s|없|취소|철회)"#)
        static let uncertain = regex(#"\b(?:if|maybe|perhaps|might|think|guess|suppose|apparently|reportedly)\b|(?:아마|만약|같습니다|같아요|추측)"#)
        static let firstPerson = regex(#"^\s*(?:i\b|i['’]ll\b|i['’]ve\b|저는\s*|제가\s*|나는\s*|내가\s*|전\s+)"#)
        static let commitment = regex(#"\bi(?:\s+will|['’]ll|\s+am going to|\s+plan to)\s+\p{L}|\band\s+(?:will|plan to|am going to)\s+\p{L}|(?:겠습니다|할게요|낼게요|낼 거예요|할 예정|하기로 했)"#)
        static let completed = regex(#"\b(?:i\s+(?:(?:have|already|just)\s+)*|i['’]ve\s+(?:already\s+)?)(?:completed|finished|sent|submitted|shared|fixed|deployed|implemented|resolved|updated|reviewed|prepared|delivered)\b|(?:(?:완료|수정|배포|구현|처리|공유|제출|검토|준비|전달|확인|작성|정리|분석|업데이트)했(?:습니다|어요|어|고)|끝냈(?:습니다|어요|고)|보냈(?:습니다|어요|고))"#)
        static let request = regex(#"\b(?:please\s+|(?:can|could|would|will)\s+you\s+(?:please\s+)?)(?:send|submit|share|review|confirm|schedule|prepare|update|deliver|check|fix|deploy|finish|complete|do|follow\s+up)\b|(?:해\s*주세요|해\s*주시|부탁|보내\s*주세요)"#)
        static let namedEnglishRequest = regex(#"^\s*("# + name + #")(?:\s*,\s*|\s+(?=please\b|can\b|could\b|would\b|will\b))(?:(?:please\s+)?|(?:can|could|would|will)\s+you\s+(?:please\s+)?)(?:send|submit|share|review|confirm|schedule|prepare|update|deliver|check|fix|deploy|finish|complete|do|follow\s+up)\b"#)
        static let namedKoreanRequest = regex(#"^\s*([\p{L}\p{M}]{2,16}?)(?:님|씨)(?:께서는|께서|은|는|이|가)?[\s,，]+|^\s*([\p{L}\p{M}]{2,16}?)[,，]\s*"#)
        static let namedStatement = regex(#"^\s*("# + name + #")\s+(?:(?:has|already|just)\s+)*(completed|finished|sent|submitted|shared|fixed|deployed|implemented|resolved|updated|reviewed|prepared|delivered|will)\b|^\s*([\p{L}\p{M}]{2,16}?)(?:님|씨)?(?:께서|은|는|이|가)\s+"#)
        static let acknowledgement = regex(#"^\s*(?:(?:yes|sure|okay|ok|absolutely)(?:[.!]?\s*$|(?:[,，.!]\s*|\s+)i(?:['’]ll|\s+will|\s+can|\s+am going to)\b)|(?:네|예|알겠습니다|좋습니다)(?:[.!]?\s*$|(?:[,，.!]\s*|\s+)(?:제가|저는|하겠습니다|알겠습니다)))"#)
        static let clauseBoundary = regex(#"[.!?？;\n]+(?:\s*|$)|,\s*(?=i\s+(?:will|completed|finished|sent)|i['’]ll)|\s+and\s+(?=i\s|i['’])"#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            // These are fixed source literals, not transcript/model input.
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }

    private static func namedRequest(_ text: String) -> String? {
        if let name = captures(Pattern.namedEnglishRequest, text).first, validName(name) { return name }
        guard matches(Pattern.request, text) else { return nil }
        if let name = captures(Pattern.namedKoreanRequest, text).first, validName(name) { return name }
        return nil
    }

    private static func namedStatement(_ text: String) -> (name: String, kind: ActivityKind)? {
        guard !matches(Pattern.firstPerson, text),
              let match = Pattern.namedStatement.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let captures = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let name = captures.first, validName(name), !["i", "we", "you", "he", "she", "they", "저", "제", "내", "나"].contains(key(name)) else { return nil }
        if matches(Pattern.commitment, text) || captures.contains(where: { key($0) == "will" }) {
            return (name, .committed)
        }
        if captures.count > 1 || matches(Pattern.completed, text) { return (name, .completed) }
        return nil
    }

    private static func clauses(in text: String) -> [String] {
        var clauses: [String] = []
        var start = text.startIndex
        for boundary in Pattern.clauseBoundary.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(boundary.range, in: text) else { continue }
            // Keep question marks, punctuation and original wording as evidence.
            let punctuation = text[range].first.map { ".!?？;\n".contains($0) } ?? false
            let end = punctuation ? range.upperBound : range.lowerBound
            let clause = trim(String(text[start..<end]))
            if !clause.isEmpty { clauses.append(clause) }
            start = range.upperBound
        }
        let tail = trim(String(text[start...]))
        if !tail.isEmpty { clauses.append(tail) }
        return clauses
    }

    private static func overlappingIDs(_ segments: [MeetingSegment]) -> Set<String> {
        var blocked: Set<String> = []
        var group: [MeetingSegment] = []
        var end: Int64 = -1
        func flush() {
            let speakers = Set(group.flatMap(\.speakerIDs))
            if group.count > 1 && (speakers.count != 1 || group.contains(where: { $0.speakerIDs.count != 1 })) {
                blocked.formUnion(group.map(\.id))
            }
        }
        for segment in segments {
            if segment.startMs >= end { flush(); group.removeAll(keepingCapacity: true) }
            group.append(segment)
            end = max(end, segment.endMs)
        }
        flush()
        return blocked
    }

    private static func owners(claims: [String: Claims], manual: [String: String]) -> [String: Set<String>] {
        var owners: [String: Set<String>] = [:]
        for (speaker, claim) in claims {
            for name in (claim.primary + claim.aliases + claim.addressed).map(\.0) {
                owners[key(name), default: []].insert(speaker)
            }
        }
        for (speaker, name) in manual { owners[key(name), default: []].insert(speaker) }
        return owners
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func introductions(in text: String) -> [String] {
        Pattern.introduction.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { match in
            (1..<match.numberOfRanges).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: text) else { return nil }
                let name = trim(String(text[range]))
                // "I'm working on it" is not an introduction. The weaker
                // English form requires proper-name casing for every word.
                if index == 2 && !name.split(separator: " ").allSatisfy({ $0.first?.isUppercase == true }) {
                    return nil
                }
                return name
            }
        }
    }

    private static func captures(_ regex: NSRegularExpression, _ text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { trim(String(text[$0])) }
            }
        }
    }

    private static func hasQuote(_ text: String) -> Bool {
        text.contains(where: { "\"“”‘’「」『』«»".contains($0) && $0 != "’" })
            || text.first == "'" || text.contains(" '")
    }

    private static let rejectedNameWords: Set<String> = [
        "i", "we", "you", "he", "she", "they", "it", "and", "or", "not", "unknown", "someone",
        "nobody", "done", "ready", "sorry", "happy", "sure", "going", "working", "finished",
        "responsible", "team", "already", "just", "저는", "제가", "우리", "완료", "담당자"
    ]

    private static func validName(_ name: String) -> Bool {
        let words = key(name).split(separator: " ")
        guard (2...48).contains(name.count), words.count <= 3 else { return false }
        return !words.contains { rejectedNameWords.contains(String($0)) }
    }

    private static func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func key(_ text: String) -> String { trim(text).precomposedStringWithCanonicalMapping.lowercased() }
    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert(key($0)).inserted }
    }
    private static func uniqueIDs(_ values: [String]) -> [String] { Array(Set(values)).sorted() }
    private static func scoped(_ meetingID: String, _ kind: String, _ value: String) -> String {
        "\(meetingID.utf8.count):\(meetingID)|\(kind):\(value)"
    }
}
