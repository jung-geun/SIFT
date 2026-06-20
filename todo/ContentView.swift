// ContentView.swift
// 앱 루트 뷰는 todoApp.swift에서 TodoListView()를 직접 사용합니다.
// 이 파일은 SwiftUI Preview 등 보조 목적으로 유지됩니다.

import SwiftUI
import SwiftData

/// SwiftUI Preview 진입점 — 앱 실제 루트는 todoApp.swift의 WindowGroup 참조.
struct ContentView: View {
    var body: some View {
        TodoListView()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
}
