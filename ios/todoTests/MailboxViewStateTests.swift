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

        state.selectedProvider = .gmail
        state.reconcileAuthenticatedProviders([.gmail])
        #expect(state.selectedProvider == .gmail)

        state.reconcileAuthenticatedProviders([.outlook])
        #expect(state.selectedProvider == .outlook)
        state.reconcileAuthenticatedProviders([])
        #expect(state.selectedProvider == nil)
    }

    @Test("Gmail category와 cursor count 상태가 올바르게 업데이트된다")
    func testGmailPagingAndCategoryState() {
        var state = MailboxViewState(selectedProvider: .gmail)
        state.selectedGmailCategory = .updates
        let beganGmailPage = state.beginPage(for: .gmail, loadMore: false)
        #expect(beganGmailPage)
        state.completePage(for: .gmail, nextCursor: "gmail-next")
        let beganGmailIndex = state.beginIndex(for: .gmail)
        #expect(beganGmailIndex)
        state.completeIndex(for: .gmail, totalCount: 250)

        #expect(state.selectedGmailCategory == .updates)
        #expect(state.pagingState(for: .gmail).nextCursor == "gmail-next")
        #expect(state.pagingState(for: .gmail).totalInboxCount == 250)
        #expect(state.pagingState(for: .gmail).canLoadMore)
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

    @Test("Gmail IMAP errors stay localized in the selected language")
    func testGmailIMAPErrorLocalization() {
        let korean = mailDetailAlert(
            action: .markAsRead,
            error: GmailIMAPError.invalidResponse,
            language: .korean
        )
        #expect(korean.title == "읽음 동기화 오류")
        #expect(korean.message == "Gmail IMAP에서 올바르지 않은 응답을 받았습니다.")

        let english = mailDetailAlert(
            action: .trash,
            error: GmailIMAPError.authenticationFailed,
            language: .english
        )
        #expect(english.title == "Mail deletion error")
        #expect(english.message == "Gmail IMAP authentication failed.")
    }

    @Test("Gmail IMAP mutation capability errors are localized")
    func testGmailMutationCapabilityAlertLocalization() {
        let korean = mailDetailAlert(
            action: .trash,
            error: GmailIMAPError.mutationUnsupported,
            language: .korean
        )
        #expect(korean.title == "메일 삭제 오류")
        #expect(korean.message.contains("지원하지 않습니다"))

        let english = mailDetailAlert(
            action: .markAsRead,
            error: GmailIMAPError.mailboxReset,
            language: .english
        )
        #expect(english.title == "Read-status sync error")
        #expect(english.message == "The Gmail mailbox changed. Refresh the inbox and try again.")
    }

    @Test("MailboxStartupPresentation pure presentation contract")
    func testMailboxStartupPresentationContract() {
        // 1. checking + cached Gmail => shows mailbox/visible Gmail
        let checkingWithCachedGmail = MailboxStartupPresentation(
            authenticationState: .checking,
            cachedProviders: [.gmail],
            authenticatedProviders: [],
            storedCredentialProviders: [.gmail]
        )
        #expect(checkingWithCachedGmail.visibleProviders == [.gmail])
        #expect(checkingWithCachedGmail.showsMailbox == true)
        #expect(checkingWithCachedGmail.showsAuthenticationCheckingStatus == true)

        // 2. checking + no cache => no mailbox/checking status true
        let checkingNoCache = MailboxStartupPresentation(
            authenticationState: .checking,
            cachedProviders: [],
            authenticatedProviders: [],
            storedCredentialProviders: []
        )
        #expect(checkingNoCache.visibleProviders.isEmpty)
        #expect(checkingNoCache.showsMailbox == false)
        #expect(checkingNoCache.showsAuthenticationCheckingStatus == true)

        // 3. resolved + no live session keeps cached mail only while its
        // local App Password is still present.
        let resolvedNoAuthenticatedProviders = MailboxStartupPresentation(
            authenticationState: .resolved,
            cachedProviders: [.gmail],
            authenticatedProviders: [],
            storedCredentialProviders: [.gmail]
        )
        #expect(resolvedNoAuthenticatedProviders.visibleProviders == [.gmail])
        #expect(resolvedNoAuthenticatedProviders.showsMailbox == true)
        #expect(resolvedNoAuthenticatedProviders.showsAuthenticationCheckingStatus == false)

        let resolvedMissingCredential = MailboxStartupPresentation(
            authenticationState: .resolved,
            cachedProviders: [.gmail],
            authenticatedProviders: [],
            storedCredentialProviders: []
        )
        #expect(resolvedMissingCredential.visibleProviders.isEmpty)
        #expect(resolvedMissingCredential.showsMailbox == false)

        // 4. resolved + Gmail authenticated => shows Gmail
        let resolvedGmailAuthenticated = MailboxStartupPresentation(
            authenticationState: .resolved,
            cachedProviders: [.gmail],
            authenticatedProviders: [.gmail],
            storedCredentialProviders: []
        )
        #expect(resolvedGmailAuthenticated.visibleProviders == [.gmail])
        #expect(resolvedGmailAuthenticated.showsMailbox == true)
        #expect(resolvedGmailAuthenticated.showsAuthenticationCheckingStatus == false)
    }

    @Test("Gmail and Outlook stored credentials permit valid account namespaces")
    func testGmailAndOutlookCredentialsPermitValidNamespaces() {
        let cacheAccess = MailboxCachedProviderAccess(
            activeGmailNamespace: "mail@example.com",
            activeOutlookNamespace: "outlook@example.com"
        )
        #expect(cacheAccess.locallyConfiguredProviders == [.gmail, .outlook])
        #expect(cacheAccess.isLocallyConfigured(.gmail))
        #expect(cacheAccess.isLocallyConfigured(.outlook))
        #expect(
            cacheAccess.permits(
                provider: .gmail,
                sourceAccountNamespace: "mail@example.com"
            )
        )
        #expect(
            !cacheAccess.permits(
                provider: .gmail,
                sourceAccountNamespace: "other@example.com"
            )
        )
        #expect(
            cacheAccess.permits(
                provider: .outlook,
                sourceAccountNamespace: "outlook@example.com"
            )
        )
        #expect(
            !cacheAccess.permits(
                provider: .outlook,
                sourceAccountNamespace: ""
            )
        )
        #expect(
            !cacheAccess.permits(
                provider: .outlook,
                sourceAccountNamespace: "other@outlook.com"
            )
        )
        let presentation = MailboxStartupPresentation(
            authenticationState: .checking,
            cachedProviders: [.gmail],
            authenticatedProviders: [],
            storedCredentialProviders: [.gmail]
        )
        #expect(presentation.visibleProviders == [.gmail])
    }
    @Test("stored mail credentials make the Mail tab visible without remote validation")
    func testMailTabVisibilityUsesLocalCredentialSignals() {
        #expect(
            mailTabIsVisibleForStoredCredentials(
                uiTestShowsAllTabs: false,
                gmailAccount: "mail@example.com"
            )
        )
        #expect(
            mailTabIsVisibleForStoredCredentials(
                uiTestShowsAllTabs: false,
                gmailAccount: "",
                outlookAccount: "outlook@example.com"
            )
        )
        #expect(
            !mailTabIsVisibleForStoredCredentials(
                uiTestShowsAllTabs: false,
                gmailAccount: "",
                outlookAccount: ""
            )
        )
        #expect(
            mailTabIsVisibleForStoredCredentials(
                uiTestShowsAllTabs: true,
                gmailAccount: ""
            )
        )
    }

    @Test("첫 번째 메일 row만, 준비 완료 후에만 top sync를 트리거한다")
    func testShouldTriggerTopSyncOnlyFiresForFirstReadyRow() {
        // First row + fully resolved/loaded/provider-selected => fires.
        #expect(
            MailTabView.shouldTriggerTopSync(
                emailID: "first",
                firstEmailID: "first",
                authenticationState: .resolved,
                hasLoadedInitialPage: true,
                hasProvider: true
            )
        )

        // Any row other than the first never fires, even when fully ready.
        #expect(
            !MailTabView.shouldTriggerTopSync(
                emailID: "second",
                firstEmailID: "first",
                authenticationState: .resolved,
                hasLoadedInitialPage: true,
                hasProvider: true
            )
        )

        // Still checking authentication => no trigger.
        #expect(
            !MailTabView.shouldTriggerTopSync(
                emailID: "first",
                firstEmailID: "first",
                authenticationState: .checking,
                hasLoadedInitialPage: true,
                hasProvider: true
            )
        )

        // Initial page not yet loaded => no trigger.
        #expect(
            !MailTabView.shouldTriggerTopSync(
                emailID: "first",
                firstEmailID: "first",
                authenticationState: .resolved,
                hasLoadedInitialPage: false,
                hasProvider: true
            )
        )

        // No selected provider => no trigger.
        #expect(
            !MailTabView.shouldTriggerTopSync(
                emailID: "first",
                firstEmailID: "first",
                authenticationState: .resolved,
                hasLoadedInitialPage: true,
                hasProvider: false
            )
        )

        // Empty list (no first row yet) => no trigger for any id.
        #expect(
            !MailTabView.shouldTriggerTopSync(
                emailID: "first",
                firstEmailID: nil,
                authenticationState: .resolved,
                hasLoadedInitialPage: true,
                hasProvider: true
            )
        )
    }

    @Test("locally stored credentials select and render provider immediately without remote auth")
    func testLocalCredentialStartupSelectionAndVisibility() {
        let presentation = MailboxStartupPresentation(
            authenticationState: .resolved,
            cachedProviders: [],
            authenticatedProviders: [],
            storedCredentialProviders: [.gmail]
        )

        #expect(presentation.showsMailbox == true)
        #expect(presentation.visibleProviders == [.gmail])
        #expect(presentation.showsAuthenticationCheckingStatus == false)

        var viewState = MailboxViewState()
        viewState.reconcileProviders(presentation.visibleProviders)
        #expect(viewState.selectedProvider == .gmail)
    }

    @Test("locally stored credentials for Outlook select Outlook when no Gmail credentials exist")
    func testLocalCredentialOutlookSelection() {
        let presentation = MailboxStartupPresentation(
            authenticationState: .resolved,
            cachedProviders: [],
            authenticatedProviders: [],
            storedCredentialProviders: [.outlook]
        )

        #expect(presentation.showsMailbox == true)
        #expect(presentation.visibleProviders == [.outlook])
        #expect(presentation.showsAuthenticationCheckingStatus == false)

        var viewState = MailboxViewState()
        viewState.reconcileProviders(presentation.visibleProviders)
        #expect(viewState.selectedProvider == .outlook)
    }
}
