import SwiftUI

struct VocabularyDetailView: View {
    @Environment(\.userVocabulary) private var vocabulary
    @State private var terms: [VocabularyTermSummary] = []
    @State private var query = ""
    @State private var newCanonical = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("새 단어") {
                TextField("정규 표기", text: $newCanonical)
                Button("추가") { addManual() }
                    .disabled(newCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vocabulary == nil)
            }
            section("승격됨", terms.filter(\.isPromoted))
            section("검토 필요", terms.filter { !$0.isPromoted && !$0.isRejected })
            section("거절됨", terms.filter(\.isRejected))
        }
        .searchable(text: $query)
        .navigationTitle("사용자 단어장")
        .task(id: query) { await reload() }
        .alert("단어장 오류", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ values: [VocabularyTermSummary]) -> some View {
        Section(title) {
            if values.isEmpty {
                Text("없음").foregroundStyle(.secondary)
            }
            ForEach(values, id: \.canonicalKey) { term in
                VStack(alignment: .leading, spacing: 4) {
                    Text(term.canonical).font(.headline)
                    Text(term.category.rawValue).font(.caption).foregroundStyle(.secondary)
                    if !term.aliases.isEmpty || !term.variants.isEmpty {
                        Text((term.aliases.map(\.value) + term.variants).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if term.isRejected {
                            Button("다시 학습 허용") { allowRelearning(term) }
                        } else if !term.isPromoted {
                            Button("확인") { confirm(term) }
                            Button("거절", role: .destructive) { reject(term) }
                        } else {
                            Button("거절", role: .destructive) { reject(term) }
                        }
                    }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func reload() async {
        guard let service = vocabulary?.service else { terms = []; return }
        do { terms = try await service.list(query: query) }
        catch { errorMessage = error.localizedDescription }
    }

    private func addManual() {
        guard let service = vocabulary?.service else { return }
        let canonical = newCanonical
        Task {
            do {
                try await service.addManual(.init(canonical: canonical))
                newCanonical = ""
                await reload()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func confirm(_ term: VocabularyTermSummary) { mutate { service in try await service.confirm(canonicalKey: term.canonicalKey) } }
    private func reject(_ term: VocabularyTermSummary) { mutate { service in try await service.reject(canonicalKey: term.canonicalKey) } }
    private func allowRelearning(_ term: VocabularyTermSummary) { mutate { service in try await service.allowRelearning(canonicalKey: term.canonicalKey) } }

    private func mutate(_ action: @escaping (UserVocabularyService) async throws -> Void) {
        guard let service = vocabulary?.service else { return }
        Task {
            do { try await action(service); await reload() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
