package xyz.pieroot.sift

import android.media.AudioManager
import android.media.ToneGenerator
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

/** Capture configuration selected for one meeting. Cloud modes are intentionally unavailable until configured. */
data class MeetingCaptureConfig(
    val meetingId: String = UUID.randomUUID().toString(),
    val mode: MeetingProcessingMode = MeetingProcessingMode.ON_DEVICE,
    val languageTag: String = "ko-KR",
    val timezoneIdentifier: String = "Asia/Seoul",
    val expectedSpeakerRange: SpeakerRange? = null,
    val retentionEnabled: Boolean = false,
    val disclosureVersionID: String = "local-v1",
)

data class MeetingCaptureState(
    val meetingId: String? = null,
    val status: MeetingStatus? = null,
    val mediaTimeMs: Long = 0,
    val sampleCount: Long = 0,
    val mode: MeetingProcessingMode? = null,
    val error: String? = null,
) {
    val isActive: Boolean get() = status == MeetingStatus.RECORDING || status == MeetingStatus.PAUSED || status == MeetingStatus.INTERRUPTED || status == MeetingStatus.STOPPING
}

/** Process-local bridge between MeetingScreen and the non-exported foreground service. */
class MeetingCaptureRepository private constructor(private val appContext: Context) {
    private val meetingStore = MeetingStore(appContext)
    private val mutableState = MutableStateFlow(MeetingCaptureState())
    val state: StateFlow<MeetingCaptureState> = mutableState
    private var lastProgressPersistMillis = 0L
    private var lastProgressStatus: MeetingStatus? = null

    fun start(config: MeetingCaptureConfig): Result<Unit> {
        if (config.mode != MeetingProcessingMode.ON_DEVICE) {
            return Result.failure(IllegalStateException("클라우드 제공자 설정이 없어 온디바이스 모드만 사용할 수 있습니다."))
        }
        if (mutableState.value.isActive) return Result.failure(IllegalStateException("이미 녹음 중인 회의가 있습니다."))
        if (!hasRecordPermission(appContext)) return Result.failure(SecurityException("마이크 권한이 필요합니다."))
        val readiness = MeetingOnDeviceModelGate.readiness(appContext)
        if (!readiness.ready) return Result.failure(IllegalStateException(readiness.reason))
        val id = MeetingRecord.requireMeetingID(config.meetingId)
        val record = MeetingRecord(
            meetingId = id,
            mode = config.mode,
            languageTag = config.languageTag,
            timezoneIdentifier = config.timezoneIdentifier,
            expectedSpeakerRange = config.expectedSpeakerRange,
            retentionEnabled = config.retentionEnabled,
            disclosureVersionID = config.disclosureVersionID,
            status = MeetingStatus.RECORDING,
            createdAtEpochMillis = System.currentTimeMillis(),
            updatedAtEpochMillis = System.currentTimeMillis(),
        )
        meetingStore.save(record)
        mutableState.value = MeetingCaptureState(id, MeetingStatus.RECORDING, mode = config.mode)
        val intent = Intent(appContext, MeetingCaptureService::class.java).apply {
            action = MeetingCaptureService.ACTION_START
            putExtra(MeetingCaptureService.EXTRA_MEETING_ID, id)
        }
        return runCatching {
            ContextCompat.startForegroundService(appContext, intent)
        }.onFailure {
            mutableState.value = MeetingCaptureState(error = it.message ?: "녹음을 시작할 수 없습니다.")
            meetingStore.save(record.copy(status = MeetingStatus.FAILED, updatedAtEpochMillis = System.currentTimeMillis()))
        }
    }

    fun pause(): Result<Unit> = sendCommand(MeetingCaptureService.ACTION_PAUSE)
    fun resume(): Result<Unit> = sendCommand(MeetingCaptureService.ACTION_RESUME)
    fun stop(): Result<Unit> = sendCommand(MeetingCaptureService.ACTION_STOP)

    fun delete(meetingId: String): Boolean {
        if (mutableState.value.meetingId == meetingId && mutableState.value.isActive) return false
        return meetingStore.delete(meetingId)
    }

    fun refresh() {
        val current = mutableState.value.meetingId ?: return
        meetingStore.load(current)?.let { record ->
            mutableState.value = MeetingCaptureState(current, record.status, record.artifact.meetingSampleCount * 1000 / SAMPLE_RATE, record.artifact.meetingSampleCount, record.mode)
        }
    }

