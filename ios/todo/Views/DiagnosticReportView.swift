import SwiftUI


private struct PendingDiagnostic {
    let error: Error
    let component: String
    let operation: String
}
/// Both the readable highlights and complete text come from the attachment bytes,
/// never from a second environment sample or archive read.
struct DiagnosticReportPreview: Equatable {
    let text: String
    let app: DiagnosticAppInfo
    let device: DiagnosticDeviceInfo
    let events: [DiagnosticEvent]

    init?(data: Data) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let text = String(data: data, encoding: .utf8),
              let report = try? decoder.decode(UserDiagnosticReport.self, from: data) else {
            return nil
        }
        self.text = text
        app = report.app
        device = report.device
        events = report.events
    }
}

struct DiagnosticExportRequest: Identifiable, Equatable {
    let id: UUID
    let data: Data
    let preview: DiagnosticReportPreview?
    /// Only diagnostics captured in this exact report are acknowledged after receipt.
    let events: [DiagnosticEvent]
    let metricPayloads: [String]
    let metricPayloadIDs: [UUID]

    init(
        data: Data,
        events: [DiagnosticEvent],
        metricPayloads: [String] = [],
        metricPayloadIDs: [UUID] = [],
        id: UUID = UUID()
    ) {
        self.id = id
        self.data = data
        preview = DiagnosticReportPreview(data: data)
        self.events = events
        self.metricPayloads = metricPayloads
        self.metricPayloadIDs = metricPayloadIDs
    }
}

