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
import android.os.Handler
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.io.RandomAccessFile
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

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

    init {
        // START_NOT_STICKY never resumes a microphone after process death.
        // Persisted active/processing states therefore belong to an interrupted session.
        meetingStore.list().forEach { record ->
            when (record.status) {
                MeetingStatus.RECORDING, MeetingStatus.PAUSED, MeetingStatus.INTERRUPTED,
                MeetingStatus.STOPPING, MeetingStatus.FINALIZING_TRANSCRIPT, MeetingStatus.EXTRACTING_ACTIONS ->
                    meetingStore.save(record.copy(status = MeetingStatus.FAILED, updatedAtEpochMillis = System.currentTimeMillis()))
                else -> Unit
            }
        }
    }

    @Synchronized
    fun start(config: MeetingCaptureConfig): Result<Unit> {
        if (config.mode != MeetingProcessingMode.ON_DEVICE) {
            return Result.failure(IllegalStateException("클라우드 제공자 설정이 없어 온디바이스 모드만 사용할 수 있습니다."))
        }
        if (mutableState.value.isActive) return Result.failure(IllegalStateException("이미 녹음 중인 회의가 있습니다."))
        if (!hasRecordPermission(appContext)) return Result.failure(SecurityException("마이크 권한이 필요합니다."))
        val readiness = MeetingOnDeviceModelGate.readiness(appContext)
        if (!readiness.ready) return Result.failure(IllegalStateException(readiness.reason))
        val id = runCatching { MeetingRecord.requireMeetingID(config.meetingId) }.getOrElse { return Result.failure(it) }
        if (meetingStore.directory(id).exists()) return Result.failure(IllegalStateException("이미 저장된 회의 ID입니다."))
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
        runCatching { meetingStore.save(record) }.onFailure { return Result.failure(it) }
        lastProgressPersistMillis = 0L
        lastProgressStatus = null
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

    @Synchronized
    fun delete(meetingId: String): Boolean {
        if (mutableState.value.meetingId == meetingId && mutableState.value.isActive) return false
        return meetingStore.delete(meetingId)
    }

    @Synchronized
    fun deleteAll(): Result<Int> = runCatching {
        check(!mutableState.value.isActive) { "녹음 중인 회의는 중지한 뒤 삭제할 수 있습니다." }
        meetingStore.deleteAll().also { mutableState.value = MeetingCaptureState() }
    }

    @Synchronized
    fun refresh() {
        val current = mutableState.value.meetingId ?: return
        val record = meetingStore.load(current) ?: run {
            if (!mutableState.value.isActive) mutableState.value = MeetingCaptureState()
            return
        }
        // Disk progress is throttled. Never roll live samples/status back to that older checkpoint.
        if (!mutableState.value.isActive) mutableState.value = MeetingCaptureState(current, record.status, record.artifact.meetingSampleCount * 1000 / SAMPLE_RATE, record.artifact.meetingSampleCount, record.mode)
    }

    @Synchronized
    internal fun onServiceProgress(meetingId: String, status: MeetingStatus, samples: Long) {
        val current = mutableState.value
        if (current.meetingId != meetingId || !current.isActive) return
        val now = System.currentTimeMillis()
        if (status != lastProgressStatus || now - lastProgressPersistMillis >= 5_000L) {
            val record = meetingStore.load(meetingId) ?: return
            val artifact = record.artifact.copy(meetingSampleCount = samples)
            meetingStore.save(record.copy(status = status, artifact = artifact, updatedAtEpochMillis = now))
            lastProgressPersistMillis = now
            lastProgressStatus = status
        }
        mutableState.value = MeetingCaptureState(meetingId, status, samples * 1000 / SAMPLE_RATE, samples, current.mode)
    }

    @Synchronized
    internal fun onServiceFinished(meetingId: String, artifact: MeetingArtifact, error: String? = null) {
        val record = meetingStore.load(meetingId) ?: return
        // This build has no transcription implementation. Never fabricate a READY result,
        // or delete the only audio behind a successful-looking empty transcript.
        val reason = error ?: MeetingOnDeviceModelGate.readiness(appContext).reason
        meetingStore.save(record.copy(status = MeetingStatus.FAILED, artifact = artifact, updatedAtEpochMillis = System.currentTimeMillis()))
        mutableState.value = MeetingCaptureState(meetingId, MeetingStatus.FAILED, artifact.meetingSampleCount * 1000 / SAMPLE_RATE, artifact.meetingSampleCount, record.mode, reason)
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
    @Volatile private var worker: Thread? = null
    @Volatile private var recorder: AudioRecord? = null
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
        if (worker == null) {
            if (intent?.action != ACTION_START || requestedId == null || runCatching { MeetingRecord.requireMeetingID(requestedId) }.isFailure) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
                return START_NOT_STICKY
            }
            val repository = MeetingCaptureRepository.get(this)
            val record = MeetingStore(this).load(requestedId)
            if (record?.status != MeetingStatus.RECORDING || repository.state.value.meetingId != requestedId || !repository.state.value.isActive) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
                return START_NOT_STICKY
            }
            meetingId = requestedId
            beginCapture()
        } else if (requestedId == meetingId) {
            when (intent?.action) {
                ACTION_PAUSE -> pauseCapture()
                ACTION_RESUME -> resumeCapture()
                ACTION_STOP -> stopCapture()
            }
        }
        return START_NOT_STICKY
    }

    private fun beginCapture() {
        val id = meetingId ?: return failStart("회의 ID가 없습니다.")
        if (!MeetingCaptureRepository.hasRecordPermission(this)) return failStart("마이크 권한이 없습니다.")
        val readiness = MeetingOnDeviceModelGate.readiness(this)
        if (!readiness.ready) return failStart(readiness.reason)
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
        paused = false
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
        var failure: String? = null
        try {
            playChime()
            if (stopping.get()) return
            audio.startRecording()
            getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification("회의 녹음 중"))
            openPart(id, partOwnedStart)
            val buffer = ShortArray(bufferSamples.coerceIn(256, 16_384))
            while (!stopping.get()) {
                if (paused) {
                    if (audio.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                        audio.stop()
                        timeline.pause("pause")
                        MeetingCaptureRepository.get(this).onServiceProgress(id, MeetingStatus.PAUSED, sampleCount)
                        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification("회의 녹음 일시정지"))
                    }
                    timeline.enforcePauseLimit()
                    if (timeline.status == MeetingStatus.STOPPING) {
                        stopping.set(true)
                        continue
                    }
                    Thread.sleep(20)
                    continue
                }
                if (audio.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                    timeline.resume()
                    audio.startRecording()
                    MeetingCaptureRepository.get(this).onServiceProgress(id, MeetingStatus.RECORDING, sampleCount)
                    getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification("회의 녹음 중"))
                }
                val read = audio.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                if (stopping.get()) break
                if (paused) continue // Never write a buffer read across a pause request.
                if (read < 0) throw IllegalStateException("오디오 캡처가 중단되었습니다.")
                if (read == 0) continue
                var offset = 0
                while (offset < read && !stopping.get() && !paused) {
                    if (sampleCount - partOwnedStart >= MeetingPartLayout.OWNED_PART_SAMPLES) {
                        closePart()
                        partIndex += 1
                        partOwnedStart = sampleCount
                        partStart = maxOf(0L, partOwnedStart - MeetingPartLayout.OVERLAP_SAMPLES)
                    }
                    if (writer == null) openPart(id, partOwnedStart)
                    val remaining = minOf(MeetingPartLayout.OWNED_PART_SAMPLES - (sampleCount - partOwnedStart), MeetingPartLayout.MAX_MEETING_SAMPLES - sampleCount)
                    val count = minOf(read - offset, remaining.toInt())
                    if (count <= 0) { stopping.set(true); break }
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
            timeline.stop()
            closePart()
        } catch (error: Throwable) {
            failure = error.message ?: "녹음에 실패했습니다."
            runCatching { closePart() }
        } finally {
            runCatching { audio.stop() }
            runCatching { audio.release() }
            val artifact = MeetingArtifact(parts = parts.toList(), meetingSampleCount = sampleCount, discontinuities = timeline.discontinuities.toList())
            playChime()
            Handler(Looper.getMainLooper()).post {
                recorder = null
                worker = null
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                MeetingCaptureRepository.get(this).onServiceFinished(id, artifact, failure)
            }
        }
    }
    private fun playChime() {
        runCatching {
            val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 80)
            try {
                tone.startTone(ToneGenerator.TONE_PROP_BEEP, 120)
                Thread.sleep(140) // Releasing immediately cancels the disclosure tone.
            } finally {
                tone.release()
            }
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
            overlapCount = overlapRing.size
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

    // The capture worker alone owns recorder/timeline transitions. UI state changes only
    // after the microphone is actually stopped/restarted, not when a command is queued.
    private fun pauseCapture() { paused = true }
    private fun resumeCapture() { paused = false }
    private fun stopCapture() {
        stopping.set(true)
        recorder?.let { runCatching { it.stop() } }
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
        if (!closed) {
            try {
                if (pendingCount > 0) flushFrame()
                patchTotalSamples()
                random.fd.sync()
            } finally {
                closed = true
                random.close()
            }
        }
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
