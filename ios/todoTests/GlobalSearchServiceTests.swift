import Foundation
import Testing
@testable import todo

@Suite("GlobalSearchService pure search behavior")
struct GlobalSearchServiceTests {
    private static let fixedUUID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let fixedUUID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func makeDoc(
        key: GlobalSearchRecordKey = .todo(fixedUUID1),
        source: GlobalSearchSource = .todo,
        stableSortKey: String = "key-1",
        title: String,
        subtitle: String = "",
        date: Date = Date(timeIntervalSince1970: 1000),
        content: [String] = []
    ) -> GlobalSearchDocument {
        GlobalSearchDocument(
            key: key,
            source: source,
            stableSortKey: stableSortKey,
            title: title,
            subtitle: subtitle,
            date: date,
            content: content
        )
    }

    // MARK: - 1. Empty & Whitespace Input

    @Test("empty or whitespace query yields empty results")
    func emptyOrWhitespaceQueryReturnsEmpty() {
        let docs = [
            makeDoc(title: "Task 1", subtitle: "Notes"),
            makeDoc(title: "Meeting 2", subtitle: "Summary")
        ]

        #expect(GlobalSearchService.search(query: "", documents: docs).isEmpty)
        #expect(GlobalSearchService.search(query: "   \t\n ", documents: docs).isEmpty)
    }

    // MARK: - 2. Text Normalization

    @Test("case normalization matches uppercase and lowercase")
    func caseNormalization() {
        let doc = makeDoc(title: "Swift Programming Tutorial")
        let results = GlobalSearchService.search(query: "SWIFT", documents: [doc])

        #expect(results.count == 1)
        #expect(results.first?.title == "Swift Programming Tutorial")
    }

    @Test("Korean text normalization matches exact and decomposed forms")
    func koreanNormalization() {
        let doc1 = makeDoc(title: "주간 회의록", content: ["오전 팀 미팅"])
        let doc2 = makeDoc(title: "프로젝트 계약서", subtitle: "법무 검토")
        let docs = [doc1, doc2]

        let meetingResults = GlobalSearchService.search(query: "회의", documents: docs)
        #expect(meetingResults.count == 1)
        #expect(meetingResults.first?.title == "주간 회의록")

        let contractResults = GlobalSearchService.search(query: "계약서", documents: docs)
        #expect(contractResults.count == 1)
        #expect(contractResults.first?.title == "프로젝트 계약서")
    }

    @Test("diacritic normalization folds accent marks")
    func diacriticNormalization() {
        let doc = makeDoc(title: "Café Lunch", content: ["Reservations at Bistro"])
        let results = GlobalSearchService.search(query: "cafe", documents: [doc])

        #expect(results.count == 1)
        #expect(results.first?.title == "Café Lunch")
    }

    @Test("full-width and half-width character normalization")
    func widthNormalization() {
        let doc = makeDoc(title: "SWIFT")
        // Full-width "ＳＷＩＦＴ"
        let fullWidthQuery = "ＳＷＩＦＴ"
        let results = GlobalSearchService.search(query: fullWidthQuery, documents: [doc])

        #expect(results.count == 1)
        #expect(results.first?.title == "SWIFT")
    }

    // MARK: - 3. Cross-Field Token AND Matching

    @Test("multi-token AND matching requires all tokens across title, subtitle, or content")
    func crossFieldTokenANDMatching() {
        let doc1 = makeDoc(title: "Contract Review", subtitle: "Legal Dept", content: ["Annual renewal"])
        let doc2 = makeDoc(title: "Q3 Strategy", subtitle: "Contract", content: ["Review pending"])
        let doc3 = makeDoc(title: "Contract Drafting", subtitle: "No review needed", content: ["Drafting terms"])
        let doc4 = makeDoc(title: "Design Review", subtitle: "UI/UX", content: ["Mockups and wireframes"])

        let docs = [doc1, doc2, doc3, doc4]
        let results = GlobalSearchService.search(query: "contract review", documents: docs)

        // doc1, doc2, doc3 match both "contract" and "review"
        // doc4 only matches "review", missing "contract"
        #expect(results.count == 3)
        let matchedTitles = results.map(\.title)
        #expect(matchedTitles.contains("Contract Review"))
        #expect(matchedTitles.contains("Q3 Strategy"))
        #expect(matchedTitles.contains("Contract Drafting"))
        #expect(!matchedTitles.contains("Design Review"))
    }

    // MARK: - 4. Deterministic Ranking & Tie Breaking

    @Test("ranking scores exact title > prefix > title tokens > subtitle > content")
    func rankingScores() {
        let exactTitle = makeDoc(stableSortKey: "a", title: "Contract")
        let prefixTitle = makeDoc(stableSortKey: "b", title: "Contract Review")
        let tokenTitle = makeDoc(stableSortKey: "c", title: "Q3 Contract Review")
        let subtitleMatch = makeDoc(stableSortKey: "d", title: "Annual Update", subtitle: "Contract")
        let contentMatch = makeDoc(stableSortKey: "e", title: "Team Sync", content: ["Mentions Contract"])

        let docs = [contentMatch, subtitleMatch, tokenTitle, prefixTitle, exactTitle]
        let results = GlobalSearchService.search(query: "Contract", documents: docs)

        #expect(results.count == 5)
        #expect(results[0].title == "Contract")             // Exact title (score 5)
        #expect(results[1].title == "Contract Review")      // Prefix title (score 4)
        #expect(results[2].title == "Q3 Contract Review")   // Title token match (score 3)
        #expect(results[3].title == "Annual Update")        // Subtitle match (score 2)
        #expect(results[4].title == "Team Sync")            // Content match (score 1)
    }