struct DiagnosticReportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var diagnostics = DiagnosticReportService.shared
    @State private var activeExport: DiagnosticExportRequest?
    @State private var isDeliveryPresented = false
    @State private var hasDeliveredDiagnostics = false
    @State private var isPreparingReport = false
    @State private var preparationTask: Task<Void, Never>?
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
                        korean: "이전 활성 세션이 일반적인 비활성 전환을 기록하지 못했습니다. 이는 충돌을 확정하지 않습니다. 진단 로그 수집을 허용하면 이 종료 징후만 포함한 최소 보고서를 이 기기에 만들 수 있습니다. 앱은 사용자의 동의 없이 정보를 전송하지 않습니다.",
                        english: "The previous active session did not record a normal deactivation. This does not confirm a crash. Allow diagnostic collection to create a minimal on-device report about this termination signal. The app never sends information without your consent."
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
                            recordPendingDiagnosticIfConsented()
                            diagnostics.prepareReport()
                        }
                    )
                )
                .accessibilityIdentifier("diagnostics.collectionToggle")
                .disabled(isPreparingReport || activeExport != nil)
                Text(copy(
                    "diagnostics.collection.detail",
                    korean: "동의한 경우에만 오류 발생 시각·반복 횟수, 소스 파일·줄 번호·함수, 오류 코드·메시지·하위 오류 사슬, 오류 당시 앱·OS 빌드와 실행 상태·기능 설정·언어/국가/지역·시간대·UTC 오프셋·달력·24시간 설정, 보고서 준비 시점의 기기 모델·사양·언어·지역·시간대, 최근 앱 오류 로그와 Apple 시스템 진단을 이 기기에 보관합니다. 국가/지역은 기기 언어 설정에서 파생하며 GPS 등 실제 위치, 음성 녹음, 전사문, TODO, 이메일 내용, 계정 정보는 포함하지 않습니다.",
                    english: "Only with your consent, this device keeps error timestamps and repeat counts; source file, line, and function; error codes, messages, and underlying errors; the app and OS build plus runtime state, feature settings, language, locale-derived country or region, time zone, UTC offset, calendar, and 24-hour setting at the error; device model, specifications, language, region, and time zone when the report is prepared; recent app error logs; and Apple system diagnostics. Country and region come from device locale settings. Physical or GPS location, recordings, transcripts, to-dos, email content, and account information are excluded."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    } label: {
                        Label(copy("diagnostics.clear", korean: "기기에 저장된 진단 로그 삭제", english: "Delete diagnostic logs on this device"), systemImage: "trash")
                    }
                    .disabled(!diagnostics.hasShareableReport || isPreparingReport || activeExport != nil)
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
                        guard preparationTask == nil else { return }
                        preparationTask = Task { await beginReport() }
                    } label: {
                        if isPreparingReport {
                            HStack(spacing: AppTheme.Spacing.compact) {
                                ProgressView().controlSize(.small)
                                Text(copy(
                                    "diagnostics.preparing",
                                    korean: "보고서를 준비하는 중…",
                                    english: "Preparing report…"
                                ))
                            }
                        } else {
                            Label(copy("diagnostics.send", korean: "오류 보고서 보내기", english: "Send error report"), systemImage: "paperplane")
                        }
                    }
                    .disabled(!diagnostics.hasShareableReport || isPreparingReport || activeExport != nil)
                    .accessibilityIdentifier("diagnostics.sendButton")

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
        .appFormStyle()
        .navigationTitle(copy("diagnostics.title", korean: "오류 보고", english: "Error Reports"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recordPendingDiagnosticIfConsented()
            diagnostics.prepareReport()
        }
        .onDisappear {
            preparationTask?.cancel()
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
        .onChange(of: diagnostics.collectionEnabled) { _, enabled in
            if !enabled, let export = activeExport {
                finishExport(export)
            }
        }
        .sheet(item: $activeExport, onDismiss: {
            // Covers an interactive dismissal of the local review as well.
            isDeliveryPresented = false
            if !hasDeliveredDiagnostics { diagnostics.discardPreparedReport() }
            hasDeliveredDiagnostics = false
        }) { export in
            reportReview(export)
                .interactiveDismissDisabled(isDeliveryPresented)
                .sheet(isPresented: $isDeliveryPresented, onDismiss: {
                    if let export = activeExport { finishExport(export) }
                }) {
                    NavigationStack {
                        FeedbackView(initialKind: .bug, diagnosticData: export.data, showsCloseButton: true) { _, includedDiagnostics in
                            guard includedDiagnostics, !hasDeliveredDiagnostics,
                                  activeExport?.id == export.id else { return }
                            diagnostics.acknowledgeDeliveredReport(.init(
                                data: export.data,
                                events: export.events,
                                metricPayloads: export.metricPayloads,
                                metricPayloadIDs: export.metricPayloadIDs
                            ))
                            hasDeliveredDiagnostics = true
                        }
                    }
                }
        }
    }

    private func reportReview(_ export: DiagnosticExportRequest) -> some View {
        NavigationStack {
            ScrollView {
                if let preview = export.preview {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
                        Text(copy(
                            "feedback.diagnostics.reviewDetail",
                            korean: "이 보고서는 아직 이 기기에만 있습니다. 전체 내용을 검토한 뒤 의견 작성을 계속하세요. 최종 전송을 승인할 때만 이 정확한 보고서를 SIFT 비공개 접수함으로 보냅니다. 로그인이나 메일 연결은 필요하지 않으며 취소하면 진단 로그는 유지됩니다.",
                            english: "This report is still only on this device. Review its complete contents before continuing to feedback. This exact report is sent to SIFT’s private inbox only when you approve the final submission. No login or email setup is required. Cancelling keeps your diagnostic logs."
                        ))

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                            Text(copy("diagnostics.review.device", korean: "보고서 준비 시점의 저장 공간 및 가동 시간", english: "Disk space and uptime at report preparation"))
                                .font(.headline)
                                .accessibilityIdentifier("diagnostics.preview.deviceSummary")
                            previewValue(copy("diagnostics.review.disk.total", korean: "전체 디스크 용량 (바이트)", english: "Total disk capacity (bytes)"), value: preview.device.totalDiskBytes.map { String($0) })
                            previewValue(copy("diagnostics.review.disk.available", korean: "중요 용도로 사용 가능한 디스크 용량 (바이트)", english: "Available disk capacity for important usage (bytes)"), value: preview.device.availableDiskBytes.map { String($0) })
                            previewValue(copy("diagnostics.review.uptime.system", korean: "시스템 가동 시간 (초)", english: "System uptime (seconds)"), value: String(preview.device.systemUptimeSeconds))
                            previewValue(copy("diagnostics.review.boot", korean: "시스템 부팅 시각 (Unix epoch 초)", english: "System boot time (Unix epoch seconds)"), value: preview.device.bootEpoch.map { String($0) })
                            previewValue(copy("diagnostics.review.uptime.app", korean: "앱 실행 경과 시간 (초)", english: "Elapsed app runtime (seconds)"), value: String(preview.app.processUptimeSeconds))
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                            Text(copy("diagnostics.review.events", korean: "보고서에 포함된 모든 오류 시점 스냅샷", english: "All event snapshots included in this report"))
                                .font(.headline)
                                .accessibilityIdentifier("diagnostics.preview.eventSnapshots")
                            ForEach(preview.events.indices, id: \.self) { index in
                                let event = preview.events[index]
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                                    Text("\(index + 1). \(event.component) / \(event.operation)")
                                        .font(.subheadline.weight(.medium))
                                    Text(event.timestamp.ISO8601Format())
                                    previewValue(copy("diagnostics.review.disk.available", korean: "중요 용도로 사용 가능한 디스크 용량 (바이트)", english: "Available disk capacity for important usage (bytes)"), value: event.runtime?.availableDiskBytes.map { String($0) })
                                    previewValue(copy("diagnostics.review.uptime.app", korean: "앱 실행 경과 시간 (초)", english: "Elapsed app runtime (seconds)"), value: event.runtime.map { String($0.processUptimeSeconds) })
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                            Text(copy("diagnostics.review.payload", korean: "공유될 전체 보고서 (정확한 JSON 원문)", english: "Complete report to be shared (exact JSON)"))
                                .font(.headline)
                            Text(preview.text)
                                .font(.system(.footnote, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("diagnostics.preview.payload")
                        }
                    }
                    .padding()
                }
            }
            .appScreenStyle()
            .navigationTitle(copy("diagnostics.review.title", korean: "오류 보고서 검토", english: "Review error report"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copy("diagnostics.review.cancel", korean: "취소", english: "Cancel")) {
                        finishExport(export)
                    }
                    .accessibilityIdentifier("diagnostics.preview.cancel")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard diagnostics.collectionEnabled, activeExport?.id == export.id,
                          export.preview != nil else {
                        finishExport(export)
                        return
                    }
                    isDeliveryPresented = true
                } label: {
                    Text(copy("feedback.diagnostics.continue", korean: "의견 작성 계속", english: "Continue to feedback"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!diagnostics.collectionEnabled || export.preview == nil || isDeliveryPresented)
                .accessibilityIdentifier("diagnostics.preview.continue")
                .padding()
                .background(.bar)
            }
        }
        .presentationDetents([.large])
    }

    private func previewValue(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value ?? copy("diagnostics.review.unavailable", korean: "사용 불가 — 보고서에 값이 없음", english: "Unavailable — no value in the report"))
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private func beginReport() async {
        guard !isPreparingReport, activeExport == nil, diagnostics.collectionEnabled else {
            preparationTask = nil
            return
        }
        isPreparingReport = true
        defer {
            isPreparingReport = false
            preparationTask = nil
        }
        guard let report = await diagnostics.prepareAttachment(), diagnostics.collectionEnabled,
              !Task.isCancelled else {
            diagnostics.discardPreparedReport()
            return
        }
        let export = DiagnosticExportRequest(
            data: report.data,
            events: report.events,
            metricPayloads: report.metricPayloads,
            metricPayloadIDs: report.metricPayloadIDs
        )
        guard export.preview != nil else {
            diagnostics.discardPreparedReport()
            return
        }
        activeExport = export
    }

    private func finishExport(_ export: DiagnosticExportRequest) {
        guard activeExport?.id == export.id else { return }
        if !hasDeliveredDiagnostics { diagnostics.discardPreparedReport() }
        activeExport = nil
        isDeliveryPresented = false
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

