import CryptoKit
import Foundation
import NaturalLanguage

struct UserVocabularyExtractor: Sendable {
    nonisolated static let version = 1

    private static let englishStopwords: Set<String> = ["a", "an", "and", "are", "at", "be", "been", "by", "for", "from", "hello", "hi", "in", "is", "of", "on", "or", "please", "re", "thanks", "that", "the", "these", "this", "those", "to", "was", "were", "with"]
    private static let koreanStopwords: Set<String> = ["감사합니다", "관련", "내용", "메일", "안녕하세요", "업무", "요청", "일정", "확인"]

    /// Automatic vocabulary is intentionally restricted to standalone technical
    /// terms. Korean particles/endings and ordinary prose never become entries.
    private static let technicalLexicon: Set<String> = [
        "api", "backend", "cache", "container", "database", "debug", "debugging",
        "deployment", "docker", "frontend", "kubernetes", "openstack",
        "orchestration", "server", "swift", "swiftdata",
        "쿠버네티스", "오픈스택", "디버깅"
    ]

    func extract(from document: VocabularySourceDocument) -> [VocabularyCandidate] {
        let text = document.fields.map(\.value).joined(separator: "\n")
        var candidates: [VocabularyCandidate] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = String(text[range])
            guard Self.isAutomaticSurface(token), !Self.isExcluded(token) else { return true }
            if token.range(of: #"^[A-Z]{2,}$"#, options: .regularExpression) != nil {
                candidates.append(.init(canonical: token, surface: token, role: .canonical, category: .acronym, confidence: 0.9))
            } else if token.range(of: #"^(?=.*[A-Za-z])(?=.*[0-9]|.*[A-Z].*[a-z]|.*[a-z].*[A-Z])[A-Za-z0-9-]+$"#, options: .regularExpression) != nil || Self.technicalLexicon.contains(UserVocabularyService.normalizedKey(token)) {
                candidates.append(.init(canonical: token, surface: token, role: .canonical, category: .technicalTerm, confidence: 0.9))
            }
            return candidates.count < 24
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert(UserVocabularyService.normalizedKey($0.canonical)).inserted }
    }

    private static func isAutomaticSurface(_ value: String) -> Bool {
        UserVocabularyService.isVocabularyToken(value)
    }

    private static func isExcluded(_ value: String) -> Bool {
        let key = UserVocabularyService.normalizedKey(value)
        if englishStopwords.contains(key) || koreanStopwords.contains(key) { return true }
        if value.range(of: #"^[0-9₩$€¥,.]+$"#, options: .regularExpression) != nil { return true }
        if value.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}$"#, options: .regularExpression) != nil { return true }
        return value.contains("@") || value.contains("://")
    }
}

enum VocabularySourceDocumentBuilder {
    nonisolated static func make(source: VocabularySourceKind, stableID: String, evidenceGroupID: String, fields: [VocabularyTextField]) -> VocabularySourceDocument {
        var remaining = 8_000
        let capped = fields.compactMap { field -> VocabularyTextField? in
            guard remaining > 0 else { return nil }
            let value = String(field.value.prefix(remaining))
            remaining -= value.count
            return value.isEmpty ? nil : VocabularyTextField(field.kind, value)
        }
        var bytes = Data()
        for field in capped {
            bytes.append(contentsOf: field.kind.rawValue.utf8)
            bytes.append(0)
            bytes.append(contentsOf: UserVocabularyService.normalizedKey(field.value).utf8)
            bytes.append(0)
        }
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return VocabularySourceDocument(source: source, stableID: stableID, evidenceGroupID: evidenceGroupID, contentFingerprint: fingerprint, fields: capped)
    }
}

extension VocabularySourceDocumentBuilder {
    static func todo(_ todo: Todo) -> VocabularySourceDocument {
        let stable = "todo\u{0}\(todo.id.uuidString)"
        let evidence: String
        if todo.todoSource == .email, !todo.sourceAccountNamespace.isEmpty, !todo.sourceRef.isEmpty {
            let provider: String = todo.sourceRef.hasPrefix("outlook:") ? MailProvider.outlook.rawValue : MailProvider.gmail.rawValue
            let messageID = todo.sourceRef.replacingOccurrences(of: "outlook:", with: "")
            evidence = "email\u{0}\(todo.sourceAccountNamespace)\u{0}\(provider)\u{0}\(messageID)"
        } else {
            evidence = stable
        }
        return make(
            source: .todo,
            stableID: stable,
            evidenceGroupID: evidence,
            fields: [
                .init(.subject, todo.title),
                .init(.notes, todo.notes),
                .init(.tags, todo.tags.joined(separator: ", ")),
                .init(.senderDisplay, todo.sourceSender)
            ]
        )
    }
}
