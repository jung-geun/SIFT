package xyz.pieroot.sift

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.text.DecimalFormat
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

@Serializable
enum class AppTab {
    TODO,
    CALENDAR,
    MAIL,
    MEETING,
}

@Serializable
enum class LaunchBehavior {
    LAST_USED,
    FIXED,
}

@Serializable
enum class CloudSyncMode {
    LOCAL,
    @SerialName("GOOGLE_DRIVE") FIREBASE,
}

@Serializable
enum class TodoSource {
    MANUAL,
    EMAIL,
    CALENDAR,
    MEETING,
}
@Serializable
enum class TodoTriage {
    TODO,
    REVIEW,
}

@Serializable
enum class CalendarCompletionAction {
    REMOVE,
    SILENCE,
}

@Serializable
enum class IntelligenceProvider {
    HEURISTIC,
}

@Serializable
enum class TodoFilter {
    ACTIVE,
    OVERDUE,
    ALL,
    REVIEW,
    COMPLETED,
}

@Serializable
enum class PersonaType(
    val displayName: String,
    val keywords: List<String>,
    val presets: List<String>,
) {
    STUDENT(
        displayName = "학생",
        keywords = listOf("과제", "시험", "수업", "제출", "리포트", "발표", "강의", "퀴즈", "프로젝트", "논문", "실습"),
        presets = listOf("대학교 재학 중", "대학원 과정", "고등학생", "자격증 공부 중", "졸업 예정"),
    ),
    OFFICE_WORKER(
        displayName = "직장인",
        keywords = listOf("회의", "보고", "마감", "프로젝트", "결재", "기획서", "미팅", "업무", "출장", "계약", "검토"),
        presets = listOf("IT/개발", "기획/마케팅", "영업/고객지원", "재무/회계", "디자인", "HR/교육"),
    ),
    FREELANCER(
        displayName = "프리랜서",
        keywords = listOf("납품", "클라이언트", "계약", "수정", "검수", "청구", "견적", "피드백", "마감", "포트폴리오"),
        presets = listOf("개발·프로그래밍", "디자인·영상", "번역·글쓰기", "컨설팅", "강의·튜터링"),
    ),
    JOB_SEEKER(
        displayName = "취업준비생",
        keywords = listOf("지원", "면접", "서류", "이력서", "자소서", "자기소개서", "인적성", "필기", "채용", "공고"),
        presets = listOf("대기업 준비", "공기업·공무원", "스타트업 지원 중", "해외 취업 목표", "포트폴리오 준비 중"),
    ),
    SELF_EMPLOYED(
        displayName = "자영업",
        keywords = listOf("발주", "재고", "정산", "매출", "세금", "고객", "배송", "주문", "공급", "계약"),
        presets = listOf("온라인 쇼핑몰", "음식점·카페", "서비스업", "B2B 사업", "1인 기업"),
    ),
    HOMEMAKER(
        displayName = "주부",
        keywords = listOf("장보기", "청소", "육아", "병원", "학교", "준비물", "요리", "세탁", "모임"),
        presets = listOf("육아 중", "학부모", "가사 전담", "부업 병행 중"),
    ),
    OTHER(
        displayName = "기타",
        keywords = emptyList(),
        presets = listOf("은퇴·휴식 중", "창업 준비 중", "다양한 활동 병행", "특수 직종"),
    ),
}

@Serializable
data class PersonaProfile(
    val descriptionText: String = "",
    val personaTypes: List<PersonaType> = emptyList(),
)

@Serializable
data class MemoryInsight(
    val summary: String = "",
    val insights: List<String> = emptyList(),
    val fastTags: List<String> = emptyList(),
    val overdueRate: Double = 0.0,
    val productiveHour: Int? = null,
    val createdAt: Long = System.currentTimeMillis(),
)

@Serializable
data class AppSettings(
    val selectedTab: AppTab = AppTab.TODO,
    val launchBehavior: LaunchBehavior = LaunchBehavior.LAST_USED,
    val launchTab: AppTab = AppTab.TODO,
    val cloudSyncMode: CloudSyncMode = CloudSyncMode.LOCAL,
    val selectedProvider: IntelligenceProvider = IntelligenceProvider.HEURISTIC,
    val aiAutomationEnabled: Boolean = true,
    val calendarAutoRegister: Boolean = false,
    val calendarCompletionAction: CalendarCompletionAction = CalendarCompletionAction.SILENCE,
    val emailAutoAnalysisEnabled: Boolean = true,
    val providerEmailAnalysisEnabled: Boolean = false,
    val emailRefreshHour: Int = 7,
    val emailLookbackDays: Int = 7,
)