    internal fun onServiceProgress(meetingId: String, status: MeetingStatus, samples: Long) {
        val record = meetingStore.load(meetingId) ?: return
        val now = System.currentTimeMillis()
        if (status != lastProgressStatus || now - lastProgressPersistMillis >= 5_000L) {
            val artifact = record.artifact.copy(meetingSampleCount = samples)
            meetingStore.save(record.copy(status = status, artifact = artifact, updatedAtEpochMillis = now))
            lastProgressPersistMillis = now
            lastProgressStatus = status
        }
        mutableState.value = MeetingCaptureState(meetingId, status, samples * 1000 / SAMPLE_RATE, samples, record.mode)
    }

    internal fun onServiceFinished(meetingId: String, artifact: MeetingArtifact, error: String? = null) {
        val record = meetingStore.load(meetingId) ?: return
        if (error != null) {
            meetingStore.save(record.copy(status = MeetingStatus.FAILED, artifact = artifact, updatedAtEpochMillis = System.currentTimeMillis()))
            mutableState.value = MeetingCaptureState(meetingId, MeetingStatus.FAILED, artifact.meetingSampleCount * 1000 / SAMPLE_RATE, artifact.meetingSampleCount, record.mode, error)
            return
        }
        val readiness = MeetingOnDeviceModelGate.readiness(appContext)
        if (!readiness.ready) {
            meetingStore.save(record.copy(
                status = MeetingStatus.FAILED,
                artifact = artifact,
                updatedAtEpochMillis = System.currentTimeMillis(),
            ))
            mutableState.value = MeetingCaptureState(
                meetingId,
                MeetingStatus.FAILED,
                artifact.meetingSampleCount * 1000 / SAMPLE_RATE,
                artifact.meetingSampleCount,
                record.mode,
                readiness.reason,
            )
            return
        }
        meetingStore.save(record.copy(status = MeetingStatus.FINALIZING_TRANSCRIPT, artifact = artifact, updatedAtEpochMillis = System.currentTimeMillis()))
        val deterministicResult = MeetingResult(
            transcriptRevision = record.transcriptRevision,
            title = "회의 녹음",
            summary = "",
            decisions = emptyList(),
            unresolvedQuestions = emptyList(),
            segments = emptyList(),
            actionDrafts = emptyList(),
        )
        meetingStore.save(record.copy(status = MeetingStatus.EXTRACTING_ACTIONS, result = deterministicResult, artifact = artifact, updatedAtEpochMillis = System.currentTimeMillis()))
        if (!record.retentionEnabled) meetingStore.deleteAudio(meetingId)
        val savedArtifact = if (record.retentionEnabled) artifact else artifact.copy(parts = emptyList())
        meetingStore.save(record.copy(status = MeetingStatus.READY, result = deterministicResult, artifact = savedArtifact, updatedAtEpochMillis = System.currentTimeMillis()))
        mutableState.value = MeetingCaptureState(meetingId, MeetingStatus.READY, artifact.meetingSampleCount * 1000 / SAMPLE_RATE, artifact.meetingSampleCount, record.mode)
    }

    private fun sendCommand(action: String): Result<Unit> {
        val id = mutableState.value.meetingId ?: return Result.failure(IllegalStateException("녹음 중인 회의가 없습니다."))
        if (!mutableState.value.isActive) return Result.failure(IllegalStateException("녹음 중인 회의가 없습니다."))
        return runCatching {
            ContextCompat.startForegroundService(appContext, Intent(appContext, MeetingCaptureService::class.java).apply {
                this.action = action
                putExtra(MeetingCaptureService.EXTRA_MEETING_ID, id)
            })
        }
    }

    companion object {
        private const val SAMPLE_RATE = 16_000L
        @Volatile private var instance: MeetingCaptureRepository? = null
        fun get(context: Context): MeetingCaptureRepository = instance ?: synchronized(this) {
            instance ?: MeetingCaptureRepository(context.applicationContext).also { instance = it }
        }
        fun hasRecordPermission(context: Context): Boolean = ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    }
}
/** Foreground microphone capture. The service is non-exported and only accepts app-local commands. */
class MeetingCaptureService : Service() {
    private val stopping = AtomicBoolean(false)
    private var worker: Thread? = null
    private var recorder: AudioRecord? = null
    private var writer: MeetingFlacPartWriter? = null
    private var meetingId: String? = null
    @Volatile private var sampleCount = 0L
    private var partIndex = 0
    private var partStart = 0L
    private var partOwnedStart = 0L
    private val overlapRing = ShortArray(MeetingPartLayout.OVERLAP_SAMPLES.toInt())
    private var overlapCount = 0
    @Volatile private var paused = false
    private var timeline = MeetingTimeline()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, notification("회의 녹음 준비 중"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requestedId = intent?.getStringExtra(EXTRA_MEETING_ID)
        if (requestedId != null) meetingId = requestedId
        when (intent?.action) {
            ACTION_START -> if (worker == null) beginCapture()
            ACTION_PAUSE -> pauseCapture()
            ACTION_RESUME -> resumeCapture()
            ACTION_STOP -> stopCapture(null)
        }
        return START_NOT_STICKY
    }

