import SwiftUI
import SwiftData

struct TodoDetailView: View {
    @Bindable var todo: Todo
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showDatePicker = false
    @State private var showReminderPicker = false
    @State private var calendarError: String?
    @State private var isRegisteringCalendar = false
    @State private var showDeleteConfirm = false
    /// 앱 내 메일 상세 시트 — 로컬 EmailMessage가 있을 때 표시
    @State private var showingEmail: EmailMessage?

    // MARK: - Body

    var body: some View {
        Form {
            titleSection
            schedulingSection
            prioritySection
            remindersSection
            calendarSection
            tagSection
            metaSection
        }
        .listSectionSpacing(.compact)
        .navigationTitle(todo.title.isEmpty ? "새 할 일" : todo.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                completeButton
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("삭제", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        .alert("캘린더 오류", isPresented: .constant(calendarError != nil)) {
            Button("확인") { calendarError = nil }
        } message: {
            Text(calendarError ?? "")
        }
        .confirmationDialog("할일을 삭제하시겠습니까?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("삭제", role: .destructive) { deleteTodo() }
            Button("취소", role: .cancel) { }
        }
        .sheet(item: $showingEmail) { email in
            MailDetailView(email: email)
                .modelContainer(AppDataContainer.shared.emailContainer)
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        Section("제목 및 메모") {
            TextField("제목", text: Binding(
                get: { todo.title },
                set: { newVal in
                    todo.title = newVal
                    todo.updatedAt = Date()
                    if todo.calendarEventID != nil {
                        _ = try? CalendarService.shared.registerOrUpdate(todo: todo)
                    }
                }
            ))
                .font(.body)
            TextField("메모 (선택)", text: Binding(
                get: { todo.notes },
                set: { newVal in
                    todo.notes = newVal
                    todo.updatedAt = Date()
                    if todo.calendarEventID != nil {
                        _ = try? CalendarService.shared.registerOrUpdate(todo: todo)
                    }
                }
            ), axis: .vertical)
                .lineLimit(3...8)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var schedulingSection: some View {
        Section("마감 일정") {
            // Due date toggle + picker
            Toggle(isOn: Binding(
                get: { todo.dueDate != nil },
                set: { on in
                    if on {
                        todo.dueDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
                        todo.updatedAt = Date()
                        // 마감 첫 설정 시 자동 등록 정책 적용 (강제 우선순위 포함)
                        CalendarService.shared.applyAutoRegistration(for: todo)
                    } else {
                        if let eventID = todo.calendarEventID {
                            try? CalendarService.shared.removeEvent(eventID: eventID)
                            todo.calendarEventID = nil
                        }
                        todo.dueDate = nil
                        todo.reminderOffsets = []   // 마감 없으면 알림도 제거
                        todo.updatedAt = Date()
                        NotificationService.shared.cancel(todo: todo)
                    }
                }
            )) {
                Label("마감 시각 설정", systemImage: "calendar.badge.clock")
            }

            if let _ = todo.dueDate {
                DatePicker(
                    "마감",
                    selection: Binding(
                        get: { todo.dueDate ?? Date() },
                        set: { newDate in
                            todo.dueDate = newDate
                            todo.updatedAt = Date()
                            if todo.calendarEventID != nil {
                                _ = try? CalendarService.shared.registerOrUpdate(todo: todo)
                            } else {
                                CalendarService.shared.applyAutoRegistration(for: todo)
                            }
                            Task { await NotificationService.shared.update(todo: todo) }
                        }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)

                if todo.isOverdue {
                    Label("기한이 초과되었습니다", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var prioritySection: some View {
        Section("우선순위") {
            // 수동 우선순위
            HStack {
                Label("수동 우선순위", systemImage: "hand.raised")
                Spacer()
                if let p = todo.manualPriorityEnum {
                    Text(p.label)
                        .foregroundStyle(.secondary)
                }
                Menu {
                    Button("설정 안함") {
                        todo.manualPriority = nil
                        todo.updatedAt = Date()
                    }
                    Divider()
                    ForEach(TodoPriority.allCases, id: \.rawValue) { p in
                        Button {
                            todo.manualPriority = p.rawValue
                            todo.updatedAt = Date()
                            // 긴급/최우선 선택 시 강제 등록 (마감 있을 때만)
                            CalendarService.shared.applyAutoRegistration(for: todo)
                        } label: {
                            Label(p.label, systemImage: "flag")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .foregroundStyle(.secondary)
                }
            }

            // AI 자동 우선순위 표시
            if !todo.priorityReason.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("AI 우선순위", systemImage: "sparkles")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0f%%", todo.computedPriorityScore * 100))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(todo.priorityReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 22)
                    if !todo.aiDetail.isEmpty {
                        Text(todo.aiDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                    if let rec = todo.aiRecommendedTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text("추천 처리 시각: \(rec.formatted(.dateTime.month().day().hour().minute()))")
                        }
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .padding(.leading, 22)
                    }
                    if todo.aiNeedsNotification {
                        HStack(spacing: 4) {
                            Image(systemName: "bell.fill")
                            Text("알림 자동 설정됨")
                        }
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.leading, 22)
                    }
                    if todo.aiPersonaFit {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                            Text("페르소나 부합 항목")
                        }
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .padding(.leading, 22)
                    }
                    if todo.manualPriority != nil {
                        Text("수동 우선순위가 AI 점수를 덮어씁니다.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.leading, 22)
                    }
                }
            }
        }
    }

    private var remindersSection: some View {
        Section {
            if todo.dueDate == nil {
                Text("마감 시각을 설정해야 알림을 추가할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 현재 오프셋 목록
                ForEach(todo.reminderOffsets.sorted(), id: \.self) { offset in
                    HStack {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.orange)
                        Text(offsetLabel(offset))
                        Spacer()
                        Button(role: .destructive) {
                            removeOffset(offset)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 프리셋 추가 메뉴
                Menu {
                    ForEach(NotificationService.presetOffsets, id: \.offset) { preset in
                        if !todo.reminderOffsets.contains(preset.offset) {
                            Button(preset.label) { addOffset(preset.offset) }
                        }
                    }
                } label: {
                    Label("알림 추가", systemImage: "plus")
                }
            }
        } header: {
            Text("알림")
        } footer: {
            if !todo.reminderOffsets.isEmpty {
                Text("마감 기준 상대 시각으로 알림을 보냅니다.")
                    .font(.caption)
            }
        }
    }

    private var calendarSection: some View {
        Section("캘린더 연동") {
            if todo.dueDate == nil {
                Text("마감 시각을 설정해야 캘린더에 등록할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if CalendarService.shared.isAuthorized {
                Toggle(isOn: Binding(
                    get: { todo.calendarEventID != nil },
                    set: { on in
                        if on { registerCalendarEvent() }
                        else { unregisterCalendarEvent() }
                    }
                )) {
                    Label(
                        todo.calendarEventID != nil ? "캘린더에 등록됨" : "캘린더에 등록",
                        systemImage: "calendar"
                    )
                }
                .disabled(isRegisteringCalendar)

                if isRegisteringCalendar {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("등록 중…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Button {
                    Task {
                        await CalendarService.shared.requestAccess()
                    }
                } label: {
                    Label("캘린더 접근 허용", systemImage: "calendar.badge.exclamationmark")
                }
            }
        }
    }

    private var tagSection: some View {
        Section("태그") {
            TagEditorView(tags: $todo.tags)
        }
    }

    private var metaSection: some View {
        Section {
            LabeledContent("출처") {
                sourceBadge
            }
            if todo.isFixedSchedule {
                LabeledContent("유형") {
                    Label("고정 일정 (반복)", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.green)
                }
            }
            if todo.todoSource == .email {
                if !todo.sourceSender.isEmpty {
                    LabeledContent("발신자") {
                        Text(todo.sourceSender)
                            .foregroundStyle(.secondary)
                    }
                }
                if todo.todoSource == .email, !todo.sourceRef.isEmpty {
                    Button { openOriginalEmail() } label: {
                        Label("원본 메일 열기", systemImage: "arrow.up.right.square")
                            .foregroundStyle(.blue)
                    }
                }
            }
            LabeledContent("생성일") {
                Text(todo.createdAt, style: .date)
                    .foregroundStyle(.secondary)
            }
            if let completed = todo.completedAt {
                LabeledContent("완료일") {
                    Text(completed, style: .date)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
    }

    // MARK: - Helpers

    private var completeButton: some View {
        Button {
            withAnimation {
                todo.isCompleted.toggle()
                todo.completedAt = todo.isCompleted ? Date() : nil
                if todo.isCompleted {
                    NotificationService.shared.cancel(todo: todo)
                }
            }
        } label: {
            Label(
                todo.isCompleted ? "되돌리기" : "완료",
                systemImage: todo.isCompleted ? "arrow.uturn.left" : "checkmark.circle.fill"
            )
        }
        .tint(todo.isCompleted ? .orange : .green)
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch todo.todoSource {
        case .manual:
            Text("직접 입력").foregroundStyle(.secondary)
        case .email:
            Label("이메일", systemImage: "envelope.fill").foregroundStyle(.blue)
        case .calendar:
            Label("캘린더", systemImage: "calendar").foregroundStyle(.green)
        }
    }

    /// 원본 메일을 엽니다.
    /// 1순위: 로컬 EmailMessage 캐시 → 앱 내 MailDetailView 시트로 표시.
    /// 2순위: googlegmail:///cv={id} — Gmail 앱 딥링크.
    /// 3순위: message:// — Mail.app 딥링크.
    /// 4순위: Gmail 웹 URL 폴백.
    private func openOriginalEmail() {
        let ref = todo.sourceRef
        if !ref.isEmpty {
            let emailCtx = AppDataContainer.shared.emailContainer.mainContext
            let descriptor = FetchDescriptor<EmailMessage>(
                predicate: #Predicate { $0.id == ref }
            )
            if let found = try? emailCtx.fetch(descriptor).first {
                showingEmail = found
                return
            }
        }
        for url in mailDeepLinkCandidates() {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                return
            }
        }
    }

    private func mailDeepLinkCandidates() -> [URL] {
        var candidates: [URL] = []

        // 1순위 — googlegmail:///cv={id}/accountId=0 (슬래시 3개, 올바른 포맷)
        // cv = conversation-view 식별자. threadId 우선, 없으면 Gmail message.id(sourceRef).
        // accountId = Gmail 앱 계정 슬롯 인덱스. 슬롯 불명이므로 두 형식 모두 시도.
        // ⚠️ 실기기 검증: cv가 threadId인지 message.id인지, accountId 동작 확인 필요.
        let gmailCVID = todo.sourceThreadID.isEmpty ? todo.sourceRef : todo.sourceThreadID
        if !gmailCVID.isEmpty {
            if let url = URL(string: "googlegmail:///cv=\(gmailCVID)/accountId=0") {
                candidates.append(url)
            }
            if let url = URL(string: "googlegmail:///cv=\(gmailCVID)") {
                candidates.append(url)
            }
        }

        // 2순위 — message:// Mail.app 딥링크 (iOS 7+)
        // 전제조건: 동일 계정이 시스템 Mail.app에 추가·동기화돼 있어야 열림.
        if let url = messageDeepLink(from: todo.sourceMessageID) {
            candidates.append(url)
        }

        // 3순위 — Gmail 웹 threadId 직접 URL
        if !todo.sourceThreadID.isEmpty,
           let url = URL(string: "https://mail.google.com/mail/u/0/#all/\(todo.sourceThreadID)") {
            candidates.append(url)
        }

        // 4순위 — rfc822msgid 검색 URL
        if let url = todo.emailURL {
            candidates.append(url)
        }

        // 폴백 — Gmail 웹 받은편지함
        if let url = URL(string: "https://mail.google.com/mail/u/0/") {
            candidates.append(url)
        }

        return candidates
    }

    /// RFC822 Message-ID를 message:// URL로 변환.
    ///
    /// Message-ID 헤더는 보통 `<id@domain>` 형태로 꺾쇠를 포함한다.
    /// iOS Mail.app은 꺾쇠 포함 전체 값을 percent-encode한 URL을 기대한다.
    /// 이중 인코딩·꺾쇠 누락 시 Mail.app이 메시지를 찾지 못하므로 주의.
    private func messageDeepLink(from messageID: String) -> URL? {
        guard !messageID.isEmpty else { return nil }
        // 꺾쇠 정규화: 없으면 추가, 있으면 그대로
        let normalized = messageID.hasPrefix("<") && messageID.hasSuffix(">")
            ? messageID
            : "<\(messageID)>"
        // 영숫자 + 기본 안전문자만 허용 → <, >, @ 모두 인코딩 (NSHipster 검증 포맷)
        let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = normalized.addingPercentEncoding(withAllowedCharacters: allowedChars) else {
            return nil
        }
        return URL(string: "message://\(encoded)")
    }

    private func offsetLabel(_ offset: Double) -> String {
        let abs = Swift.abs(offset)
        switch abs {
        case ..<900:    return "마감 \(Int(abs / 60))분 전"
        case ..<3660:   return "마감 1시간 전"
        case ..<7260:   return "마감 2시간 전"
        case ..<21660:  return "마감 6시간 전"
        case ..<86460:  return "마감 하루 전"
        default:        return "마감 \(Int(abs / 86400))일 전"
        }
    }

    private func addOffset(_ offset: Double) {
        guard !todo.reminderOffsets.contains(offset) else { return }
        todo.reminderOffsets.append(offset)
        todo.updatedAt = Date()
        Task { await NotificationService.shared.update(todo: todo) }
    }

    private func removeOffset(_ offset: Double) {
        todo.reminderOffsets.removeAll { $0 == offset }
        todo.updatedAt = Date()
        Task { await NotificationService.shared.update(todo: todo) }
    }

    private func registerCalendarEvent() {
        isRegisteringCalendar = true
        do {
            if let eventID = try CalendarService.shared.registerOrUpdate(todo: todo) {
                todo.calendarEventID = eventID
            }
        } catch {
            calendarError = error.localizedDescription
        }
        isRegisteringCalendar = false
    }

    private func unregisterCalendarEvent() {
        guard let eventID = todo.calendarEventID else { return }
        try? CalendarService.shared.removeEvent(eventID: eventID)
        todo.calendarEventID = nil
    }

    private func deleteTodo() {
        // 대기열(review) 항목은 캘린더 이벤트 보존 — 태스크(todo)로 승격된 경우만 함께 삭제
        if todo.triage == .todo, let eventID = todo.calendarEventID {
            try? CalendarService.shared.removeEvent(eventID: eventID)
        }
        NotificationService.shared.cancel(todo: todo)
        modelContext.delete(todo)
        dismiss()
    }
}

// MARK: - Tag Editor

struct TagEditorView: View {
    @Binding var tags: [String]
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(tags) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1), in: Capsule())
                    Button(role: .destructive) {
                        tags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("태그 추가…", text: $newTag)
                    .font(.subheadline)
                    .onSubmit { addTag() }
                Button("추가", action: addTag)
                    .font(.caption)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !tags.contains(trimmed) else { return }
        tags.append(trimmed)
        newTag = ""
    }
}

// MARK: - Flow Layout (태그 래핑)

struct FlowLayout<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let content: (Data.Element) -> Content

    init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
    }

    var body: some View {
        // iOS 16+ Layout 프로토콜 활용
        _FlowLayout {
            ForEach(Array(data), id: \.self) { item in
                content(item)
            }
        }
    }
}

private struct _FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Todo.self, configurations: config)
    let todo = Todo(title: "디자인 시안 검토", notes: "클라이언트 미팅 전 확인", dueDate: Date().addingTimeInterval(3600))
    todo.computedPriorityScore = 0.85
    todo.priorityReason = "1시간 이내 마감"
    container.mainContext.insert(todo)
    return NavigationStack { TodoDetailView(todo: todo) }
        .modelContainer(container)
}
