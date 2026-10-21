import Foundation
import Testing
@testable import todo

@Suite("Source-local transcript attribution")
@MainActor
struct MeetingTranscriptAttributionTests {
    private func segment(_ id: String, _ speaker: String?, _ text: String, at index: Int) -> MeetingSegment {
        MeetingSegment(id: id, startMs: Int64(index * 2_000), endMs: Int64(index * 2_000 + 1_000),
                       speakerIDs: speaker.map { [$0] } ?? [], text: text)
    }

    private func report(_ segments: [MeetingSegment], meetingID: String = "source-a",
                        profiles: [MeetingSpeakerProfile] = []) -> MeetingTranscriptAttribution {
        MeetingTranscriptAttribution(meetingID: meetingID, result: MeetingResult(segments: segments), profiles: profiles)
    }

    private func draft(_ evidence: [String], assignee: String? = nil) -> MeetingActionDraft {
        MeetingActionDraft(id: "draft", title: "Review the source action", assignee: assignee, sourceSegmentIDs: evidence)
    }

    @Test("Korean introduction and nickname connect distinct activity kinds to their actor")
    func koreanNameAliasAndActivities() throws {
        let attribution = report([
            segment("intro", "s1", "저는 김민수입니다, 미노라고 불러주세요.", at: 0),
            segment("done", "s1", "제가 API 구현을 완료했습니다.", at: 1),
            segment("promise", "s1", "제가 내일까지 보고서를 보내겠습니다.", at: 2),
            segment("request", "s2", "미노님, 배포 상태를 확인해 주세요.", at: 3)
        ])
        let identity = try #require(attribution.names.first)
        #expect(identity.speakerID == "s1")
        #expect(identity.name == "김민수")
        #expect(identity.aliases == ["미노"])
        #expect(identity.sourceSegmentIDs == ["intro"])
        #expect(!identity.isManual)
        #expect(attribution.activities.map(\.kind) == [.completed, .committed, .requested])
        #expect(attribution.activities.allSatisfy { $0.speakerID == "s1" && $0.personName == "김민수" })
        #expect(Set(attribution.activities.map(\.personID)).count == 1)
        #expect(attribution.activities.flatMap(\.sourceSegmentIDs) == ["done", "promise", "request"])
        #expect(attribution.assignee(for: draft(["request"], assignee: "미노")) == "김민수")
        #expect(attribution.assignee(for: draft(["done"])) == nil)
    }

    @Test("English aliases resolve requests without renaming the requesting speaker")
    func englishNameAliasAndActivities() throws {
        let attribution = report([
            segment("intro", "a", "My name is Alex, call me Lex.", at: 0),
            segment("other", "b", "My name is Morgan.", at: 1),
            segment("done", "a", "I already completed the migration.", at: 2),
            segment("promise", "a", "I'll deliver the report tomorrow.", at: 3),
            segment("request", "b", "Lex, could you review the release?", at: 4)
        ])
        #expect(attribution.names.first(where: { $0.speakerID == "a" })?.aliases == ["Lex"])
        #expect(attribution.names.first(where: { $0.speakerID == "b" })?.name == "Morgan")
        #expect(attribution.activities.map(\.kind) == [.completed, .committed, .requested])
        #expect(attribution.activities.allSatisfy { $0.speakerID == "a" })
        #expect(attribution.assignee(for: draft(["promise"])) == "Alex")
        #expect(attribution.assignee(for: draft(["request"], assignee: "Lex")) == "Alex")
        let request = try #require(attribution.activities.last)
        #expect(request.sourceSegmentIDs == ["request"])
        #expect(!request.text.isEmpty)
    }

    @Test("Full-source resolution includes introductions after work and speaker changes")
    func laterIntroductionsAndSpeakerChanges() {
        let attribution = report([
            segment("earlier", "a", "I finished the prototype.", at: 0),
            segment("other-work", "b", "I will prepare the tests.", at: 1),
            segment("intro-a", "a", "My name is Alex.", at: 2),
            segment("intro-b", "b", "저는 박지수입니다.", at: 3)
        ])
        #expect(attribution.activities.first?.personName == "Alex")
        #expect(attribution.activities.last?.personName == "박지수")
        #expect(attribution.activities.first?.personID != attribution.activities.last?.personID)
        #expect(attribution.assignee(for: draft(["other-work"])) == "박지수")
    }

