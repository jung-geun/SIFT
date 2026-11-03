import SwiftUI

/// Version selection is explicit: opening a comparison never chooses or writes a version.
struct ICloudConflictReviewView: View {
    @ObservedObject var sync: FullCloudSyncService
    @State private var failure: String?
    @State private var reviewing = false
    @State private var retainedReview: CloudSyncConflict?
    @State private var loaded = false
    @State private var refreshing = false

    var body: some View {
        List {
            Section {
                Text(CloudConflictCopy.text("intro", "Compare the versions and select the one to use. Other items continue syncing. All compared versions are saved on this device before a change is applied.", "버전을 비교하고 사용할 내용을 선택하세요. 다른 항목은 계속 동기화됩니다. 변경을 적용하기 전에 비교한 모든 버전을 이 기기에 보관합니다."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if loaded && failure == nil && sync.conflicts.isEmpty {
                    Text(CloudConflictCopy.text("empty", "No unresolved conflicts", "해결되지 않은 충돌이 없습니다"))
                }
                if refreshing { ProgressView() }
                ForEach(sync.conflicts) { conflict in
                    NavigationLink {
                        ICloudConflictDetailView(sync: sync, conflict: conflict)
                    } label: {
                        conflictLabel(conflict)
                    }
                    .accessibilityIdentifier("settings.sync.conflict.item.\(conflict.id)")
                }
            } header: {
                Text(CloudConflictCopy.text("pending", "Needs your choice", "선택이 필요한 항목"))
            }
            if !sync.retainedConflicts.isEmpty {
                Section {
                    ForEach(Array(sync.retainedConflicts.enumerated()), id: \.element.id) { index, conflict in
                        Button {
                            reviewing = true
                            Task { @MainActor in
                                defer { reviewing = false }
                                do { retainedReview = try await sync.reviewRetainedConflict(conflict) }
                                catch { failure = CloudConflictCopy.message(error) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                conflictLabel(conflict)
                                Text(CloudConflictCopy.text("historyRecord", "Saved comparison", "보관 기록") + " "
                                     + (sync.retainedConflicts.count - index).formatted(.number.locale(AppLanguage.current.locale)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .disabled(reviewing || sync.synchronizing)
                        .accessibilityIdentifier("settings.sync.conflict.retained.\(conflict.id)")
                    }
                } header: {
                    Text(CloudConflictCopy.text("retained", "Saved versions", "보관한 버전"))
                } footer: {
                    Text(CloudConflictCopy.text("retainedHelp", "Review saved versions against the current item to restore a different version. This history is kept on this device, not confirmed as an iCloud backup.", "보관한 버전과 현재 항목을 비교하여 다른 버전으로 복원할 수 있습니다. 이 기록은 이 기기에 보관되며 iCloud 백업 완료를 의미하지 않습니다."))
                }
            }
            if reviewing { ProgressView() }
            if let failure {
                Section { Text(failure).foregroundStyle(.red).accessibilityIdentifier("settings.sync.conflict.error") }
            }
        }
        .appFormStyle()
        .navigationTitle(CloudConflictCopy.text("title", "Sync conflicts", "동기화 충돌"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { retainedReview != nil },
            set: { if !$0 { retainedReview = nil } }
        )) {
            if let conflict = retainedReview {
                ICloudConflictDetailView(sync: sync, conflict: conflict)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label(CloudConflictCopy.text("refresh", "Refresh", "새로 고침"), systemImage: "arrow.clockwise")
                }
                .disabled(sync.synchronizing || reviewing || refreshing)
                .accessibilityIdentifier("settings.sync.conflict.refresh")
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; loaded = true }
        do {
            try await sync.refreshConflicts()
            failure = nil
        } catch { failure = CloudConflictCopy.message(error) }
    }

    private func conflictLabel(_ conflict: CloudSyncConflict) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: conflict.contentTitle ?? CloudConflictCopy.entity(conflict.entity)).foregroundStyle(.primary)
            Text(CloudConflictCopy.entity(conflict.entity)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ICloudConflictDetailView: View {
    @ObservedObject var sync: FullCloudSyncService
    let conflict: CloudSyncConflict
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var showAllFields = false
    @State private var confirmSelection = false
    @State private var applying = false
    @State private var failure: String?

    private var fieldNames: [String] {
        Set(conflict.versions.flatMap { $0.fields.map(\.name) }).sorted()
    }

    private var differingNames: Set<String> {
        Set(fieldNames.filter { name in
            Set(conflict.versions.map { version in
                version.fields.first(where: { $0.name == name })?.value
            }).count > 1
        })
    }

    var body: some View {
        let differences = differingNames
        List {
            Section {
                Text(verbatim: conflict.contentTitle ?? CloudConflictCopy.entity(conflict.entity)).font(.headline).textSelection(.enabled)
                Text(CloudConflictCopy.text("chooseHelp", "Select one complete version. Only that version becomes the synced item; all compared versions remain available in Saved versions. Nothing changes until you apply your choice.", "항목 전체에 적용할 버전 하나를 선택하세요. 선택한 버전으로 동기화하고 비교한 버전은 모두 ‘보관한 버전’에 남깁니다. 선택을 적용하기 전까지는 변경하지 않습니다."))
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle(CloudConflictCopy.text("allFields", "Show all fields", "모든 필드 보기"), isOn: $showAllFields)
                    .accessibilityIdentifier("settings.sync.conflict.allFields")
            }
            ForEach(Array(conflict.versions.enumerated()), id: \.element.id) { index, version in
                Section {
                    Button {
                        selectedID = version.id
                        failure = nil
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: selectedID == version.id ? "checkmark.circle.fill" : "circle")
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(CloudConflictCopy.text("version", "Version", "버전") + " \(index + 1)")
                                    .font(.headline)
                                Text(CloudConflictCopy.origin(version.origin)).font(.subheadline).foregroundStyle(.secondary)
                                if let date = version.modifiedAt {
                                    Text(date, format: .dateTime.year().month().day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(applying || (conflict.entity == "MeetingRecord" && version.payload == nil))
                    .accessibilityAddTraits(selectedID == version.id ? .isSelected : [])
                    .accessibilityIdentifier("settings.sync.conflict.version.\(index)")
                    if version.payload == nil {
                        if conflict.entity == "MeetingRecord" {
                            Text(CloudConflictCopy.dependentContentMessage).font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Label(CloudConflictCopy.text("deleted", "Deleted version — applying this removes the current item", "삭제된 버전 — 적용하면 현재 항목을 삭제합니다"), systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                    }
                    ForEach(version.fields.filter { showAllFields || differences.contains($0.name) }) { field in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(CloudConflictCopy.field(field.name)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(verbatim: CloudConflictCopy.value(field)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Section {
                if let failure {
                    Text(failure).foregroundStyle(.red).accessibilityIdentifier("settings.sync.conflict.error")
                }
                Button {
                    confirmSelection = true
                } label: {
                    Text(CloudConflictCopy.text("apply", "Apply selected version", "선택한 버전 적용"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(selectedID == nil || applying || sync.synchronizing)
                .accessibilityIdentifier("settings.sync.conflict.apply")
                if applying { ProgressView() }
            } footer: {
                Text(CloudConflictCopy.text("staleHelp", "If this item changes while you review it, applying stops so you can compare the latest versions again.", "비교 중 항목이 바뀌면 적용을 중지합니다. 최신 버전을 다시 확인하고 선택해 주세요."))
            }
        }
        .appFormStyle()
        .navigationTitle(CloudConflictCopy.text("compare", "Compare versions", "버전 비교"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(CloudConflictCopy.text("confirm", "Use the selected version?", "선택한 버전을 사용할까요?"), isPresented: $confirmSelection, titleVisibility: .visible) {
            Button(CloudConflictCopy.text("apply", "Apply selected version", "선택한 버전 적용"), role: conflict.versions.first(where: { $0.id == selectedID })?.payload == nil ? .destructive : nil) {
                guard let selectedID else { return }
                applying = true
                Task { @MainActor in
                    defer { applying = false }
                    do {
                        try await sync.resolveConflict(conflict, selecting: selectedID)
                        dismiss()
                    } catch { failure = CloudConflictCopy.message(error) }
                }
            }
            .accessibilityIdentifier("settings.sync.conflict.confirm")
            Button(CloudConflictCopy.text("cancel", "Cancel", "취소"), role: .cancel) {}
        } message: {
            Text(CloudConflictCopy.text("confirmHelp", "The selected version will be used for this item on synced devices. All compared versions are saved on this device first.", "동기화하는 기기에서 이 항목에 선택한 버전을 사용합니다. 먼저 비교한 모든 버전을 이 기기에 보관합니다."))
        }
        .interactiveDismissDisabled(applying)
    }
}

enum CloudConflictCopy {
    static var dependentContentMessage: String {
        text("error.dependentContent", "A deleted meeting version cannot be applied here because its original audio cannot be restored from this record alone. Choose a version that keeps the meeting; use the meeting list to delete it explicitly.", "삭제된 회의 버전은 이 기록만으로 원음을 복원할 수 없어 여기서 적용하지 않습니다. 회의를 보존할 버전을 선택하세요. 회의 삭제는 회의 목록에서 직접 할 수 있습니다.")
    }

    static func text(_ suffix: String, _ english: String, _ korean: String) -> String {
        AppLanguage.localized("settings.sync.conflict." + suffix,
            defaultValue: AppLanguage.current == .korean ? korean : english, language: .current,
            comment: "Review and explicitly resolve iCloud data conflicts without losing compared versions.")
    }

    static func origin(_ origin: CloudSyncConflictVersion.Origin) -> String {
        switch origin {
        case .local: text("origin.local", "This device", "이 기기")
        case .legacy: text("origin.legacy", "Earlier iCloud data", "이전 iCloud 데이터")
        case .cloud: text("origin.cloud", "iCloud version", "iCloud 버전")
        case .retained: text("origin.retained", "Saved version", "보관한 버전")
        }
    }

    static func entity(_ name: String) -> String {
        switch name {
        case "Todo": text("entity.todo", "Task", "할 일")
        case "EmailMessage": text("entity.email", "Email", "메일")
        case "MeetingRecord": text("entity.meeting", "Meeting", "회의")
        default: text("entity.other", "Other app data", "기타 앱 데이터")
        }
    }

    static func field(_ name: String) -> String {
        switch name {
        case "title", "subject": text("field.title", "Title", "제목")
        case "content", "body", "bodyText": text("field.content", "Content", "내용")
        case "notes": text("field.notes", "Notes", "메모")
        case "status": text("field.status", "Status", "상태")
        case "dueDate": text("field.dueDate", "Due date", "마감일")
        case "createdAt": text("field.createdAt", "Created", "생성 일시")
        case "updatedAt", "modifiedAt": text("field.updatedAt", "Updated", "수정 일시")
        default: name
        }
    }

    private static let dateFields: Set<String> = [
        "createdAt", "updatedAt", "modifiedAt", "receivedAt", "occurredAt", "observedAt",
        "dueDate", "startDate", "completedAt", "deletedAt"
    ]

    static func value(_ field: CloudSyncConflictField) -> String {
        // CloudModelCodec uses JSONEncoder's Date representation. Do not
        // reinterpret user text such as \"null\" or \"true\" as metadata.
        guard dateFields.contains(field.name), let seconds = Double(field.value), seconds.isFinite else {
            return field.value
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
            .formatted(Date.FormatStyle(date: .numeric, time: .standard).locale(AppLanguage.current.locale))
    }

    static func message(_ error: Error) -> String {
        guard let error = error as? CloudSyncConflictError else {
            return text("error.save", "Could not apply the selection. Saved originals are retained. Return to the list, refresh, and try again.", "선택을 적용하지 못했습니다. 보관한 원본은 유지됩니다. 목록으로 돌아가 새로 고친 후 다시 시도하세요.")
        }
        switch error {
        case .staleSelection, .versionUnavailable:
            return text("error.stale", "The item changed or this version is no longer available. Return to the list and refresh before selecting again.", "항목이 변경되었거나 해당 버전을 사용할 수 없습니다. 목록으로 돌아가 새로 고친 후 다시 선택하세요.")
        case .busy:
            return text("error.busy", "Sync is in progress. Wait for it to finish, then try again.", "동기화 중입니다. 완료된 후 다시 시도하세요.")
        case .recordingActive:
            return text("error.recording", "Stop the recording before resolving conflicts. The original data is retained.", "녹음을 끝낸 후 충돌을 해결하세요. 원본 데이터는 유지됩니다.")
        case .dependentContentUnavailable:
            return dependentContentMessage
        case .syncUnavailable:
            return text("error.unavailable", "iCloud sync is not ready. Check the sync status and try again; local data is retained.", "iCloud 동기화가 준비되지 않았습니다. 동기화 상태를 확인한 후 다시 시도하세요. 기기 데이터는 유지됩니다.")
        }
    }
}
