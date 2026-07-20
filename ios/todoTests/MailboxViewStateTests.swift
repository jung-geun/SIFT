import Foundation
import Testing
@testable import todo

@MainActor
@Suite("Mailbox view state")
struct MailboxViewStateTests {
    @Test("인증 provider fallback은 현재 선택을 유지하고 Gmail을 우선한다")
    func testAuthenticatedProviderFallback() {
        var state = MailboxViewState()
        state.reconcileAuthenticatedProviders([.gmail, .outlook])
        #expect(state.selectedProvider == .gmail)

        state.selectedProvider = .outlook
        state.reconcileAuthenticatedProviders([.gmail, .outlook])
        #expect(state.selectedProvider == .outlook)

        state.reconcileAuthenticatedProviders([.gmail])
        #expect(state.selectedProvider == .gmail)

        state.reconcileAuthenticatedProviders([.outlook])
        #expect(state.selectedProvider == .outlook)

        state.reconcileAuthenticatedProviders([])
        #expect(state.selectedProvider == nil)
    }

    @Test("Gmail과 Outlook category cursor count는 provider 전환 후에도 독립 유지된다")
    func testProviderSpecificPagingAndCategoryState() {
        var state = MailboxViewState(selectedProvider: .gmail)
        state.selectedGmailCategory = .updates
        let beganGmailPage = state.beginPage(for: .gmail, loadMore: false)
        #expect(beganGmailPage)
        state.completePage(for: .gmail, nextCursor: "gmail-next")
        let beganGmailIndex = state.beginIndex(for: .gmail)
        #expect(beganGmailIndex)
        state.completeIndex(for: .gmail, totalCount: 250)

        state.selectedProvider = .outlook
        state.selectedOutlookClassification = .other
        let beganOutlookPage = state.beginPage(for: .outlook, loadMore: false)
        #expect(beganOutlookPage)
        state.completePage(for: .outlook, nextCursor: "outlook-next")
        let beganOutlookIndex = state.beginIndex(for: .outlook)
        #expect(beganOutlookIndex)
        state.completeIndex(for: .outlook, totalCount: 80)

        state.selectedProvider = .gmail
        #expect(state.selectedGmailCategory == .updates)
        #expect(state.pagingState(for: .gmail).nextCursor == "gmail-next")
        #expect(state.pagingState(for: .gmail).totalInboxCount == 250)
        #expect(state.pagingState(for: .gmail).canLoadMore)

        state.selectedProvider = .outlook
        #expect(state.selectedOutlookClassification == .other)
        #expect(state.pagingState(for: .outlook).nextCursor == "outlook-next")
        #expect(state.pagingState(for: .outlook).totalInboxCount == 80)
        #expect(state.pagingState(for: .outlook).canLoadMore)
    }

    @Test("page와 index 실패는 기존 cursor count를 보존하고 retry 상태만 기록한다")
    func testFailuresPreserveSuccessfulState() {
        var state = MailboxViewState(selectedProvider: .gmail)
        let beganInitialPage = state.beginPage(for: .gmail, loadMore: false)
        #expect(beganInitialPage)
        state.completePage(for: .gmail, nextCursor: "same-cursor")
        let beganInitialIndex = state.beginIndex(for: .gmail)
        #expect(beganInitialIndex)
        state.completeIndex(for: .gmail, totalCount: 321)

        let beganLoadMore = state.beginPage(for: .gmail, loadMore: true)
        #expect(beganLoadMore)
        state.failPage(for: .gmail, message: "page failed")
        #expect(state.pagingState(for: .gmail).nextCursor == "same-cursor")
        #expect(state.pagingState(for: .gmail).hasLoadedInitialPage)
        #expect(state.pagingState(for: .gmail).pageErrorMessage == "page failed")
        #expect(state.pagingState(for: .gmail).canLoadMore)

        let beganRetryIndex = state.beginIndex(for: .gmail)
        #expect(beganRetryIndex)
        state.failIndex(for: .gmail, message: "index warning")
        #expect(state.pagingState(for: .gmail).totalInboxCount == 321)
        #expect(state.pagingState(for: .gmail).indexWarningMessage == "index warning")
    }

    @Test("중복 page/index 시작은 거부되고 category 0건이어도 cursor가 있으면 load more 가능하다")
    func testDuplicateBeginGuardsAndLoadMoreInvariant() {
        var state = MailboxViewState(selectedProvider: .gmail)
        let beganPage = state.beginPage(for: .gmail, loadMore: false)
        let duplicatePage = state.beginPage(for: .gmail, loadMore: false)
        #expect(beganPage)
        #expect(!duplicatePage)
        state.completePage(for: .gmail, nextCursor: "older")
        #expect(state.pagingState(for: .gmail).canLoadMore)

        let beganIndex = state.beginIndex(for: .gmail)
        let duplicateIndex = state.beginIndex(for: .gmail)
        #expect(beganIndex)
        #expect(!duplicateIndex)
        state.failIndex(for: .gmail, message: "warning")
        #expect(!state.pagingState(for: .gmail).isReconcilingIndex)
    }

    @Test("detail mutation alert title은 action과 local save failure를 구분한다")
    func testMailDetailAlertTitles() {
        let read = mailDetailAlert(
            action: .markAsRead,
            error: URLError(.notConnectedToInternet),
            language: .korean
        )
        #expect(read.title == "읽음 동기화 오류")

        let trash = mailDetailAlert(
            action: .trash,
            error: URLError(.notConnectedToInternet),
            language: .korean
        )
        #expect(trash.title == "메일 삭제 오류")

        let local = mailDetailAlert(
            action: .trash,
            error: MailboxMutationError.remoteCommittedLocalSaveFailed(
                provider: .gmail,
                action: .trash
            ),
            language: .korean
        )
        #expect(local.title == "메일 상태 저장 오류")
        #expect(
            local.message
                == "프로바이더에는 반영되었지만 로컬 상태 저장에 실패했습니다. 메일 목록을 다시 동기화합니다."
        )
    }
}
