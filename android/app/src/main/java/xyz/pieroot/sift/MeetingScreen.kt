package xyz.pieroot.sift

import android.Manifest
import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun MeetingScreen(
    modifier: Modifier = Modifier,
    meetingStore: MeetingStore,
    capture: MeetingCaptureRepository,
    todoStore: SiftStore,
    onMessage: (String) -> Unit,
) {
    val context = LocalContext.current
    val captureState by capture.state.collectAsState()
    var meetings by remember { mutableStateOf(meetingStore.list()) }
    var mode by rememberSaveable { mutableStateOf(MeetingProcessingMode.ON_DEVICE) }
    var languageTag by rememberSaveable { mutableStateOf("ko-KR") }
    var speakerRangeText by rememberSaveable { mutableStateOf("") }
    var retentionEnabled by rememberSaveable { mutableStateOf(false) }
    var consentAcknowledged by rememberSaveable { mutableStateOf(false) }
    var showDeleteAll by remember { mutableStateOf(false) }

    fun refreshMeetings() { meetings = meetingStore.list() }
    fun startCapture() {
        val range = speakerRangeText.trim().takeIf { it.isNotEmpty() }?.let { text ->
            val parts = text.split('-', limit = 2)
            if (parts.size != 2) null else runCatching { SpeakerRange(parts[0].toInt(), parts[1].toInt()) }.getOrNull()
        }
        if (speakerRangeText.isNotBlank() && range == null) {
            onMessage("화자 수는 1-8 형식으로 입력하세요.")
            return
        }
        val result = capture.start(MeetingCaptureConfig(mode = mode, languageTag = languageTag, expectedSpeakerRange = range, retentionEnabled = retentionEnabled))
        result.onFailure { onMessage(it.message ?: "회의 녹음을 시작할 수 없습니다.") }.onSuccess {
            consentAcknowledged = false
            onMessage("회의 녹음을 시작했습니다. 참석자에게 녹음 사실을 알리고 필요한 동의를 받았는지 확인하세요.")
        }
        refreshMeetings()
    }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startCapture() else onMessage("마이크 권한이 없어 녹음을 시작하지 않았습니다.")
    }

    LaunchedEffect(captureState.status, captureState.sampleCount) {
        refreshMeetings()
    }
    LaunchedEffect(captureState.isActive) {
        while (captureState.isActive) {
            delay(1_000)
            capture.refresh()
            refreshMeetings()
        }
    }

    Column(modifier = modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (captureState.isActive) {
            RecordingCard(
                state = captureState,
                onPause = { capture.pause().onFailure { onMessage(it.message ?: "일시정지하지 못했습니다.") } },
                onResume = { capture.resume().onFailure { onMessage(it.message ?: "재개하지 못했습니다.") } },
                onStop = { capture.stop().onFailure { onMessage(it.message ?: "녹음을 중지하지 못했습니다.") } },
            )
        } else {
            CaptureSetupCard(
                mode = mode,
                languageTag = languageTag,
                speakerRangeText = speakerRangeText,
                retentionEnabled = retentionEnabled,
                consentAcknowledged = consentAcknowledged,
                onModeChange = { mode = it },
                onLanguageChange = { languageTag = it },
                onSpeakerRangeChange = { speakerRangeText = it },
                onRetentionChange = { retentionEnabled = it },
                onConsentChange = { consentAcknowledged = it },
                onStart = {
                    if (!consentAcknowledged) onMessage("참석자 동의 확인 후 녹음을 시작할 수 있습니다.")
                    else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED) startCapture()
                    else permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                },
            )
        }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text("저장된 회의", style = MaterialTheme.typography.titleMedium)
            TextButton(onClick = { showDeleteAll = true }, enabled = meetings.isNotEmpty() && !captureState.isActive) { Text("전체 삭제") }
        }
        if (meetings.isEmpty()) {
            Text("아직 회의가 없습니다. 녹음은 이 기기에만 저장됩니다.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxSize()) {
                items(meetings, key = { it.meetingId }) { meeting ->
                    MeetingResultCard(
                        meeting = meeting,
                        onConfirmDraft = { draft ->
                            runCatching { MeetingTodoImporter.confirm(meetingStore, todoStore, meeting.meetingId, draft, meeting.transcriptRevision) }
                                .onSuccess { onMessage("검토 대기 할 일을 추가했습니다."); refreshMeetings() }
                                .onFailure { onMessage(it.message ?: "할 일을 추가하지 못했습니다.") }
                        },
                        onDelete = {
                            if (capture.delete(meeting.meetingId)) { refreshMeetings(); onMessage("회의와 녹음 파일을 삭제했습니다.") }
                            else onMessage("녹음 중인 회의는 중지한 뒤 삭제할 수 있습니다.")
                        },
                    )
                }
            }
        }
    }

    if (showDeleteAll) {
        AlertDialog(
            onDismissRequest = { showDeleteAll = false },
            title = { Text("회의를 모두 삭제할까요?") },
            text = { Text("회의 녹음, 전사, 요약, 임시 파일을 이 기기에서 삭제합니다. 이미 확인한 할 일은 유지됩니다.") },
            confirmButton = {
                TextButton(onClick = {
                    val count = meetingStore.deleteAll()
                    capture.refresh()
                    refreshMeetings()
                    showDeleteAll = false
                    onMessage("회의 ${count}개를 삭제했습니다.")
                }) { Text("삭제") }
            },
            dismissButton = { TextButton(onClick = { showDeleteAll = false }) { Text("취소") } },
        )
    }
}

