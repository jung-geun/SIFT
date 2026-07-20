package xyz.pieroot.sift

import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.text.Normalizer
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.Locale
import java.util.UUID
import kotlinx.serialization.Serializable

/** Local-only meeting contracts. Provider tags and raw audio are intentionally absent. */
enum class MeetingProcessingMode { ON_DEVICE, OPEN_AI, GOOGLE }
enum class MeetingStatus { RECORDING, PAUSED, INTERRUPTED, STOPPING, FINALIZING_TRANSCRIPT, EXTRACTING_ACTIONS, READY, FAILED, CANCELLED }

@Serializable
data class MeetingSegment(
    val id: String,
    val startMs: Long,
    val endMs: Long,
    val speakerIDs: List<String> = emptyList(),
    val text: String,
    val isFinal: Boolean = true,
    val confidence: Double? = null,
) {
    init {
        require(startMs >= 0 && endMs > startMs) { "invalid segment range" }
        require(confidence == null || confidence.isFinite() && confidence in 0.0..1.0) { "invalid confidence" }
        require(speakerIDs == speakerIDs.distinct().sorted()) { "speaker IDs must be sorted and unique" }
    }
}

@Serializable
data class ProviderActionDraftInput(
    val title: String,
    val notes: String = "",
    val assignee: String? = null,
    val dueAtISO8601: String? = null,
    val sourceSegmentIDs: List<String> = emptyList(),
    val confidence: Double = 0.0,
    val requiresReview: Boolean = true,
)

@Serializable
data class ProviderMeetingExtraction(
    val title: String,
    val summary: String,
    val decisions: List<String> = emptyList(),
    val unresolvedQuestions: List<String> = emptyList(),
    val actionDrafts: List<ProviderActionDraftInput> = emptyList(),
)

@Serializable
data class MeetingActionDraft(
    val id: String,
    val title: String,
    val notes: String,
    val assignee: String?,
    val dueAtISO8601: String?,
    val sourceSegmentIDs: List<String>,
    val confidence: Double,
    val requiresReview: Boolean,
)

@Serializable
data class MeetingResult(
    val transcriptRevision: Int,
    val title: String,
    val summary: String,
    val decisions: List<String>,
    val unresolvedQuestions: List<String>,
    val segments: List<MeetingSegment>,
    val actionDrafts: List<MeetingActionDraft>,
)

@Serializable
data class MeetingDiscontinuity(
    val mediaTimeMs: Long,
    val wallStartISO8601: String,
    val wallEndISO8601: String,
    val reason: String,
    val estimatedLostAudioMs: Long,
)

@Serializable
data class MeetingFlacPart(
    val index: Int,
    val partStartSample: Long,
    val ownedStartSample: Long,
    val ownedEndSample: Long,
    val byteCount: Long = 0,
    val sha256: String = "",
    val fileName: String = "part-%02d.flac".format(Locale.ROOT, index),
)

@Serializable
data class MeetingArtifact(
    val parts: List<MeetingFlacPart> = emptyList(),
    val meetingSampleCount: Long = 0,
    val discontinuities: List<MeetingDiscontinuity> = emptyList(),
    val droppedSamples: Long = 0,
    val routeChanges: Int = 0,
    val provisionalCursorMs: Long = 0,
)

@Serializable
data class SpeakerRange(val min: Int, val max: Int) {
    init { require(min in 1..8 && max in min..8) }
}

