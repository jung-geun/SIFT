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
                Section {
                    if sync.isRecordingDeferred {
                        Text(copy("settings.sync.full.recordingDeferred", "Recordings are queued after capture stops.", "녹음 중 데이터는 캡처가 끝난 뒤 저장 대기열에 추가합니다."))
                    } else if sync.isQueuedForCloud {
                        Label(copy("settings.sync.full.queued", "Prepared locally · waiting for iCloud", "기기 저장 완료 · iCloud 반영 대기"), systemImage: "icloud.and.arrow.up")
                    } else if let lastExport = sync.lastCloudExport {
                        LabeledContent(copy("settings.sync.full.lastExport", "Last confirmed iCloud export", "최근 확인된 iCloud 내보내기")) {
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
                    Text(copy("settings.sync.full.transport", "Data appears on other devices after Apple's transfer completes. Recordings consume iCloud storage; quota or network failures are shown rather than treated as completed sync. Credentials also require iCloud Keychain.", "Apple의 전송이 완료된 뒤 다른 기기에 적용됩니다. 녹음은 iCloud 저장공간을 사용하며 용량·네트워크 오류를 동기화 완료로 처리하지 않습니다. 연결 정보 복원에는 iCloud 키체인도 필요합니다."))
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
            Text(copy("settings.sync.full.confirm.message", "This includes email bodies, meeting recordings and transcripts, routines, vocabulary, settings and account connections under your Apple account. Health data, OS grants and downloadable model files are excluded. This does not authorize sending content to ChatGPT.", "같은 Apple 계정에 메일 본문·회의 녹음/전사·루틴·학습 사전·설정·연결 정보를 저장합니다. 건강정보·OS 권한·재다운로드 가능한 모델 파일은 제외하며, ChatGPT로 내용을 전송하는 동의와는 별개입니다."))
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