@Serializable
data class MailFeatureState(
    val gmailConnected: Boolean = false,
    val outlookConnected: Boolean = false,
    val lastSyncMessage: String = "Android OAuth client registration이 필요합니다.",
    val suppressedSenders: List<String> = emptyList(),
)

@Serializable
data class TodoItem(
    val id: String = UUID.randomUUID().toString(),
    val title: String = "",
    val notes: String = "",
    val createdAt: Long = System.currentTimeMillis(),
    val updatedAt: Long = System.currentTimeMillis(),
    val dueAt: Long? = null,
    val isCompleted: Boolean = false,
    val completedAt: Long? = null,
    val manualPriority: Int? = null,
    val computedPriorityScore: Double = 0.0,
    val priorityReason: String = "",
    val reminderOffsets: List<Long> = emptyList(),
    val estimatedDurationMinutes: Int = 30,
    val source: TodoSource = TodoSource.MANUAL,
    val sourceRef: String = "",
    val sourceSender: String = "",
    val sourceMessageId: String = "",
    val sourceThreadId: String = "",
    val sourceSenderEmail: String = "",
    val triage: TodoTriage = TodoTriage.TODO,
    val tags: List<String> = emptyList(),
    val calendarEventId: Long? = null,
    val memoryNotes: String = "",
    val aiRecommendedTime: Long? = null,
    val aiNeedsNotification: Boolean = false,
    val aiPersonaFit: Boolean = false,
    val aiDetail: String = "",
    val aiEngine: String = "",
    val aiRequestedProvider: String = "",
    val aiFallbackReason: String = "",
    val isFixedSchedule: Boolean = false,
) {
    val effectivePriority: Double
        get() = manualPriority?.let { it / 5.0 } ?: computedPriorityScore

    val isOverdue: Boolean
        get() = !isCompleted && dueAt?.let { it < System.currentTimeMillis() } == true
}

@Serializable
data class SiftSnapshot(
    val onboardingComplete: Boolean = false,
    val persona: PersonaProfile = PersonaProfile(),
    val memory: MemoryInsight? = null,
    val memoryHistory: List<MemoryInsight> = emptyList(),
    val settings: AppSettings = AppSettings(),
    val mail: MailFeatureState = MailFeatureState(),
    val todos: List<TodoItem> = emptyList(),
)

// Mail-derived content and provider/device identities never leave this device in a snapshot.
internal fun TodoItem.isMailOrigin(): Boolean = source == TodoSource.EMAIL ||
    sourceMessageId.isNotBlank() || sourceThreadId.isNotBlank() || sourceSenderEmail.isNotBlank()

internal fun SiftSnapshot.forCloudSync(): SiftSnapshot = copy(
    mail = MailFeatureState(),
    todos = todos.filterNot { it.isMailOrigin() }.map { it.copy(calendarEventId = null) },
)

internal fun decodeAndroidCloudSnapshot(json: Json, raw: String): SiftSnapshot {
    val fields = json.parseToJsonElement(raw).jsonObject
    require(fields.keys.containsAll(listOf("onboardingComplete", "persona", "settings", "todos"))) {
        "현재 Android 버전에서 복원할 수 없는 스냅샷 형식입니다."
    }
    return json.decodeFromString<SiftSnapshot>(raw)
}

internal fun mergeCloudSnapshot(local: SiftSnapshot, remote: SiftSnapshot): SiftSnapshot {
    val safeRemote = remote.forCloudSync().normalizedMemorySnapshot()
    val mergedTodos = local.todos.associateByTo(linkedMapOf()) { it.id }
    for (incoming in safeRemote.todos) {
        val existing = mergedTodos[incoming.id]
        if (existing?.isMailOrigin() == true) continue
        if (existing == null || incoming.updatedAt > existing.updatedAt) {
            mergedTodos[incoming.id] = incoming.copy(calendarEventId = existing?.calendarEventId)
        }
    }
    return safeRemote.copy(
        settings = safeRemote.settings.copy(cloudSyncMode = local.settings.cloudSyncMode),
        mail = local.mail,
        todos = mergedTodos.values.sortedByDescending { it.createdAt },
    )
}

internal fun normalizedMemoryHistory(memory: MemoryInsight?, memoryHistory: List<MemoryInsight>): List<MemoryInsight> {
    val source = if (memoryHistory.isNotEmpty()) memoryHistory else listOfNotNull(memory)
    return source
        .filter { it.summary.isNotBlank() || it.insights.isNotEmpty() }
        .distinctBy { it.createdAt to it.summary }
        .sortedByDescending { it.createdAt }
        .take(5)
}

internal fun SiftSnapshot.normalizedMemorySnapshot(): SiftSnapshot {
    val normalized = normalizedMemoryHistory(memory, memoryHistory)
    return copy(memory = normalized.firstOrNull(), memoryHistory = normalized)
}

