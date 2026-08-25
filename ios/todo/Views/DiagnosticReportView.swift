import MessageUI
import UniformTypeIdentifiers
import SwiftUI


private struct PendingDiagnostic {
    let error: Error
    let component: String
    let operation: String
}
struct DiagnosticExportRequest: Identifiable, Equatable {
    enum Destination: String, Equatable {
        case mail
        case share
    }

    let id: UUID
    let data: Data
    let fileURL: URL?
    /// Only diagnostics recorded no later than this report are acknowledged
    /// after a successful user delivery.
    let generatedAt: Date
    let metricPayloads: [String]
    let metricPayloadIDs: [UUID]
    let destination: Destination

    init(
        data: Data,
        fileURL: URL?,
        canSendMail: Bool,
        generatedAt: Date = Date(),
        metricPayloads: [String] = [],
        metricPayloadIDs: [UUID] = [],
        id: UUID = UUID()
    ) {
        self.id = id
        self.data = data
        self.fileURL = fileURL
        self.generatedAt = generatedAt
        self.metricPayloads = metricPayloads
        self.metricPayloadIDs = metricPayloadIDs
        destination = canSendMail ? .mail : .share
    }
}

struct DiagnosticReportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var diagnostics = DiagnosticReportService.shared
    @State private var activeExport: DiagnosticExportRequest?
    @State private var isPreparingReport = false
    @State private var pendingDiagnostic: PendingDiagnostic?
    private let presentsPendingDiagnostic: Bool
    private let showsCloseButton: Bool

    init(
        pendingError: Error? = nil,
        component: String = "meeting.capture",
        operation: String = "userReportedFailure",
        showsCloseButton: Bool = false
    ) {
        _pendingDiagnostic = State(initialValue: pendingError.map {
            PendingDiagnostic(error: $0, component: component, operation: operation)
        })
        presentsPendingDiagnostic = pendingError != nil
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        Form {
            if presentsPendingDiagnostic {
                Section {
                    Text(copy(
                        "diagnostics.recovery.detail",
                        korean: "이전 앱 세션이 예기치 않게 종료된 것으로 감지되었습니다. 진단 로그 수집을 허용하면 이 종료 사실만 포함한 최소 보고서를 이 기기에 만들 수 있습니다. 앱은 사용자의 동의 없이 정보를 전송하지 않습니다.",
                        english: "The previous app session appears to have ended unexpectedly. Allow diagnostic collection to create a minimal on-device report about this event. The app never sends information without your consent."
                    ))
                } header: {
                    Text(copy(
                        "diagnostics.recovery.title",
                        korean: "이전 세션 복구",
                        english: "Previous session recovery"
                    ))
                }
            }
            Section {
                Toggle(
                    copy(
                        "diagnostics.collection.toggle",
                        korean: "진단 로그 수집 허용",
                        english: "Allow diagnostic log collection"
                    ),
                    isOn: Binding(
                        get: { diagnostics.collectionEnabled },
                        set: { enabled in
                            diagnostics.setCollectionEnabled(enabled)
                            if !enabled {
                                Self.removeTemporaryReport()
                            }
                            recordPendingDiagnosticIfConsented()
                            diagnostics.prepareReport()
                        }
                    )
                )
                .accessibilityIdentifier("diagnostics.collectionToggle")
                .disabled(isPreparingReport)
                Text(copy(
                    "diagnostics.collection.detail",
                    korean: "동의한 경우에만 오류 발생 시각·위치·소스 줄 번호, 오류 코드·메시지, 기기 사양과 설정 상태, 최근 앱 오류 로그, 앱·OS 버전과 Apple 시스템 진단을 이 기기에 보관합니다. 음성 녹음, 전사문, TODO, 이메일 내용, 계정 정보는 포함하지 않습니다.",
                    english: "Only with your consent, error timestamps, locations, and source line numbers, error codes and messages, device specs and setting states, recent app error logs, app and OS versions, and Apple system diagnostics are kept on this device. Recordings, transcripts, to-dos, email content, and account information are excluded."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text(copy("diagnostics.collection.title", korean: "진단 및 개인정보", english: "Diagnostics and privacy"))
            }

            if diagnostics.collectionEnabled {
                Section {
                    LabeledContent(copy("diagnostics.events", korean: "로컬 오류 이벤트", english: "Local error events")) {
                        Text("\(diagnostics.eventCount)")
                    }
                    LabeledContent(copy("diagnostics.system", korean: "Apple 시스템 진단", english: "Apple system diagnostics")) {
                        Text("\(diagnostics.metricPayloadCount)")
                    }
                    Button(role: .destructive) {
                        diagnostics.clearLocalReports()
                        Self.removeTemporaryReport()
                    } label: {
                        Label(copy("diagnostics.clear", korean: "기기에 저장된 진단 로그 삭제", english: "Delete diagnostic logs on this device"), systemImage: "trash")
                    }
                    .disabled(!diagnostics.hasShareableReport)
                } header: {
                    Text(copy("diagnostics.stored.title", korean: "기기에 저장됨", english: "Stored on this device"))
                } footer: {
                    Text(copy(
                        "diagnostics.metricKit.detail",
                        korean: "Apple 시스템 진단은 충돌, 멈춤, 메모리 종료 등을 나중에 전달할 수 있습니다. 즉시 전달되거나 모든 강제 종료가 포착되는 것은 아닙니다.",
                        english: "Apple system diagnostics can later report crashes, hangs, and memory terminations. Delivery isn’t immediate in every case, and not every forced termination is captured."
                    ))
                }

                Section {
                    Button {
                        Task { await beginReport() }
                    } label: {
                        if isPreparingReport {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(copy(
                                    "diagnostics.preparing",
                                    korean: "보고서를 준비하는 중…",
                                    english: "Preparing report…"
                                ))
                            }
                        } else {
                            Label(copy("diagnostics.send", korean: "오류 보고서 보내기", english: "Send error report"), systemImage: "envelope")
                        }
                    }
                    .disabled(!diagnostics.hasShareableReport || isPreparingReport)
                    .accessibilityIdentifier("diagnostics.sendButton")

                    if !MFMailComposeViewController.canSendMail() {
                        Text(copy(
                            "diagnostics.mail.unavailable",
                            korean: "이 기기에서 메일을 보낼 수 없어 공유 시트로 보고서를 내보냅니다.",
                            english: "Mail can’t be sent from this device, so the report opens in the share sheet."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(copy("diagnostics.send.title", korean: "지원팀에 보내기", english: "Send to support"))
                } footer: {
                    Text(copy(
                        "diagnostics.send.detail",
                        korean: "보내기를 누르면 보고서를 검토할 수 있습니다. 앱은 동의 없이 로그를 네트워크로 전송하지 않습니다.",
                        english: "Selecting Send lets you review the report first. The app never transmits logs without your consent."
                    ))
                }
            }
        }
        .navigationTitle(copy("diagnostics.title", korean: "오류 보고", english: "Error Reports"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recordPendingDiagnosticIfConsented()
            diagnostics.prepareReport()
        }
        .toolbar {
            if showsCloseButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(copy("action.close", korean: "닫기", english: "Close")) {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $activeExport) { export in
            switch export.destination {
            case .mail:
                DiagnosticMailComposer(
                    recipients: [DiagnosticReportService.supportEmail],
                    subject: copy("diagnostics.mail.subject", korean: "SIFT 오류 보고", english: "SIFT Error Report"),
                    body: copy("diagnostics.mail.body", korean: "아래 첨부 파일에는 사용자가 동의한 진단 정보만 포함됩니다.", english: "The attached file contains only diagnostics you consented to share."),
                    attachment: export.data,
                    onFinish: { delivered in
                        finishExport(export, delivered: delivered)
                    }
                )
            case .share:
                DiagnosticShareSheet(
                    items: [export.fileURL as Any? ?? DiagnosticReportItemSource(data: export.data)],
                    onFinish: { delivered in
                        if let fileURL = export.fileURL {
                            Self.removeTemporaryReport(at: fileURL)
                        }
                        finishExport(export, delivered: delivered)
                    }
                )
            }
        }
    }

    private func beginReport() async {
        guard !isPreparingReport else { return }
        isPreparingReport = true
        defer { isPreparingReport = false }
        guard let report = await diagnostics.prepareAttachment(), diagnostics.collectionEnabled else {
            return
        }
        let canSendMail = MFMailComposeViewController.canSendMail()
        let fileURL = canSendMail ? nil : try? await Self.writeTemporaryReport(report.data)
        guard diagnostics.collectionEnabled else {
            if let fileURL {
                Self.removeTemporaryReport(at: fileURL)
            }
            diagnostics.discardPreparedReport()
            return
        }
        activeExport = DiagnosticExportRequest(
            data: report.data,
            fileURL: fileURL,
            canSendMail: canSendMail,
            generatedAt: report.generatedAt,
            metricPayloads: report.metricPayloads,
            metricPayloadIDs: report.metricPayloadIDs
        )
    }

    private func finishExport(_ export: DiagnosticExportRequest, delivered: Bool) {
        if delivered {
            diagnostics.acknowledgeDeliveredReport(
                .init(
                    data: export.data,
                    generatedAt: export.generatedAt,
                    metricPayloads: export.metricPayloads,
                    metricPayloadIDs: export.metricPayloadIDs
                )
            )
        } else {
            diagnostics.discardPreparedReport()
        }
        activeExport = nil
    }

    private static var temporaryReportURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sift-diagnostic-report.json")
    }

    private static func writeTemporaryReport(_ data: Data) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sift-diagnostic-report.json")
            do {
                try data.write(
                    to: url,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                var protectedURL = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try protectedURL.setResourceValues(values)
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }.value
    }

    private static func removeTemporaryReport(at url: URL = temporaryReportURL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func recordPendingDiagnosticIfConsented() {
        guard diagnostics.collectionEnabled, let pendingDiagnostic else { return }
        DiagnosticRecorder.shared.record(
            error: pendingDiagnostic.error,
            component: pendingDiagnostic.component,
            operation: pendingDiagnostic.operation
        )
        self.pendingDiagnostic = nil
    }


    private func copy(_ key: String, korean: String, english: String) -> String {
        AppLanguage.localized(
            key,
            defaultValue: AppLanguage.current == .english ? english : korean,
            language: .current,
            comment: "User-consented diagnostic reporting UI."
        )
    }
}

private struct DiagnosticMailComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    let attachment: Data
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.view.accessibilityIdentifier = "diagnostics.mailComposer"
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients(recipients)
        composer.setSubject(subject)
        composer.setMessageBody(body, isHTML: false)
        composer.addAttachmentData(attachment, mimeType: "application/json", fileName: "sift-diagnostic-report.json")
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish(result == .sent && error == nil)
        }
    }
}

private final class DiagnosticReportItemSource: NSObject, UIActivityItemSource {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        data
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        data
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        UTType.json.identifier
    }
}

private struct DiagnosticShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.view.accessibilityIdentifier = "diagnostics.shareSheet"
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onFinish(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
