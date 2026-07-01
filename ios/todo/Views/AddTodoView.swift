import SwiftUI
import SwiftData

struct AddTodoView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTutorialState) private var tutorial
    @Query private var todos: [Todo]
    @Query(sort: \Persona.updatedAt, order: .reverse) private var personas: [Persona]

    // MARK: - State

    @State private var title = ""
    @State private var notes = ""
    @State private var hasDueDate = false
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var selectedPriority: TodoPriority?
    @State private var selectedReminderPresets: Set<Double> = []
    @State private var tagsText = ""

    // 캘린더 등록
    @State private var registerToCalendar = false
    @State private var selectedCalendarID = ""
    @State private var calendarSources: [CalendarService.CalendarSourceGroup] = []

    @FocusState private var isTitleFocused: Bool

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // 제목 (필수)
                Section {
                    TextField("제목 (필수)", text: $title)
                        .focused($isTitleFocused)
                        .font(.body)
                    TextField("메모 (선택)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // 마감 일정
                Section("마감 일정") {
                    Toggle(isOn: $hasDueDate.animation()) {
                        Label("마감 시각 설정", systemImage: "calendar.badge.clock")
                    }

                    if hasDueDate {
                        DatePicker(
                            "마감",
                            selection: $dueDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.graphical)
                    }
                }

                // 캘린더 등록 — 마감 일정 설정 시에만 표시, 기본 ON
                if hasDueDate && CalendarService.shared.isAuthorized {
                    Section("캘린더 등록") {
                        Toggle(isOn: $registerToCalendar.animation()) {
                            Label("캘린더에 등록", systemImage: "calendar.badge.plus")
                        }
                        if registerToCalendar, !calendarSources.isEmpty {
                            Picker("캘린더", selection: $selectedCalendarID) {
                                ForEach(calendarSources) { source in
                                    ForEach(source.calendars) { calInfo in
                                        Text(calInfo.title).tag(calInfo.id)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }

                // 우선순위
                Section("우선순위 (선택)") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button {
                                selectedPriority = nil
                            } label: {
                                Text("자동")
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        selectedPriority == nil
                                            ? Color.accentColor.opacity(0.15)
                                            : Color.secondary.opacity(0.08),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(selectedPriority == nil ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)

                            ForEach(TodoPriority.allCases, id: \.rawValue) { p in
                                Button {
                                    selectedPriority = (selectedPriority == p) ? nil : p
                                } label: {
                                    Text(p.label)
                                        .font(.subheadline)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(
                                            selectedPriority == p
                                                ? Color.accentColor.opacity(0.15)
                                                : Color.secondary.opacity(0.08),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(selectedPriority == p ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // 알림 (마감 설정 시)
                if hasDueDate {
                    Section("알림") {
                        ForEach(NotificationService.presetOffsets, id: \.offset) { preset in
                            Toggle(isOn: Binding(
                                get: { selectedReminderPresets.contains(preset.offset) },
                                set: { on in
                                    if on { selectedReminderPresets.insert(preset.offset) }
                                    else  { selectedReminderPresets.remove(preset.offset) }
                                }
                            )) {
                                Text(preset.label)
                                    .font(.subheadline)
                            }
                        }
                    }
                }

                // 태그
                Section("태그 (쉼표로 구분)") {
                    TextField("예: 업무, 마감, 학습", text: $tagsText)
                        .font(.subheadline)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("새 할 일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") { addTodo() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { isTitleFocused = true }
            .onChange(of: hasDueDate) { _, newValue in
                // 마감 시각을 설정하면 캘린더 등록을 자동으로 켬
                if newValue && CalendarService.shared.isAuthorized {
                    registerToCalendar = true
                }
            }
            .task {
                calendarSources = CalendarService.shared.availableCalendars()
                // 기본 캘린더 설정값 → 없으면 첫 번째 캘린더
                let defaultID = CalendarService.shared.defaultCalendarID
                if !defaultID.isEmpty {
                    selectedCalendarID = defaultID
                } else {
                    selectedCalendarID = calendarSources.first?.calendars.first?.id ?? ""
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 12) {
            if let tutorial, let hint = tutorial.hint(for: .addTodo) {
                AppTutorialHintCard(hint: hint)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    // MARK: - Action

    private func addTodo() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let offsets = Array(selectedReminderPresets)

        let todo = Todo(
            title: trimmedTitle,
            notes: notes.trimmingCharacters(in: .whitespaces),
            dueDate: hasDueDate ? dueDate : nil,
            source: .manual,
            tags: tags,
            reminderOffsets: offsets
        )

        if let p = selectedPriority {
            todo.manualPriority = p.rawValue
        }

        modelContext.insert(todo)

        // 캘린더 등록 처리
        if registerToCalendar && hasDueDate && CalendarService.shared.isAuthorized {
            let calID = selectedCalendarID.isEmpty ? nil : selectedCalendarID
            if let eventID = try? CalendarService.shared.registerOrUpdate(
                todo: todo, preferredCalendarID: calID
            ) {
                todo.calendarEventID = eventID
            }
        } else if !hasDueDate {
            // 마감 없는 경우 자동 등록 정책 적용
            CalendarService.shared.applyAutoRegistration(for: todo)
        }

        // 알림 등록
        if hasDueDate && !offsets.isEmpty {
            Task {
                await NotificationService.shared.update(todo: todo)
            }
        }

        // 수동 추가 즉시 온디바이스 AFM 약한 정렬 (비차단, ANE 실행)
        // 수동 우선순위 지정 시 QuickSortService.analyzeOnAdd 내부 guard에서 자동 생략
        let ctx = PersonaContext(
            types: personas.first?.personaTypes ?? [],
            description: personas.first?.descriptionText ?? ""
        )
        Task { await QuickSortService.analyzeOnAdd(todo, persona: ctx) }

        dismiss()
    }
}

#Preview {
    AddTodoView()
        .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
}