    private fun beginCapture() {
        val id = meetingId ?: return failStart("회의 ID가 없습니다.")
        if (!MeetingCaptureRepository.hasRecordPermission(this)) return failStart("마이크 권한이 없습니다.")
        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
        if (minBuffer <= 0) return failStart("이 기기에서 PCM 녹음을 사용할 수 없습니다.")
        val bufferBytes = maxOf(minBuffer.toLong(), SAMPLE_RATE * 2L / 2L).toInt()
        val audio = runCatching {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.MIC)
                .setAudioFormat(AudioFormat.Builder().setSampleRate(SAMPLE_RATE).setChannelMask(CHANNEL_CONFIG).setEncoding(AUDIO_FORMAT).build())
                .setBufferSizeInBytes(bufferBytes)
                .build()
        }.getOrElse { return failStart(it.message ?: "마이크 초기화에 실패했습니다.") }
        if (audio.state != AudioRecord.STATE_INITIALIZED) {
            audio.release()
            return failStart("마이크 초기화에 실패했습니다.")
        }
        recorder = audio
        timeline = MeetingTimeline()
        timeline.start()
        stopping.set(false)
        sampleCount = 0L
        partIndex = 0
        partStart = 0L
        partOwnedStart = 0L
        overlapCount = 0
        parts.clear()
        worker = Thread({ captureLoop(id, audio, bufferBytes / 2) }, "meeting-audio-capture").also { it.start() }
    }

    private fun failStart(message: String) {
        val id = meetingId
        recorder?.release()
        recorder = null
        id?.let {
            MeetingCaptureRepository.get(this).onServiceFinished(it, MeetingArtifact(), message)
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun captureLoop(id: String, audio: AudioRecord, bufferSamples: Int) {
        try {
            playChime()
            audio.startRecording()
            openPart(id, partOwnedStart)
            val buffer = ShortArray(bufferSamples.coerceIn(256, 16_384))
            while (!stopping.get()) {
                if (paused) {
                    audio.read(buffer, 0, buffer.size, AudioRecord.READ_NON_BLOCKING)
                    timeline.enforcePauseLimit()
                    if (timeline.status == MeetingStatus.STOPPING) {
                        stopping.set(true)
                        continue
                    }
                    Thread.sleep(20)
                    continue
                }
                val read = audio.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                if (read < 0) throw IllegalStateException("오디오 캡처가 중단되었습니다.")
                if (read == 0) continue
                var offset = 0
                while (offset < read) {
                    if (sampleCount - partOwnedStart >= MeetingPartLayout.OWNED_PART_SAMPLES) {
                        closePart()
                        partIndex += 1
                        partOwnedStart = sampleCount
                        partStart = maxOf(0L, partOwnedStart - MeetingPartLayout.OVERLAP_SAMPLES)
                    }
                    if (writer == null) openPart(id, partOwnedStart)
                    val remaining = MeetingPartLayout.OWNED_PART_SAMPLES - (sampleCount - partOwnedStart)
                    val count = minOf(read - offset, remaining.toInt())
                    if (count <= 0) continue
                    writer?.write(buffer, offset, count)
                    appendOverlapRing(buffer, offset, count)
                    offset += count
                    sampleCount += count
                    timeline.append(count)
                    val progressStatus = if (timeline.status == MeetingStatus.STOPPING) MeetingStatus.STOPPING else MeetingStatus.RECORDING
                    MeetingCaptureRepository.get(this).onServiceProgress(id, progressStatus, sampleCount)
                    if (timeline.status == MeetingStatus.STOPPING) stopping.set(true)
                }
            }
            closePart()
            MeetingCaptureRepository.get(this).onServiceFinished(id, MeetingArtifact(parts = parts, meetingSampleCount = sampleCount, discontinuities = timeline.discontinuities.toList()))
        } catch (error: Throwable) {
            runCatching { closePart() }
            MeetingCaptureRepository.get(this).onServiceFinished(id, MeetingArtifact(parts = parts, meetingSampleCount = sampleCount, discontinuities = timeline.discontinuities.toList()), error.message ?: "녹음에 실패했습니다.")
        } finally {
            runCatching { audio.stop() }
            audio.release()
            recorder = null
            worker = null
            playChime()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }
    private fun playChime() {
        runCatching {
            val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80)
            tone.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
            tone.release()
        }
    }

    private val parts = mutableListOf<MeetingFlacPart>()

    private fun openPart(id: String, ownedStart: Long) {
        val root = MeetingStore(this).audioDirectory(id).also { check(it.exists() || it.mkdirs()) }
        partOwnedStart = ownedStart
        partStart = maxOf(0L, ownedStart - MeetingPartLayout.OVERLAP_SAMPLES)
        val file = File(root, "part-%02d.flac".format(partIndex))
        writer = MeetingFlacPartWriter(file)
        if (partIndex > 0 && overlapCount > 0) writer?.write(overlapRing, 0, overlapCount)
    }

    private fun appendOverlapRing(values: ShortArray, offset: Int, length: Int) {
        if (length >= overlapRing.size) {
            values.copyInto(overlapRing, 0, offset + length - overlapRing.size, offset + length)
            return
            return
        }
        val total = overlapCount + length
        if (total <= overlapRing.size) {
            values.copyInto(overlapRing, overlapCount, offset, offset + length)
            overlapCount = total
            return
        }
        val drop = total - overlapRing.size
        val retained = overlapCount - drop
        if (retained > 0) overlapRing.copyInto(overlapRing, 0, drop, overlapCount)
        values.copyInto(overlapRing, retained, offset, offset + length)
        overlapCount = overlapRing.size
    }

    private fun closePart() {
        val current = writer ?: return
        val count = current.closeAndGetSampleCount()
        val ownedEnd = sampleCount
        require(count == ownedEnd - partStart) { "FLAC decoded count does not match part ownership" }
        parts += MeetingFlacPart(partIndex, partStart, partOwnedStart, ownedEnd, current.file.length(), current.sha256(), current.file.name)
        writer = null
    }

    private fun pauseCapture() {
        if (!paused) timeline.pause("pause")
        paused = true
        meetingId?.let { MeetingCaptureRepository.get(this).onServiceProgress(it, MeetingStatus.PAUSED, sampleCount) }
    }
    private fun resumeCapture() {
        if (paused) timeline.resume()
        paused = false
        meetingId?.let { MeetingCaptureRepository.get(this).onServiceProgress(it, MeetingStatus.RECORDING, sampleCount) }
    }
    private fun stopCapture(error: String?) {
        timeline.stop()
        if (!stopping.compareAndSet(false, true)) return
        if (error != null) meetingId?.let {
            MeetingCaptureRepository.get(this).onServiceFinished(it, MeetingArtifact(parts = parts, meetingSampleCount = sampleCount, discontinuities = timeline.discontinuities.toList()), error)
        }
    }

    private fun notification(text: String): Notification = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.ic_btn_speak_now)
        .setContentTitle("SIFT 회의 녹음")
        .setContentText(text)
        .setOngoing(true)
        .setCategory(NotificationCompat.CATEGORY_SERVICE)
        .build()

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(CHANNEL_ID, "회의 녹음", NotificationManager.IMPORTANCE_LOW))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null
    override fun onDestroy() { stopping.set(true); recorder?.let { runCatching { it.stop() } }; super.onDestroy() }

    companion object {
        const val ACTION_START = "xyz.pieroot.sift.meeting.START"
        const val ACTION_PAUSE = "xyz.pieroot.sift.meeting.PAUSE"
        const val ACTION_RESUME = "xyz.pieroot.sift.meeting.RESUME"
        const val ACTION_STOP = "xyz.pieroot.sift.meeting.STOP"
        const val EXTRA_MEETING_ID = "meetingId"
        private const val CHANNEL_ID = "meeting-recording"
        private const val NOTIFICATION_ID = 7401
        private const val SAMPLE_RATE = 16_000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
    }
}

