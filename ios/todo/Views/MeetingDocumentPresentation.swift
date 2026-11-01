import SwiftUI
import SwiftData
import UIKit

enum MeetingDocumentTab: String, CaseIterable, Identifiable {
    case summary, transcript
    var id: String { rawValue }
    var title: String {
        MeetingLanguageCopy.text("meeting.document.\(rawValue)", self == .summary ? "Summary" : "Transcript")
    }
}

/// UITextView reports actual selection and first-responder changes; tapping the prose never seeks audio.
private struct MeetingSelectableProse: UIViewRepresentable {
    let text: String
    let identifier: String
    @Binding var isInteracting: Bool

    final class TextView: UITextView {
        var interactionChanged: ((Bool) -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { interactionChanged?(true) }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { interactionChanged?(selectedRange.length > 0) }
            return accepted
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MeetingSelectableProse
        init(_ parent: MeetingSelectableProse) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) {
            update(textView.isFirstResponder || textView.selectedRange.length > 0)
        }
        func update(_ active: Bool) {
            guard parent.isInteracting != active else { return }
            // UIKit can update selection during SwiftUI's update pass.
            DispatchQueue.main.async { [weak self] in self?.parent.isInteracting = active }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .label
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.interactionChanged = { [weak coordinator = context.coordinator] in coordinator?.update($0) }
        return view
    }
    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.tintColor = UIColor(AppTheme.accent)
        view.accessibilityIdentifier = identifier
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

struct MeetingTranscriptProseRow: View {
    let text: String
    let sourceLabel: String?
    let speakerLabel: String?
    let timeRange: String
    let identifier: String
    var highlighted = false
    var canPlay = true
    var reservesEditingControl = false
    let play: () -> Void
    @State private var hovered = false
    @State private var selecting = false

    private var showsTime: Bool { hovered || selecting }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sourceLabel {
                Text(sourceLabel).font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("\(identifier).source")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let speakerLabel {
                    Text(speakerLabel).font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.secondaryText)
                        .accessibilityIdentifier("\(identifier).speaker")
                }
                Spacer(minLength: 0)
                if showsTime {
                    Text(timeRange).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(identifier).timestamp")
                }
                if canPlay {
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AppTheme.accent)
                    .opacity(hovered || highlighted ? 1 : 0.72)
                    .accessibilityLabel(MeetingLanguageCopy.text("meeting.transcript.playSegment", "Play this segment"))
                    .accessibilityIdentifier("\(identifier).play")
                }
            }
            MeetingSelectableProse(text: text, identifier: "\(identifier).text", isInteracting: $selecting)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, AppTheme.Spacing.item)
        .background(highlighted ? AppTheme.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(highlighted ? MeetingLanguageCopy.text("meeting.transcript.highlighted", "Highlighted transcript segment") : "")
    }
}

