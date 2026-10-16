import Foundation
import Testing
@testable import todo

@Suite("Measured transcription progress")
struct MeetingTranscriptionProgressTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    @Test("Model loading and downstream work never borrow an ASR estimate")
    func estimateScope() {
        var progress = MeetingTranscriptionProgress(totalMilliseconds: 120_000, now: start)
        progress.receive(.init(.loadingModel, date: start))
        #expect(progress.fraction == nil)
        #expect(progress.estimatedRemaining(at: start.addingTimeInterval(90)) == nil)
        progress.receive(.init(.recognizing, completedMilliseconds: 0, date: start.addingTimeInterval(100)))
        progress.receive(.init(.recognizing, completedMilliseconds: 30_000, date: start.addingTimeInterval(110)))
        #expect(progress.estimatedRemaining(at: start.addingTimeInterval(110)) == 30)
        #expect(progress.elapsed(at: start.addingTimeInterval(110)) == 110)
        progress.receive(.init(.validating, date: start.addingTimeInterval(140)))
        #expect(progress.fraction == nil)
        #expect(progress.estimatedRemaining(at: start.addingTimeInterval(150)) == nil)
    }

    @Test("A stalled window does not count down to a fabricated completion")
    func stalledEstimate() {
        var progress = MeetingTranscriptionProgress(totalMilliseconds: 120_000, now: start)
        progress.receive(.init(.recognizing, completedMilliseconds: 30_000, date: start))
        #expect(progress.estimatedRemaining(at: start.addingTimeInterval(10)) == 30)
        #expect(progress.estimatedRemaining(at: start.addingTimeInterval(40)) == 120)
        #expect(progress.completedMilliseconds == 30_000)
        #expect(progress.lastActivityAt == start)
    }

    @Test("Late callbacks and padded endpoints cannot reverse stages or signal commit")
    func lateCallbacks() throws {
        var progress = MeetingTranscriptionProgress(totalMilliseconds: 120_000, now: start)
        progress.receive(.init(.recognizing, completedMilliseconds: 60_000, date: start))
        progress.receive(.init(.recognizing, completedMilliseconds: 10_000, date: start))
        #expect(progress.fraction == 0.5)
        progress.receive(.init(.recognizing, completedMilliseconds: Int64.max, date: start))
        #expect(progress.completedMilliseconds == 120_000)
        #expect(try #require(progress.fraction) < 1)
        #expect(progress.estimatedRemaining(at: start.addingTimeInterval(10)) == nil)
        progress.receive(.init(.validating, date: start))
        progress.receive(.init(.recognizing, completedMilliseconds: 60_000, date: start.addingTimeInterval(1)))
        #expect(progress.stage == .validating)
        #expect(progress.fraction == nil)
    }

    @Test("Short or unmeasured audio does not invent speed")
    func insufficientEvidence() {
        for total in [Int64(0), 5_000, 4_688_000] {
            var progress = MeetingTranscriptionProgress(totalMilliseconds: total, now: start)
            progress.receive(.init(.recognizing, completedMilliseconds: min(total, 5_000), date: start))
            #expect(progress.estimatedRemaining(at: start.addingTimeInterval(60)) == nil)
        }
    }

    @Test("Preparation completion does not leak into recognition progress")
    func stageReset() {
        var progress = MeetingTranscriptionProgress(totalMilliseconds: 60_000, now: start)
        progress.receive(.init(.preparingAudio, completedMilliseconds: 60_000, date: start))
        #expect(progress.fraction == 1)
        progress.receive(.init(.recognizing, date: start))
        #expect(progress.fraction == 0)
        #expect(progress.estimatedRemaining(at: start.addingTimeInterval(60)) == nil)
    }
}
