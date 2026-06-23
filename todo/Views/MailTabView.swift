import SwiftUI
import SwiftData

// MARK: - MailTabView

struct MailTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \EmailMessage.receivedAt, order: .reverse)
    private var emails: [EmailMessage]

    @State private var isRefreshing = false
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var selectedEmail: EmailMessage?
    @State private var isAuthenticated = false

    var body: some View {
        NavigationStack {
            Group {
                if !isAuthenticated {
                    notConnectedView
                } else if emails.isEmpty && !isRefreshing {
                    emptyView
                } else {
                    mailList
                }
            }
            .navigationTitle("메일")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if isRefreshing {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .refreshable {
                await syncEmails()
            }
            .sheet(item: $selectedEmail) { email in
                MailDetailView(email: email)
                    .modelContainer(modelContext.container)
            }
            .alert("Gmail 연결 오류", isPresented: $showError) {
                Button("확인") {}
            } message: {
                if let msg = errorMessage { Text(msg) }
            }
        }
        .task {
            isAuthenticated = EmailService.shared.isAuthenticated
            if emails.isEmpty && isAuthenticated {
                await syncEmails()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gmailAuthChanged)) { note in
            let connected = note.object as? Bool ?? EmailService.shared.isAuthenticated
            isAuthenticated = connected
            if connected {
                Task { await syncEmails() }
            }
        }
    }

    // MARK: - Placeholder Views

    private var notConnectedView: some View {
        ContentUnavailableView {
            Label("Gmail 미연결", systemImage: "envelope.badge.shield.half.filled")
        } description: {
            Text("Gmail 계정을 연결하면\n최근 메일을 이 앱에서 바로 읽을 수 있습니다.")
        } actions: {
            Button {
                Task { await connectGmail() }
            } label: {
                if isConnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Gmail 연결", systemImage: "plus.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isConnecting)
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("메일 없음", systemImage: "envelope.open")
        } description: {
            Text("당겨서 새로고침하면 최근 메일을 불러옵니다.")
        }
    }

    // MARK: - Mail List

    private var mailList: some View {
        List {
            ForEach(emails) { email in
                Button {
                    selectedEmail = email
                } label: {
                    MailMessageRow(email: email)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteEmails)
        }
        .listStyle(.plain)
    }

    // MARK: - Actions

    @MainActor
    private func connectGmail() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await EmailService.shared.authenticate()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    @MainActor
    private func syncEmails() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let messages = try await EmailService.shared.fetchAllRecentMessages()
            let existing = (try? modelContext.fetch(FetchDescriptor<EmailMessage>())) ?? []
            let existingIDs = Set(existing.map { $0.id })
            var count = 0
            for msg in messages where !existingIDs.contains(msg.id) {
                let em = EmailMessage(
                    id: msg.id,
                    threadID: msg.threadID,
                    subject: msg.subject,
                    from: msg.from,
                    snippet: msg.snippet,
                    body: msg.body,
                    receivedAt: msg.receivedAt
                )
                modelContext.insert(em)
                count += 1
            }
            if count > 0 { try? modelContext.save() }
        } catch EmailError.notAuthenticated {
            // refresh token 만료 → 로컬 인증 상태 갱신 후 재연결 안내 표시
            isAuthenticated = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEmails(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(emails[index])
        }
        try? modelContext.save()
    }
}

// MARK: - MailMessageRow

struct MailMessageRow: View {
    let email: EmailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(senderName)
                    .font(.subheadline)
                    .fontWeight(email.isRead ? .regular : .semibold)
                    .lineLimit(1)
                Spacer()
                Text(email.receivedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(email.subject.isEmpty ? "(제목 없음)" : email.subject)
                .font(.body)
                .fontWeight(email.isRead ? .regular : .medium)
                .lineLimit(1)
            Text(email.snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .foregroundStyle(email.isRead ? .secondary : .primary)
    }

    private var senderName: String {
        let from = email.from
        if let nameEnd = from.firstIndex(of: "<") {
            return String(from[from.startIndex..<nameEnd])
                .trimmingCharacters(in: .whitespaces)
        }
        return from.isEmpty ? "(발신자 없음)" : from
    }
}

// MARK: - MailDetailView

struct MailDetailView: View {
    let email: EmailMessage
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 헤더
                    VStack(alignment: .leading, spacing: 6) {
                        Text(email.subject.isEmpty ? "(제목 없음)" : email.subject)
                            .font(.title3)
                            .fontWeight(.semibold)

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(email.from)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(email.receivedAt.formatted(
                                .dateTime.month(.abbreviated).day().hour().minute()
                            ))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding()

                    Divider()

                    // 본문
                    let bodyText = email.body.isEmpty ? email.snippet : email.body
                    if bodyText.isEmpty {
                        Text("(본문 없음)")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .padding()
                    } else {
                        Text(bodyText)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
            .navigationTitle("메일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .onAppear {
                if !email.isRead {
                    email.isRead = true
                    try? modelContext.save()
                }
            }
        }
    }
}