    @Test("An explicit third-person actor is not the current speaker's identity")
    func thirdPersonDoesNotRenameSpeaker() throws {
        let attribution = report([
            segment("intro", "a", "My name is Morgan.", at: 0),
            segment("mention", "a", "Alex completed the migration.", at: 1),
            segment("own", "a", "I will review the tests.", at: 2)
        ])
        #expect(attribution.names.count == 1)
        #expect(attribution.names.first?.name == "Morgan")
        let mentioned = try #require(attribution.activities.first)
        #expect(mentioned.personName == "Alex")
        #expect(mentioned.speakerID == nil)
        #expect(attribution.activities.last?.speakerID == "a")
        #expect(attribution.assignee(for: draft(["own"])) == "Morgan")
    }

    @Test("Named external addressees are supported without claiming the requester's voice")
    func namedRequestsWithoutKnownSpeaker() {
        let attribution = report([
            segment("en", "requester", "Élodie, send the report tomorrow.", at: 0),
            segment("ko", "requester", "김민수님, 자료를 공유해 주세요.", at: 1)
        ])
        #expect(attribution.names.isEmpty)
        #expect(attribution.activities.map(\.kind) == [.requested, .requested])
        #expect(attribution.activities.allSatisfy { $0.speakerID == nil })
        #expect(attribution.assignee(for: draft(["en"])) == "Élodie")
        #expect(attribution.assignee(for: draft(["ko"])) == "김민수")
    }

    @Test("An adjacent different-speaker acceptance can identify the addressee")
    func addressedAcknowledgement() throws {
        let attribution = report([
            segment("request", "a", "Alex, please send the report.", at: 0),
            segment("reply", "b", "Sure, I'll send it.", at: 1),
            segment("later", "b", "I completed the report.", at: 2)
        ])
        let name = try #require(attribution.names.first)
        #expect(name.speakerID == "b")
        #expect(name.name == "Alex")
        #expect(Set(name.sourceSegmentIDs) == ["request", "reply"])
        #expect(attribution.activities.first?.speakerID == "b")
        #expect(attribution.activities.last?.personName == "Alex")
    }

    @Test("Korean addressed acceptance identifies the listener, not the requester")
    func koreanAddressedAcknowledgement() {
        let attribution = report([
            segment("request", "a", "김민수님, 보고서를 보내 주세요.", at: 0),
            segment("reply", "b", "네, 제가 하겠습니다.", at: 1)
        ])
        #expect(attribution.names.first?.speakerID == "b")
        #expect(attribution.names.first?.name == "김민수")
        #expect(attribution.assignee(for: draft(["request"])) == "김민수")
    }

    @Test("Mentions, questions, quotes and non-acceptances do not supply names")
    func rejectsWeakNameEvidence() {
        let attribution = report([
            segment("mention", "a", "Alex is on vacation.", at: 0),
            segment("quoted", "a", "She said \"My name is Jordan. Call me Jo. I finished the work.\"", at: 1),
            segment("question", "a", "My name is Alex?", at: 2),
            segment("request", "a", "Jordan, please send the report.", at: 3),
            segment("reply", "b", "Yes, the schedule changed.", at: 4),
            segment("working", "c", "I'm working on the design.", at: 5)
        ])
        #expect(attribution.names.isEmpty)
        #expect(attribution.activities.count == 1)
        #expect(attribution.activities.first?.speakerID == nil)
    }

