import Foundation
import Testing
@testable import todo

@Suite("Mail analysis progress")
struct MailAnalysisProgressTests {
    @Test("진행 상태는 현재 인덱스와 완료 개수를 구분한다")
    func testProgressStringsAndFractions() {
        let first = MailAnalysisProgress.processing(index: 1, total: 3)
        #expect(first.currentIndex == 1)
        #expect(first.completedCount == 0)
        #expect(first.fraction == 0)
        #expect(first.statusText(language: .korean) == "메일 분석 1/3")
        #expect(first.accessibilityValue(language: .korean) == "총 3개 중 1번째 메일 분석 중, 0개 처리됨")

        let intermediate = MailAnalysisProgress.processing(index: 2, total: 3)
        #expect(intermediate.currentIndex == 2)
        #expect(intermediate.completedCount == 1)
        #expect(intermediate.fraction == 1.0 / 3.0)
        #expect(intermediate.statusText(language: .korean) == "메일 분석 2/3")
        #expect(intermediate.accessibilityValue(language: .korean) == "총 3개 중 2번째 메일 분석 중, 1개 처리됨")

        let final = MailAnalysisProgress.processing(index: 3, total: 3).completingCurrent()
        #expect(final.currentIndex == 3)
        #expect(final.completedCount == 3)
        #expect(final.fraction == 1)
        #expect(final.statusText(language: .korean) == "메일 분석 완료 3/3")
        #expect(final.accessibilityValue(language: .korean) == "총 3개 메일 처리 완료")
    }

    @Test("배치는 실패한 시도를 포함해 공급된 순서대로 전후 진행을 방출한다")
    @MainActor
    func testBatchProgressOrderIncludesFailedAttempt() async {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let emails = [
            EmailMessage(id: "newest", receivedAt: baseDate),
            EmailMessage(id: "failed", receivedAt: baseDate.addingTimeInterval(-60)),
            EmailMessage(id: "oldest", receivedAt: baseDate.addingTimeInterval(-120))
        ]
        var processedIDs: [String] = []
        var events: [MailAnalysisProgress] = []

        await MailAnalysisBatch.run(
            emails: emails,
            process: { email in
                processedIDs.append(email.id)
                if email.id == "failed" {
                    return
                }
            },
            onProgress: { events.append($0) }
        )

        #expect(processedIDs == ["newest", "failed", "oldest"])
        #expect(
            events == [
                MailAnalysisProgress(currentIndex: 1, completedCount: 0, totalCount: 3),
                MailAnalysisProgress(currentIndex: 1, completedCount: 1, totalCount: 3),
                MailAnalysisProgress(currentIndex: 2, completedCount: 1, totalCount: 3),
                MailAnalysisProgress(currentIndex: 2, completedCount: 2, totalCount: 3),
                MailAnalysisProgress(currentIndex: 3, completedCount: 2, totalCount: 3),
                MailAnalysisProgress(currentIndex: 3, completedCount: 3, totalCount: 3)
            ]
        )
        #expect(events.last?.statusText(language: .korean) == "메일 분석 완료 3/3")
        #expect(events.last?.accessibilityValue(language: .korean) == "총 3개 메일 처리 완료")
    }

    @Test("분석 중 동기화 요청은 한 번으로 합쳐지고 종료 후 초기화된다")
    func testSyncGateCoalescesAndResets() {
        var gate = MailAnalysisSyncGate()

        let firstBegin = gate.beginAnalysis()
        let secondBegin = gate.beginAnalysis()
        let firstDeferredSync = gate.requestSync()
        let secondDeferredSync = gate.requestSync()
        let syncWasRequested = gate.syncRequested
        let firstFinish = gate.finishAnalysis()
        let secondFinish = gate.finishAnalysis()
        let idleSync = gate.requestSync()

        #expect(firstBegin)
        #expect(secondBegin == false)
        #expect(firstDeferredSync == false)
        #expect(secondDeferredSync == false)
        #expect(syncWasRequested)
        #expect(firstFinish)
        #expect(gate.isAnalyzing == false)
        #expect(gate.syncRequested == false)
        #expect(secondFinish == false)
        #expect(idleSync)
    }
}
