package xyz.pieroot.sift

import android.content.Context

/** Explicit local-model gate. No network fallback is permitted when assets are unavailable. */
object MeetingOnDeviceModelGate {
    data class Readiness(val ready: Boolean, val reason: String)

    fun readiness(context: Context): Readiness {
        // The Android ASR/diarization assets are not bundled in this build yet. Keep the
        // capture lane usable, but never imply that local transcription is available.
        return Readiness(false, "온디바이스 전사·화자 모델 자산이 설치되지 않았습니다.")
    }
}
