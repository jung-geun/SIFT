import CoreMedia
import Foundation
import Speech

extension MeetingTimedTextRun {
    /// Speech's time attribute is optional (notably for Dictation). All runs
    /// contribute to UTF-16 offsets, but only finite, forward measured spans get times.
    /// Clip to the owning result and previously retained end; never fill timing gaps.
    nonisolated static func extract(from text: AttributedString, startMs: Int64, endMs: Int64) -> [MeetingTimedTextRun] {
        var timed: [MeetingTimedTextRun] = []
        var endIndex = text.startIndex
        var utf16End = 0
        var previousEnd = max(0, startMs)
        for run in text.runs {
            utf16End += text.utf16.distance(from: endIndex, to: run.range.lowerBound)
            let length = text.utf16.distance(from: run.range.lowerBound, to: run.range.upperBound)
            if let range = run.audioTimeRange, length > 0 {
                let start = CMTimeGetSeconds(range.start) * 1_000
                let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range)) * 1_000
                if start.isFinite, end.isFinite, end > start {
                    let runStart = start.rounded()
                    let runEnd = end.rounded()
                    // previousEnd starts at startMs and only advances. Reject empty
                    // intersections before converting, so even large finite times
                    // outside the result cannot overflow Int64.
                    if runStart < Double(endMs), runEnd > Double(previousEnd) {
                        let boundedStart = runStart <= Double(previousEnd) ? previousEnd : Int64(runStart)
                        let boundedEnd = runEnd >= Double(endMs) ? endMs : Int64(runEnd)
                        if boundedEnd > boundedStart {
                            timed.append(Self(utf16Offset: utf16End, utf16Length: length,
                                              startMs: boundedStart, endMs: boundedEnd))
                            previousEnd = boundedEnd
                        }
                    }
                }
            }
            utf16End += length
            endIndex = run.range.upperBound
        }
        return timed
    }
}
