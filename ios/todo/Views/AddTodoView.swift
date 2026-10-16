import SwiftUI
import SwiftData

struct AddTodoView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTutorialState) private var tutorial
    @Environment(\.userVocabulary) private var userVocabulary
    @Environment(\.verticalSizeClass) private var verticalSizeClass
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

    // Save only after an explicit tap; dismissing a draft never creates a task.
    @State private var hasSaved = false
    @State private var isSaving = false
    @State private var showSaveError = false
    @State private var showCalendarError = false
    @State private var showMoreOptions = false
    private enum Field: Hashable {
        case title, notes, tags
    }
    @FocusState private var focusedField: Field?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // 제목 (필수)
                Section {
                    TextField("제목 (필수)", text: $title)
                        .accessibilityIdentifier("todo.add.titleField")
                        .focused($focusedField, equals: .title)
                        .font(.body)
                        .appTutorialGlow(tutorial?.currentStep == .addTodoTitle)
                    TextField("메모 (선택)", text: $notes, axis: .vertical)
                        .accessibilityIdentifier("todo.add.notesField")
                        .focused($focusedField, equals: .notes)
                        .lineLimit(2...5)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .appTutorialGlow(tutorial?.currentStep == .addTodoTitle)
                }

                // 마감 일정
                Section("마감 일정") {
                    Toggle(isOn: $hasDueDate.animation()) {
                        Label("마감 시각 설정", systemImage: "calendar.badge.clock")
                    }
                    .appTutorialGlow(tutorial?.currentStep == .addTodoDueDate)
                    .accessibilityIdentifier("todo.add.dueDateToggle")

                    if hasDueDate {
                        DatePicker(
                            "마감",
                            selection: $dueDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.compact)
                        .appTutorialGlow(tutorial?.currentStep == .addTodoDueDate)
                    }
                }

                // Secondary controls stay available without obscuring title and deadline.
                Section {
                    DisclosureGroup(isExpanded: $showMoreOptions) {
                        if hasDueDate && CalendarService.shared.isAuthorized {
                            Toggle(
                                AppLanguage.localized("todo.add.calendarNow", defaultValue: "지금 캘린더에 등록", language: .current, comment: "Create an event immediately for the new task."),
                                isOn: $registerToCalendar
                            )
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
                            Text(AppLanguage.localized("todo.add.calendarSyncNote", defaultValue: "마감이 있으면 나중에 캘린더 동기화 과정에서 자동 등록될 수 있습니다.", language: .current, comment: "A separate calendar sync may later create an event for a due task."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("우선순위 (선택)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Button {
                                    selectedPriority = nil
                                    tutorial?.handleAddTodoPriorityReviewed()
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
                                .accessibilityIdentifier("todo.add.priority.automatic")

                                ForEach(TodoPriority.allCases, id: \.rawValue) { priority in
                                    Button {
                                        selectedPriority = (selectedPriority == priority) ? nil : priority
                                        tutorial?.handleAddTodoPriorityReviewed()
                                    } label: {
                                        Text(priority.label)
                                            .font(.subheadline)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                selectedPriority == priority
                                                    ? Color.accentColor.opacity(0.15)
                                                    : Color.secondary.opacity(0.08),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(selectedPriority == priority ? Color.accentColor : Color.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("todo.add.priority.\(priority.rawValue)")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .appTutorialGlow(tutorial?.currentStep == .addTodoPriority)

                        if hasDueDate {
                            Text("알림")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
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
                                .accessibilityIdentifier("todo.add.reminder.\(Int(preset.offset))")
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("태그 (쉼표로 구분)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField("예: 업무, 마감, 학습", text: $tagsText)
                                .accessibilityIdentifier("todo.add.tagsField")
                                .focused($focusedField, equals: .tags)
                                .font(.subheadline)
                                .autocorrectionDisabled()
                        }
                    } label: {
                        Label(
                            AppLanguage.localized(
                                "todo.add.moreOptions",
                                defaultValue: "추가 옵션",
                                language: .current,
                                comment: "Expandable advanced task fields."
                            ),
                            systemImage: "slider.horizontal.3"
                        )
                        .accessibilityIdentifier("todo.add.moreOptions")
                    }
                }
            }
            .accessibilityIdentifier("todo.add.form")
            .scrollDismissesKeyboard(.interactively)
            // The Form must own this inset so its scrollable viewport excludes Save,
            // including when the keyboard reduces the navigation content's safe area.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if tutorial?.isActive != true && verticalSizeClass != .compact {
                        Button {
                            Task { await addTodo() }
                        } label: {
                            Text(AppLanguage.localized("todo.add.saveAction", defaultValue: "할 일 저장", language: .current, comment: "Primary action to save a manually entered to-do."))
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 14)
                                .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSave)
                        .opacity(canSave ? 1 : 0.5)
                        .accessibilityIdentifier("todo.add.saveButton")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    }
                    if let tutorial {
                        AppTutorialTipHost(tutorial: tutorial, screen: .addTodo)
                    }
                }
            }
            .navigationTitle("새 할 일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                        .accessibilityIdentifier("todo.add.cancelButton")
                }
                if tutorial?.isActive == true || verticalSizeClass == .compact {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await addTodo() }
                        } label: {
                            Text("추가")
                                .fontWeight(.semibold)
                                .appTutorialGlow(tutorial?.currentStep == .addTodoSave)
                        }
                        .disabled(!canSave)
                        .accessibilityIdentifier("todo.add.saveButton")
                    }
                }
                if focusedField != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { focusedField = nil } label: {
                            Label("완료", systemImage: "keyboard.chevron.compact.down")
                        }
                        .accessibilityIdentifier("todo.add.dismissKeyboard")
                    }
                }
            }
            .onAppear {
                focusedField = .title
                showMoreOptions = tutorial?.currentStep == .addTodoPriority
                updateAddTodoTutorialFromText()
            }
            .onChange(of: title) { _, _ in
                updateAddTodoTutorialFromText()
            }
            .onChange(of: notes) { _, _ in
                updateAddTodoTutorialFromText()
            }
            .onChange(of: hasDueDate) { _, newValue in
                if !newValue { registerToCalendar = false }
                tutorial?.handleAddTodoDueDateEnabled(newValue)
                if tutorial?.currentStep == .addTodoPriority { showMoreOptions = true }
            }
            .onChange(of: tutorial?.currentStep) { _, newStep in
                if newStep == .addTodoPriority { showMoreOptions = true }
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
        .alert(
            AppLanguage.localized("todo.add.saveError.title", defaultValue: "저장 실패", language: .current, comment: "Manual to-do save failure title."),
            isPresented: $showSaveError
        ) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(AppLanguage.localized("todo.add.saveError.message", defaultValue: "할 일을 저장하지 못했습니다. 다시 시도해 주세요.", language: .current, comment: "Manual to-do save failure with retry available."))
        }
        .alert(
            AppLanguage.localized("todo.add.calendarError.title", defaultValue: "캘린더 등록 실패", language: .current, comment: "Calendar creation failure after saving a manual to-do."),
            isPresented: $showCalendarError
        ) {
            Button("확인") { dismiss() }
        } message: {
            Text(AppLanguage.localized("todo.add.calendarError.message", defaultValue: "할 일은 저장했지만 캘린더 일정은 만들지 못했습니다.", language: .current, comment: "Task was saved, but optional calendar event failed."))
        }
    }

    // MARK: - Action

    private var canSave: Bool {
        !isSaving && !hasSaved && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateAddTodoTutorialFromText() {
        tutorial?.handleAddTodoTextChanged(title: title, notes: notes)
    }

    private func addTodo() async {
        guard !hasSaved && !isSaving else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }

        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let offsets = hasDueDate ? Array(selectedReminderPresets) : []

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
        TaskBehaviorRecorder.recordCreation(of: todo, actor: .user, in: modelContext)

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            DiagnosticRecorder.shared.record(error: error, component: "todo.add", operation: "save")
            showSaveError = true
            return
        }
        hasSaved = true

        if hasDueDate && !offsets.isEmpty {
            Task { await NotificationService.shared.update(todo: todo) }
        }

        // Saving the to-do does not depend on optional EventKit access.
        if registerToCalendar && hasDueDate && CalendarService.shared.isAuthorized {
            let calID = selectedCalendarID.isEmpty ? nil : selectedCalendarID
            do {
                if let eventID = try CalendarService.shared.registerOrUpdate(
                    todo: todo, preferredCalendarID: calID
                ) {
                    todo.calendarEventID = eventID
                    try modelContext.save()
                } else {
                    showCalendarError = true
                }
            } catch {
                if let eventID = todo.calendarEventID {
                    _ = try? CalendarService.shared.removeEvent(eventID: eventID)
                }
                modelContext.rollback()
                DiagnosticRecorder.shared.record(error: error, component: "todo.add", operation: "calendar")
                showCalendarError = true
            }
        }

        if let observer = userVocabulary?.observer {
            let document = VocabularySourceDocumentBuilder.todo(todo)
            Task { await observer.observeDocument(document, false) }
        }

        // 수동 추가 즉시 온디바이스 AFM 약한 정렬 (비차단, ANE 실행)
        // 수동 우선순위 지정 시 QuickSortService.analyzeOnAdd 내부 guard에서 자동 생략
        let ctx = PersonaContext(
            types: personas.first?.personaTypes ?? [],
            description: personas.first?.descriptionText ?? ""
        )
        Task { await QuickSortService.analyzeOnAdd(todo, persona: ctx, context: modelContext) }

        if !showCalendarError { dismiss() }
    }
}

#Preview {
    AddTodoView()
        .modelContainer(for: [Todo.self, Persona.self], inMemory: true)
}