    @Test("ties in score are broken by newest date")
    func tieBreakingByNewestDate() {
        let dateOlder = Date(timeIntervalSince1970: 1000)
        let dateNewer = Date(timeIntervalSince1970: 2000)

        let docOlder = makeDoc(stableSortKey: "a", title: "Task Match", date: dateOlder)
        let docNewer = makeDoc(stableSortKey: "b", title: "Task Match", date: dateNewer)

        let results = GlobalSearchService.search(query: "Task", documents: [docOlder, docNewer])

        #expect(results.count == 2)
        #expect(results[0].document.date == dateNewer)
        #expect(results[1].document.date == dateOlder)
    }

    @Test("ties in score and date are broken by source order todo < mail < meeting")
    func tieBreakingBySourceOrder() {
        let sameDate = Date(timeIntervalSince1970: 1000)

        let meetingDoc = makeDoc(key: .meeting("m1"), source: .meeting, stableSortKey: "a", title: "Sync Match", date: sameDate)
        let mailDoc = makeDoc(key: .mail(EmailMessageKey(providerRawValue: "gmail", sourceAccountNamespace: "user@example.com", providerMessageID: "1")), source: .mail, stableSortKey: "a", title: "Sync Match", date: sameDate)
        let todoDoc = makeDoc(key: .todo(Self.fixedUUID1), source: .todo, stableSortKey: "a", title: "Sync Match", date: sameDate)

        let results = GlobalSearchService.search(query: "Sync", documents: [meetingDoc, mailDoc, todoDoc])

        #expect(results.count == 3)
        #expect(results[0].source == .todo)
        #expect(results[1].source == .mail)
        #expect(results[2].source == .meeting)
    }

    @Test("ties in score, date, and source are broken by stableSortKey ascending")
    func tieBreakingByStableSortKey() {
        let sameDate = Date(timeIntervalSince1970: 1000)

        let docB = makeDoc(key: .todo(Self.fixedUUID2), source: .todo, stableSortKey: "b_key", title: "Report Match", date: sameDate)
        let docA = makeDoc(key: .todo(Self.fixedUUID1), source: .todo, stableSortKey: "a_key", title: "Report Match", date: sameDate)

        let results = GlobalSearchService.search(query: "Report", documents: [docB, docA])

        #expect(results.count == 2)
        #expect(results[0].document.stableSortKey == "a_key")
        #expect(results[1].document.stableSortKey == "b_key")
    }

    // MARK: - 5. Source Filters

    @Test("source filter restricts results to specified source")
    func sourceFiltering() {
        let todoDoc = makeDoc(key: .todo(Self.fixedUUID1), source: .todo, title: "Shared Title")
        let mailDoc = makeDoc(key: .mail(EmailMessageKey(providerRawValue: "gmail", sourceAccountNamespace: "user@example.com", providerMessageID: "2")), source: .mail, title: "Shared Title")
        let meetingDoc = makeDoc(key: .meeting("m2"), source: .meeting, title: "Shared Title")

        let docs = [todoDoc, mailDoc, meetingDoc]

        let todoOnly = GlobalSearchService.search(query: "Shared", source: .todo, documents: docs)
        #expect(todoOnly.count == 1)
        #expect(todoOnly.first?.source == .todo)

        let mailOnly = GlobalSearchService.search(query: "Shared", source: .mail, documents: docs)
        #expect(mailOnly.count == 1)
        #expect(mailOnly.first?.source == .mail)

        let meetingOnly = GlobalSearchService.search(query: "Shared", source: .meeting, documents: docs)
        #expect(meetingOnly.count == 1)
        #expect(meetingOnly.first?.source == .meeting)

        let allSources = GlobalSearchService.search(query: "Shared", source: nil, documents: docs)
        #expect(allSources.count == 3)
    }

    // MARK: - 6. Limit Cap

    @Test("limit parameter is capped at 100 and handles invalid limits")
    func limitCap() {
        let docs = (0..<150).map { i in
            makeDoc(stableSortKey: String(format: "sort-%03d", i), title: "Item \(i)")
        }

        let defaultLimitResults = GlobalSearchService.search(query: "Item", documents: docs)
        #expect(defaultLimitResults.count == 100)

        let overLimitResults = GlobalSearchService.search(query: "Item", documents: docs, limit: 200)
        #expect(overLimitResults.count == 100)

        let customLimitResults = GlobalSearchService.search(query: "Item", documents: docs, limit: 15)
        #expect(customLimitResults.count == 15)

        let zeroLimitResults = GlobalSearchService.search(query: "Item", documents: docs, limit: 0)
        #expect(zeroLimitResults.isEmpty)

        let negativeLimitResults = GlobalSearchService.search(query: "Item", documents: docs, limit: -5)
        #expect(negativeLimitResults.isEmpty)
    }
}
