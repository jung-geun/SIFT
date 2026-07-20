package xyz.pieroot.sift

/** Canonical 16 kHz ownership and overlap equations shared by capture and manifest validation. */
data class MeetingPartWindow(
    val index: Int,
    val partStartSample: Long,
    val ownedStartSample: Long,
    val ownedEndSample: Long,
) {
    val decodedSampleCount: Long get() = ownedEndSample - partStartSample
}

object MeetingPartLayout {
    const val SAMPLE_RATE = 16_000L
    const val OWNED_PART_SAMPLES = 9_600_000L
    const val OVERLAP_SAMPLES = 32_000L
    const val MAX_MEETING_SAMPLES = 345_600_000L

    fun windows(totalSamples: Long): List<MeetingPartWindow> {
        require(totalSamples in 1..MAX_MEETING_SAMPLES) { "meeting sample count outside six-hour limit" }
        val count = ((totalSamples + OWNED_PART_SAMPLES - 1) / OWNED_PART_SAMPLES).toInt()
        require(count in 1..36) { "meeting part count outside limit" }
        return (0 until count).map { index ->
            val ownedStart = index * OWNED_PART_SAMPLES
            val ownedEnd = minOf((index + 1) * OWNED_PART_SAMPLES, totalSamples)
            MeetingPartWindow(index, maxOf(0L, ownedStart - OVERLAP_SAMPLES), ownedStart, ownedEnd)
        }
    }

    fun validate(parts: List<MeetingFlacPart>, totalSamples: Long) {
        val expected = windows(totalSamples)
        require(parts.size == expected.size) { "part count mismatch" }
        expected.zip(parts).forEach { (window, part) ->
            require(part.index == window.index) { "part index mismatch" }
            require(part.partStartSample == window.partStartSample) { "part overlap mismatch" }
            require(part.ownedStartSample == window.ownedStartSample) { "owned start mismatch" }
            require(part.ownedEndSample == window.ownedEndSample) { "owned end mismatch" }
            require(window.decodedSampleCount > 0) { "empty decoded part" }
        }
    }
}
