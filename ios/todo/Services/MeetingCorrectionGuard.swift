import Foundation

/// Hallucination guard for the transcript correction pass, shared by the AFM and
/// on-device LLM engines. Accepts only spelling/typo-level fixes and rejects
/// wholesale rewrites, so a model that "improves" a segment by inventing new
/// content is dropped in favor of the original text.
///
/// Non-isolated and framework-free so both the iOS 26 AFM path and the MLX path
/// can call it.
enum MeetingCorrectionGuard {
    /// Whether `new` is an acceptable correction of `old`:
    ///   1) non-empty and actually different;
    ///   2) length change within ±40% (8-char floor for short segments);
    ///   3) a majority of the original tokens survive — a same-length rewrite
    ///      that swaps most words is rejected as hallucination.
    static func isAcceptable(old: String, new: String) -> Bool {
        guard !new.isEmpty, new != old else { return false }
        let allowedLenDelta = max(8, Int(Double(max(old.count, 1)) * 0.4))
        guard abs(new.count - old.count) <= allowedLenDelta else { return false }

        let oldTokens = old.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
        guard !oldTokens.isEmpty else { return true }
        let newTokens = Set(new.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() })
        let changed = oldTokens.filter { !newTokens.contains($0) }.count
        let allowedChanged = max(2, Int(Double(oldTokens.count) * 0.4))
        return changed <= allowedChanged
    }
}