@Serializable
data class MeetingRecord(
    val meetingId: String,
    val mode: MeetingProcessingMode = MeetingProcessingMode.ON_DEVICE,
    val languageTag: String = "ko-KR",
    val timezoneIdentifier: String = "Asia/Seoul",
    val expectedSpeakerRange: SpeakerRange? = null,
    val retentionEnabled: Boolean = false,
    val disclosureVersionID: String = "local-v1",
    val status: MeetingStatus = MeetingStatus.READY,
    val transcriptRevision: Int = 0,
    val result: MeetingResult? = null,
    val confirmedTodoIDs: List<String> = emptyList(),
    val artifact: MeetingArtifact = MeetingArtifact(),
    val createdAtEpochMillis: Long = System.currentTimeMillis(),
    val updatedAtEpochMillis: Long = System.currentTimeMillis(),
) {
    init { require(UUID_REGEX.matches(meetingId)) { "meeting ID must be lowercase UUID" } }

    fun renameSpeaker(from: String, to: String): MeetingRecord {
        val current = result ?: return this
        val renamed = current.copy(segments = current.segments.map { segment ->
            segment.copy(speakerIDs = segment.speakerIDs.map { if (it == from) to else it }.distinct().sorted())
        })
        return copy(result = renamed, updatedAtEpochMillis = System.currentTimeMillis())
    }

    fun reviseSegments(segments: List<MeetingSegment>): MeetingRecord {
        validateSegments(segments)
        val nextRevision = transcriptRevision + 1
        return copy(
            transcriptRevision = nextRevision,
            status = MeetingStatus.READY,
            result = result?.copy(
                transcriptRevision = nextRevision,
                segments = segments,
                summary = "",
                title = result.title,
                decisions = emptyList(),
                unresolvedQuestions = emptyList(),
                actionDrafts = emptyList(),
            ),
            updatedAtEpochMillis = System.currentTimeMillis(),
        )
    }

    companion object {
        private val UUID_REGEX = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

        fun requireMeetingID(value: String): String {
            require(UUID_REGEX.matches(value)) { "meeting ID must be lowercase UUID" }
            return value
        }

        fun validateSegments(segments: List<MeetingSegment>, durationMs: Long? = null) {
            segments.zipWithNext().forEach { (a, b) ->
                require(compareValuesBy(a, b, MeetingSegment::startMs, MeetingSegment::endMs, MeetingSegment::id) < 0) {
                    "segments must be ordered by start, end, id"
                }
            }
            segments.forEach { segment ->
                require(durationMs == null || segment.endMs <= durationMs) { "segment outside meeting" }
            }
        }
    }
}

/** The canonical bytes used for stable replacement/action IDs on every platform. */
object MeetingCanonicalIds {
    private const val MAX_SAFE_INTEGER = 9_007_199_254_740_991L
    private val trimChars = setOf(
        '\u0009', '\u000A', '\u000B', '\u000C', '\u000D', ' ', '\u0085', '\u00A0', '\u1680',
        '\u2000', '\u2001', '\u2002', '\u2003', '\u2004', '\u2005', '\u2006', '\u2007', '\u2008', '\u2009', '\u200A',
        '\u2028', '\u2029', '\u202F', '\u205F', '\u3000',
    )

    fun replacementSegmentId(meetingId: String, transcriptRevision: Int, startMs: Long, endMs: Long, text: String): String =
        replacementSegmentId(meetingId, transcriptRevision.toLong(), startMs, endMs, text)

    fun replacementSegmentId(meetingId: String, transcriptRevision: Long, startMs: Long, endMs: Long, text: String): String {
        require(MeetingRecord.requireMeetingID(meetingId) == meetingId)
        require(transcriptRevision in 0..MAX_SAFE_INTEGER && startMs in 0..MAX_SAFE_INTEGER && endMs in 0..MAX_SAFE_INTEGER && endMs >= startMs)
        return digest(canonicalReplacementJson(meetingId, transcriptRevision, startMs, endMs, text))
    }

    fun canonicalReplacementJson(meetingId: String, transcriptRevision: Long, startMs: Long, endMs: Long, text: String): String {
        require(MeetingRecord.requireMeetingID(meetingId) == meetingId)
        require(transcriptRevision in 0..MAX_SAFE_INTEGER && startMs in 0..MAX_SAFE_INTEGER && endMs in 0..MAX_SAFE_INTEGER && endMs >= startMs)
        return canonicalObject(listOf("meetingId" to meetingId, "transcriptRevision" to transcriptRevision, "startMs" to startMs, "endMs" to endMs, "text" to normalizedText(text)))
    }

    fun actionId(meetingId: String, sourceSegmentIds: List<String>, title: String, assignee: String?, dueAtISO8601: String?): String =
        digest(canonicalActionJson(meetingId, sourceSegmentIds, title, assignee, dueAtISO8601))

    fun canonicalActionJson(meetingId: String, sourceSegmentIds: List<String>, title: String, assignee: String?, dueAtISO8601: String?): String {
        require(MeetingRecord.requireMeetingID(meetingId) == meetingId)
        val ids = sourceSegmentIds.distinct().sorted()
        require(ids.all { it.isNotEmpty() && it.all { ch -> ch.code in 0x21..0x7e && ch != '"' && ch != '\\' } })
        val due = dueAtISO8601?.also { validatedDueAtMillis(it) }
        return canonicalObject(listOf("meetingId" to meetingId, "sourceSegmentIds" to ids, "title" to normalizedInline(title), "assignee" to assignee?.let(::normalizedInline), "dueAt" to due))
    }

