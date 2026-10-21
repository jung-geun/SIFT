import SwiftUI

/// A virtual audio track under a fixed playhead. Only the visible time bins are
/// drawn into a viewport-sized Canvas, regardless of the recording's duration.
/// Drag for fine seeking; the full-duration slider provides coarse navigation.
/// Both commit a single playback fraction on release, not on every touch move.
struct MeetingWaveformView: View {
    let waveform: MeetingWaveform
    /// Playback position 0...1, drives the track offset when not scrubbing.
    var progress: Double = 0
    var totalMs: Int64 = 0
    /// Called with the target fraction (0...1) when the user releases a scrub.
    var onSeek: ((Double) -> Void)?

    private let trackHeight: CGFloat = 96

    @State private var dragProgress: Double?
    @State private var dragBase: Double = 0

    private var effectiveProgress: Double { dragProgress ?? min(max(progress, 0), 1) }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.compact) {
            timeline
            Slider(
                value: Binding(get: { effectiveProgress }, set: { dragProgress = $0 }),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { commitSeek() }
                }
            )
            .disabled(onSeek == nil || totalMs <= 0)
            .frame(minHeight: 44)
            .accessibilityIdentifier("meeting.waveform.scrubber")
            .accessibilityLabel("전체 녹음 탐색")
            .accessibilityValue("\(timeLabel(Int64(effectiveProgress * Double(totalMs)))) / \(timeLabel(totalMs))")
        }
        .onDisappear { dragProgress = nil }
    }

    private var timeline: some View {
        VStack(spacing: AppTheme.Spacing.item) {
            GeometryReader { geometry in
                let viewport = geometry.size.width
                let layout = MeetingWaveformViewport(
                    width: viewport,
                    totalMs: totalMs,
                    bucketCount: waveform.buckets.count,
                    progress: effectiveProgress
                )

                ZStack(alignment: .leading) {
                    trackCanvas(layout: layout)
                        .frame(width: viewport, height: trackHeight)

                    // Fixed center playhead.
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: trackHeight)
                        .position(x: viewport / 2, y: trackHeight / 2)
                }
                .frame(width: viewport, height: trackHeight, alignment: .leading)
                .contentShape(Rectangle())
                .clipped()
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if dragProgress == nil { dragBase = min(max(progress, 0), 1) }
                            // Dragging the track right moves the needle earlier.
                            dragProgress = layout.seekProgress(from: dragBase, translation: value.translation.width)
                        }
                        .onEnded { _ in commitSeek() }
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
        .accessibilityRepresentation {
            Slider(value: Binding(get: { effectiveProgress }, set: { onSeek?($0) }), in: 0...1)
                .disabled(onSeek == nil || totalMs <= 0)
                .accessibilityLabel("음성 트랙")
                .accessibilityValue("\(timeLabel(Int64(effectiveProgress * Double(totalMs)))) / \(timeLabel(totalMs))")
                .accessibilityIdentifier("meeting.waveform.timeline")
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
    }

    static func adjustedProgress(_ progress: Double, totalMs: Int64, increment: Bool) -> Double {
        guard totalMs > 0 else { return min(max(progress, 0), 1) }
        let step = min(1, 5_000 / Double(totalMs))
        return min(max(progress + (increment ? step : -step), 0), 1)
    }

    private func commitSeek() {
        if let target = dragProgress { onSeek?(target) }
        dragProgress = nil
    }

    private func trackCanvas(layout: MeetingWaveformViewport) -> some View {
        Canvas { context, size in
            let center = size.height / 2
            // Index into the original array. No full-recording copy or scan on
            // playback ticks, and no offscreen drawing surface to clip later.
            for index in layout.visibleBuckets {
                let peak = waveform.buckets[index]
                guard peak > 0 else { continue }
                let amplitude = max(2, CGFloat(peak) * center)
                let x = layout.x(for: index)
                let color: Color = x <= size.width / 2 ? .accentColor : .secondary.opacity(0.35)
                var bar = Path()
                bar.move(to: CGPoint(x: x, y: center - amplitude))
                bar.addLine(to: CGPoint(x: x, y: center + amplitude))
                context.stroke(bar, with: .color(color), lineWidth: min(3, max(1, layout.bucketSpan * 0.6)))
            }
        }
    }

    private func timeLabel(_ ms: Int64) -> String {
        let clamped = max(0, ms)
        return String(format: "%02lld:%02lld", clamped / 60_000, (clamped / 1_000) % 60)
    }
}

/// Geometry only: contentWidth is a virtual time scale, never a view allocation.
/// Keep rendering and fine seeking on this same scale, including short clips
/// whose entire waveform is stretched to the viewport's width.
struct MeetingWaveformViewport {
    let width: CGFloat
    let bucketCount: Int
    let progress: Double
    let contentWidth: CGFloat

    init(width: CGFloat, totalMs: Int64, bucketCount: Int, progress: Double) {
        self.width = max(0, width)
        self.bucketCount = max(0, bucketCount)
        self.progress = min(max(progress, 0), 1)
        contentWidth = max(1, max(width, CGFloat(max(0, totalMs)) / 1_000 * 40))
    }

    var bucketSpan: CGFloat { contentWidth / CGFloat(max(1, bucketCount)) }
    private var origin: CGFloat { width / 2 - CGFloat(progress) * contentWidth }

    var visibleBuckets: Range<Int> {
        guard bucketCount > 0, width > 0 else { return 0..<0 }
        // One extra bin at each edge retains partially visible strokes.
        let first = min(bucketCount, max(0, Int(floor(-origin / bucketSpan)) - 1))
        let end = min(bucketCount, max(0, Int(ceil((width - origin) / bucketSpan)) + 1))
        return first..<max(first, end)
    }

    func x(for bucket: Int) -> CGFloat {
        origin + (CGFloat(bucket) + 0.5) * bucketSpan
    }

    func seekProgress(from base: Double, translation: CGFloat) -> Double {
        min(max(base - Double(translation / contentWidth), 0), 1)
    }
}