internal fun latestMemoryInsight(memory: MemoryInsight?, memoryHistory: List<MemoryInsight>): MemoryInsight? {
    return normalizedMemoryHistory(memory, memoryHistory).firstOrNull()
}

internal fun computeMemoryAnalysis(todos: List<TodoItem>, nowMillis: Long = System.currentTimeMillis()): MemoryInsight {
    val completed = todos.filter { it.isCompleted && it.completedAt != null }
    if (completed.isEmpty()) {
        return MemoryInsight(
            summary = "완료 기록이 쌓이면 행동 패턴 분석을 생성합니다.",
            createdAt = nowMillis,
        )
    }

    val overdueRate = completed.count { todo ->
        val dueAt = todo.dueAt ?: return@count false
        val completedAt = todo.completedAt ?: return@count false
        completedAt > dueAt
    }.toDouble() / completed.size.toDouble()

    val tagCounts = completed.flatMap { it.tags }
        .groupingBy { it }
        .eachCount()
        .entries
        .sortedByDescending { it.value }
        .take(3)
        .map { it.key }

    val productiveHour = completed.mapNotNull { todo ->
        todo.completedAt?.let { millis ->
            java.util.Calendar.getInstance().apply { timeInMillis = millis }.get(java.util.Calendar.HOUR_OF_DAY)
        }
    }.groupingBy { it }.eachCount().maxByOrNull { it.value }?.key

    val completedCount = completed.size
    val overdueText = DecimalFormat("0%").format(overdueRate)
    val summary = buildString {
        append("최근 완료한 할 일 ")
        append(completedCount)
        append("건을 기준으로 보면")
        if (productiveHour != null) {
            append(", 주로 ")
            append(String.format("%02d시", productiveHour))
            append(" 전후에 마무리합니다")
        }
        append(". 기한 초과 비율은 ")
        append(overdueText)
        append(" 입니다.")
    }

    val insights = buildList {
        if (productiveHour != null) add("집중 완료 시간대는 ${String.format("%02d:00", productiveHour)} 전후입니다.")
        if (tagCounts.isNotEmpty()) add("자주 완료하는 범주: ${tagCounts.joinToString(", ")}")
        if (overdueRate >= 0.4) add("기한이 가까워질수록 우선순위를 더 공격적으로 끌어올리는 편이 좋습니다.")
        else add("기한 관리가 비교적 안정적입니다. 장기 과제도 같은 방식으로 쪼개면 유지하기 쉽습니다.")
    }

    return MemoryInsight(
        summary = summary,
        insights = insights,
        fastTags = tagCounts,
        overdueRate = overdueRate,
        productiveHour = productiveHour,
        createdAt = nowMillis,
    )
}

data class DriveSyncUiState(
    val configured: Boolean = false,
    val mode: CloudSyncMode = CloudSyncMode.LOCAL,
    val signedInEmail: String? = null,
    val lastSyncedAt: Long? = null,
    val isSyncing: Boolean = false,
    val lastError: String? = null,
)

data class PriorityResult(
    val score: Double,
    val reason: String,
    val detail: String,
    val recommendedTime: Long?,
    val needsNotification: Boolean,
    val personaFit: Boolean,
)

data class TodoDraft(
    val id: String? = null,
    val title: String,
    val notes: String,
    val dueAt: Long?,
    val manualPriority: Int?,
    val tags: List<String>,
    val estimatedDurationMinutes: Int,
    val triage: TodoTriage,
)