/** Minimal valid FLAC writer using verbatim PCM16 subframes; no lossy fallback is used. */
private class MeetingFlacPartWriter(val file: File) {
    private val random = RandomAccessFile(file, "rw")
    private var samples = 0L
    private var frameNumber = 0
    private var closed = false
    private val pending = ShortArray(256)
    private var pendingCount = 0

    init {
        random.setLength(0)
        random.writeBytes("fLaC")
        random.writeByte(0x80)
        random.writeByte(0); random.writeByte(0); random.writeByte(34)
        random.writeShort(256)
        random.writeShort(256)
        repeat(6) { random.writeByte(0) }
        repeat(8) { random.writeByte(0) }
        repeat(16) { random.writeByte(0) }
    }

    fun write(values: ShortArray, offset: Int, length: Int) {
        check(!closed)
        var cursor = offset
        var remaining = length
        while (remaining > 0) {
            val copy = minOf(remaining, pending.size - pendingCount)
            values.copyInto(pending, pendingCount, cursor, cursor + copy)
            pendingCount += copy; cursor += copy; remaining -= copy
            if (pendingCount == pending.size) flushFrame()
        }
    }

    fun closeAndGetSampleCount(): Long {
        if (!closed) { if (pendingCount > 0) flushFrame(); patchTotalSamples(); closed = true; random.fd.sync(); random.close() }
        return samples
    }

