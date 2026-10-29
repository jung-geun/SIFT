import SwiftUI
import WidgetKit

private func recordingActivityText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "RecordingActivity", locale: AppLanguage.current.locale)
}

private func recordingSourceText(_ source: MeetingRecordingSourceState, multiple: Bool) -> String {
    let key: String
    switch source.kind {
    case .microphone: key = "Microphone"
    case .application: key = "Application audio"
    case .screen: key = "Screen audio"
    }
    let label = recordingActivityText(key)
    return multiple ? "\(label) \(source.colorIndex + 1)" : label
}

struct MeetingRecordingActivityOverlay: ViewModifier {
    @ObservedObject private var activity = MeetingRecordingActivityCenter.shared
    var openRecording: (() -> Void)? = nil

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        VStack(spacing: 0) {
            if let snapshot = activity.current {
                MeetingRecordingCapsule(snapshot: snapshot, openRecording: openRecording)
                    .id(snapshot.sessionID)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
            }
            content
        }
        #endif
    }
}

struct MeetingRecordingNavigationHandler: ViewModifier {
    let openRecording: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .meetingRecordingOpen)) { _ in
                openRecording()
            }
            #if !targetEnvironment(macCatalyst)
            .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in
                MeetingRecordingActivityCenter.shared.requestOpenRecording()
            }
            #endif
    }
}

private struct MeetingRecordingCapsule: View {
    let snapshot: MeetingRecordingActivitySnapshot
    let openRecording: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = true

    private var paused: Bool { snapshot.phase == .paused }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: paused ? "pause.fill" : "record.circle.fill")
                            .foregroundStyle(paused ? Color.secondary : Color.red)
                            .accessibilityHidden(true)
                        if isExpanded {
                            Text(recordingActivityText(paused ? "Paused" : "Recording"))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        } else {
                            MeetingRecordingWaveform(sources: snapshot.sources, isPaused: paused)
                                .frame(width: 64, height: 24)
                                .accessibilityHidden(true)
                        }
                        RecordingElapsedTime(seconds: max(0, snapshot.elapsedMilliseconds / 1_000))
                            .equatable()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(recordingActivityText(paused ? "Paused" : "Recording"))
                .accessibilityHint(recordingActivityText(isExpanded ? "Hide recording details" : "Show recording details"))
                .accessibilityIdentifier("meeting.recordingActivity.toggle")

                if isExpanded, let openRecording {
                    Button(action: openRecording) {
                        Image(systemName: "arrow.up.forward")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(recordingActivityText("Open recording"))
                    .accessibilityIdentifier("meeting.recordingActivity.open")
                }
            }
            if isExpanded {
                MeetingRecordingWaveformPanel(snapshot: snapshot)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isExpanded ? 24 : 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isExpanded ? 24 : 26, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: isExpanded ? 420 : nil)
        .accessibilityIdentifier(isExpanded ? "meeting.recordingActivity.expanded" : "meeting.recordingActivity.compact")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isExpanded)
        .task(id: isExpanded) {
            guard isExpanded else { return }
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard !Task.isCancelled else { return }
            isExpanded = false
        }
    }
}

/// The same source histories and stable colors as the system Live Activity.
struct MeetingRecordingWaveformPanel: View {
    let snapshot: MeetingRecordingActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MeetingRecordingWaveform(sources: snapshot.sources, isPaused: snapshot.phase == .paused)
                .frame(height: 44)
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(snapshot.sources) { source in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(MeetingRecordingSourcePalette.color(for: source.colorIndex))
                                .frame(width: 7, height: 7)
                            Text(recordingSourceText(source, multiple: snapshot.sources.count > 1))
                                .font(.caption)
                                .fixedSize()
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(recordingActivityText("Recording sources"))
        }
        .accessibilityIdentifier("meeting.recordingActivity.waveforms")
    }
}

private struct RecordingElapsedTime: View, Equatable {
    let seconds: Int64

    var body: some View {
        Text(Duration.seconds(seconds), format: .time(pattern: seconds >= 3_600 ? .hourMinuteSecond : .minuteSecond))
            .font(.subheadline.monospacedDigit())
            .lineLimit(1)
            .accessibilityIdentifier("meeting.recordingActivity.elapsed")
    }
}
