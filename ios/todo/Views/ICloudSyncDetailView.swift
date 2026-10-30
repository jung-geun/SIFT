import SwiftUI

struct ICloudSyncDetailView: View {
    @AppStorage(UserCloudSyncPolicy.syncKey) private var iCloudSyncEnabled = false
    @AppStorage(UserCloudSyncPolicy.consentKey) private var consentVersion = 0
    @ObservedObject private var sync = FullCloudSyncService.shared
    @State private var confirmFullScope = false
    @State private var changingPolicy = false

    private var enabled: Bool {
        SettingsStore.supportsICloud && iCloudSyncEnabled && consentVersion == UserCloudSyncPolicy.consentVersion
    }

    var body: some View {
        Form {
            Section {
                Toggle(copy("settings.sync.full.toggle", "Save all app data in iCloud", "앱 데이터 전체를 iCloud에 저장"), isOn: Binding(
                    get: { enabled },
                    set: { value in
                        if value { confirmFullScope = true }
                        else { changePolicy(false) }
                    }
                ))
                .disabled(!SettingsStore.supportsICloud || changingPolicy)
                .accessibilityIdentifier("settings.sync.full.toggle")
                if changingPolicy { ProgressView() }
                if UserCloudSyncPolicy.needsScopeConsent {
                    Text(copy("settings.sync.full.upgrade", "Your earlier consent did not include email or recordings. iCloud storage is paused until you consent to the expanded scope. Confirm it to resume full storage.", "기존 동의에는 메일과 녹음이 포함되지 않았습니다. 확대된 범위에 동의하기 전까지 iCloud 저장은 중지됩니다. 전체 저장을 다시 사용하려면 범위를 확인해 주세요."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = sync.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.sync.full.error")
                }
            } footer: {
                if SettingsStore.supportsICloud {
                    Text(copy("settings.sync.full.offline", "Turning sync off retains local data and does not erase other devices.", "동기화를 꺼도 현재 기기와 다른 기기의 데이터는 삭제하지 않습니다."))
                } else {
                    Text(AppLanguage.localized("settings.sync.unavailableMessage", defaultValue: "이 빌드에서는 iCloud 동기화를 사용할 수 없습니다. 기존 데이터는 기기에만 보존됩니다.", language: .current))
                }
            }

            Section(copy("settings.sync.full.includes.title", "Included in full storage", "전체 저장에 포함")) {
                Label(copy("settings.sync.full.includes.tasks", "Tasks, personas, audit and behavior history", "할 일·페르소나·감사 기록·행동 분석"), systemImage: "checklist")
                Label(copy("settings.sync.full.includes.mail", "Email content, analysis and learned decisions", "메일 본문·분석 결과·학습 기록"), systemImage: "envelope")
                Label(copy("settings.sync.full.includes.meetings", "Meeting audio, transcripts, speakers and edits", "회의 원본 음성·전사·화자·편집 내역"), systemImage: "waveform")
                Label(copy("settings.sync.full.includes.routines", "Routines and personalized vocabulary", "루틴·개인화 학습 사전"), systemImage: "repeat")
                Label(copy("settings.sync.full.includes.settings", "App settings and model selections", "앱 설정·모델 선택 설정"), systemImage: "slider.horizontal.3")
                Label(copy("settings.sync.full.includes.connections", "Account connections through iCloud Keychain", "iCloud 키체인을 통한 계정 연결 정보"), systemImage: "key")
            }

            Section(copy("settings.sync.full.device.title", "Remains device-specific", "기기별로 유지")) {
                Text(copy("settings.sync.full.device.health", "Personal health information is excluded under Apple's rules. Health data and OS permissions are read or authorized on each device.", "Apple 정책에 따라 개인 건강정보는 제외합니다. 건강 데이터와 OS 권한은 각 기기에서 읽거나 승인합니다."))
                Text(copy("settings.sync.full.device.models", "Model files are not uploaded. Laya, the local LLM and speech models must be downloaded and verified on each device before they can be selected.", "모델 설치파일은 업로드하지 않습니다. Laya·로컬 LLM·음성 모델은 각 기기에서 다운로드와 검증을 마쳐야 선택할 수 있습니다."))
                Text(copy("settings.sync.full.device.permissions", "Saved permission history does not grant access on a new device. Confirm external-AI sharing, background mail and device-specific calendar choices locally; restored outbox history does not automatically replay mail actions.", "저장된 권한 내역만으로 새 기기에 권한을 부여하지 않습니다. 외부 AI 전송·메일 백그라운드 접근·기기별 캘린더 선택은 해당 기기에서 확인하며, 복원된 대기 작업 내역으로 메일 작업을 자동 재실행하지 않습니다."))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if enabled {
                AccountConnectionSyncSection(sync: sync.connectionSync,
                    canAuthorize: UserCloudSyncPolicy.isEnabled && !changingPolicy,
                    authorize: sync.authorizeAccountConnectionSync)
                Section {
                    if sync.isRecordingDeferred {
                        Text(copy("settings.sync.full.recordingDeferred", "Recordings are queued after capture stops.", "녹음 중 데이터는 캡처가 끝난 뒤 저장 대기열에 추가합니다."))
                    } else if sync.isQueuedForCloud {
                        Label(copy("settings.sync.full.queued", "Prepared locally · waiting for iCloud", "기기 저장 완료 · iCloud 반영 대기"), systemImage: "icloud.and.arrow.up")
                    } else if let lastExport = sync.lastCloudExport {
                        LabeledContent(copy("settings.sync.full.lastDataExport", "Last confirmed app-data export", "최근 확인된 앱 데이터 내보내기")) {
                            Text(lastExport, style: .time)
                        }
                    } else {
                        Text(copy("settings.sync.full.waiting", "Waiting for iCloud account and synchronization status.", "iCloud 계정과 동기화 상태를 확인하는 중입니다."))
                    }
                    Button(copy("settings.sync.full.retry", "Sync now", "지금 동기화")) {
                        Task { try? await sync.synchronizeNow() }
                    }
                    .accessibilityIdentifier("settings.sync.full.retry")
                } header: {
                    Text(copy("settings.sync.full.status.title", "iCloud status", "iCloud 상태"))
                } footer: {
                    Text(copy("settings.sync.full.dataTransport", "This status covers app data, not account connections. Data appears on other devices after Apple's transfer completes. Recordings consume iCloud storage; quota or network failures are not treated as completed sync.", "이 상태는 계정 연결 정보가 아닌 앱 데이터의 전송 상태입니다. Apple의 전송이 완료된 뒤 다른 기기에 적용됩니다. 녹음은 iCloud 저장공간을 사용하며 용량·네트워크 오류를 동기화 완료로 처리하지 않습니다."))
                }
            }
        }
        .appFormStyle()
        .navigationTitle("iCloud 동기화")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(copy("settings.sync.full.confirm.title", "Store all eligible app data in iCloud?", "앱 데이터 전체를 iCloud에 저장할까요?"), isPresented: $confirmFullScope, titleVisibility: .visible) {
            Button(copy("settings.sync.full.confirm.action", "Enable full storage", "전체 저장 켜기")) { changePolicy(true) }
                .accessibilityIdentifier("settings.sync.full.confirm")
            Button("취소", role: .cancel) {}
        } message: {
            Text(copy("settings.sync.full.confirm.storageMessage", "This stores email bodies, recordings and transcripts, routines, vocabulary and settings under your Apple account. Account connections use iCloud Keychain; protected connections require a separate action and device authentication. Health data, OS grants and model downloads are excluded. This does not authorize ChatGPT sharing.", "같은 Apple 계정에 메일 본문·회의 녹음/전사·루틴·학습 사전·설정을 저장합니다. 계정 연결 정보는 iCloud 키체인을 사용하며, 보호된 연결 정보는 별도 작업과 기기 인증이 필요합니다. 건강정보·OS 권한·모델 다운로드는 제외하며 ChatGPT 전송 동의와 별개입니다."))
        }
    }

    private func changePolicy(_ enabled: Bool) {
        if !enabled { iCloudSyncEnabled = false }
        changingPolicy = true
        Task {
            defer { changingPolicy = false }
            do { try await sync.setEnabled(enabled) }
            catch { /* The service retains local data and publishes a safe error. */ }
        }
    }

    private func copy(_ key: String, _ english: String, _ korean: String) -> String {
        AppLanguage.localized(key, defaultValue: AppLanguage.current == .korean ? korean : english,
            language: .current, comment: "Full iCloud storage scope, consent and real transport status.")
    }
}

private struct AccountConnectionSyncSection: View {
    @ObservedObject var sync: FullCloudConnectionSync
    let canAuthorize: Bool
    let authorize: () -> Void

    var body: some View {
        Section {
            Text(status).accessibilityIdentifier("settings.sync.connections.status")
            if !canAuthorize {
                Text(copy("connections.accountWaiting", "Account connection approval is unavailable until the iCloud Apple account is verified. Check the app-data status below; no device authentication has started.", "iCloud Apple 계정이 확인되기 전에는 계정 연결 정보를 승인할 수 없습니다. 아래 앱 데이터 상태를 확인해 주세요. 기기 인증은 시작하지 않았습니다."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if sync.state == .authorizing || sync.state == .checking {
                ProgressView(value: Double(sync.completedFamilyCount), total: Double(max(1, sync.familyCount))) {
                    Text(copy("connections.progress", "Connection groups checked (not OS prompts)", "확인한 연결 정보 그룹 (OS 인증 횟수 아님)"))
                }
                if let family = sync.currentFamily { Text(familyName(family)).font(.footnote) }
            }
            if !sync.pendingFamilies.isEmpty, sync.state != .notChecked {
                Text(copy("connections.pending", "Still awaiting preparation:", "아직 준비되지 않은 연결 정보:") + " "
                    + FullCloudConnectionSync.Family.allCases.filter { sync.pendingFamilies.contains($0) }.map(familyName).joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !sync.blockedFamilies.isEmpty {
                Text(copy("connections.locked", "Device authentication required:", "기기 인증이 필요한 연결 정보:") + " "
                    + FullCloudConnectionSync.Family.allCases.filter { sync.blockedFamilies.contains($0) }.map(familyName).joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.orange)
            }
            if sync.isAuthorizing {
                Button(copy("connections.stop", "Stop account connection sync", "계정 연결 정보 동기화 중지"), role: .cancel) { sync.cancelAuthorization() }
                    .accessibilityIdentifier("settings.sync.connections.stop")
            } else {
                Button(copy("connections.authorize", "Authorize account connection sync", "계정 연결 정보 동기화 승인"), action: authorize)
                    .disabled(!canAuthorize || sync.state == .checking)
                    .accessibilityIdentifier("settings.sync.connections.authorize")
            }
        } header: {
            Text(copy("connections.title", "Account connection sync", "계정 연결 정보 동기화"))
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy("connections.purpose", "This action unlocks protected connection secrets only to prepare them for iCloud Keychain. It ends after the listed families are checked or at the first authentication cancellation or failure. Cancel in the system dialog or stop here; local data and existing credentials are retained. Automatic sync never requests this approval again; retry only with this button.", "이 작업은 보호된 연결 정보를 잠금 해제해 iCloud 키체인 저장을 준비합니다. 표시된 항목을 확인하면 종료되며, 인증을 취소하거나 인증에 실패하면 즉시 멈춥니다. 시스템 창에서 취소하거나 여기서 중지해도 로컬 데이터와 기존 연결 정보는 보존됩니다. 자동 동기화는 승인을 다시 요청하지 않으며 이 버튼으로만 재시도합니다."))
                Text(copy("connections.authentication", "Your Apple account identifies iCloud storage. Touch ID, Face ID or this device's login password/passcode unlocks device Keychain items; it is not a mail app password. Never enter a mail app password into an OS authentication dialog. Prompt count depends on protected connections and the OS, not a fixed number. OS permissions and biometric data are not uploaded, and this action does not enable background mail or AI sharing.", "Apple 계정은 iCloud 저장 계정을 확인합니다. Touch ID·Face ID 또는 이 기기의 로그인 암호·암호 코드는 기기 키체인의 잠금을 해제하며, 메일 앱 비밀번호와 다릅니다. OS 인증 창에 메일 앱 비밀번호를 입력하지 마세요. 인증 횟수는 보호된 연결 정보와 OS에 따라 다르며 고정되어 있지 않습니다. OS 권한과 생체정보는 업로드하지 않고, 이 작업으로 메일 백그라운드 접근이나 AI 전송을 켜지 않습니다."))
            }
        }
        .onDisappear { sync.cancelAuthorization() }
    }

    private var status: String {
        switch sync.state {
        case .notChecked: copy("connections.notChecked", "Account connections have not been checked. App-data storage is independent.", "계정 연결 정보를 아직 확인하지 않았습니다. 앱 데이터 저장은 별도로 진행합니다.")
        case .checking: copy("connections.checking", "Checking account connections without authentication prompts…", "인증 창 없이 계정 연결 정보를 확인하는 중…")
        case .authorizing: copy("connections.authorizing", "Preparing account connections with your device approval…", "기기 승인을 받아 계정 연결 정보를 준비하는 중…")
        case .prepared: copy("connections.prepared", "Account connections prepared locally. iCloud Keychain delivery is controlled by Apple.", "계정 연결 정보의 기기 내 준비가 완료되었습니다. iCloud 키체인 전송은 Apple이 처리합니다.")
        case .awaitingApproval: copy("connections.awaiting", "Account connection sync awaiting approval. App-data storage continues.", "계정 연결 정보 동기화 승인 대기 중입니다. 앱 데이터 저장은 계속 진행합니다.")
        case .cancelled: copy("connections.cancelled", "Account connection sync stopped · awaiting approval. Existing credentials and local data are retained. App-data storage continues.", "계정 연결 정보 동기화 중지 · 승인 대기 중입니다. 기존 연결 정보와 로컬 데이터는 보존되며 앱 데이터 저장은 계속 진행합니다.")
        case .failed: copy("connections.failed", "Account connection sync could not finish. Existing credentials are retained; check Keychain availability and retry. App-data errors are shown separately.", "계정 연결 정보 동기화를 완료하지 못했습니다. 기존 연결 정보는 보존됩니다. 키체인 상태를 확인한 뒤 다시 시도하세요. 앱 데이터 오류는 별도로 표시됩니다.")
        }
    }

    private func familyName(_ family: FullCloudConnectionSync.Family) -> String {
        switch family {
        case .gmailIMAP: copy("connections.family.gmail", "Gmail IMAP", "Gmail IMAP")
        case .outlookIMAP: copy("connections.family.outlook", "Outlook IMAP", "Outlook IMAP")
        case .google: copy("connections.family.google", "Google sign-in", "Google 로그인")
        case .mailIdentity: copy("connections.family.mailIdentity", "Mail learning identity", "메일 학습 식별 키")
        case .vocabulary: copy("connections.family.vocabulary", "Vocabulary identity", "학습 사전 식별 키")
        case .openAI: copy("connections.family.openAI", "ChatGPT connection", "ChatGPT 연결")
        }
    }

    private func copy(_ suffix: String, _ english: String, _ korean: String) -> String {
        AppLanguage.localized("settings.sync.full." + suffix,
            defaultValue: AppLanguage.current == .korean ? korean : english,
            language: .current, comment: "Account connection authentication purpose, bounded progress and retained-data outcome.")
    }
}