    fun sha256(): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream -> val buffer = ByteArray(8192); var read: Int; while (stream.read(buffer).also { read = it } > 0) digest.update(buffer, 0, read) }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun flushFrame() {
        val count = pendingCount
        val header = ByteArrayOutput(16)
        header.writeByte(0xFF); header.writeByte(0xF8); header.writeByte(0x65); header.writeByte(0x08)
        writeUtf8(header, frameNumber++)
        header.writeByte(count - 1)
        val headerWithoutCrc = header.toByteArray()
        header.writeByte(crc8(headerWithoutCrc))
        val frameHeader = header.toByteArray()
        random.write(frameHeader)
        val frameBytes = fileFrameBytes(frameHeader, pending, count)
        random.writeByte(0x02)
        for (index in 0 until count) random.writeShort(pending[index].toInt())
        random.writeShort(crc16(frameBytes))
        samples += count
        pendingCount = 0
    }

    private fun patchTotalSamples() {
        val position = random.filePointer
        random.seek(18)
        val packed = (16_000L shl 44) or (15L shl 36) or samples
        for (shift in 56 downTo 0 step 8) random.writeByte(((packed ushr shift) and 0xff).toInt())
        random.seek(position)
    }
    private fun fileFrameBytes(header: ByteArray, values: ShortArray, count: Int): ByteArray {
        val output = ByteArrayOutput(header.size + 1 + count * 2)
        header.forEach { output.writeByte(it.toInt()) }
        output.writeByte(0x02)
        for (i in 0 until count) output.writeShort(values[i].toInt())
        return output.toByteArray()
    }

    private class ByteArrayOutput(capacity: Int) {
        private val bytes = java.io.ByteArrayOutputStream(capacity)
        fun writeByte(value: Int) { bytes.write(value and 0xff) }
        fun writeShort(value: Int) { writeByte(value shr 8); writeByte(value) }
        fun toByteArray(): ByteArray = bytes.toByteArray()
    }

    private fun writeUtf8(output: ByteArrayOutput, value: Int) {
        when {
            value < 0x80 -> output.writeByte(value)
            value < 0x800 -> { output.writeByte(0xc0 or (value shr 6)); output.writeByte(0x80 or (value and 0x3f)) }
            value < 0x10000 -> { output.writeByte(0xe0 or (value shr 12)); output.writeByte(0x80 or ((value shr 6) and 0x3f)); output.writeByte(0x80 or (value and 0x3f)) }
            else -> { output.writeByte(0xf0 or (value shr 18)); output.writeByte(0x80 or ((value shr 12) and 0x3f)); output.writeByte(0x80 or ((value shr 6) and 0x3f)); output.writeByte(0x80 or (value and 0x3f)) }
        }
    }

    private fun crc8(bytes: ByteArray): Int { var crc = 0; for (byte in bytes) { crc = crc xor (byte.toInt() and 0xff); repeat(8) { crc = if (crc and 0x80 != 0) ((crc shl 1) xor 0x07) and 0xff else (crc shl 1) and 0xff } }; return crc }
    private fun crc16(bytes: ByteArray): Int { var crc = 0; for (byte in bytes) { crc = crc xor ((byte.toInt() and 0xff) shl 8); repeat(8) { crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x8005) and 0xffff else (crc shl 1) and 0xffff } }; return crc }
}
