import Foundation

struct LiveTranscriptReducer {
    private(set) var entries = [LiveTranscriptEntry]()

    mutating func replace(_ entry: LiveTranscriptEntry) {
        let hasText = !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText else { return }
        let overlapsFinal = entries.contains { existing in
            existing.isFinal && existing.endMs > entry.startMs && existing.startMs < entry.endMs
        }
        guard entry.isFinal || !overlapsFinal else { return }
        entries.removeAll { existing in
            let overlaps = existing.endMs > entry.startMs && existing.startMs < entry.endMs
            return overlaps && (entry.isFinal || !existing.isFinal)
        }
        entries.append(entry)
        entries.sort {
            $0.startMs == $1.startMs ? ($0.endMs == $1.endMs ? $0.id < $1.id : $0.endMs < $1.endMs) : $0.startMs < $1.startMs
        }
    }

    mutating func reset() {
        entries = []
    }
}
