import Foundation
import NaturalLanguage

struct UserVocabularyCanonicalizer: Sendable {
    let snapshot: UserVocabularySnapshot

    func canonicalize(_ text: String) -> String {
        guard !snapshot.canonicalizationMappings.isEmpty else { return text }
        let protected = snapshot.protectedCanonicalPhrases.sorted {
            tokenCount($0) == tokenCount($1) ? $0.count > $1.count : tokenCount($0) > tokenCount($1)
        }
        let mappings = snapshot.canonicalizationMappings.sorted {
            let lhsTokens = tokenCount($0.alias)
            let rhsTokens = tokenCount($1.alias)
            if lhsTokens != rhsTokens { return lhsTokens > rhsTokens }
            if $0.alias.count != $1.alias.count { return $0.alias.count > $1.alias.count }
            if $0.aliasKey != $1.aliasKey { return $0.aliasKey < $1.aliasKey }
            return $0.canonicalKey < $1.canonicalKey
        }

        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if let protectedMatch = longestMatch(in: text, from: cursor, candidates: protected.map { ($0, $0) }) {
                output += protectedMatch.output
                cursor = protectedMatch.end
            } else if let replacement = longestMatch(in: text, from: cursor, candidates: mappings.map { ($0.alias, $0.canonical) }) {
                output += replacement.output
                cursor = replacement.end
            } else {
                output.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        return output
    }

    private func longestMatch(in text: String, from start: String.Index, candidates: [(String, String)]) -> (end: String.Index, output: String)? {
        for (phrase, output) in candidates {
            guard !phrase.isEmpty, text[start...].hasPrefix(phrase) else { continue }
            let end = text.index(start, offsetBy: phrase.count)
            if isTokenBoundary(text, before: start) && isTokenBoundary(text, after: end) {
                return (end, output)
            }
        }
        return nil
    }

    private func isTokenBoundary(_ text: String, before index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        return !text[text.index(before: index)].isLetter && !text[text.index(before: index)].isNumber
    }

    private func isTokenBoundary(_ text: String, after index: String.Index) -> Bool {
        guard index < text.endIndex else { return true }
        return !text[index].isLetter && !text[index].isNumber
    }

    private func tokenCount(_ text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }
}