struct MeetingCitedSummaryView: View {
    let result: MeetingResult
    let record: MeetingRecord
    @Environment(\.modelContext) private var meetingContext
    @State private var registeredSourceRefs = Set<String>()
    @State private var importError: String?
    let openCitation: (MeetingSummaryCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.section) {
            if let sections = result.summarySections, !sections.isEmpty {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.item) {
                        Text(section.title).font(.headline)
                        ForEach(section.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(displayText(item.text))
                                    .font(isHeading(item.text) ? .headline : .body)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                if MeetingSummaryTaskClassification.isTask(item, in: section, result: result) {
                                    taskButton(item, sectionID: section.id)
                                }
                                if item.citations.count == 1, let citation = item.citations.first {
                                    Button { openCitation(citation) } label: {
                                        citationLinkLabel
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("\(transcriptSourceLabel) 1")
                                    .accessibilityIdentifier("meeting.summary.citation.\(citation.trackID).\(citation.segmentID)")
                                } else if !item.citations.isEmpty {
                                    Menu {
                                        ForEach(Array(item.citations.enumerated()), id: \.offset) { index, citation in
                                            Button("\(transcriptSourceLabel) \(index + 1)") {
                                                openCitation(citation)
                                            }
                                            .accessibilityIdentifier("meeting.summary.citation.\(citation.trackID).\(citation.segmentID)")
                                        }
                                    } label: {
                                        citationLinkLabel
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(transcriptSourceLabel)
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("meeting.summary.section.\(section.id)")
                }
            } else if !result.summary.isEmpty {
                Text(result.summary).textSelection(.enabled)
            } else {
                Text(MeetingLanguageCopy.text("meeting.summary.empty", "No summary yet. Choose a format in meeting settings, then generate a summary using an available AI provider."))
                    .foregroundStyle(.secondary)
            }
            if let importError {
                Text(importError).font(.caption).foregroundStyle(AppTheme.destructive)
                    .accessibilityIdentifier("meeting.summary.task.error")
            }
            MeetingAIAccuracyNotice()
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.summary.document")
        .task(id: record.updatedAt) { refreshRegisteredTasks() }
    }

    private func taskButton(_ item: MeetingSummaryItem, sectionID: String) -> some View {
        let sourceRef = MeetingTodoImporter.summarySourceRef(item: item, meetingID: record.meetingID)
        let registered = !MeetingTodoImporter.summarySourceRefs(item: item, meeting: record)
            .isDisjoint(with: registeredSourceRefs)
        return Button {
            importError = nil
            do {
                _ = try MeetingTodoImporter.confirmSummaryItem(sectionID: sectionID, itemID: item.id,
                    reviewedSourceRef: sourceRef,
                    meeting: record, todoContext: AppDataContainer.shared.container.mainContext,
                    meetingContext: meetingContext)
                registeredSourceRefs.insert(sourceRef)
            } catch {
                importError = error.localizedDescription
            }
        } label: {
            Label(MeetingLanguageCopy.text(registered ? "meeting.summary.task.added" : "meeting.summary.task.add",
                registered ? "Added" : "Add task"), systemImage: registered ? "checkmark.circle" : "plus.circle")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: citationControlSize)
        }
        .buttonStyle(.borderless)
        .disabled(registered)
        .accessibilityLabel("\(MeetingLanguageCopy.text(registered ? "meeting.summary.task.added" : "meeting.summary.task.add", registered ? "Added" : "Add task")): \(displayText(item.text))")
        .accessibilityIdentifier("meeting.summary.task.\(sectionID).\(item.id)")
    }

    private func refreshRegisteredTasks() {
        let sourceRefs = (result.summarySections ?? []).flatMap { section in
            section.items.filter { MeetingSummaryTaskClassification.isTask($0, in: section, result: result) }
                .flatMap { MeetingTodoImporter.summarySourceRefs(item: $0, meeting: record) }
        }
        guard !sourceRefs.isEmpty else { registeredSourceRefs = []; return }
        do {
            let todos = try AppDataContainer.shared.container.mainContext.fetch(
                FetchDescriptor<Todo>(predicate: #Predicate { sourceRefs.contains($0.sourceRef) }))
            registeredSourceRefs = Set(todos.map(\.sourceRef))
        } catch {
            importError = error.localizedDescription
        }
    }

    private var transcriptSourceLabel: String {
        MeetingLanguageCopy.text("meeting.summary.source", "Transcript source")
    }

    private func isHeading(_ text: String) -> Bool {
        text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil
    }

    private func displayText(_ text: String) -> String {
        guard isHeading(text) else { return text }
        return text.replacingOccurrences(of: #"^#{1,6}\s+(?:\[\d+/\d+\]\s*)?"#,
            with: "", options: .regularExpression)
    }

    private var citationLinkLabel: some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.caption.weight(.medium))
            .foregroundStyle(AppTheme.accent)
            .frame(minWidth: citationControlSize, minHeight: citationControlSize)
            .help(AppLanguage.localized("meeting.summary.openTranscriptSource",
                defaultValue: AppLanguage.current == .english ? "View in transcript" : "전사문 위치 보기",
                language: .current))
    }

    private var citationControlSize: CGFloat {
        #if targetEnvironment(macCatalyst)
        28
        #else
        44
        #endif
    }
}

struct MeetingSummaryFormatControls: View {
    @Binding var format: MeetingSummaryFormat
    @Binding var instructions: String
    var body: some View {
        Picker(MeetingLanguageCopy.text("meeting.summary.format", "Summary format"), selection: $format) {
            ForEach(MeetingSummaryFormat.allCases, id: \.self) { option in
                Text(option.displayName()).tag(option)
            }
        }
        .accessibilityIdentifier("meeting.settings.summaryFormat")
        if format == .custom {
            Text(MeetingLanguageCopy.text("meeting.summary.instructions", "Custom instructions")).font(.subheadline)
            TextEditor(text: $instructions)
                .frame(minHeight: 120)
                .accessibilityLabel(MeetingLanguageCopy.text("meeting.summary.instructions", "Custom instructions"))
                .accessibilityIdentifier("meeting.settings.customInstructions")
        }
    }
}