class SiftStore private constructor(context: Context) {
    companion object {
        @Volatile private var instance: SiftStore? = null

        fun get(context: Context): SiftStore = instance ?: synchronized(this) {
            instance ?: SiftStore(context.applicationContext).also { instance = it }
        }
    }
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
        encodeDefaults = true
    }
    private val stateFile = File(appContext.filesDir, "sift_state.json")
    private val persistenceMutex = Mutex()
    private var cloudSyncJob: Job? = null
    private var cloudSyncGeneration = 0L
    private var cloudAccountId = FirebaseSyncService.signedInAccountId(appContext)
    private var signOutJob: Deferred<Unit>? = null
    var isSigningOut by mutableStateOf(false)
        private set

    var snapshot by mutableStateOf(loadSnapshot())
        private set

    var driveSyncState by mutableStateOf(
        DriveSyncUiState(
            configured = FirebaseSyncService.isConfigured(appContext),
            mode = snapshot.settings.cloudSyncMode,
            signedInEmail = FirebaseSyncService.signedInEmail(appContext),
        )
    )
        private set

    fun visibleTodos(filter: TodoFilter): List<TodoItem> {
        val now = System.currentTimeMillis()
        val monthAgo = now - 30L * 24L * 60L * 60L * 1000L
        return when (filter) {
            TodoFilter.ALL -> snapshot.todos
                .filter { !it.isCompleted && it.triage == TodoTriage.TODO }
                .sortedByDescending { it.effectivePriority }
            TodoFilter.ACTIVE -> snapshot.todos
                .filter { !it.isCompleted && it.triage == TodoTriage.TODO && (!it.isOverdue || it.effectivePriority >= 0.8) }
                .sortedByDescending { it.effectivePriority + if (it.isOverdue && it.effectivePriority >= 0.8) 0.05 else 0.0 }
            TodoFilter.OVERDUE -> snapshot.todos
                .filter { it.isOverdue && it.triage == TodoTriage.TODO }
                .sortedByDescending { it.effectivePriority }
            TodoFilter.REVIEW -> snapshot.todos
                .filter { !it.isCompleted && it.triage == TodoTriage.REVIEW }
                .sortedWith(compareBy<TodoItem> { it.dueAt ?: Long.MAX_VALUE }.thenBy { it.title.lowercase() })
            TodoFilter.COMPLETED -> snapshot.todos
                .filter { it.isCompleted && (it.completedAt == null || it.completedAt >= monthAgo) }
                .sortedByDescending { it.completedAt ?: 0L }
        }
    }

    fun activeCount(): Int = visibleTodos(TodoFilter.ACTIVE).size
    fun overdueCount(): Int = snapshot.todos.count { it.isOverdue && it.triage == TodoTriage.TODO }
    fun reviewCount(): Int = snapshot.todos.count { !it.isCompleted && it.triage == TodoTriage.REVIEW }

    fun setSelectedTab(tab: AppTab) = mutate {
        copy(settings = settings.copy(selectedTab = tab))
    }

    fun setLaunchBehavior(behavior: LaunchBehavior) = mutate {
        copy(settings = settings.copy(launchBehavior = behavior))
    }

    fun setLaunchTab(tab: AppTab) = mutate {
        copy(settings = settings.copy(launchTab = tab))
    }

    fun setAiAutomationEnabled(enabled: Boolean) = mutate {
        copy(settings = settings.copy(aiAutomationEnabled = enabled))
    }

    fun setCalendarAutoRegister(enabled: Boolean) = mutate {
        copy(settings = settings.copy(calendarAutoRegister = enabled))
    }

    fun setCalendarCompletionAction(action: CalendarCompletionAction) = mutate {
        copy(settings = settings.copy(calendarCompletionAction = action))
    }

    fun setEmailAutoAnalysisEnabled(enabled: Boolean) = mutate {
        copy(settings = settings.copy(emailAutoAnalysisEnabled = enabled))
    }

    fun setProviderEmailAnalysisEnabled(enabled: Boolean) = mutate {
        copy(settings = settings.copy(providerEmailAnalysisEnabled = enabled))
    }

    fun setCloudSyncMode(mode: CloudSyncMode) = mutate {
        if (mode != snapshot.settings.cloudSyncMode) cancelCloudSync()
        driveSyncState = driveSyncState.copy(mode = mode)
        copy(settings = settings.copy(cloudSyncMode = mode))
    }

    fun refreshDriveSyncState() {
        val accountId = FirebaseSyncService.signedInAccountId(appContext)
        if (accountId != cloudAccountId) {
            cancelCloudSync()
            cloudAccountId = accountId
            driveSyncState = driveSyncState.copy(lastSyncedAt = null, lastError = null)
        }
        driveSyncState = driveSyncState.copy(
            configured = FirebaseSyncService.isConfigured(appContext),
            mode = snapshot.settings.cloudSyncMode,
            signedInEmail = FirebaseSyncService.signedInEmail(appContext),
            lastError = if (FirebaseSyncService.isConfigured(appContext)) driveSyncState.lastError else "Firebase Google 로그인 설정이 없어 동기화를 시작할 수 없습니다.",
        )
    }

    fun cancelCloudSync() {
        cloudSyncGeneration += 1
        cloudSyncJob?.cancel()
        cloudSyncJob = null
        driveSyncState = driveSyncState.copy(isSyncing = false)
    }

    suspend fun signOutGoogleAccount() {
        val pending = signOutJob
        if (pending?.isActive == true) {
            pending.await()
            return
        }
        // Disconnect belongs to the application, not the screen that requested it.
        val operation = scope.async(start = CoroutineStart.UNDISPATCHED) {
            isSigningOut = true
            cancelCloudSync()
            driveSyncState = driveSyncState.copy(signedInEmail = null)
            try {
                FirebaseSyncService.signOut(appContext)
                setCloudSyncMode(CloudSyncMode.LOCAL)
            } finally {
                isSigningOut = false
                refreshDriveSyncState()
                refreshMailAvailability()
            }
        }
        signOutJob = operation
        operation.await()
    }

    suspend fun syncWithDriveNow(passphrase: String): Result<String> = runCloudSync(passphrase, restore = false)

    suspend fun restoreFromDrive(passphrase: String): Result<String> = runCloudSync(passphrase, restore = true)

    private suspend fun runCloudSync(passphrase: String, restore: Boolean): Result<String> {
        if (isSigningOut) return Result.failure(IllegalStateException("Google 계정 연결을 해제하는 중입니다."))
        if (driveSyncState.isSyncing) return Result.failure(IllegalStateException("동기화가 이미 진행 중입니다."))
        val accountId = FirebaseSyncService.signedInAccountId(appContext)
            ?: return Result.failure(IllegalStateException("Google 계정이 연결되지 않았습니다."))
        val generation = ++cloudSyncGeneration
        cloudSyncJob = currentCoroutineContext()[Job]
        driveSyncState = driveSyncState.copy(isSyncing = true, lastError = null)
        return try {
            val syncedAt: Long
            if (restore) {
                val raw = FirebaseSyncService.downloadSnapshot(appContext, passphrase)
                    ?: error("Firebase에 저장된 SIFT 스냅샷이 없습니다.")
                val remote = decodeAndroidCloudSnapshot(json, raw)
                currentCoroutineContext().ensureActive()
                checkCloudAccount(accountId, generation)
                snapshot = mergeCloudSnapshot(snapshot, remote)
                persist()
                syncedAt = System.currentTimeMillis()
            } else {
                val current = snapshot.forCloudSync()
                val result = FirebaseSyncService.uploadSnapshot(appContext, json.encodeToString(current), passphrase)
                currentCoroutineContext().ensureActive()
                checkCloudAccount(accountId, generation)
                syncedAt = result.syncedAt
            }
            driveSyncState = driveSyncState.copy(
                configured = true,
                mode = snapshot.settings.cloudSyncMode,
                signedInEmail = FirebaseSyncService.signedInEmail(appContext),
                lastSyncedAt = syncedAt,
                lastError = null,
            )
            Result.success(if (restore) "Firebase에서 데이터를 복원했습니다." else "Firebase에 동기화했습니다.")
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (generation == cloudSyncGeneration) {
                driveSyncState = driveSyncState.copy(lastError = error.message ?: "Firebase 동기화에 실패했습니다.")
            }
            Result.failure(error)
        } finally {
            if (generation == cloudSyncGeneration) {
                cloudSyncJob = null
                driveSyncState = driveSyncState.copy(isSyncing = false)
            }
        }
    }

    private fun checkCloudAccount(accountId: String, generation: Long) {
        if (generation != cloudSyncGeneration || accountId != FirebaseSyncService.signedInAccountId(appContext)) {
            throw CancellationException("Google 계정이 변경되어 동기화를 취소했습니다.")
        }
    }

    fun completeOnboarding(types: Set<PersonaType>, description: String) = mutate {
        val trimmed = description.trim()
        copy(
            onboardingComplete = true,
            persona = persona.copy(descriptionText = trimmed, personaTypes = types.toList().sortedBy { it.ordinal }),
        )
    }

    fun updatePersona(types: Set<PersonaType>, description: String) = mutate {
        copy(
            persona = persona.copy(
                descriptionText = description.trim(),
                personaTypes = types.toList().sortedBy { it.ordinal },
            )
        )
    }

    fun generatePersonaFromHistory(): String {
        val topTags = snapshot.todos
            .flatMap { it.tags }
            .groupingBy { it }
            .eachCount()
            .entries
            .sortedByDescending { it.value }
            .take(4)
            .map { it.key }

        val typeSummary = snapshot.persona.personaTypes.joinToString(" · ") { it.displayName }
        val detail = buildString {
            if (typeSummary.isNotBlank()) {
                append(typeSummary)
                append(" 중심의 일정 선호. ")
            }
            if (topTags.isNotEmpty()) {
                append("최근 반복되는 키워드: ")
                append(topTags.joinToString(", "))
                append(". ")
            }
            val analysis = latestMemoryInsight(snapshot.memory, snapshot.memoryHistory)
            if (analysis?.productiveHour != null) {
                append("집중 시간은 ")
                append(String.format("%02d:00", analysis.productiveHour))
                append(" 전후입니다.")
            }
        }.trim()

        val personaText = if (detail.isBlank()) {
            "마감과 중요도를 균형 있게 정리하고, 반복되는 생활 패턴에 맞춰 우선순위를 잡는 사용자"
        } else {
            detail
        }

        mutate { copy(persona = persona.copy(descriptionText = personaText)) }
        return personaText
    }

    fun saveTodo(draft: TodoDraft): TodoItem {
        val now = System.currentTimeMillis()
        val existing = draft.id?.let { id -> snapshot.todos.firstOrNull { it.id == id } }
        val todo = TodoItem(
            id = existing?.id ?: UUID.randomUUID().toString(),
            title = draft.title.trim(),
            notes = draft.notes.trim(),
            createdAt = existing?.createdAt ?: now,
            updatedAt = now,
            dueAt = draft.dueAt,
            isCompleted = existing?.isCompleted ?: false,
            completedAt = existing?.completedAt,
            manualPriority = draft.manualPriority,
            computedPriorityScore = existing?.computedPriorityScore ?: 0.0,
            priorityReason = existing?.priorityReason ?: "",
            reminderOffsets = existing?.reminderOffsets ?: emptyList(),
            estimatedDurationMinutes = draft.estimatedDurationMinutes.coerceIn(5, 240),
            source = existing?.source ?: TodoSource.MANUAL,
            sourceRef = existing?.sourceRef ?: "",
            sourceSender = existing?.sourceSender ?: "",
            sourceMessageId = existing?.sourceMessageId ?: "",
            sourceThreadId = existing?.sourceThreadId ?: "",
            sourceSenderEmail = existing?.sourceSenderEmail ?: "",
            triage = draft.triage,
            tags = draft.tags.filter { it.isNotBlank() }.distinct(),
            calendarEventId = existing?.calendarEventId,
            memoryNotes = existing?.memoryNotes ?: "",
            aiRecommendedTime = existing?.aiRecommendedTime,
            aiNeedsNotification = existing?.aiNeedsNotification ?: false,
            aiPersonaFit = existing?.aiPersonaFit ?: false,
            aiDetail = existing?.aiDetail ?: "",
            aiEngine = existing?.aiEngine ?: "",
            aiRequestedProvider = existing?.aiRequestedProvider ?: "",
            aiFallbackReason = existing?.aiFallbackReason ?: "",
            isFixedSchedule = existing?.isFixedSchedule ?: false,
        )
        mutate {
            val others = todos.filterNot { it.id == todo.id }
            copy(todos = (others + todo).sortedByDescending { it.createdAt })
        }
        return todo
    }

    fun saveMeetingTodo(title: String, notes: String, dueAt: Long?, sourceRef: String): TodoItem {
        snapshot.todos.firstOrNull { it.source == TodoSource.MEETING && it.sourceRef == sourceRef }?.let { return it }
        val now = System.currentTimeMillis()
        val todo = TodoItem(
            title = title.trim(),
            notes = notes.trim(),
            createdAt = now,
            updatedAt = now,
            dueAt = dueAt,
            source = TodoSource.MEETING,
            sourceRef = sourceRef,
            triage = TodoTriage.REVIEW,
            reminderOffsets = emptyList(),
            manualPriority = null,
            computedPriorityScore = 0.0,
            aiRecommendedTime = null,
            aiNeedsNotification = false,
            aiPersonaFit = false,
            aiDetail = "",
            aiEngine = "",
            aiRequestedProvider = "",
            aiFallbackReason = "",
        )
        mutate { copy(todos = (todos + todo).sortedByDescending { it.createdAt }) }
        return todo
    }

    fun saveImportedCalendarTodo(event: DeviceCalendarEvent): TodoItem {
        val existing = snapshot.todos.firstOrNull {
            it.source == TodoSource.CALENDAR && (it.sourceRef == event.stableRef ||
                (event.isRecurring && it.sourceRef == "calendar:${event.id}" && it.dueAt == event.startMillis))
        }
        val todo = TodoItem(
            id = existing?.id ?: UUID.randomUUID().toString(),
            title = event.title.ifBlank { "캘린더 일정" },
            notes = buildString {
                append(event.calendarName)
                if (!event.description.isNullOrBlank()) {
                    append("\n\n")
                    append(event.description.trim())
                }
            },
            createdAt = existing?.createdAt ?: System.currentTimeMillis(),
            updatedAt = System.currentTimeMillis(),
            dueAt = event.startMillis,
            isCompleted = existing?.isCompleted ?: false,
            completedAt = existing?.completedAt,
            manualPriority = existing?.manualPriority,
            computedPriorityScore = existing?.computedPriorityScore ?: 0.0,
            priorityReason = existing?.priorityReason ?: "캘린더에서 가져온 일정",
            reminderOffsets = existing?.reminderOffsets ?: emptyList(),
            estimatedDurationMinutes = max(30, ((event.endMillis - event.startMillis) / 60000L).toInt()),
            source = TodoSource.CALENDAR,
            sourceRef = event.stableRef,
            sourceSender = event.calendarName,
            triage = existing?.triage ?: TodoTriage.REVIEW,
            tags = existing?.tags ?: listOf("calendar"),
            calendarEventId = event.id,
            aiRecommendedTime = existing?.aiRecommendedTime,
            aiNeedsNotification = existing?.aiNeedsNotification ?: false,
            aiPersonaFit = existing?.aiPersonaFit ?: false,
            aiDetail = existing?.aiDetail ?: "",
            aiEngine = existing?.aiEngine ?: "",
            aiRequestedProvider = existing?.aiRequestedProvider ?: "",
            aiFallbackReason = existing?.aiFallbackReason ?: "",
            isFixedSchedule = event.isRecurring,
        )
        mutate {
            val others = todos.filterNot { it.id == todo.id }
            copy(todos = (others + todo).sortedByDescending { it.createdAt })
        }
        return todo
    }

    fun promoteReviewTodo(id: String): TodoItem? {
        var updated: TodoItem? = null
        mutate {
            copy(
                todos = todos.map { todo ->
                    if (todo.id != id) return@map todo
                    updated = todo.copy(triage = TodoTriage.TODO, updatedAt = System.currentTimeMillis())
                    updated!!
                }
            )
        }
        return updated
    }

    fun toggleTodoCompleted(id: String): TodoItem? {
        var updated: TodoItem? = null
        val now = System.currentTimeMillis()
        mutate {
            copy(
                todos = todos.map { todo ->
                    if (todo.id != id) return@map todo
                    updated = todo.copy(
                        isCompleted = !todo.isCompleted,
                        completedAt = if (!todo.isCompleted) now else null,
                        updatedAt = now,
                    )
                    updated!!
                }
            )
        }
        return updated
    }

    fun deleteTodo(id: String) = mutate {
        copy(todos = todos.filterNot { it.id == id })
    }

    fun updateTodoCalendarLink(id: String, eventId: Long?) = mutate {
        copy(
            todos = todos.map { todo ->
                if (todo.id == id) todo.copy(calendarEventId = eventId, updatedAt = System.currentTimeMillis()) else todo
            }
        )
    }

    fun prioritizeTodos(calendarEvents: List<DeviceCalendarEvent>): Int {
        val personaKeywords = snapshot.persona.personaTypes.flatMap { it.keywords }.toSet()
        val productiveHour = latestMemoryInsight(snapshot.memory, snapshot.memoryHistory)?.productiveHour
        val now = System.currentTimeMillis()
        var changed = 0
        mutate {
            copy(
                todos = todos.map { todo ->
                    if (todo.isCompleted || todo.triage != TodoTriage.TODO || todo.manualPriority != null) return@map todo
                    val result = computePriority(todo, personaKeywords, productiveHour, calendarEvents, now)
                    changed += 1
                    todo.copy(
                        computedPriorityScore = result.score,
                        priorityReason = result.reason,
                        aiRecommendedTime = result.recommendedTime,
                        aiNeedsNotification = result.needsNotification,
                        aiPersonaFit = result.personaFit,
                        aiDetail = result.detail,
                        aiEngine = "heuristic",
                        aiRequestedProvider = snapshot.settings.selectedProvider.name.lowercase(),
                        aiFallbackReason = "",
                        updatedAt = now,
                    )
                }.sortedByDescending { it.effectivePriority }
            )
        }
        return changed
    }

    fun analyzeMemoryPreview(): MemoryInsight = computeMemoryAnalysis(snapshot.todos)

    fun applyMemoryAnalysis(analysis: MemoryInsight) = mutate {
        val updated = (listOf(analysis) + normalizedMemoryHistory(memory, memoryHistory))
            .filter { it.summary.isNotBlank() || it.insights.isNotEmpty() }
            .distinctBy { it.createdAt to it.summary }
            .sortedByDescending { it.createdAt }
            .take(5)
        copy(memory = updated.firstOrNull(), memoryHistory = updated)
    }

    fun deleteMemoryHistoryAt(index: Int) {
        val history = normalizedMemoryHistory(snapshot.memory, snapshot.memoryHistory)
        if (index !in history.indices) return
        mutate {
            val updated = history.toMutableList().also { it.removeAt(index) }
            copy(memory = updated.firstOrNull(), memoryHistory = updated)
        }
    }

    fun resetTutorial() = mutate { copy(onboardingComplete = false) }

    fun refreshMailAvailability() = mutate {
        copy(
            mail = mail.copy(
                gmailConnected = AndroidGmailService.signedInEmail(appContext) != null,
                outlookConnected = false,
                lastSyncMessage = if (AndroidGmailService.isConfigured(appContext)) {
                    "Gmail은 읽기 전용 최근 메일 미리보기를 지원합니다. Outlook 및 자동 메일 분석은 사용할 수 없습니다."
                } else {
                    "Android Gmail OAuth client와 SHA-1 등록이 없어 메일 미리보기를 시작할 수 없습니다."
                },
            )
        )
    }

    private fun computePriority(
        todo: TodoItem,
        personaKeywords: Set<String>,
        productiveHour: Int?,
        calendarEvents: List<DeviceCalendarEvent>,
        now: Long,
    ): PriorityResult {
        var score = 0.15
        val reasons = mutableListOf<String>()
        val detail = mutableListOf<String>()
        val text = (todo.title + " " + todo.notes + " " + todo.tags.joinToString(" ")).lowercase()

        val dueAt = todo.dueAt
        if (dueAt != null) {
            val hours = (dueAt - now) / 3600000.0
            when {
                hours <= 0 -> {
                    score += 0.5
                    reasons += "이미 기한이 지났습니다"
                }
                hours <= 24 -> {
                    score += 0.4
                    reasons += "오늘 안에 처리해야 합니다"
                }
                hours <= 72 -> {
                    score += 0.25
                    reasons += "이번 주 안에 마감됩니다"
                }
                else -> {
                    score += 0.1
                    detail += "기한은 남아 있지만 일정 블록을 잡아두는 편이 좋습니다"
                }
            }
        } else {
            detail += "기한이 없어 사용자가 직접 우선순위를 다듬기 좋습니다"
        }

        val personaFit = personaKeywords.any { text.contains(it.lowercase()) }
        if (personaFit) {
            score += 0.15
            reasons += "현재 페르소나와 맞는 할 일입니다"
        }

        val calendarConflict = dueAt != null && calendarEvents.any { event ->
            val startGap = abs(event.startMillis - dueAt)
            startGap <= 90L * 60L * 1000L
        }
        if (calendarConflict) {
            score += 0.1
            detail += "캘린더 일정과 가까워 먼저 처리하거나 시간을 재조정하는 편이 안전합니다"
        }

        if (todo.estimatedDurationMinutes >= 90) {
            score += 0.05
            detail += "예상 소요 시간이 길어 미리 시작하는 편이 좋습니다"
        }

        val recommendedTime = when {
            dueAt == null || productiveHour == null -> dueAt?.minus(60L * 60L * 1000L)
            else -> {
                val cal = java.util.Calendar.getInstance().apply {
                    timeInMillis = max(now, dueAt - 12L * 60L * 60L * 1000L)
                    set(java.util.Calendar.HOUR_OF_DAY, productiveHour)
                    set(java.util.Calendar.MINUTE, 0)
                    set(java.util.Calendar.SECOND, 0)
                    set(java.util.Calendar.MILLISECOND, 0)
                }
                val candidate = cal.timeInMillis
                if (candidate > now && candidate <= dueAt) candidate else dueAt - 60L * 60L * 1000L
            }
        }

        score = min(1.0, score)
        val reason = reasons.firstOrNull() ?: "중요도와 기한을 균형 있게 반영했습니다"
        val finalDetail = buildString {
            append(reason)
            if (detail.isNotEmpty()) {
                append(" · ")
                append(detail.joinToString(" · "))
            }
        }
        val needsNotification = dueAt?.let { it - now <= 24L * 60L * 60L * 1000L } == true || score >= 0.8

        return PriorityResult(
            score = score,
            reason = reason,
            detail = finalDetail,
            recommendedTime = recommendedTime,
            needsNotification = needsNotification,
            personaFit = personaFit,
        )
    }

    private fun mutate(transform: SiftSnapshot.() -> SiftSnapshot) {
        snapshot = snapshot.transform()
        persist()
    }

    private fun persist() {
        val current = snapshot
        scope.launch {
            // Acquire on Main before dispatching IO so older snapshots cannot overtake newer ones.
            persistenceMutex.withLock {
                withContext(Dispatchers.IO) {
                    val temporaryFile = File(stateFile.parentFile, "${stateFile.name}.tmp")
                    temporaryFile.outputStream().use { stream ->
                        stream.write(json.encodeToString(current).toByteArray())
                        stream.fd.sync()
                    }
                    try {
                        Files.move(
                            temporaryFile.toPath(),
                            stateFile.toPath(),
                            StandardCopyOption.ATOMIC_MOVE,
                            StandardCopyOption.REPLACE_EXISTING,
                        )
                    } catch (_: AtomicMoveNotSupportedException) {
                        Files.move(temporaryFile.toPath(), stateFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    }
                }
            }
        }
    }

    private fun loadSnapshot(): SiftSnapshot {
        return runCatching {
            if (!stateFile.exists()) return SiftSnapshot()
            json.decodeFromString<SiftSnapshot>(stateFile.readText()).normalizedMemorySnapshot()
        }.getOrElse { SiftSnapshot() }
    }
}
