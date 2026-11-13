import Testing
@testable import todo

@Suite("Todo list tag filter")
@MainActor
struct TodoTagFilterTests {
    @Test("A nil tag keeps every todo, including untagged ones")
    func nilTagKeepsAll() {
        let tagged = Todo(title: "a", tags: ["afterglow"])
        let untagged = Todo(title: "b")
        let result = TodoListView.applyingTag(nil, to: [tagged, untagged])
        #expect(result.map(\.id) == [tagged.id, untagged.id])
    }

    @Test("A selected tag keeps only exact matches")
    func selectedTagMatchesExactly() {
        let match = Todo(title: "dash", tags: ["afterglow", "ui"])
        let other = Todo(title: "other", tags: ["afterglow-old"])
        let none = Todo(title: "none")
        let result = TodoListView.applyingTag("afterglow", to: [match, other, none])
        #expect(result.map(\.id) == [match.id])
    }
}