@Composable
private fun CaptureSetupCard(
    mode: MeetingProcessingMode,
    languageTag: String,
    speakerRangeText: String,
    retentionEnabled: Boolean,
    consentAcknowledged: Boolean,
    onModeChange: (MeetingProcessingMode) -> Unit,
    onLanguageChange: (String) -> Unit,
    onSpeakerRangeChange: (String) -> Unit,
    onRetentionChange: (Boolean) -> Unit,
    onConsentChange: (Boolean) -> Unit,
    onStart: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("새 회의 녹음", style = MaterialTheme.typography.titleLarge)
            Text("회의실의 마이크 소리만 녹음합니다. 통화·화상회의·기기 오디오는 캡처하지 않습니다.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("처리 방식", style = MaterialTheme.typography.labelLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                MeetingProcessingMode.entries.forEach { candidate ->
                    FilterChip(
                        selected = mode == candidate,
                        onClick = { if (candidate == MeetingProcessingMode.ON_DEVICE) onModeChange(candidate) },
                        enabled = candidate == MeetingProcessingMode.ON_DEVICE,
                        label = { Text(candidate.displayName()) },
                    )
                }
            }
            Text("클라우드 처리는 제공자 인증·공개 설정이 준비될 때까지 사용할 수 없습니다. 설정되지 않은 제공자로 오디오를 전송하지 않습니다.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("언어", style = MaterialTheme.typography.labelLarge)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("ko-KR" to "한국어", "en-US" to "English").forEach { (tag, label) ->
                    FilterChip(selected = languageTag == tag, onClick = { onLanguageChange(tag) }, label = { Text(label) })
                }
            }
            OutlinedTextField(value = speakerRangeText, onValueChange = onSpeakerRangeChange, label = { Text("예상 화자 수 (선택, 1-8)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("오디오 보관", style = MaterialTheme.typography.bodyLarge)
                    Text(if (retentionEnabled) "삭제 전까지 보관합니다." else "처리 성공 후 오디오 파일을 삭제합니다. 모델 준비 전에는 재처리를 위해 보관합니다.", style = MaterialTheme.typography.bodySmall)
                }
                Switch(checked = retentionEnabled, onCheckedChange = onRetentionChange)
            }
            Row(verticalAlignment = Alignment.Top) {
                Checkbox(checked = consentAcknowledged, onCheckedChange = onConsentChange)
                Text("참석자에게 녹음 사실과 처리 방식을 알리고 필요한 동의를 받았습니다. 시작/종료 알림음이 재생됩니다.", modifier = Modifier.padding(top = 12.dp))
            }
            Button(onClick = onStart, enabled = mode == MeetingProcessingMode.ON_DEVICE && consentAcknowledged, modifier = Modifier.fillMaxWidth()) { Text("녹음 시작") }
        }
    }
}