    @Test("Negated and question-only completed claims do not become work evidence")
    func rejectsNegatedAndQuestionedWork() {
        let attribution = report([
            segment("intro", "a", "My name is Alex.", at: 0),
            segment("negated", "a", "I did not complete the report.", at: 1),
            segment("denied", "a", "I haven't finished the migration.", at: 2),
            segment("question", "a", "I completed the report?", at: 3),
            segment("ko-negative", "a", "제가 배포를 완료하지 않았습니다.", at: 4),
            segment("ko-question", "a", "제가 보고서를 완료했나요?", at: 5),
            segment("future", "a", "I will finish the report tomorrow.", at: 6),
            segment("actual", "a", "I just sent the report.", at: 7)
        ])
        #expect(attribution.activities.map(\.kind) == [.committed, .completed])
        #expect(attribution.activities.flatMap(\.sourceSegmentIDs) == ["future", "actual"])
    }

    @Test("Overlapping and multi-speaker segments cannot rename or claim first-person work")
    func overlappingAndMixedSpeakers() {
        let overlapA = MeetingSegment(id: "overlap-a", startMs: 0, endMs: 2_000,
                                      speakerIDs: ["a"], text: "My name is Alex. I completed the report.")
        let overlapB = MeetingSegment(id: "overlap-b", startMs: 1_000, endMs: 3_000,
                                      speakerIDs: ["b"], text: "My name is Morgan. I will send the report.")
        let mixed = MeetingSegment(id: "mixed", startMs: 4_000, endMs: 5_000,
                                   speakerIDs: ["a", "b"], text: "저는 김민수입니다. 제가 배포를 완료했습니다.")
        let attribution = report([overlapA, overlapB, mixed])
        #expect(attribution.names.isEmpty)
        #expect(attribution.activities.isEmpty)
    }

    @Test("Contradictory names and ambiguous aliases stay unconfirmed")
    func conflictingNamesAndAliases() {
        let conflict = report([
            segment("one", "a", "My name is Alex.", at: 0),
            segment("two", "a", "My name is Jordan.", at: 1),
            segment("work", "a", "I will send the report.", at: 2),
            segment("named", "b", "Alex, please review the release.", at: 3)
        ])
        #expect(conflict.names.isEmpty)
        #expect(conflict.activities.allSatisfy { $0.personName == nil })
        #expect(conflict.assignee(for: draft(["work"])) == nil)
        #expect(conflict.assignee(for: draft(["named"])) == nil)
        let aliasConflict = report([
            segment("a", "a", "My name is Alex, call me Lex.", at: 0),
            segment("b", "b", "My name is Jordan, call me Lex.", at: 1),
            segment("request", "c", "Lex, please review the release.", at: 2)
        ])
        #expect(aliasConflict.names.count == 2)
        #expect(aliasConflict.activities.first?.personName == nil)
        #expect(aliasConflict.activities.first?.speakerID == nil)
        #expect(aliasConflict.assignee(for: draft(["request"], assignee: "Lex")) == nil)
    }

    @Test("Manual names remain authoritative and overlays leave original profiles untouched")
    func manualOverride() {
        let profiles = [MeetingSpeakerProfile(id: "a", ordinal: 1, displayName: "수동 이름"),
                        MeetingSpeakerProfile(id: "b", ordinal: 2, displayName: nil)]
        let attribution = report([
            segment("intro-a", "a", "My name is Alex, call me Lex.", at: 0),
            segment("intro-b", "b", "저는 박지수입니다.", at: 1),
            segment("work", "a", "I will prepare the report.", at: 2)
        ], profiles: profiles)
        #expect(attribution.names.first(where: { $0.speakerID == "a" })?.isManual == true)
        #expect(attribution.assignee(for: draft(["work"])) == "수동 이름")
        let overlay = attribution.applyingNames(to: profiles)
        #expect(overlay[0].displayName == "수동 이름")
        #expect(overlay[1].displayName == "박지수")
        #expect(profiles[1].displayName == nil)
    }

