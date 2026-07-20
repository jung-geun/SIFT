import SwiftUI

/// A Voice-Memos-style audio track: the waveform slides under a fixed center
/// playhead. Dragging the track scrubs (a single seek fires on release, so the
/// streaming scheduler isn't rescheduled on every touch move). Current and
/// total time are shown below.
struct MeetingWaveformView: View {
    let waveform: MeetingWaveform
    /// Playback position 0...1, drives the track offset when not scrubbing.
    var progress: Double = 0
    var totalMs: Int64 = 0
    /// Called with the target fraction (0...1) when the user releases a scrub.
    var onSeek: ((Double) -> Void)?

    /// Points per second of audio; sets how wide (scrollable) the track is.
    private let pointsPerSecond: CGFloat = 40
    private let trackHeight: CGFloat = 96

    @State private var dragProgress: Double?
    @State private var dragBase: Double = 0

    private var effectiveProgress: Double { dragProgress ?? min(max(progress, 0), 1) }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let viewport = geometry.size.width
                let totalSeconds = max(1, Double(totalMs) / 1000)
                let contentWidth = max(viewport, CGFloat(totalSeconds) * pointsPerSecond)
                let offsetX = viewport / 2 - CGFloat(effectiveProgress) * contentWidth

                ZStack(alignment: .leading) {
                    trackCanvas(contentWidth: contentWidth)
                        .frame(width: contentWidth, height: trackHeight)
                        .offset(x: offsetX)

                    // Fixed center playhead.
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: trackHeight)
                        .position(x: viewport / 2, y: trackHeight / 2)
                }
                .frame(width: viewport, height: trackHeight, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragProgress == nil { dragBase = min(max(progress, 0), 1) }
                            // Dragging the track right moves the needle earlier.
                            let delta = Double(value.translation.width / contentWidth)
                            dragProgress = min(max(dragBase - delta, 0), 1)
                        }
                        .onEnded { _ in
                            if let target = dragProgress { onSeek?(target) }
                            dragProgress = nil
                        }
                )
            }
            .frame(height: trackHeight)

            HStack {
                Text(timeLabel(Int64(effectiveProgress * Double(totalMs))))
                Spacer()
                Text(timeLabel(totalMs))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("음성 트랙")
        .accessibilityValue("\(timeLabel(Int64(effectiveProgress * Double(totalMs)))) / \(timeLabel(totalMs))")
        .accessibilityHint("위나 아래로 쓸어 5초씩 이동")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onSeek?(Self.adjustedProgress(progress, totalMs: totalMs, increment: true))
            case .decrement:
                onSeek?(Self.adjustedProgress(progress, totalMs: totalMs, increment: false))
            @unknown default:
                break
            }
        }
    }

    static func adjustedProgress(_ progress: Double, totalMs: Int64, increment: Bool) -> Double {
        guard totalMs > 0 else { return min(max(progress, 0), 1) }
        let step = min(1, 5_000 / Double(totalMs))
        return min(max(progress + (increment ? step : -step), 0), 1)
    }

    private func trackCanvas(contentWidth: CGFloat) -> some View {
        Canvas { context, size in
            let count = max(1, waveform.buckets.count)
            let barSpan = size.width / CGFloat(count)
            let center = size.height / 2
            let played = CGFloat(effectiveProgress) * size.width
            for (index, peak) in waveform.buckets.enumerated() where peak > 0 {
                let amplitude = max(2, CGFloat(peak) * center)
                let x = (CGFloat(index) + 0.5) * barSpan
                let color: Color = x <= played ? .accentColor : .secondary.opacity(0.35)
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: center - amplitude))
                bar.addLine(to: CGPoint(x: x, y: center + amplitude))
                context.stroke(bar, with: .color(color), lineWidth: max(1, barSpan * 0.6))
            }
        }
    }

    private func timeLabel(_ ms: Int64) -> String {
        let clamped = max(0, ms)
        return String(format: "%02lld:%02lld", clamped / 60_000, (clamped / 1_000) % 60)
    }
}
