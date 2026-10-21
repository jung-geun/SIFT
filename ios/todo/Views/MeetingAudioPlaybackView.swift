import SwiftUI

/// Shared controls for a source-local recording or a derived, time-aligned meeting mix.
struct MeetingAudioPlaybackView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var player: MeetingAudioPlaybackController
    let waveform: MeetingWaveform?
    let waveformError: String?
    let totalMilliseconds: Int64
    var identifier = "meeting.playbackButton"
    let togglePlayback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
            if let waveform {
                MeetingWaveformView(waveform: waveform, progress: player.playbackProgress,
                    totalMs: totalMilliseconds,
                    onSeek: { player.seek(toProgress: $0, totalMilliseconds: totalMilliseconds) })
            } else if let waveformError {
                Text("음성 트랙 생성 실패: \(waveformError)")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView("음성 트랙을 읽는 중")
                    .frame(minHeight: 96)
            }
            HStack(spacing: AppTheme.Spacing.item) {
                Button(action: togglePlayback) {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.largeTitle.weight(.regular))
                        .foregroundStyle(AppTheme.accent)
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(AppLanguage.localized(
                    player.isPlaying ? "meeting.playback.pause" : "meeting.playback.play",
                    defaultValue: player.isPlaying ? "음성 일시 정지" : "음성 재생",
                    language: .current, comment: "Meeting audio playback button."))
                .accessibilityIdentifier(identifier)
                .buttonStyle(.plain)
                .animation(AppTheme.motion(reduceMotion: reduceMotion), value: player.isPlaying)
                Text("\(duration(player.playbackMilliseconds))  /  \(duration(totalMilliseconds))")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifier).time")
                Spacer(minLength: 0)
            }
            Divider()
            DisclosureGroup {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                    Stepper(value: $player.outputLevelPercent, in: 0...400, step: 10) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.compact) {
                                Label("음성 크기", systemImage: "speaker.wave.2")
                                Text("\(player.outputLevelPercent)%").monospacedDigit()
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.compact) {
                                Label("음성 크기", systemImage: "speaker.wave.2")
                                Text("\(player.outputLevelPercent)%").monospacedDigit()
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityLabel("음성 크기")
                    .accessibilityValue("\(player.outputLevelPercent)%")
                    .accessibilityIdentifier("\(identifier).outputLevel")
                    Text("100%는 원본 · 미만은 감쇠 · 초과는 증폭")
                        .font(.caption).foregroundStyle(.secondary)
                    if player.outputLevelPercent > 100 {
                        Text("100%를 넘는 증폭은 왜곡될 수 있습니다.")
                            .font(.caption).foregroundStyle(AppTheme.warning)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, AppTheme.Spacing.item)
                .padding(.bottom, AppTheme.Spacing.compact)
            } label: {
                Text("재생 설정")
                    .frame(minHeight: 44, alignment: .leading)
            }
            .font(.subheadline)
            .frame(maxWidth: 520, alignment: .leading)
            .accessibilityIdentifier("\(identifier).settings")
        }
        // This composite owns its insets; List must not add another form-row gutter.
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, horizontalSizeClass == .compact ? 16 : AppTheme.Spacing.section)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
    }

    private func duration(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }
}
