package xyz.pieroot.sift

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class MeetingExtractionTest {
    private val meetingId = "123e4567-e89b-12d3-a456-426614174000"

    @Test
    fun canonicalIds_matchSharedGoldenVectors() {
        assertEquals(
            "{\"meetingId\":\"123e4567-e89b-12d3-a456-426614174000\",\"transcriptRevision\":0,\"startMs\":0,\"endMs\":1000,\"text\":\"민수님이 다음 주 화요일까지 견적서를 보내주세요\"}",
            MeetingCanonicalIds.canonicalReplacementJson(meetingId, 0, 0, 1_000, "  민수님이 다음 주 화요일까지 견적서를 보내주세요\r\n"),
        )
        assertEquals(
            "b1d9ec713d8164418c29c9fa85b30423",
            MeetingCanonicalIds.replacementSegmentId(meetingId, 0, 0, 1_000, "  민수님이 다음 주 화요일까지 견적서를 보내주세요\r\n"),
        )
        assertEquals(
            "029e3179e11f497b4342bcb902c98b20",
            MeetingCanonicalIds.replacementSegmentId(meetingId, 9_007_199_254_740_991L, 0, 9_007_199_254_740_991L, "앞\u2028중간\u2029끝"),
        )
        assertEquals(
            "ea912f8e12cf7512daa4ea43a2fe958f",
            MeetingCanonicalIds.actionId(meetingId, listOf("bbbb", "aaaa", "bbbb"), "  견적서\u00a0제출  ", null, null),
        )
        assertEquals(
            "1441a82b6dcff9b5de1388f3db781c87",
            MeetingCanonicalIds.actionId(meetingId, listOf("0001", "0002"), "\t정산  자료\n공유 ", " 민수\u2003님 ", "2026-07-14T00:00:00.000Z"),
        )
    }

    @Test
    fun canonicalIds_rejectUnsafeIntegerSurrogateAndInvalidDate() {
        assertThrows(IllegalArgumentException::class.java) {
            MeetingCanonicalIds.replacementSegmentId(meetingId, 9_007_199_254_740_992L, 0, 1, "x")
        }
        assertThrows(IllegalArgumentException::class.java) {
            MeetingCanonicalIds.actionId(meetingId, listOf("a"), "x", null, "2026-02-29T00:00:00.000Z")
        }
        assertThrows(IllegalArgumentException::class.java) {
            MeetingCanonicalIds.actionId(meetingId, listOf("a"), String(charArrayOf('\uD800')), null, null)
        }
    }

    @Test
    fun revision_editsRegenerateIDsAndInvalidateUnconfirmedOutputs() {
        val old = MeetingSegment("old", 0, 1_000, text = "민수님이 견적서를 보내주세요")
        val draft = MeetingActionDraft("draft", "견적서 보내기", "", null, null, listOf("old"), 0.8, true)
        val result = MeetingResult(0, "회의", "요약", listOf("결정"), listOf("질문"), listOf(old), listOf(draft))

        val revised = MeetingRevisionEditor.editSegments(meetingId, result, listOf(old.copy(text = "민수님이 다음 주 화요일까지 견적서를 보내주세요")))

        assertEquals(1, revised.transcriptRevision)
        assertEquals("", revised.summary)
        assertTrue(revised.actionDrafts.isEmpty())
        assertEquals("adcddfedb6c926f07e5b756b7e80890a", revised.segments.single().id)
    }

    @Test
    fun deterministicExtraction_makesReviewDraftWithoutDueDateGuess() {
        val segment = MeetingSegment("source-1", 0, 1_000, text = "민수님이 다음 주 화요일까지 견적서를 보내주세요")
        val result = DeterministicMeetingExtraction.toResult(meetingId, listOf(segment))
        val draft = result.actionDrafts.single()

        assertEquals(listOf("source-1"), draft.sourceSegmentIDs)
        assertNull(draft.dueAtISO8601)
        assertTrue(draft.requiresReview)
    }

    @Test
    fun timeline_doesNotAdvanceDuringPauseAndStopsAtLimit() {
        val timeline = MeetingTimeline()
        timeline.start(0)
        timeline.append(16_000)
        timeline.pause("interruption", 1_000)
        timeline.enforcePauseLimit(1_801_000)

        assertEquals(16_000, timeline.mediaSamples)
        assertEquals(MeetingStatus.STOPPING, timeline.status)
        assertEquals(1, timeline.discontinuities.size)
    }
    @Test
    fun partLayout_keepsExactOverlapAndOwnership() {
        val total = MeetingPartLayout.OWNED_PART_SAMPLES + 1
        val windows = MeetingPartLayout.windows(total)

        assertEquals(2, windows.size)
        assertEquals(0L, windows[0].partStartSample)
        assertEquals(MeetingPartLayout.OWNED_PART_SAMPLES, windows[0].ownedEndSample)
        assertEquals(MeetingPartLayout.OWNED_PART_SAMPLES - MeetingPartLayout.OVERLAP_SAMPLES, windows[1].partStartSample)
        assertEquals(MeetingPartLayout.OWNED_PART_SAMPLES, windows[1].ownedStartSample)
        assertEquals(MeetingPartLayout.OVERLAP_SAMPLES + 1, windows[1].decodedSampleCount)

        val manifest = windows.map {
            MeetingFlacPart(it.index, it.partStartSample, it.ownedStartSample, it.ownedEndSample)
        }
        MeetingPartLayout.validate(manifest, total)
    }
}
