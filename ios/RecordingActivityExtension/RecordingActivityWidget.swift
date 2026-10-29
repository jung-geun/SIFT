import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

@main
struct RecordingActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingActivityWidget()
    }
}

struct RecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingRecordingAttributes.self) { context in
            RecordingActivityExpanded(snapshot: context.state, isStale: context.isStale)
                .padding(16)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingActivityStatus(snapshot: context.state)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingActivityTimer(snapshot: context.state, isStale: context.isStale)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        MeetingRecordingWaveform(sources: context.state.sources,
                                                 isPaused: context.state.phase == .paused || context.isStale)
                            .frame(height: 38)
                        RecordingActivitySources(sources: context.state.sources)
                    }
                    .padding(.top, 6)
                }
            } compactLeading: {
                RecordingActivityCompact(snapshot: context.state, isStale: context.isStale)
            } compactTrailing: {
                if #available(iOS 27.0, *) {
                    RecordingActivityCompactTrailing(snapshot: context.state, isStale: context.isStale)
                } else {
                    RecordingActivityTimer(snapshot: context.state, isStale: context.isStale)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 62)
                        .minimumScaleFactor(0.75)
                        .lineLimit(1)
                }
            } minimal: {
                RecordingActivityCompact(snapshot: context.state, isStale: context.isStale)
            }
            .keylineTint(context.state.phase == .paused ? .secondary : .red)
        }
    }
}

private struct RecordingActivityExpanded: View {
    let snapshot: MeetingRecordingActivitySnapshot
    let isStale: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                RecordingActivityStatus(snapshot: snapshot)
                    .font(.headline)
                Spacer(minLength: 8)
                RecordingActivityTimer(snapshot: snapshot, isStale: isStale)
                    .font(.headline.monospacedDigit())
            }
            MeetingRecordingWaveform(sources: snapshot.sources, isPaused: snapshot.phase == .paused || isStale)
                .frame(height: 38)
            RecordingActivitySources(sources: snapshot.sources)
        }
        .accessibilityHint(Text("Open recording", tableName: "RecordingActivity"))
    }
}

private struct RecordingActivityStatus: View {
    let snapshot: MeetingRecordingActivitySnapshot

    var body: some View {
        Label {
            if snapshot.phase == .paused {
                Text("Paused", tableName: "RecordingActivity")
            } else {
                Text("Recording", tableName: "RecordingActivity")
            }
        } icon: {
            Image(systemName: snapshot.phase == .paused ? "pause.fill" : "record.circle.fill")
                .foregroundStyle(snapshot.phase == .paused ? Color.secondary : .red)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct RecordingActivityTimer: View {
    let snapshot: MeetingRecordingActivitySnapshot
    let isStale: Bool

    var body: some View {
        if snapshot.phase == .recording && !isStale {
            Text(timerInterval: snapshot.updatedAt.addingTimeInterval(-Double(snapshot.elapsedMilliseconds) / 1_000)...Date.distantFuture,
                 countsDown: false, showsHours: true)
                .multilineTextAlignment(.trailing)
        } else {
            let seconds = max(0, snapshot.elapsedMilliseconds / 1_000)
            Text(verbatim: String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60))
        }
    }
}

private struct RecordingActivitySources: View {
    let sources: [MeetingRecordingSourceState]

    var body: some View {
        HStack(spacing: 10) {
            if sources.isEmpty {
                Text("No active input", tableName: "RecordingActivity")
                    .foregroundStyle(.secondary)
            }
            ForEach(sources.prefix(5)) { source in
                Label {
                    Text(String(localized: String.LocalizationValue(MeetingRecordingSourcePalette.labelKey(for: source.kind)),
                                table: "RecordingActivity"))
                } icon: {
                    Image(systemName: MeetingRecordingSourcePalette.symbol(for: source.kind))
                        .foregroundStyle(MeetingRecordingSourcePalette.color(for: source.colorIndex))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Recording sources", tableName: "RecordingActivity"))
    }
}

private struct RecordingActivityCompact: View {
    let snapshot: MeetingRecordingActivitySnapshot
    let isStale: Bool

    var body: some View {
        ZStack {
            MeetingRecordingWaveform(sources: snapshot.sources, isPaused: snapshot.phase == .paused || isStale)
                .frame(width: 22, height: 20)
            if snapshot.phase == .paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .padding(2)
                    .background(.black, in: Circle())
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.phase == .paused
                            ? Text("Paused", tableName: "RecordingActivity")
                            : Text("Recording", tableName: "RecordingActivity"))
    }
}

@available(iOS 27.0, *)
private struct RecordingActivityCompactTrailing: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var limitedWidth
    let snapshot: MeetingRecordingActivitySnapshot
    let isStale: Bool

    var body: some View {
        if !limitedWidth {
            RecordingActivityTimer(snapshot: snapshot, isStale: isStale)
                .font(.caption2.monospacedDigit())
                .frame(maxWidth: 62)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
        }
    }
}
