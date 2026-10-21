import SwiftUI
import SwiftData

struct GlobalSearchResultsView: View {
    let appContainer: ModelContainer
    let emailContainer: ModelContainer
    let meetingContainer: ModelContainer
    let mailAccess: MailboxCachedProviderAccess?

    @Binding var searchText: String
    @State private var selectedSource: GlobalSearchSource? = nil
    @State private var isSearching = false
    @State private var documents: [GlobalSearchDocument] = []
    @State private var results: [GlobalSearchResult] = []
    @State private var searchTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            scopeFilterChips
                .padding(.vertical, AppTheme.Spacing.item)
                .background(AppTheme.canvas)

            contentArea
        }
        .appScreenStyle()
        .onChange(of: searchText) { _, _ in
            scheduleSearch()
        }
        .onChange(of: selectedSource) { _, _ in
            scheduleSearch()
        }
        .onChange(of: mailAccess) { _, newAccess in
            if newAccess == nil && selectedSource == .mail {
                selectedSource = nil
            }
            Task {
                await loadCorpusAndSearch()
            }
        }
        .task {
            await loadCorpusAndSearch()
        }
        .onDisappear {
            searchTask?.cancel()
            isSearching = false
        }
    }

    @ViewBuilder
    private var scopeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                scopeChip(titleKey: "search.scope.all", defaultTitle: "전체", source: nil, accessibilityID: "search.scope.all")

                scopeChip(titleKey: "search.scope.todo", defaultTitle: "할 일", source: .todo, accessibilityID: "search.scope.todo")

                if mailAccess != nil {
                    scopeChip(titleKey: "search.scope.mail", defaultTitle: "메일", source: .mail, accessibilityID: "search.scope.mail")
                }

                scopeChip(titleKey: "search.scope.meeting", defaultTitle: "회의", source: .meeting, accessibilityID: "search.scope.meeting")
            }
            .padding(.horizontal)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func scopeChip(
        titleKey: String,
        defaultTitle: String,
        source: GlobalSearchSource?,
        accessibilityID: String
    ) -> some View {
        let isSelected = (selectedSource == source)
        let title = AppLanguage.localized(titleKey, defaultValue: defaultTitle, language: .current, comment: "Scope chip title.")

        return Button {
            selectedSource = source
        } label: {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(
                    isSelected ? AppTheme.neutralFill : AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                )
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var contentArea: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if isSearching {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text(AppLanguage.localized("search.loading", defaultValue: "검색 중...", language: .current, comment: "Search loading."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.canvas)
        } else if trimmed.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(AppLanguage.localized("search.prompt", defaultValue: "할 일, 메일, 회의 검색", language: .current, comment: "Search prompt."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.canvas)
        } else if results.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(AppLanguage.localized("search.empty.title", defaultValue: "검색 결과 없음", language: .current, comment: "Search empty title."))
                    .font(.headline)
                Text(AppLanguage.localized("search.empty.message", defaultValue: "다른 검색어나 카테고리로 검색해보세요.", language: .current, comment: "Search empty message."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.canvas)
        } else {
            List {
                if let selectedSource {
                    Section {
                        forEachResults(results.filter { $0.source == selectedSource })
                    }
                } else {
                    let todoResults = results.filter { $0.source == .todo }
                    let mailResults = results.filter { $0.source == .mail }
                    let meetingResults = results.filter { $0.source == .meeting }

                    if !todoResults.isEmpty {
                        Section(header: Text(AppLanguage.localized("search.scope.todo", defaultValue: "할 일", language: .current, comment: "Todo section header."))) {
                            forEachResults(todoResults)
                        }
                    }

                    if !mailResults.isEmpty && mailAccess != nil {
                        Section(header: Text(AppLanguage.localized("search.scope.mail", defaultValue: "메일", language: .current, comment: "Mail section header."))) {
                            forEachResults(mailResults)
                        }
                    }

                    if !meetingResults.isEmpty {
                        Section(header: Text(AppLanguage.localized("search.scope.meeting", defaultValue: "회의", language: .current, comment: "Meeting section header."))) {
                            forEachResults(meetingResults)
                        }
                    }
                }
            }
            .appListStyle()
            .refreshable {
                await loadCorpusAndSearch()
            }
        }
    }

    private func forEachResults(_ list: [GlobalSearchResult]) -> some View {
        ForEach(list) { result in
            NavigationLink {
                destinationView(for: result.key)
            } label: {
                resultRow(result)
            }
            .accessibilityIdentifier("search.result.\(result.source.rawValue)")
        }
    }

    private func resultRow(_ result: GlobalSearchResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            HStack {
                Text(result.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer()
                Text(result.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !result.subtitle.isEmpty {
                Text(result.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, AppTheme.Spacing.compact)
    }

    @ViewBuilder
    private func destinationView(for key: GlobalSearchRecordKey) -> some View {
        if let resolved = try? GlobalSearchCorpusBuilder.resolve(
            key,
            appContainer: appContainer,
            emailContainer: emailContainer,
            meetingContainer: meetingContainer,
            mailAccess: mailAccess
        ) {
            switch resolved {
            case .todo(let todo):
                TodoDetailView(todo: todo)
                    .modelContainer(appContainer)
            case .mail(let mail):
                MailDetailView(email: mail)
                    .modelContainer(emailContainer)
            case .meeting(let meeting):
                MeetingDetailView(meeting: meeting)
                    .modelContainer(meetingContainer)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(AppLanguage.localized("search.result.unavailable", defaultValue: "이 항목은 더 이상 사용할 수 없습니다.", language: .current, comment: "Search result unavailable."))
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .task {
                await loadCorpusAndSearch()
            }
        }
    }

    private func loadCorpusAndSearch() async {
        searchTask?.cancel()
        searchTask = nil
        do {
            let docs = try GlobalSearchCorpusBuilder.build(
                appContainer: appContainer,
                emailContainer: emailContainer,
                meetingContainer: meetingContainer,
                mailAccess: mailAccess
            )
            self.documents = docs
            scheduleSearch(debounceNanoseconds: 0)
        } catch {
            searchTask?.cancel()
            searchTask = nil
            self.documents = []
            self.results = []
            self.isSearching = false
        }
    }

    private func scheduleSearch(debounceNanoseconds: UInt64 = 250_000_000) {
        searchTask?.cancel()
        let query = searchText
        let source = selectedSource
        let docs = documents

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }

            let searchResults = await Task.detached(priority: .userInitiated) {
                GlobalSearchService.search(
                    query: query,
                    source: source,
                    documents: docs
                )
            }.value

            guard !Task.isCancelled else { return }
            results = searchResults
            isSearching = false
        }
    }

}