    fun normalizedText(value: String): String = normalize(value, collapse = false)
    fun normalizedInline(value: String): String = normalize(value, collapse = true)

    private fun normalize(value: String, collapse: Boolean): String {
        var index = 0
        while (index < value.length) {
            val ch = value[index]
            if (Character.isHighSurrogate(ch)) {
                require(index + 1 < value.length && Character.isLowSurrogate(value[index + 1])) { "unpaired surrogate" }
                index += 2
            } else {
                require(!Character.isLowSurrogate(ch)) { "unpaired surrogate" }
                index += 1
            }
        }
        var nfc = Normalizer.normalize(value, Normalizer.Form.NFC).replace("\r\n", "\n").replace('\r', '\n')
        nfc = nfc.trim { it in trimChars }
        return if (!collapse) nfc else nfc.split(Regex("[\\u0009-\\u000D\\u0020\\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]+")).filter { it.isNotEmpty() }.joinToString(" ")
    }

    fun validatedDueAtMillis(value: String): Long {
        require(value.matches(Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$"))) { "dueAt must be UTC milliseconds" }
        val parsed = try {
            Instant.parse(value)
        } catch (_: DateTimeParseException) {
            throw IllegalArgumentException("invalid dueAt")
        }
        val canonical = DateTimeFormatter
            .ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.ROOT)
            .withZone(ZoneOffset.UTC)
            .format(parsed)
        require(canonical == value) { "dueAt must preserve UTC milliseconds" }
        return parsed.toEpochMilli()
    }
    private fun canonicalObject(entries: List<Pair<String, Any?>>): String =
        entries.joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) -> "${string(key)}:${json(value)}" }
    private fun json(value: Any?): String = when (value) {
        null -> "null"
        is String -> string(value)
        is Int, is Long -> value.toString()
        is List<*> -> value.joinToString(separator = ",", prefix = "[", postfix = "]") { json(it) }
        else -> error("unsupported canonical value")
    }
    private fun string(value: String): String = buildString {
        append('"')
        value.forEach { ch ->
            when (ch) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\t' -> append("\\t")
                '\n' -> append("\\n")
                '\u000C' -> append("\\f")
                '\r' -> append("\\r")
                in '\u0000'..'\u001F' -> append("\\u%04x".format(Locale.ROOT, ch.code))
                else -> append(ch)
            }
        }
        append('"')
    }
    private fun digest(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray(StandardCharsets.UTF_8)).joinToString("") { "%02x".format(it) }.take(32)
}

class MeetingTimeline(private val sampleRate: Int = 16_000) {
    var mediaSamples: Long = 0; private set
    var wallStartEpochMillis: Long? = null; private set
    var status: MeetingStatus = MeetingStatus.RECORDING; private set
    val discontinuities = mutableListOf<MeetingDiscontinuity>()
    val maxSamples = 6L * 60 * 60 * sampleRate
    private var pendingReason: String? = null
    private var pendingStartEpochMillis: Long? = null

    fun start(now: Long = System.currentTimeMillis()) {
        if (wallStartEpochMillis == null) wallStartEpochMillis = now
        status = MeetingStatus.RECORDING
    }

    fun append(capturedSamples: Int) {
        require(capturedSamples >= 0)
        if (status != MeetingStatus.RECORDING) return
        mediaSamples = (mediaSamples + capturedSamples).coerceAtMost(maxSamples)
        if (mediaSamples >= maxSamples) status = MeetingStatus.STOPPING
    }

    fun pause(reason: String, now: Long = System.currentTimeMillis()) {
        if (status != MeetingStatus.RECORDING) return
        status = if (reason == "interruption") MeetingStatus.INTERRUPTED else MeetingStatus.PAUSED
        pendingReason = reason
        pendingStartEpochMillis = now
    }

    fun resume(now: Long = System.currentTimeMillis()) {
        if (status != MeetingStatus.PAUSED && status != MeetingStatus.INTERRUPTED) return
        closeDiscontinuity(now)
        status = MeetingStatus.RECORDING
    }

