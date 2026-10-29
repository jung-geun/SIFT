import SwiftUI

/// Uses measured history only. The presenting surface owns sizing and update cadence.
struct MeetingRecordingWaveform: View {
    let sources: [MeetingRecordingSourceState]
    let isPaused: Bool

    var body: some View {
        Canvas { context, size in
            let middle = size.height / 2
            if sources.isEmpty {
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: middle))
                baseline.addLine(to: CGPoint(x: size.width, y: middle))
                context.stroke(baseline, with: .color(.secondary), lineWidth: 1)
            }
            for source in sources.prefix(5) {
                let samples = source.levels.suffix(32)
                var envelope = Path()
                guard samples.count > 1, !isPaused else {
                    envelope.move(to: CGPoint(x: 0, y: middle))
                    envelope.addLine(to: CGPoint(x: size.width, y: middle))
                    context.stroke(envelope, with: .color(MeetingRecordingSourcePalette.color(for: source.colorIndex)), lineWidth: 1.5)
                    continue
                }
                let step = size.width / CGFloat(samples.count - 1)
                let height = max(0, middle - 1)
                envelope.move(to: CGPoint(x: 0, y: middle - CGFloat(samples.first ?? 0) / 255 * height))
                for (index, level) in samples.enumerated().dropFirst() {
                    envelope.addLine(to: CGPoint(x: CGFloat(index) * step, y: middle - CGFloat(level) / 255 * height))
                }
                for (index, level) in samples.enumerated().reversed() {
                    envelope.addLine(to: CGPoint(x: CGFloat(index) * step, y: middle + CGFloat(level) / 255 * height))
                }
                envelope.closeSubpath()
                let color = MeetingRecordingSourcePalette.color(for: source.colorIndex)
                context.fill(envelope, with: .color(color.opacity(0.16)))
                context.stroke(envelope, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

enum MeetingRecordingSourcePalette {
    static func color(for index: Int) -> Color {
        return colors[((index % colors.count) + colors.count) % colors.count]
    }

    private static let colors: [Color] = [.red, .cyan, .orange, .purple, .green]

    static func symbol(for kind: MeetingRecordingSourceState.Kind) -> String {
        switch kind {
        case .microphone: "mic.fill"
        case .application: "app.fill"
        case .screen: "display"
        }
    }

    static func labelKey(for kind: MeetingRecordingSourceState.Kind) -> String {
        switch kind {
        case .microphone: "Microphone"
        case .application: "Application audio"
        case .screen: "Screen audio"
        }
    }
}
