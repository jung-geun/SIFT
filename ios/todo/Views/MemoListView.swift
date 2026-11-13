import SwiftData
import SwiftUI

/// Raw memo list. Memos stay as typed; only approved suggestions become Todos.
struct MemoListView: View {
    let existingTodoTitles: [String]
    let onRegister: ([String]) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Memo.updatedAt, order: .reverse) private var memos: [Memo]
    @State private var path: [Memo] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if memos.isEmpty {
                    ContentUnavailableView(
                        AppLanguage.localized("memo.list.empty.title", defaultValue: "메모가 없습니다", language: .current, comment: "Empty memo list title."),
                        systemImage: "note.text",
                        description: Text(AppLanguage.localized("memo.list.empty.description", defaultValue: "회의 내용이나 정리할 생각을 자유롭게 적어 보세요.", language: .current, comment: "Empty memo list description."))
                    )
                } else {
                    List {
                        ForEach(memos) { memo in
                            NavigationLink(value: memo) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(memo.text.isEmpty
                                        ? AppLanguage.localized("memo.list.untitled", defaultValue: "빈 메모", language: .current, comment: "Placeholder for an empty memo.")
                                        : memo.text)
                                        .lineLimit(2)
                                    Text(memo.updatedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { modelContext.delete(memos[index]) }
                            try? modelContext.save()
                        }
                    }
                }
            }
            .navigationTitle(AppLanguage.localized("memo.list.title", defaultValue: "메모", language: .current, comment: "Memo list title."))
            .navigationDestination(for: Memo.self) { memo in
                MemoEditorView(memo: memo, existingTodoTitles: existingTodoTitles, onRegister: onRegister)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized("action.close", defaultValue: "닫기", language: .current, comment: "Close action.")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        let memo = Memo()
                        modelContext.insert(memo)
                        path.append(memo)
                    } label: {
                        Label(
                            AppLanguage.localized("memo.list.new", defaultValue: "새 메모", language: .current, comment: "Create memo button."),
                            systemImage: "square.and.pencil"
                        )
                    }
                    .accessibilityIdentifier("memo.newButton")
                }
            }
        }
    }
}

/// Edits one memo and asks the on-device model for candidate tasks on demand.
struct MemoEditorView: View {
    @Bindable var memo: Memo
    let existingTodoTitles: [String]
    let onRegister: ([String]) -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var isExtracting = false
    @State private var suggestions: [MemoSuggestion] = []
    @State private var showSuggestions = false
    @State private var extractionError: String?

    var body: some View {
        TextEditor(text: $memo.text)
            .padding(.horizontal, 12)
            .navigationTitle(AppLanguage.localized("memo.editor.title", defaultValue: "메모", language: .current, comment: "Memo editor title."))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: memo.text) { _, _ in memo.updatedAt = Date() }
            .onDisappear { try? modelContext.save() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await extract() }
                    } label: {
                        if isExtracting {
                            ProgressView()
                        } else {
                            Text(AppLanguage.localized("memo.editor.suggest", defaultValue: "할 일 추천", language: .current, comment: "Ask the model for task suggestions from the memo."))
                        }
                    }
                    .disabled(isExtracting || memo.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("memo.suggestButton")
                }
            }
            .sheet(isPresented: $showSuggestions) {
                MemoSuggestionSheet(suggestions: $suggestions) { titles in
                    onRegister(titles)
                    showSuggestions = false
                }
            }
            .alert(
                AppLanguage.localized("memo.editor.error.title", defaultValue: "추천 실패", language: .current, comment: "Memo suggestion error title."),
                isPresented: Binding(get: { extractionError != nil }, set: { if !$0 { extractionError = nil } })
            ) {
                Button(AppLanguage.localized("action.confirm", defaultValue: "확인", language: .current, comment: "Dismiss alert.")) { extractionError = nil }
            } message: {
                Text(extractionError ?? "")
            }
    }

    private func extract() async {
        isExtracting = true
        defer { isExtracting = false }
        do {
            let titles = try await MemoTaskExtractionService().suggest(from: memo.text)
            suggestions = titles.map { title in
                MemoSuggestion(
                    title: title,
                    isDuplicate: MemoTaskExtraction.isDuplicate(title, of: existingTodoTitles)
                )
            }
            if suggestions.isEmpty {
                extractionError = AppLanguage.localized("memo.editor.error.none", defaultValue: "메모에서 실행할 일을 찾지 못했습니다.", language: .current, comment: "No memo tasks found.")
            } else {
                showSuggestions = true
            }
        } catch MemoTaskExtractionError.unavailable {
            extractionError = AppLanguage.localized("memo.editor.error.unavailable", defaultValue: "이 기기에서 온디바이스 AI를 사용할 수 없어 추천을 만들지 않았습니다.", language: .current, comment: "Memo extraction unavailable.")
        } catch MemoTaskExtractionError.timedOut {
            extractionError = AppLanguage.localized("memo.editor.error.timeout", defaultValue: "분석 시간이 초과되었습니다. 다시 시도해 주세요.", language: .current, comment: "Memo extraction timed out.")
        } catch {
            extractionError = AppLanguage.localized("memo.editor.error.invalid", defaultValue: "추천 결과를 읽을 수 없습니다. 다시 시도해 주세요.", language: .current, comment: "Memo extraction response invalid.")
        }
    }
}

struct MemoSuggestion: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let isDuplicate: Bool
    var isSelected: Bool

    init(title: String, isDuplicate: Bool) {
        self.title = title
        self.isDuplicate = isDuplicate
        self.isSelected = !isDuplicate
    }
}

/// Approval step: nothing becomes a Todo until the user confirms selected rows.
private struct MemoSuggestionSheet: View {
    @Binding var suggestions: [MemoSuggestion]
    let onConfirm: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach($suggestions) { $suggestion in
                    Toggle(isOn: $suggestion.isSelected) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                            if suggestion.isDuplicate {
                                Text(AppLanguage.localized("memo.suggestion.duplicate", defaultValue: "이미 등록된 할 일", language: .current, comment: "Suggested task already exists."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(suggestion.isDuplicate)
                }
            }
            .navigationTitle(AppLanguage.localized("memo.suggestion.title", defaultValue: "추천 할 일", language: .current, comment: "Memo task suggestion sheet title."))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.localized("action.cancel", defaultValue: "취소", language: .current, comment: "Cancel action.")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLanguage.localized("memo.suggestion.register", defaultValue: "등록", language: .current, comment: "Register approved suggestions.")) {
                        let titles = suggestions.filter { $0.isSelected && !$0.isDuplicate }.map(\.title)
                        onConfirm(titles)
                    }
                    .disabled(!suggestions.contains { $0.isSelected && !$0.isDuplicate })
                }
            }
        }
    }
}