    fun stop(now: Long = System.currentTimeMillis()) {
        if (status == MeetingStatus.PAUSED || status == MeetingStatus.INTERRUPTED) closeDiscontinuity(now)
        status = MeetingStatus.STOPPING
    }

    fun enforcePauseLimit(now: Long = System.currentTimeMillis()) {
        if ((status == MeetingStatus.PAUSED || status == MeetingStatus.INTERRUPTED) &&
            now - (pendingStartEpochMillis ?: now) >= 30L * 60L * 1000L) {
            stop(now)
        }
    }

    private fun closeDiscontinuity(end: Long) {
        val start = pendingStartEpochMillis ?: end
        discontinuities += MeetingDiscontinuity(
            mediaTimeMs = mediaSamples * 1000 / sampleRate,
            wallStartISO8601 = Instant.ofEpochMilli(start).toString(),
            wallEndISO8601 = Instant.ofEpochMilli(end).toString(),
            reason = pendingReason ?: "pause",
            estimatedLostAudioMs = (end - start).coerceAtLeast(0),
        )
        pendingReason = null
        pendingStartEpochMillis = null
    }
}

object MeetingRevisionEditor {
    fun editSegments(meetingID: String, result: MeetingResult, segments: List<MeetingSegment>): MeetingResult {
        if (segments == result.segments) return result
        val nextRevision = result.transcriptRevision + 1
        val normalized = segments.map { segment ->
            MeetingSegment(
                id = MeetingCanonicalIds.replacementSegmentId(meetingID, nextRevision, segment.startMs, segment.endMs, segment.text),
                startMs = segment.startMs,
                endMs = segment.endMs,
                speakerIDs = segment.speakerIDs,
                text = segment.text,
                isFinal = segment.isFinal,
                confidence = segment.confidence,
            )
        }.sortedWith(compareBy<MeetingSegment> { it.startMs }.thenBy { it.endMs }.thenBy { it.id })
        MeetingRecord.validateSegments(normalized)
        return MeetingResult(
            transcriptRevision = nextRevision,
            title = result.title,
            summary = "",
            decisions = emptyList(),
            unresolvedQuestions = emptyList(),
            segments = normalized,
            actionDrafts = emptyList(),
        )
    }

    fun renameSpeaker(result: MeetingResult, from: String, to: String): MeetingResult =
        result.copy(segments = result.segments.map { segment ->
            segment.copy(speakerIDs = segment.speakerIDs.map { if (it == from) to else it }.distinct().sorted())
        })
}

object DeterministicMeetingExtraction {
    private val actionWords = listOf("해 주세요", "해주세요", "부탁", "보내", "확인", "정리", "준비", "send", "please", "follow up")
    fun extract(segments: List<MeetingSegment>, revision: Int = 0): ProviderMeetingExtraction {
        MeetingRecord.validateSegments(segments)
        val title = segments.firstOrNull()?.text?.let { if (it.length > 40) it.take(40) + "…" else it } ?: "회의"
        val actions = segments.filter { segment -> actionWords.any { segment.text.contains(it, ignoreCase = true) } }.mapNotNull { segment ->
            val text = MeetingCanonicalIds.normalizedText(segment.text)
            if (text.isBlank()) null else ProviderActionDraftInput(text, sourceSegmentIDs = listOf(segment.id), confidence = 0.7, requiresReview = true)
        }.distinctBy { it.sourceSegmentIDs to it.title }
        return ProviderMeetingExtraction(title, segments.joinToString(" ") { it.text }.trim(), actionDrafts = actions)
    }

    fun toResult(meetingId: String, segments: List<MeetingSegment>, revision: Int = 0): MeetingResult {
        val extraction = extract(segments, revision)
        val drafts = extraction.actionDrafts.map { input ->
            val normalizedIds = input.sourceSegmentIDs.distinct().sorted()
            MeetingActionDraft(MeetingCanonicalIds.actionId(meetingId, normalizedIds, input.title, input.assignee, input.dueAtISO8601), input.title, input.notes, input.assignee, input.dueAtISO8601, normalizedIds, input.confidence, true)
        }
        return MeetingResult(revision, extraction.title, extraction.summary, extraction.decisions, extraction.unresolvedQuestions, segments, drafts)
    }
}
