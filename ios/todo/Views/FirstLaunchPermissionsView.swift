import SwiftUI
import AVFoundation

/// First-run preparation only. Granting permission never starts audio capture.
struct FirstLaunchPermissionsView: View {
    private enum PermissionStatus {
        case checking, notDetermined, allowed, denied, restricted, unknown

        var isAllowed: Bool { self == .allowed }

        var label: String {
            switch self {
            case .checking: FirstLaunchPermissionsView.copy("permissions.status.checking", fallback: "Checking…")
            case .notDetermined: FirstLaunchPermissionsView.copy("permissions.status.notRequested", fallback: "Not requested")
            case .allowed: FirstLaunchPermissionsView.copy("permissions.status.allowed", fallback: "Allowed")
            case .denied: FirstLaunchPermissionsView.copy("permissions.status.denied", fallback: "Not allowed")
            case .restricted: FirstLaunchPermissionsView.copy("permissions.status.restricted", fallback: "Restricted")
            case .unknown: FirstLaunchPermissionsView.copy("permissions.status.unknown", fallback: "Check in Settings")
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var microphoneStatus: PermissionStatus = .checking
    @State private var notificationStatus: PermissionStatus = .checking
    @State private var isRequesting = false
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Label("SIFT", systemImage: "waveform.circle.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("permissions.firstLaunch")

                    if geometry.size.width >= 850 {
                        HStack(alignment: .top, spacing: 40) {
                            permissionContent
                                .frame(maxWidth: .infinity, alignment: .leading)
                            explanation
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        permissionContent
                        explanation
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    Button(action: onContinue) {
                        Text(Self.copy("permissions.firstLaunch.continue", fallback: "Continue"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
                    .disabled(isRequesting)
                    .accessibilityIdentifier("permissions.continue")

                    Text(Self.copy("permissions.firstLaunch.optional", fallback: "You can continue without granting access and change it later in Settings."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
        }
        .tint(AppTheme.accent)
        .task { await refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !isRequesting {
                Task { await refreshStatus() }
            }
        }
    }

    private var permissionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(Self.copy("permissions.firstLaunch.title", fallback: "Get ready for your meetings"))
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.copy("permissions.firstLaunch.subtitle", fallback: "Allow only what you need. Nothing is recorded on this screen."))
            .foregroundStyle(.secondary)

            permissionCard(
                title: Self.copy("permissions.microphone.title", fallback: "Microphone"),
                detail: Self.copy("permissions.microphone.purpose", fallback: "Record your voice for on-device transcription."),
                icon: "mic.fill", status: microphoneStatus, identifier: "microphone"
            ) { await requestMicrophone() }

            if case .available = MeetingAppAudioCapture.availability {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(Self.copy("permissions.appAudio.title", fallback: "App audio"), systemImage: "speaker.wave.2.fill")
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text(Self.copy("permissions.appAudio.status", fallback: "Select when recording"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(appAudioDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
                .accessibilityIdentifier("permissions.appAudio")
            }

            permissionCard(
                title: Self.copy("permissions.notifications.title", fallback: "Notifications"),
                detail: Self.copy("permissions.notifications.purpose", fallback: "Receive reminders for your to-do deadlines. Recording works without notifications."),
                icon: "bell.badge.fill", status: notificationStatus, identifier: "notifications"
            ) { await requestNotifications() }
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Label(Self.copy("permissions.firstLaunch.local.title", fallback: "Audio stays on this device"), systemImage: "lock.shield")
                    .font(.headline)
                Text(Self.copy("permissions.firstLaunch.local.detail", fallback: "Meeting recording, transcription, and analysis run locally. Granting microphone access does not start a recording. You choose the audio sources and confirm recording consent in the meeting screen."))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.copy("permissions.firstLaunch.review.title", fallback: "Review before acting"))
                    .font(.headline)
                Text(Self.copy("permissions.firstLaunch.review.detail", fallback: "AI transcripts and summaries can be wrong. Review the original transcript before turning suggested actions into to-dos."))
            }
        }
        .font(.subheadline)
        .lineSpacing(4)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }

    private func permissionCard(
        title: String, detail: String, icon: String, status: PermissionStatus,
        identifier: String, request: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Label(status.label, systemImage: status.isAllowed ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.isAllowed ? AppTheme.success : .secondary)
                    .accessibilityIdentifier("permissions.\(identifier).status")
                Spacer()
                if !status.isAllowed, status != .checking {
                    Button(Self.copy(status == .notDetermined ? "permissions.action.allow" : "permissions.action.settings", fallback: status == .notDetermined ? "Allow" : "Open Settings")) {
                        if status == .notDetermined {
                            Task { await request() }
                        } else {
                            openPermissionSettings(for: identifier)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRequesting)
                    .accessibilityIdentifier("permissions.\(identifier).action")
                }
            }
        }
        .padding(18)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous))
    }

    private func refreshStatus() async {
        #if targetEnvironment(macCatalyst)
        microphoneStatus = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
        #else
        microphoneStatus = switch AVAudioApplication.shared.recordPermission {
        case .granted: .allowed
        case .undetermined: .notDetermined
        case .denied: .denied
        @unknown default: .unknown
        }
        #endif
        let status = await NotificationService.shared.authorizationStatus()
        guard !Task.isCancelled else { return }
        notificationStatus = switch status {
        case .authorized, .provisional, .ephemeral: .allowed
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .unknown
        }
    }

    private func requestMicrophone() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        #if targetEnvironment(macCatalyst)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        #else
        _ = await AVAudioApplication.requestRecordPermission()
        #endif
        await refreshStatus()
    }

    private func requestNotifications() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        _ = await NotificationService.shared.requestAuthorization()
        await refreshStatus()
    }

    private func openPermissionSettings(for identifier: String) {
        #if targetEnvironment(macCatalyst)
        let destination = identifier == "microphone"
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            : "x-apple.systempreferences:com.apple.preference.notifications"
        #else
        let destination = UIApplication.openSettingsURLString
        #endif
        if let url = URL(string: destination) { openURL(url) }
    }

    private var appAudioDescription: String {
        #if targetEnvironment(macCatalyst)
        Self.copy("permissions.appAudio.purpose.mac", fallback: "Choose the content whose audio you want in the system picker when preparing a recording. This screen does not start sharing or request access in advance.")
        #else
        Self.copy("permissions.appAudio.purpose.ios", fallback: "Approve entire-screen audio in the system screen-sharing picker when preparing a recording. This screen does not start sharing or request access in advance.")
        #endif
    }

    private static func copy(_ key: String, fallback: String) -> String {
        AppLanguage.localized(key, defaultValue: fallback, language: .current)
    }
}