    @Test("Identical names do not merge distinct speaker IDs or source meetings")
    func sourceAndSpeakerIsolation() throws {
        let segments = [
            segment("intro-a", "a", "My name is Alex.", at: 0),
            segment("intro-b", "b", "My name is Alex.", at: 1),
            segment("work-a", "a", "I will prepare the report.", at: 2),
            segment("work-b", "b", "I will review the tests.", at: 3),
            segment("request", "c", "Alex, please send the report.", at: 4)
        ]
        let first = report(segments)
        let second = report(segments, meetingID: "source-b")
        #expect(first.names.count == 2)
        let a = try #require(first.activities.first(where: { $0.sourceSegmentIDs == ["work-a"] }))
        let b = try #require(first.activities.first(where: { $0.sourceSegmentIDs == ["work-b"] }))
        #expect(a.personID != b.personID)
        #expect(a.personID != second.activities.first?.personID)
        #expect(a.id != second.activities.first?.id)
        #expect(first.activities.last?.personName == nil)
        #expect(first.assignee(for: draft(["work-a", "work-b"])) == nil)
        #expect(first.assignee(for: draft(["request"])) == nil)
        #expect(first == report(segments))
    }

    @Test("Missing evidence, invented names and mixed actor evidence cannot verify an assignee")
    func verifiesAssigneesOnlyFromEvidence() {
        let attribution = report([
            segment("intro-a", "a", "My name is Alex.", at: 0),
            segment("intro-b", "b", "My name is Morgan.", at: 1),
            segment("work-a", "a", "I will prepare the report.", at: 2),
            segment("work-b", "b", "I will review the tests.", at: 3)
        ])
        #expect(attribution.assignee(for: draft([])) == nil)
        #expect(attribution.assignee(for: draft(["missing"], assignee: "Alex")) == nil)
        #expect(attribution.assignee(for: draft(["intro-a"], assignee: "Alex")) == nil)
        #expect(attribution.assignee(for: draft(["work-a"], assignee: "Taylor")) == nil)
        #expect(attribution.assignee(for: draft(["work-a"], assignee: "Morgan")) == nil)
        #expect(attribution.assignee(for: draft(["work-a", "work-b"])) == nil)
        #expect(attribution.assignee(for: draft(["work-a"], assignee: "alex")) == "Alex")
    }

    @Test("General we, unlabelled I and group addressees do not become one person's activity")
    func avoidsArbitrarySpeakerAssignment() {
        let attribution = report([
            segment("intro", "a", "My name is Alex.", at: 0),
            segment("we", "a", "We will send the report.", at: 1),
            segment("unlabelled", nil, "I completed the migration.", at: 2),
            segment("group", "a", "Alex and Morgan, please review the report.", at: 3),
            segment("observation", "a", "The report looks good.", at: 4)
        ])
        #expect(attribution.activities.isEmpty)
    }

    @Test("Unicode names and aliases remain usable while unreasonable names are rejected")
    func unicodeAndNameBounds() {
        let attribution = report([
            segment("intro", "a", "My name is Élodie Dupont, call me Élo.", at: 0),
            segment("request", "b", "Élo, please review the release.", at: 1),
            segment("long", "c", "My name is \(String(repeating: "A", count: 100)).", at: 2)
        ])
        #expect(attribution.names.count == 1)
        #expect(attribution.names.first?.name == "Élodie Dupont")
        #expect(attribution.assignee(for: draft(["request"])) == "Élodie Dupont")
    }

    @Test("Retranscription and edits recompute the projection without retaining stale evidence")
    func recomputesAfterEdits() {
        let initial = report([
            segment("intro", "a", "My name is Alex.", at: 0),
            segment("work", "a", "I will send the report.", at: 1)
        ])
        let edited = report([
            segment("intro-new", "a", "The speaker did not introduce themselves.", at: 0),
            segment("work-new", "a", "I will send the report.", at: 1)
        ])
        #expect(initial.names.count == 1)
        #expect(edited.names.isEmpty)
        #expect(edited.activities.first?.personName == nil)
        #expect(edited.assignee(for: draft(["work"])) == nil)
        #expect(edited.assignee(for: draft(["work-new"])) == nil)
    }

