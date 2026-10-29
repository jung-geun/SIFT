import Foundation
import Testing
@testable import todo

@MainActor
private final class RecordingStatusItemSpy: NSObject, MeetingRecordingStatusItemBridging {
    struct Presentation: Equatable {
        let paused: Bool
        let elapsedSeconds: Int64
        let phaseLabel: String
        let openRecordingLabel: String
    }
    var presentations: [Presentation] = []
    var clearCount = 0
    var invalidationCount = 0
    var actionCount = 0
    var action: (() -> Void)?

    required override init() { super.init() }
    func setOpenRecordingAction(_ action: @escaping () -> Void) {
        actionCount += 1
        self.action = action
    }
    func present(paused: Bool, elapsedSeconds: Int64, phaseLabel: String, openRecordingLabel: String) {
        presentations.append(Presentation(paused: paused, elapsedSeconds: elapsedSeconds,
                                          phaseLabel: phaseLabel, openRecordingLabel: openRecordingLabel))
    }
    func clear() { clearCount += 1 }
    func invalidate() {
        invalidationCount += 1
        action = nil
    }
}

@Suite("Native macOS recording status lifecycle")
@MainActor
struct MeetingRecordingMacStatusItemTests {
    private func snapshot(_ milliseconds: Int64, paused: Bool = false, id: String = "private-session") -> MeetingRecordingActivitySnapshot {
        MeetingRecordingActivitySnapshot(sessionID: id, phase: paused ? .paused : .recording,
                                         elapsedMilliseconds: milliseconds, updatedAt: .distantPast,
                                         sources: [MeetingRecordingSourceState(id: "private-source", kind: .application,
                                                                               colorIndex: 4, levels: [0, 255])])
    }

    @Test("nil never loads a plugin and stop removes only the active presentation")
    func stopAndRestart() {
        let spy = RecordingStatusItemSpy()
        var loads = 0
        let service = MeetingRecordingMacStatusItem(loadBridge: { loads += 1; return spy },
                                                   localizedText: { $0 }, openRecording: {})
        service.update(nil)
        #expect(loads == 0)
        service.update(snapshot(1_500))
        service.update(nil)
        service.update(nil)
        #expect(loads == 1)
        #expect(spy.clearCount == 1)
        service.update(snapshot(0, id: "next-session"))
        #expect(loads == 1)
        #expect(spy.actionCount == 1)
        #expect(spy.presentations.count == 2)
        #expect(spy.presentations.last?.elapsedSeconds == 0)
        service.invalidate()
    }

    @Test("canonical whole seconds deduplicate meter frames and pause updates immediately")
    func canonicalClockAndPause() {
        let spy = RecordingStatusItemSpy()
        let service = MeetingRecordingMacStatusItem(loadBridge: { spy }, localizedText: { "localized:" + $0 },
                                                   openRecording: {})
        service.update(snapshot(1_000))
        service.update(snapshot(1_999))
        service.update(snapshot(1_999, paused: true))
        service.update(snapshot(1_999, paused: true))
        service.update(snapshot(2_000))
        #expect(spy.presentations.map(\.elapsedSeconds) == [1, 1, 2])
        #expect(spy.presentations.map(\.paused) == [false, true, false])
        #expect(spy.presentations[1].phaseLabel == "localized:Paused")
        #expect(spy.presentations[1].openRecordingLabel == "localized:Open recording")
        service.invalidate()
    }

    @Test("menu action forwards explicitly and invalidation releases it without resurrection")
    func navigationAndTermination() {
        let spy = RecordingStatusItemSpy()
        var opens = 0
        let service = MeetingRecordingMacStatusItem(loadBridge: { spy }, localizedText: { $0 },
                                                   openRecording: { opens += 1 })
        service.update(snapshot(42_000))
        spy.action?()
        #expect(opens == 1)
        service.invalidate()
        service.invalidate()
        service.update(snapshot(43_000))
        spy.action?()
        #expect(spy.invalidationCount == 1)
        #expect(spy.presentations.count == 1)
        #expect(opens == 1)
    }

    @Test("unavailable presentation attempts loading once and never affects capture")
    func missingPlugin() {
        var loads = 0
        let service = MeetingRecordingMacStatusItem(loadBridge: { loads += 1; return nil },
                                                   localizedText: { $0 }, openRecording: {})
        service.update(snapshot(0))
        service.update(snapshot(1_000))
        service.update(nil)
        service.update(snapshot(0, id: "next-session"))
        #expect(loads == 1)
        service.invalidate()
    }

    @Test("projection bounds elapsed time and discards all source and session metadata")
    func privacyProjection() {
        #expect(MeetingRecordingStatusItemPresentation(snapshot(-1)).elapsedSeconds == 0)
        #expect(MeetingRecordingStatusItemPresentation(snapshot(.max)).elapsedSeconds == 315_576_000)
        let original = snapshot(1_234)
        let unrelatedMetadata = MeetingRecordingActivitySnapshot(sessionID: "other", phase: .recording,
                                                                 elapsedMilliseconds: 1_234, updatedAt: .now, sources: [])
        #expect(MeetingRecordingStatusItemPresentation(original) == MeetingRecordingStatusItemPresentation(unrelatedMetadata))
    }
}