@Composable
private fun RecordingCard(state: MeetingCaptureState, onPause: () -> Unit, onResume: () -> Unit, onStop: () -> Unit) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("● 녹음 중", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.titleLarge)
            Text("${formatDuration(state.mediaTimeMs)} · ${state.mode?.displayName() ?: "온디바이스"}")
            Text("임시 전사는 제공하지 않습니다. 최종 전사 모델이 준비되면 별도 처리할 수 있습니다.", style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (state.status == MeetingStatus.PAUSED || state.status == MeetingStatus.INTERRUPTED) OutlinedButton(onClick = onResume) { Text("재개") }
                else OutlinedButton(onClick = onPause) { Text("일시정지") }
                Button(onClick = onStop) { Text("중지") }
            }
        }
    }
}

@Composable
private fun MeetingResultCard(meeting: MeetingRecord, onConfirmDraft: (MeetingActionDraft) -> Unit, onDelete: () -> Unit) {
    var expanded by rememberSaveable(meeting.meetingId) { mutableStateOf(false) }
    val format = remember { SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()) }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(meeting.result?.title ?: "회의 녹음", style = MaterialTheme.typography.titleMedium)
                    Text(format.format(Date(meeting.createdAtEpochMillis)) + " · " + meeting.status.displayName(), style = MaterialTheme.typography.bodySmall)
                }
                TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "접기" else "보기") }
            }
            if (expanded) {
                HorizontalDivider()
                val result = meeting.result
                if (result == null) {
                    Text("오디오가 저장되었습니다. 이 기기에는 현재 최종 전사 모델이 준비되지 않아 텍스트 결과를 만들지 않았습니다.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                } else {
                    if (result.summary.isNotBlank()) Text(result.summary)
                    result.segments.forEach { segment -> Text("${segment.speakerIDs.joinToString().ifBlank { "화자" }}  ${segment.text}") }
                    result.actionDrafts.forEach { draft ->
                        OutlinedButton(onClick = { onConfirmDraft(draft) }, modifier = Modifier.fillMaxWidth()) { Text("검토 대기 할 일 추가: ${draft.title}") }
                    }
                }
                Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                    Text(if (meeting.retentionEnabled) "오디오 보관: 켜짐" else "오디오 보관: 꺼짐", style = MaterialTheme.typography.bodySmall)
                    Spacer(Modifier.weight(1f))
                    TextButton(onClick = onDelete) { Text("삭제") }
                }
            }
        }
    }
}

private fun MeetingProcessingMode.displayName(): String = when (this) {
    MeetingProcessingMode.ON_DEVICE -> "온디바이스"
    MeetingProcessingMode.OPEN_AI -> "OpenAI (준비 중)"
    MeetingProcessingMode.GOOGLE -> "Google (준비 중)"
}

private fun MeetingStatus.displayName(): String = when (this) {
    MeetingStatus.RECORDING -> "녹음 중"
    MeetingStatus.PAUSED -> "일시정지"
    MeetingStatus.INTERRUPTED -> "중단됨"
    MeetingStatus.STOPPING -> "중지 중"
    MeetingStatus.FINALIZING_TRANSCRIPT -> "전사 처리 중"
    MeetingStatus.EXTRACTING_ACTIONS -> "할 일 추출 중"
    MeetingStatus.READY -> "완료"
    MeetingStatus.FAILED -> "실패"
    MeetingStatus.CANCELLED -> "취소됨"
}

private fun formatDuration(milliseconds: Long): String {
    val seconds = milliseconds.coerceAtLeast(0L) / 1_000L
    return "%02d:%02d:%02d".format(Locale.ROOT, seconds / 3600, (seconds / 60) % 60, seconds % 60)
}