    @Test("Legacy ID placeholders do not prevent inferred display names")
    func ignoresLegacyPlaceholderNames() {
        let profiles = [MeetingSpeakerProfile(id: "a", ordinal: 1, displayName: "a")]
        let attribution = report([segment("intro", "a", "I'm Alex.", at: 0)], profiles: profiles)
        #expect(attribution.names.first?.name == "Alex")
        #expect(attribution.names.first?.isManual == false)
        #expect(attribution.applyingNames(to: profiles).first?.displayName == "Alex")
        #expect(profiles.first?.displayName == "a")
    }

    @Test("Completed and promised work in one segment retain both kinds of evidence")
    func mixedCompletedAndFutureWork() {
        let attribution = report([
            segment("intro", "a", "My name is Alex.", at: 0),
            segment("mixed", "a", "I completed the prototype and will send the report tomorrow.", at: 1),
            segment("ko-mixed", "a", "제가 구현을 완료했고 내일 배포하겠습니다.", at: 2)
        ])
        for id in ["mixed", "ko-mixed"] {
            let activities = attribution.activities.filter { $0.sourceSegmentIDs == [id] }
            #expect(Set(activities.map(\.kind.rawValue)) == ["completed", "committed"])
            #expect(activities.allSatisfy { $0.speakerID == "a" && $0.personName == "Alex" })
            #expect(attribution.assignee(for: draft([id])) == "Alex")
        }
    }

    @Test("Denials, delayed replies and requester self-answers cannot identify an addressee")
    func rejectsUnsafeAcknowledgements() {
        let denied = report([
            segment("request", "a", "Alex, please send the report.", at: 0),
            segment("reply", "b", "Sure, I won't send it.", at: 1)
        ])
        #expect(denied.names.isEmpty)
        let delayed = report([
            segment("request", "a", "Alex, please send the report.", at: 0),
            segment("reply", "b", "Sure, I'll send it.", at: 5)
        ])
        #expect(delayed.names.isEmpty)
        let selfAnswer = report([
            segment("request", "a", "Alex, can you please send the report?", at: 0),
            segment("reply", "a", "Sure, I'll send it.", at: 1)
        ])
        #expect(selfAnswer.names.isEmpty)
        #expect(selfAnswer.activities.first?.kind == .requested)
        #expect(selfAnswer.activities.first?.speakerID == nil)
    }

    @Test("Common Korean completed verbs retain their named speaker and evidence", arguments: [
        "제가 견적서를 제출했습니다.",
        "제가 Synthetic microphone 자료를 검토했습니다.",
        "제가 발표 자료를 준비했습니다.",
        "제가 고객에게 결과를 전달했습니다.",
        "제가 회의록을 작성했습니다.",
        "제가 배포 상태를 확인했습니다."
    ])
    func commonKoreanCompletedWork(_ text: String) {
        let attribution = report([
            segment("intro", "a", "저는 김민수입니다. 미노라고 불러주세요.", at: 0),
            segment("done", "a", text, at: 1),
            segment("promise", "a", "제가 보고서를 공유하겠습니다.", at: 2),
            segment("request", "b", "미노님, 회의 요약을 보내주세요.", at: 3)
        ])
        #expect(attribution.activities.map(\.kind) == [.completed, .committed, .requested])
        #expect(attribution.activities.allSatisfy { $0.personName == "김민수" && $0.speakerID == "a" })
        #expect(attribution.activities.first?.sourceSegmentIDs == ["done"])
        #expect(attribution.assignee(for: draft(["done"])) == nil)
        #expect(attribution.assignee(for: draft(["request"])) == "김민수")
    }

    @Test("Korean named past-tense work is not a request to the current speaker")
    func namedKoreanCompletedWork() {
        let attribution = report([
            segment("intro", "a", "저는 김민수입니다.", at: 0),
            segment("named", "b", "김민수님이 견적서를 제출했습니다.", at: 1),
            segment("requested", "b", "김민수님, 견적서를 제출해 주세요.", at: 2)
        ])
        #expect(attribution.activities.map(\.kind) == [.completed, .requested])
        #expect(attribution.activities.allSatisfy { $0.speakerID == "a" })
        #expect(attribution.assignee(for: draft(["named"])) == nil)
        #expect(attribution.assignee(for: draft(["requested"])) == "김민수")
    }
}
