@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package xyz.pieroot.sift

import android.Manifest
import android.app.DatePickerDialog
import android.app.TimePickerDialog
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Checklist
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Email
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Notifications
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Divider
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import kotlinx.coroutines.launch
import java.text.DecimalFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import xyz.pieroot.sift.ui.theme.SIFTTheme

private enum class SettingsDestination {
    ROOT,
    PERSONA,
    MEMORY,
    INTELLIGENCE,
    EMAIL,
    CALENDAR,
    CLOUD_SYNC,
    SYSTEM,
    APP_INFO,
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SiftApp(
    openTodoId: String? = null,
    onOpenTodoHandled: () -> Unit = {},
) {
    val context = LocalContext.current
    val store = remember(context) { SiftStore(context) }
    val meetingStore = remember(context) { MeetingStore(context) }
    val meetingCapture = remember(context) { MeetingCaptureRepository.get(context) }
    val snapshot = store.snapshot
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val calendarPermissions = arrayOf(
        Manifest.permission.READ_CALENDAR,
        Manifest.permission.WRITE_CALENDAR,
    )

    fun showMessage(message: String) {
        scope.launch { snackbarHostState.showSnackbar(message) }
    }

    var selectedTab by rememberSaveable(snapshot.settings.launchBehavior, snapshot.settings.launchTab, snapshot.settings.selectedTab) {
        mutableStateOf(if (snapshot.settings.launchBehavior == LaunchBehavior.FIXED) snapshot.settings.launchTab else snapshot.settings.selectedTab)
    }
    var todoFilter by rememberSaveable { mutableStateOf(TodoFilter.ACTIVE) }
    var settingsDestination by rememberSaveable { mutableStateOf<SettingsDestination?>(null) }
    var editingTodoId by rememberSaveable { mutableStateOf<String?>(null) }
    var creatingTodo by rememberSaveable { mutableStateOf(false) }
    var onboardingStep by rememberSaveable { mutableIntStateOf(0) }
    var onboardingTypes by rememberSaveable { mutableStateOf(snapshot.persona.personaTypes.toSet()) }
    var onboardingDescription by rememberSaveable { mutableStateOf(snapshot.persona.descriptionText) }
    var calendarEvents by remember { mutableStateOf(emptyList<DeviceCalendarEvent>()) }
    var cloudSyncPassphrase by remember { mutableStateOf("") }
    var pendingOpenTodoId by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingMemoryAnalysis by remember { mutableStateOf<MemoryInsight?>(null) }
    val reminderService = remember(context) { ReminderNotificationService(context) }

    LaunchedEffect(openTodoId) {
        pendingOpenTodoId = openTodoId?.trim()?.ifEmpty { null }
    }

    LaunchedEffect(pendingOpenTodoId, snapshot.todos, snapshot.onboardingComplete) {
        val targetTodoId = pendingOpenTodoId?.trim()?.ifEmpty { null } ?: return@LaunchedEffect
        if (!snapshot.onboardingComplete) return@LaunchedEffect

        snapshot.todos.firstOrNull { it.id == targetTodoId } ?: return@LaunchedEffect

        selectedTab = AppTab.TODO
        cloudSyncPassphrase = ""
        settingsDestination = null
        editingTodoId = targetTodoId
        creatingTodo = false
        pendingOpenTodoId = null
        onOpenTodoHandled()
    }


    LaunchedEffect(snapshot.todos) {
        reminderService.rescheduleForTodos(snapshot.todos)
    }

    val calendarPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions(),
    ) { granted ->
        if (granted.values.all { it }) {
            calendarEvents = DeviceCalendarStore.queryUpcomingEvents(context)
            showMessage("캘린더 권한을 허용했습니다.")
        } else {
            showMessage("캘린더 권한이 없어 기기 일정 읽기/쓰기를 건너뜁니다.")
        }
    }

    val notificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { granted ->
        showMessage(if (granted) "알림 권한을 허용했습니다." else "알림 권한이 없어 로컬 알림은 비활성 상태입니다.")
    }

    val driveSignInLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        FirebaseSyncService.handleSignInIntent(result.data)
            .onSuccess {
                store.refreshDriveSyncState()
                store.setCloudSyncMode(CloudSyncMode.FIREBASE)
                showMessage("클라우드 동기화 계정을 연결했습니다. 이제 암호화 비밀번호를 입력한 뒤 수동 동기화를 실행하세요.")
            }
            .onFailure {
                store.refreshDriveSyncState()
                showMessage(it.message ?: "Firebase 로그인에 실패했습니다.")
            }
    }

    fun requestDriveSignIn() {
        if (!FirebaseSyncService.isConfigured(context)) {
            showMessage("google-services.json 에 Android OAuth client 와 SHA-1 등록이 없어 Firebase 로그인을 시작할 수 없습니다.")
            return
        }
        driveSignInLauncher.launch(FirebaseSyncService.signInIntent(context))
    }

    fun signOutDrive() {
        FirebaseSyncService.signOut(context)
        store.setCloudSyncMode(CloudSyncMode.LOCAL)
        store.refreshDriveSyncState()
        showMessage("Firebase 연결을 해제했습니다.")
    }

    fun requestCalendarPermissions() {
        calendarPermissionLauncher.launch(calendarPermissions)
    }

    fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            showMessage("이 안드로이드 버전은 별도 알림 권한이 필요하지 않습니다.")
        }
    }

    fun refreshCalendarEvents() {
        calendarEvents = if (DeviceCalendarStore.hasReadPermission(context)) {
            DeviceCalendarStore.queryUpcomingEvents(context)
        } else {
            emptyList()
        }
    }

    fun syncTodoCalendarLink(todo: TodoItem) {
        if (!store.snapshot.settings.calendarAutoRegister) return
        if (!DeviceCalendarStore.hasWritePermission(context)) return
        if (todo.isCompleted || todo.triage != TodoTriage.TODO || todo.dueAt == null) return
        val eventId = DeviceCalendarStore.createOrUpdateTodoEvent(context, todo)
        if (eventId != null) {
            store.updateTodoCalendarLink(todo.id, eventId)
        }
    }

    fun handleCompletionCalendar(todo: TodoItem) {
        val eventId = todo.calendarEventId ?: return
        when (store.snapshot.settings.calendarCompletionAction) {
            CalendarCompletionAction.REMOVE -> {
                DeviceCalendarStore.deleteEvent(context, eventId)
                store.updateTodoCalendarLink(todo.id, null)
            }
            CalendarCompletionAction.SILENCE -> DeviceCalendarStore.clearEventReminders(context, eventId)
        }
        refreshCalendarEvents()
    }

    fun deleteTodo(todo: TodoItem) {
        if (!todo.isCompleted && todo.triage == TodoTriage.TODO) {
            todo.calendarEventId?.let { eventId ->
                when (store.snapshot.settings.calendarCompletionAction) {
                    CalendarCompletionAction.REMOVE -> DeviceCalendarStore.deleteEvent(context, eventId)
                    CalendarCompletionAction.SILENCE -> DeviceCalendarStore.clearEventReminders(context, eventId)
                }
            }
        }
        store.deleteTodo(todo.id)
        refreshCalendarEvents()
        showMessage("할 일을 삭제했습니다.")
    }

    fun importCalendarEvents() {
        val imported = calendarEvents.map { event -> store.saveImportedCalendarTodo(event) }
        if (imported.isEmpty()) showMessage("가져올 캘린더 일정이 없습니다.")
        else showMessage("${imported.size}개의 캘린더 일정을 등록 대기열로 가져왔습니다.")
    }

    fun runPrioritization() {
        val updated = store.prioritizeTodos(calendarEvents)
        if (updated == 0) showMessage("AI 정렬 대상이 없습니다. 진행 중인 할 일만 정렬합니다.")
        else showMessage("${updated}개의 할 일을 휴리스틱으로 다시 정렬했습니다.")
    }

    LaunchedEffect(selectedTab) {
        store.setSelectedTab(selectedTab)
        if (selectedTab == AppTab.CALENDAR) refreshCalendarEvents()
    }

    LaunchedEffect(Unit) {
        store.markMailOAuthBlocked()
        store.refreshDriveSyncState()
        refreshCalendarEvents()
    }

    val editingTodo = remember(snapshot.todos, editingTodoId) {
        snapshot.todos.firstOrNull { it.id == editingTodoId }
    }

    if (!snapshot.onboardingComplete) {
        OnboardingScreen(
            step = onboardingStep,
            selectedTypes = onboardingTypes,
            description = onboardingDescription,
            driveSyncConfigured = store.driveSyncState.configured,
            onStepChange = { onboardingStep = it.coerceIn(0, 2) },
            onTypeToggle = { type ->
                onboardingTypes = onboardingTypes.toMutableSet().apply {
                    if (!add(type)) remove(type)
                }
            },
            onDescriptionChange = { onboardingDescription = it },
            onComplete = {
                store.completeOnboarding(onboardingTypes, onboardingDescription)
                onboardingStep = 0
                showMessage("페르소나 설정을 저장했습니다.")
            },
            onSkip = {
                store.completeOnboarding(emptySet(), "")
                onboardingStep = 0
                showMessage("온보딩을 건너뛰었습니다.")
            },
        )
        return
    }

    if (creatingTodo || editingTodo != null) {
        TodoEditorDialog(
            initialTodo = editingTodo,
            onDismiss = {
                creatingTodo = false
                editingTodoId = null
            },
            onSave = { draft ->
                val saved = store.saveTodo(draft)
                syncTodoCalendarLink(saved)
                creatingTodo = false
                editingTodoId = null
                refreshCalendarEvents()
                showMessage(if (draft.id == null) "할 일을 추가했습니다." else "할 일을 수정했습니다.")
            },
        )
    }

    if (settingsDestination != null) {
        SettingsSurface(
            destination = settingsDestination ?: SettingsDestination.ROOT,
            snapshot = snapshot,
            calendarEvents = calendarEvents,
            driveSyncState = store.driveSyncState,
            calendarPermissionGranted = DeviceCalendarStore.hasReadPermission(context),
            notificationPermissionGranted = notificationPermissionGranted(context),
            onBack = {
                cloudSyncPassphrase = ""
                settingsDestination = when (settingsDestination) {
                    SettingsDestination.ROOT -> null
                    else -> SettingsDestination.ROOT
                }
            },
            onClose = {
                cloudSyncPassphrase = ""
                settingsDestination = null
            },
            onNavigate = {
                if (settingsDestination == SettingsDestination.CLOUD_SYNC && it != SettingsDestination.CLOUD_SYNC) {
                    cloudSyncPassphrase = ""
                }
                settingsDestination = it
            },
            onPersonaSave = { types, description ->
                store.updatePersona(types, description)
                showMessage("페르소나를 저장했습니다.")
            },
            onGeneratePersona = {
                val generated = store.generatePersonaFromHistory()
                showMessage("AI 페르소나 문장을 갱신했습니다: $generated")
            },
            onAnalyzeMemory = {
                pendingMemoryAnalysis = store.analyzeMemoryPreview()
                showMessage("분석 결과를 확인한 뒤 적용하세요.")
            },
            pendingMemoryAnalysis = pendingMemoryAnalysis,
            onApplyMemoryAnalysis = { analysis ->
                store.applyMemoryAnalysis(analysis)
                pendingMemoryAnalysis = null
                showMessage("행동 패턴 분석을 저장했습니다.")
            },
            onCancelMemoryAnalysis = { pendingMemoryAnalysis = null },
            onDeleteMemoryAnalysis = { index ->
                store.deleteMemoryHistoryAt(index)
                showMessage("저장된 분석을 삭제했습니다.")
            },
            onRunPrioritize = { runPrioritization() },
            onSetAiAutomation = store::setAiAutomationEnabled,
            onSetCalendarAutoRegister = store::setCalendarAutoRegister,
            onSetCalendarCompletionAction = store::setCalendarCompletionAction,
            onSetEmailAutoAnalysis = store::setEmailAutoAnalysisEnabled,
            onSetProviderEmailAnalysis = store::setProviderEmailAnalysisEnabled,
            onSetEmailRefreshHour = store::setEmailRefreshHour,
            onSetEmailLookbackDays = store::setEmailLookbackDays,
            onSetCloudSyncMode = store::setCloudSyncMode,
            syncPassphrase = cloudSyncPassphrase,
            onSyncPassphraseChange = { cloudSyncPassphrase = it },
            onDriveSignIn = { requestDriveSignIn() },
            onDriveSignOut = { signOutDrive() },
            onDriveSyncNow = { passphrase ->
                scope.launch {
                    store.syncWithDriveNow(passphrase)
                        .onSuccess { showMessage(it) }
                        .onFailure { showMessage(it.message ?: "클라우드 동기화에 실패했습니다.") }
                    cloudSyncPassphrase = ""
                }
            },
            onDriveRestore = { passphrase ->
                scope.launch {
                    store.restoreFromDrive(passphrase)
                        .onSuccess { showMessage(it) }
                        .onFailure { showMessage(it.message ?: "Firebase 복원에 실패했습니다.") }
                    cloudSyncPassphrase = ""
                }
            },
            onSetLaunchBehavior = store::setLaunchBehavior,
            onSetLaunchTab = store::setLaunchTab,
            onRequestCalendarPermission = { requestCalendarPermissions() },
            onRequestNotificationPermission = { requestNotificationPermission() },
            onReplayOnboarding = {
                onboardingTypes = snapshot.persona.personaTypes.toSet()
                onboardingDescription = snapshot.persona.descriptionText
                onboardingStep = 0
                settingsDestination = null
                store.resetTutorial()
            },
            onMarkMailBlocked = {
                store.markMailOAuthBlocked()
                showMessage(store.snapshot.mail.lastSyncMessage)
            },
        )
        return
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        when (selectedTab) {
                            AppTab.TODO -> "할 일"
                            AppTab.CALENDAR -> "캘린더"
                            AppTab.MAIL -> "메일"
                            AppTab.MEETING -> "회의"
                        }
                    )
                },
                actions = {
                    if (selectedTab == AppTab.TODO) {
                        IconButton(onClick = { runPrioritization() }) {
                            Icon(Icons.Rounded.AutoAwesome, contentDescription = "정렬")
                        }
                    }
                    if (selectedTab == AppTab.CALENDAR) {
                        IconButton(onClick = { refreshCalendarEvents() }) {
                            Icon(Icons.Rounded.CalendarMonth, contentDescription = "새로고침")
                        }
                    }
                    IconButton(onClick = { settingsDestination = SettingsDestination.ROOT }) {
                        Icon(Icons.Rounded.Settings, contentDescription = "설정")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
        floatingActionButton = {
            if (selectedTab == AppTab.TODO) {
                FloatingActionButton(onClick = { creatingTodo = true }) {
                    Text("+")
                }
            }
        },
        bottomBar = {
            NavigationBar(modifier = Modifier.navigationBarsPadding()) {
                NavigationBarItem(
                    selected = selectedTab == AppTab.TODO,
                    onClick = { selectedTab = AppTab.TODO },
                    icon = { Icon(Icons.Rounded.Checklist, contentDescription = null) },
                    label = { Text("할 일") },
                )
                NavigationBarItem(
                    selected = selectedTab == AppTab.CALENDAR,
                    onClick = { selectedTab = AppTab.CALENDAR },
                    icon = { Icon(Icons.Rounded.CalendarMonth, contentDescription = null) },
                    label = { Text("캘린더") },
                )
                NavigationBarItem(
                    selected = selectedTab == AppTab.MAIL,
                    onClick = { selectedTab = AppTab.MAIL },
                    icon = { Icon(Icons.Rounded.Email, contentDescription = null) },
                    label = { Text("메일") },
                )
                NavigationBarItem(
                    selected = selectedTab == AppTab.MEETING,
                    onClick = { selectedTab = AppTab.MEETING },
                    icon = { Icon(Icons.Rounded.Mic, contentDescription = null) },
                    label = { Text("회의") },
                )
            }
        },
    ) { innerPadding ->
        Surface(modifier = Modifier.fillMaxSize()) {
            when (selectedTab) {
                AppTab.TODO -> TodoScreen(
                    modifier = Modifier.padding(innerPadding),
                    todos = store.visibleTodos(todoFilter),
                    filter = todoFilter,
                    activeCount = store.activeCount(),
                    overdueCount = store.overdueCount(),
                    reviewCount = store.reviewCount(),
                    onFilterChange = { todoFilter = it },
                    onEdit = { todo -> editingTodoId = todo.id },
                    onToggleComplete = { todo ->
                        val updated = store.toggleTodoCompleted(todo.id) ?: return@TodoScreen
                        if (updated.isCompleted) handleCompletionCalendar(updated)
                        showMessage(if (updated.isCompleted) "완료 처리했습니다." else "완료를 취소했습니다.")
                    },
                    onPromote = { todo ->
                        val updated = store.promoteReviewTodo(todo.id)
                        if (updated != null) {
                            syncTodoCalendarLink(updated)
                            showMessage("등록 대기열에서 진행 중으로 옮겼습니다.")
                        }
                    },
                    onDelete = { todo -> deleteTodo(todo) },
                )
                AppTab.CALENDAR -> CalendarScreen(
                    modifier = Modifier.padding(innerPadding),
                    calendarPermissionGranted = DeviceCalendarStore.hasReadPermission(context),
                    events = calendarEvents,
                    dueTodos = snapshot.todos.filter { !it.isCompleted && it.dueAt != null }.sortedBy { it.dueAt },
                    onRequestPermission = { requestCalendarPermissions() },
                    onRefresh = { refreshCalendarEvents() },
                    onImport = { importCalendarEvents() },
                    onOpenTodo = { todo -> editingTodoId = todo.id },
                )
                AppTab.MAIL -> MailScreen(
                    modifier = Modifier.padding(innerPadding),
                    snapshot = snapshot,
                    onCheckOAuth = {
                        store.markMailOAuthBlocked()
                        showMessage(store.snapshot.mail.lastSyncMessage)
                    },
                )
                AppTab.MEETING -> MeetingScreen(
                    modifier = Modifier.padding(innerPadding),
                    meetingStore = meetingStore,
                    capture = meetingCapture,
                    todoStore = store,
                    onMessage = ::showMessage,
                )
            }
        }
    }
}

@Composable
private fun OnboardingScreen(
    step: Int,
    selectedTypes: Set<PersonaType>,
    description: String,
    driveSyncConfigured: Boolean,
    onStepChange: (Int) -> Unit,
    onTypeToggle: (PersonaType) -> Unit,
    onDescriptionChange: (String) -> Unit,
    onComplete: () -> Unit,
    onSkip: () -> Unit,
) {
    fun personaEmoji(type: PersonaType): String = when (type) {
        PersonaType.STUDENT -> "🎓"
        PersonaType.OFFICE_WORKER -> "💼"
        PersonaType.FREELANCER -> "💻"
        PersonaType.JOB_SEEKER -> "🔎"
        PersonaType.SELF_EMPLOYED -> "🏪"
        PersonaType.HOMEMAKER -> "🏠"
        PersonaType.OTHER -> "✨"
    }

    Scaffold { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .padding(horizontal = 24.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                OutlinedButton(onClick = onSkip) {
                    Text("건너뛰기")
                }
            }

            Text(
                "처음 오셨군요!",
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.ExtraBold,
            )

            when (step) {
                0 -> {
                    Text("데이터 동기화 설정", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    Text(
                        "할 일, 페르소나 등의 데이터를 클라우드에 동기화할지 선택해 주세요. Android 포트는 우선 로컬 저장을 기본 경로로 제공합니다.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )

                    Card(
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text(if (driveSyncConfigured) "☁️  클라우드 동기화" else "☁️  클라우드 동기화 준비 중", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
                            Text(
                                if (driveSyncConfigured) "iOS의 iCloud 동기화에 대응해 Android에서는 Firebase Auth와 Firestore를 사용합니다. 로그인 후 사용자별 Firestore 경로에 암호화된 SIFT 데이터를 동기화합니다." else "iOS의 iCloud 동기화에 대응해 Android에서는 Firebase Auth와 Firestore를 사용합니다. 현재 Android OAuth 클라이언트가 없어 로컬 경로를 기본값으로 둡니다.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }

                    Card(
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primary),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(modifier = Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text("📁  이 기기에만 저장 (로컬)", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onPrimary, fontWeight = FontWeight.Bold)
                            Text(
                                "데이터를 클라우드에 업로드하지 않고 현재 기기에만 보관합니다. 추후 클라우드 동기화를 연결하면 같은 Android 데이터 흐름으로 확장할 수 있습니다.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.86f),
                            )
                        }
                    }
                }

                1 -> {
                    Text("어떤 생활을 하고 계신가요?", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    Text(
                        "중복 선택 가능합니다. 선택한 유형에 따라 AI가 할 일 우선순위를 더 정확하게 조정합니다.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )

                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        PersonaType.entries.chunked(2).forEach { row ->
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                                row.forEach { type ->
                                    val selected = selectedTypes.contains(type)
                                    Card(
                                        colors = CardDefaults.cardColors(
                                            containerColor = if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surfaceVariant,
                                        ),
                                        modifier = Modifier
                                            .weight(1f)
                                            .clickable { onTypeToggle(type) },
                                    ) {
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(vertical = 20.dp),
                                            horizontalAlignment = Alignment.CenterHorizontally,
                                            verticalArrangement = Arrangement.spacedBy(10.dp),
                                        ) {
                                            Text(personaEmoji(type), style = MaterialTheme.typography.headlineMedium)
                                            Text(
                                                type.displayName,
                                                style = MaterialTheme.typography.titleMedium,
                                                color = if (selected) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface,
                                                fontWeight = FontWeight.Bold,
                                            )
                                        }
                                    }
                                }
                                if (row.size == 1) Spacer(modifier = Modifier.weight(1f))
                            }
                        }
                    }
                }

                else -> {
                    val suggested = selectedTypes.flatMap { it.presets }.distinct()
                    Text("나를 조금 더 설명해 주세요", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                    Text(
                        "페르소나 설명은 TODO 정렬과 패턴 분석의 기준이 됩니다.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (suggested.isNotEmpty()) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            suggested.forEach { preset ->
                                AssistChip(
                                    onClick = {
                                        val next = if (description.contains(preset)) description else listOf(description.trim(), preset).filter { it.isNotBlank() }.joinToString(", ")
                                        onDescriptionChange(next)
                                    },
                                    label = { Text(preset) },
                                )
                            }
                        }
                    }
                    OutlinedTextField(
                        value = description,
                        onValueChange = onDescriptionChange,
                        label = { Text("나의 우선순위 기준") },
                        placeholder = { Text("예: 업무 마감 > 가족 일정 > 개인 학습. 오전은 집중 업무 시간") },
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 5,
                    )
                }
            }

            Spacer(modifier = Modifier.weight(1f))

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
                if (step > 0) {
                    OutlinedButton(onClick = { onStepChange(step - 1) }, modifier = Modifier.weight(1f)) {
                        Text("이전")
                    }
                }
                Button(
                    onClick = {
                        when (step) {
                            0 -> onStepChange(1)
                            1 -> onStepChange(2)
                            else -> onComplete()
                        }
                    },
                    modifier = Modifier.weight(1f),
                    enabled = when (step) {
                        0 -> true
                        1 -> selectedTypes.isNotEmpty()
                        else -> description.isNotBlank()
                    },
                ) {
                    Text(
                        when (step) {
                            0 -> "로컬 전용으로 다음 단계 진행"
                            1 -> "다음"
                            else -> "시작하기"
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun TodoScreen(
    modifier: Modifier = Modifier,
    todos: List<TodoItem>,
    filter: TodoFilter,
    activeCount: Int,
    overdueCount: Int,
    reviewCount: Int,
    onFilterChange: (TodoFilter) -> Unit,
    onEdit: (TodoItem) -> Unit,
    onToggleComplete: (TodoItem) -> Unit,
    onPromote: (TodoItem) -> Unit,
    onDelete: (TodoItem) -> Unit,
) {
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            FilterRow(
                filter = filter,
                activeCount = activeCount,
                overdueCount = overdueCount,
                reviewCount = reviewCount,
                onFilterChange = onFilterChange,
            )
        }
        if (todos.isEmpty()) {
            item {
                EmptyStateCard(
                    title = when (filter) {
                        TodoFilter.ACTIVE -> "진행 중인 할 일이 없습니다"
                        TodoFilter.OVERDUE -> "기한이 지난 할 일이 없습니다"
                        TodoFilter.ALL -> "할 일이 없습니다"
                        TodoFilter.REVIEW -> "등록 대기열이 비어 있습니다"
                        TodoFilter.COMPLETED -> "완료한 항목이 없습니다"
                    },
                    body = when (filter) {
                        TodoFilter.REVIEW -> "캘린더에서 가져온 일정이 이곳에 쌓입니다. 진행 중으로 승격하면 메인 목록에 들어갑니다."
                        TodoFilter.COMPLETED -> "완료한 항목은 최근 30일 기준으로 유지합니다."
                        else -> "새 할 일을 추가하거나 AI 정렬을 실행해 우선순위를 확인해 보세요."
                    },
                )
            }
        }
        items(todos, key = { it.id }) { todo ->
            TodoCard(
                todo = todo,
                onClick = { onEdit(todo) },
                onToggleComplete = { onToggleComplete(todo) },
                onPromote = { onPromote(todo) },
                onDelete = { onDelete(todo) },
            )
        }
        item { Spacer(modifier = Modifier.height(96.dp)) }
    }
}

@Composable
private fun FilterRow(
    filter: TodoFilter,
    activeCount: Int,
    overdueCount: Int,
    reviewCount: Int,
    onFilterChange: (TodoFilter) -> Unit,
) {
    val items = listOf(
        TodoFilter.ACTIVE to "진행 중 $activeCount",
        TodoFilter.OVERDUE to "기한 초과 $overdueCount",
        TodoFilter.ALL to "전체",
        TodoFilter.REVIEW to "등록 대기열 $reviewCount",
        TodoFilter.COMPLETED to "완료",
    )
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items.forEach { (target, label) ->
                FilterChip(
                    selected = filter == target,
                    onClick = { onFilterChange(target) },
                    label = { Text(label) },
                )
            }
        }
    }
}

@Composable
private fun TodoCard(
    todo: TodoItem,
    onClick: () -> Unit,
    onToggleComplete: () -> Unit,
    onPromote: () -> Unit,
    onDelete: () -> Unit,
) {
    OutlinedCard(
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clickable(onClick = onClick),
        colors = CardDefaults.outlinedCardColors(
            containerColor = if (todo.isCompleted) MaterialTheme.colorScheme.surfaceVariant else MaterialTheme.colorScheme.surface,
        ),
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                PriorityDot(todo = todo)
                Spacer(modifier = Modifier.width(10.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(todo.title.ifBlank { "제목 없는 할 일" }, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    val detail = buildList {
                        todo.dueAt?.let { add("마감 ${formatDateTime(it)}") }
                        if (todo.tags.isNotEmpty()) add(todo.tags.joinToString(", "))
                        if (todo.priorityReason.isNotBlank()) add(todo.priorityReason)
                    }.joinToString(" · ")
                    if (detail.isNotBlank()) {
                        Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                Text(
                    when (todo.triage) {
                        TodoTriage.TODO -> if (todo.isCompleted) "완료" else "진행"
                        TodoTriage.REVIEW -> "대기"
                    },
                    style = MaterialTheme.typography.labelMedium,
                    color = if (todo.triage == TodoTriage.REVIEW) MaterialTheme.colorScheme.secondary else MaterialTheme.colorScheme.primary,
                )
            }
            if (todo.notes.isNotBlank()) {
                Text(todo.notes, style = MaterialTheme.typography.bodyMedium, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when (todo.source) {
                    TodoSource.EMAIL -> BadgeChip("이메일")
                    TodoSource.CALENDAR -> BadgeChip(if (todo.isFixedSchedule) "반복 일정" else "캘린더")
                    TodoSource.MEETING -> BadgeChip("회의")
                    TodoSource.MANUAL -> Unit
                }
                if (todo.aiPersonaFit) BadgeChip("페르소나 적합")
                if (todo.aiRecommendedTime != null) BadgeChip("추천 ${formatHour(todo.aiRecommendedTime)}")
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                if (todo.triage == TodoTriage.REVIEW && !todo.isCompleted) {
                    Button(onClick = onPromote, modifier = Modifier.weight(1f)) {
                        Text("진행 중으로 추가")
                    }
                } else {
                    Button(onClick = onToggleComplete, modifier = Modifier.weight(1f)) {
                        Text(if (todo.isCompleted) "완료 취소" else "완료")
                    }
                }
                OutlinedButton(onClick = onDelete, modifier = Modifier.weight(1f)) {
                    Text("삭제")
                }
            }
        }
    }
}

@Composable
private fun PriorityDot(todo: TodoItem) {
    val color = when {
        todo.triage == TodoTriage.REVIEW && todo.dueAt != null && todo.dueAt < System.currentTimeMillis() -> Color(0xFFD32F2F)
        todo.effectivePriority >= 0.8 -> Color(0xFFD32F2F)
        todo.effectivePriority >= 0.6 -> Color(0xFFF57C00)
        todo.effectivePriority >= 0.4 -> Color(0xFF1976D2)
        else -> Color(0xFF9E9E9E)
    }
    Box(
        modifier = Modifier
            .size(14.dp)
            .background(color, CircleShape)
    )
}

@Composable
private fun BadgeChip(label: String) {
    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        shape = CircleShape,
    ) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
        )
    }
}

@Composable
private fun CalendarScreen(
    modifier: Modifier = Modifier,
    calendarPermissionGranted: Boolean,
    events: List<DeviceCalendarEvent>,
    dueTodos: List<TodoItem>,
    onRequestPermission: () -> Unit,
    onRefresh: () -> Unit,
    onImport: () -> Unit,
    onOpenTodo: (TodoItem) -> Unit,
) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            if (!calendarPermissionGranted) {
                EmptyStateCard(
                    title = "캘린더 권한이 필요합니다",
                    body = "기기 캘린더를 읽고 TODO 마감을 일정으로 등록하려면 캘린더 권한을 허용해야 합니다.",
                    actionLabel = "권한 허용",
                    onAction = onRequestPermission,
                )
            } else {
                Card(
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
                ) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("기기 캘린더", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text("안드로이드에서는 EventKit 대신 CalendarContract를 사용해 일정 읽기/쓰기 권한을 다룹니다.")
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = onRefresh) { Text("새로고침") }
                            OutlinedButton(onClick = onImport) { Text("등록 대기열로 가져오기") }
                        }
                    }
                }
            }
        }
        if (calendarPermissionGranted) {
            item {
                SectionTitle("다가오는 기기 일정")
            }
            if (events.isEmpty()) {
                item {
                    EmptyStateCard(
                        title = "가져온 일정이 없습니다",
                        body = "캘린더가 비어 있거나 아직 권한이 반영되지 않았습니다. 새로고침하거나 실제 기기 계정을 확인하세요.",
                    )
                }
            } else {
                items(events, key = { "event-${it.id}-${it.startMillis}" }) { event ->
                    CalendarEventCard(event)
                }
            }
        }
        item {
            SectionTitle("SIFT 일정")
        }
        if (dueTodos.isEmpty()) {
            item {
                EmptyStateCard(
                    title = "예정된 할 일이 없습니다",
                    body = "마감일이 있는 할 일을 추가하면 여기와 기기 캘린더 양쪽에서 관리할 수 있습니다.",
                )
            }
        } else {
            items(dueTodos, key = { it.id }) { todo ->
                OutlinedCard(
                    modifier = Modifier
                        .padding(horizontal = 16.dp)
                        .fillMaxWidth()
                        .clickable { onOpenTodo(todo) },
                ) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(todo.title.ifBlank { "제목 없는 할 일" }, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        todo.dueAt?.let { Text(formatDateTime(it), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                        if (todo.priorityReason.isNotBlank()) {
                            Text(todo.priorityReason, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
        item { Spacer(modifier = Modifier.height(96.dp)) }
    }
}

@Composable
private fun CalendarEventCard(event: DeviceCalendarEvent) {
    OutlinedCard(modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(event.title.ifBlank { "(제목 없음)" }, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text("${formatDateTime(event.startMillis)} · ${event.calendarName}", color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (!event.description.isNullOrBlank()) {
                Text(event.description, style = MaterialTheme.typography.bodySmall, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (event.isAllDay) BadgeChip("하루 종일")
                if (event.isRecurring) BadgeChip("반복")
            }
        }
    }
}

@Composable
private fun MailScreen(
    modifier: Modifier = Modifier,
    snapshot: SiftSnapshot,
    onCheckOAuth: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var gmailEmail by remember { mutableStateOf(AndroidGmailService.signedInEmail(context)) }
    var messages by remember { mutableStateOf(emptyList<AndroidMailPreview>()) }
    var isLoading by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    lateinit var refreshMessages: () -> Unit

    val gmailLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        AndroidGmailService.handleSignInIntent(result.data)
            .onSuccess {
                gmailEmail = it
                refreshMessages()
            }
            .onFailure {
                if (gmailEmail != null) {
                    refreshMessages()
                } else {
                    errorText = it.message ?: "Gmail 로그인에 실패했습니다."
                }
            }
    }

    refreshMessages = {
        scope.launch {
            isLoading = true
            runCatching { AndroidGmailService.fetchRecentMessages(context) }
                .onSuccess {
                    messages = it
                    errorText = null
                }
                .onFailure {
                    val recoverable = AndroidGmailService.recoverableIntent(it)
                    if (recoverable != null) {
                        gmailLauncher.launch(recoverable)
                    } else {
                        errorText = it.message ?: "Gmail 메시지를 가져오지 못했습니다."
                    }
                }
            isLoading = false
        }
    }

    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Gmail direct OAuth", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        if (AndroidGmailService.isConfigured(context)) {
                            "Android에서는 Gmail API 읽기 권한을 직접 OAuth로 요청합니다. 클라우드 동기화 로그인과는 별도로 Gmail scope를 승인해야 합니다."
                        } else {
                            "google-services.json 에 Android OAuth client 와 SHA-1 등록이 없어 Gmail direct OAuth 를 시작할 수 없습니다."
                        },
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(gmailEmail?.let { "연결된 Gmail 계정: $it" } ?: "연결된 Gmail 계정 없음")
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        if (gmailEmail == null) {
                            Button(
                                onClick = {
                                    if (AndroidGmailService.isConfigured(context)) {
                                        gmailLauncher.launch(AndroidGmailService.signInIntent(context))
                                    } else {
                                        onCheckOAuth()
                                    }
                                },
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Gmail 연결")
                            }
                        } else {
                            Button(onClick = { refreshMessages() }, modifier = Modifier.weight(1f), enabled = !isLoading) {
                                Text(if (isLoading) "불러오는 중…" else "최근 메일 확인")
                            }
                            OutlinedButton(
                                onClick = {
                                    AndroidGmailService.signOut(context)
                                    gmailEmail = null
                                    messages = emptyList()
                                },
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("연결 해제")
                            }
                        }
                    }
                    errorText?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                    Text(snapshot.mail.lastSyncMessage, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
        if (gmailEmail != null) {
            if (messages.isEmpty() && !isLoading) {
                item {
                    EmptyStateCard(
                        title = "가져온 메일이 없습니다",
                        body = "최근 14일의 Gmail 받은편지함을 조회합니다. 권한 승인 후 다시 새로고침해 보세요.",
                    )
                }
            } else {
                items(messages, key = { it.id }) { message ->
                    OutlinedCard(modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
                        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(message.subject, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                            Text(message.from, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                            if (message.snippet.isNotBlank()) {
                                Text(message.snippet, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsSurface(
    destination: SettingsDestination,
    snapshot: SiftSnapshot,
    calendarEvents: List<DeviceCalendarEvent>,
    driveSyncState: DriveSyncUiState,
    calendarPermissionGranted: Boolean,
    notificationPermissionGranted: Boolean,
    onBack: () -> Unit,
    onClose: () -> Unit,
    onNavigate: (SettingsDestination) -> Unit,
    onPersonaSave: (Set<PersonaType>, String) -> Unit,
    onGeneratePersona: () -> Unit,
    onAnalyzeMemory: () -> Unit,
    pendingMemoryAnalysis: MemoryInsight?,
    onApplyMemoryAnalysis: (MemoryInsight) -> Unit,
    onCancelMemoryAnalysis: () -> Unit,
    onDeleteMemoryAnalysis: (Int) -> Unit,
    onRunPrioritize: () -> Unit,
    onSetAiAutomation: (Boolean) -> Unit,
    onSetCalendarAutoRegister: (Boolean) -> Unit,
    onSetCalendarCompletionAction: (CalendarCompletionAction) -> Unit,
    onSetEmailAutoAnalysis: (Boolean) -> Unit,
    onSetProviderEmailAnalysis: (Boolean) -> Unit,
    onSetEmailRefreshHour: (Int) -> Unit,
    onSetEmailLookbackDays: (Int) -> Unit,
    onSetCloudSyncMode: (CloudSyncMode) -> Unit,
    syncPassphrase: String,
    onSyncPassphraseChange: (String) -> Unit,
    onDriveSignIn: () -> Unit,
    onDriveSignOut: () -> Unit,
    onDriveSyncNow: (String) -> Unit,
    onDriveRestore: (String) -> Unit,
    onSetLaunchBehavior: (LaunchBehavior) -> Unit,
    onSetLaunchTab: (AppTab) -> Unit,
    onRequestCalendarPermission: () -> Unit,
    onRequestNotificationPermission: () -> Unit,
    onReplayOnboarding: () -> Unit,
    onMarkMailBlocked: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        when (destination) {
                            SettingsDestination.ROOT -> "설정"
                            SettingsDestination.PERSONA -> "나의 페르소나"
                            SettingsDestination.MEMORY -> "행동 패턴 분석"
                            SettingsDestination.INTELLIGENCE -> "TODO 자동 정렬 및 AI"
                            SettingsDestination.EMAIL -> "이메일 연동"
                            SettingsDestination.CALENDAR -> "캘린더 설정"
                            SettingsDestination.CLOUD_SYNC -> "클라우드 동기화"
                            SettingsDestination.SYSTEM -> "시스템 권한 및 상태"
                            SettingsDestination.APP_INFO -> "앱 정보"
                        }
                    )
                },
                navigationIcon = {
                    IconButton(onClick = { if (destination == SettingsDestination.ROOT) onClose() else onBack() }) {
                        Text("←")
                    }
                },
            )
        }
    ) { innerPadding ->
        when (destination) {
            SettingsDestination.ROOT -> SettingsRoot(
                modifier = Modifier.padding(innerPadding),
                onNavigate = onNavigate,
            )
            SettingsDestination.PERSONA -> PersonaSettingsScreen(
                modifier = Modifier.padding(innerPadding),
                persona = snapshot.persona,
                onSave = onPersonaSave,
                onGenerate = onGeneratePersona,
            )
            SettingsDestination.MEMORY -> MemorySettingsScreen(
                modifier = Modifier.padding(innerPadding),
                memoryHistory = normalizedMemoryHistory(snapshot.memory, snapshot.memoryHistory),
                pendingMemory = pendingMemoryAnalysis,
                completedRecordCount = snapshot.todos.count { it.isCompleted && it.completedAt != null },
                onAnalyze = onAnalyzeMemory,
                onApply = onApplyMemoryAnalysis,
                onCancel = onCancelMemoryAnalysis,
                onDeleteAt = onDeleteMemoryAnalysis,
            )
            SettingsDestination.INTELLIGENCE -> IntelligenceSettingsScreen(
                modifier = Modifier.padding(innerPadding),
                snapshot = snapshot,
                calendarEvents = calendarEvents,
                onSetAiAutomation = onSetAiAutomation,
                onRunPrioritize = onRunPrioritize,
            )
            SettingsDestination.EMAIL -> EmailSettingsScreen(
                modifier = Modifier.padding(innerPadding),
                snapshot = snapshot,
                onSetEmailAutoAnalysis = onSetEmailAutoAnalysis,
                onSetProviderEmailAnalysis = onSetProviderEmailAnalysis,
                onSetEmailRefreshHour = onSetEmailRefreshHour,
                onSetEmailLookbackDays = onSetEmailLookbackDays,
                onMarkMailBlocked = onMarkMailBlocked,
            )
            SettingsDestination.CALENDAR -> CalendarSettingsScreen(
                modifier = Modifier.padding(innerPadding),
                snapshot = snapshot,
                permissionGranted = calendarPermissionGranted,
                onSetCalendarAutoRegister = onSetCalendarAutoRegister,
                onSetCalendarCompletionAction = onSetCalendarCompletionAction,
                onRequestPermission = onRequestCalendarPermission,
            )
            SettingsDestination.CLOUD_SYNC -> CloudSyncSettingsScreen(
                modifier = Modifier.padding(innerPadding),
                settings = snapshot.settings,
                driveSyncState = driveSyncState,
                syncPassphrase = syncPassphrase,
                onSyncPassphraseChange = onSyncPassphraseChange,
                onSetCloudSyncMode = onSetCloudSyncMode,
                onDriveSignIn = onDriveSignIn,
                onDriveSignOut = onDriveSignOut,
                onDriveSyncNow = onDriveSyncNow,
                onDriveRestore = onDriveRestore,
            )
            SettingsDestination.SYSTEM -> SystemStatusScreen(
                modifier = Modifier.padding(innerPadding),
                calendarGranted = calendarPermissionGranted,
                notificationsGranted = notificationPermissionGranted,
                onRequestCalendarPermission = onRequestCalendarPermission,
                onRequestNotificationPermission = onRequestNotificationPermission,
            )
            SettingsDestination.APP_INFO -> AppInfoScreen(
                modifier = Modifier.padding(innerPadding),
                settings = snapshot.settings,
                onSetLaunchBehavior = onSetLaunchBehavior,
                onSetLaunchTab = onSetLaunchTab,
                onReplayOnboarding = onReplayOnboarding,
            )
        }
    }
}

@Composable
private fun SettingsRoot(modifier: Modifier = Modifier, onNavigate: (SettingsDestination) -> Unit) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Spacer(modifier = Modifier.height(4.dp)) }
        item { SettingsNavCard("나의 페르소나", "온보딩·AI 페르소나 문장 관리", onClick = { onNavigate(SettingsDestination.PERSONA) }) }
        item { SettingsNavCard("행동 패턴 분석", "완료 이력 기반 인사이트", onClick = { onNavigate(SettingsDestination.MEMORY) }) }
        item { SettingsNavCard("TODO 자동 정렬 및 AI", "휴리스틱 우선순위와 자동화 설정", onClick = { onNavigate(SettingsDestination.INTELLIGENCE) }) }
        item { SettingsNavCard("이메일 연동", "Gmail/Outlook Android 준비 상태", onClick = { onNavigate(SettingsDestination.EMAIL) }) }
        item { SettingsNavCard("캘린더 설정", "기기 캘린더 권한과 자동 등록", onClick = { onNavigate(SettingsDestination.CALENDAR) }) }
        item { SettingsNavCard("클라우드 동기화", "Android 클라우드 동기화 설정과 수동 복원", onClick = { onNavigate(SettingsDestination.CLOUD_SYNC) }) }
        item { SettingsNavCard("시스템 권한 및 상태", "알림·캘린더 권한 확인", onClick = { onNavigate(SettingsDestination.SYSTEM) }) }
        item { SettingsNavCard("앱 정보", "시작 탭 동작과 안드로이드 포트 정보", onClick = { onNavigate(SettingsDestination.APP_INFO) }) }
        item { Spacer(modifier = Modifier.height(24.dp)) }
    }
}

@Composable
private fun SettingsNavCard(title: String, subtitle: String, onClick: () -> Unit) {
    OutlinedCard(modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth().clickable(onClick = onClick)) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun PersonaSettingsScreen(
    modifier: Modifier = Modifier,
    persona: PersonaProfile,
    onSave: (Set<PersonaType>, String) -> Unit,
    onGenerate: () -> Unit,
) {
    var selectedTypes by rememberSaveable(persona.personaTypes) { mutableStateOf(persona.personaTypes.toSet()) }
    var description by rememberSaveable(persona.descriptionText) { mutableStateOf(persona.descriptionText) }
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(16.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("생활 유형", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        PersonaType.entries.forEach { type ->
                            FilterChip(
                                selected = selectedTypes.contains(type),
                                onClick = {
                                    selectedTypes = selectedTypes.toMutableSet().apply {
                                        if (!add(type)) remove(type)
                                    }
                                },
                                label = { Text(type.displayName) },
                            )
                        }
                    }
                    OutlinedTextField(
                        value = description,
                        onValueChange = { description = it },
                        label = { Text("설명") },
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 5,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { onSave(selectedTypes, description) }, enabled = description.isNotBlank() || selectedTypes.isNotEmpty()) {
                            Text("저장")
                        }
                        OutlinedButton(onClick = onGenerate) {
                            Text("AI 페르소나 생성")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MemorySettingsScreen(
    modifier: Modifier = Modifier,
    memoryHistory: List<MemoryInsight>,
    pendingMemory: MemoryInsight?,
    completedRecordCount: Int,
    onAnalyze: () -> Unit,
    onApply: (MemoryInsight) -> Unit,
    onCancel: () -> Unit,
    onDeleteAt: (Int) -> Unit,
) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("행동 패턴 분석", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        "완료한 할 일 메타데이터로 시간대, 태그, 기한 준수 패턴을 분석합니다. 결과는 적용을 눌러야 저장됩니다.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "분석 가능한 완료 기록: ${completedRecordCount}개",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(onClick = onAnalyze, enabled = completedRecordCount > 0) {
                        Text(if (pendingMemory == null) "지금 패턴 분석" else "다시 분석")
                    }
                }
            }
        }

        if (pendingMemory != null) {
            item {
                Card(modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("새 분석 결과", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(pendingMemory.summary, style = MaterialTheme.typography.bodyMedium)
                        pendingMemory.insights.forEach { insight ->
                            Text("• $insight", style = MaterialTheme.typography.bodyMedium)
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                            Button(onClick = { onApply(pendingMemory) }) { Text("적용") }
                            OutlinedButton(onClick = onAnalyze) { Text("다시 분석") }
                            OutlinedButton(onClick = onCancel) { Text("취소") }
                        }
                    }
                }
            }
        }

        item {
            Text(
                "저장된 분석",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }

        if (memoryHistory.isEmpty()) {
            item {
                Text(
                    "아직 저장된 분석이 없습니다.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        } else {
            items(memoryHistory.indices.toList()) { index ->
                val memory = memoryHistory[index]
                OutlinedCard(modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
                    Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(formatDateTime(memory.createdAt), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Text(memory.summary, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                            }
                            OutlinedButton(onClick = { onDeleteAt(index) }) {
                                Text("삭제", color = MaterialTheme.colorScheme.error)
                            }
                        }
                        memory.insights.forEach { insight ->
                            Text("• $insight", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
        }
        item { Spacer(modifier = Modifier.height(96.dp)) }
    }
}

@Composable
private fun IntelligenceSettingsScreen(
    modifier: Modifier = Modifier,
    snapshot: SiftSnapshot,
    calendarEvents: List<DeviceCalendarEvent>,
    onSetAiAutomation: (Boolean) -> Unit,
    onRunPrioritize: () -> Unit,
) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(16.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SettingToggleRow(
                        title = "AI 자동화",
                        checked = snapshot.settings.aiAutomationEnabled,
                        onCheckedChange = onSetAiAutomation,
                    )
                    Text("현재 안드로이드 포트는 iOS의 Foundation Models 대신 휴리스틱 엔진으로 TODO 우선순위를 다시 계산합니다.")
                    Text("캘린더 일정 ${calendarEvents.size}건과 페르소나 키워드를 함께 반영합니다.", style = MaterialTheme.typography.bodySmall)
                    Button(onClick = onRunPrioritize) { Text("지금 TODO 정렬") }
                }
            }
        }
    }
}

@Composable
private fun EmailSettingsScreen(
    modifier: Modifier = Modifier,
    snapshot: SiftSnapshot,
    onSetEmailAutoAnalysis: (Boolean) -> Unit,
    onSetProviderEmailAnalysis: (Boolean) -> Unit,
    onSetEmailRefreshHour: (Int) -> Unit,
    onSetEmailLookbackDays: (Int) -> Unit,
    onMarkMailBlocked: () -> Unit,
) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(16.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SettingToggleRow(
                        title = "메일 자동 분석",
                        checked = snapshot.settings.emailAutoAnalysisEnabled,
                        onCheckedChange = onSetEmailAutoAnalysis,
                    )
                    SettingToggleRow(
                        title = "메일 본문 분석 허용",
                        checked = snapshot.settings.providerEmailAnalysisEnabled,
                        onCheckedChange = onSetProviderEmailAnalysis,
                    )
                    NumberSettingRow(
                        title = "자동 동기화 시각",
                        value = "${snapshot.settings.emailRefreshHour}:00",
                        onDecrease = { onSetEmailRefreshHour(snapshot.settings.emailRefreshHour - 1) },
                        onIncrease = { onSetEmailRefreshHour(snapshot.settings.emailRefreshHour + 1) },
                    )
                    NumberSettingRow(
                        title = "동기화 조회 기간",
                        value = "${snapshot.settings.emailLookbackDays}일",
                        onDecrease = { onSetEmailLookbackDays(snapshot.settings.emailLookbackDays - 1) },
                        onIncrease = { onSetEmailLookbackDays(snapshot.settings.emailLookbackDays + 1) },
                    )
                    Text(snapshot.mail.lastSyncMessage, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    OutlinedButton(onClick = onMarkMailBlocked) { Text("연동 준비 상태 다시 확인") }
                }
            }
        }
    }
}

@Composable
private fun CalendarSettingsScreen(
    modifier: Modifier = Modifier,
    snapshot: SiftSnapshot,
    permissionGranted: Boolean,
    onSetCalendarAutoRegister: (Boolean) -> Unit,
    onSetCalendarCompletionAction: (CalendarCompletionAction) -> Unit,
    onRequestPermission: () -> Unit,
) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(16.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SettingToggleRow(
                        title = "마감 자동 캘린더 등록",
                        checked = snapshot.settings.calendarAutoRegister,
                        onCheckedChange = onSetCalendarAutoRegister,
                    )
                    Text(if (permissionGranted) "캘린더 권한이 허용되어 있습니다." else "캘린더 권한이 아직 없습니다.")
                    if (!permissionGranted) {
                        Button(onClick = onRequestPermission) { Text("권한 허용") }
                    }
                    Text("완료 시 처리", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                    RadioSettingRow(
                        title = "이벤트 삭제",
                        selected = snapshot.settings.calendarCompletionAction == CalendarCompletionAction.REMOVE,
                        onClick = { onSetCalendarCompletionAction(CalendarCompletionAction.REMOVE) },
                    )
                    RadioSettingRow(
                        title = "알람만 끄기",
                        selected = snapshot.settings.calendarCompletionAction == CalendarCompletionAction.SILENCE,
                        onClick = { onSetCalendarCompletionAction(CalendarCompletionAction.SILENCE) },
                    )
                }
            }
        }
    }
}

@Composable
private fun CloudSyncSettingsScreen(
    modifier: Modifier = Modifier,
    settings: AppSettings,
    driveSyncState: DriveSyncUiState,
    syncPassphrase: String,
    onSyncPassphraseChange: (String) -> Unit,
    onSetCloudSyncMode: (CloudSyncMode) -> Unit,
    onDriveSignIn: () -> Unit,
    onDriveSignOut: () -> Unit,
    onDriveSyncNow: (String) -> Unit,
    onDriveRestore: (String) -> Unit,
) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(16.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Android 클라우드 동기화는 Firebase + Firestore + Google 로그인을 사용합니다.", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        if (driveSyncState.configured) {
                            "사용자 데이터는 Firebase Auth uid 기준으로 users/{uid}/... 아래에 격리되며, 스냅샷은 암호화 비밀번호로 AES-GCM 암호화 후 Firestore에 저장됩니다."
                        } else {
                            "현재 google-services.json 에 Android OAuth 클라이언트가 없어 Firebase Google 로그인을 시작할 수 없습니다."
                        },
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    RadioSettingRow(
                        title = "이 기기에만 저장",
                        selected = settings.cloudSyncMode == CloudSyncMode.LOCAL,
                        onClick = { onSetCloudSyncMode(CloudSyncMode.LOCAL) },
                    )
                    RadioSettingRow(
                        title = "클라우드 동기화",
                        selected = settings.cloudSyncMode == CloudSyncMode.FIREBASE,
                        onClick = { onSetCloudSyncMode(CloudSyncMode.FIREBASE) },
                    )
                    OutlinedTextField(
                        value = syncPassphrase,
                        onValueChange = onSyncPassphraseChange,
                        label = { Text("암호화 비밀번호") },
                        placeholder = { Text("다른 기기에서도 같은 비밀번호로 복호화합니다") },
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        driveSyncState.signedInEmail?.let { "연결된 계정: $it" } ?: "연결된 Google 계정 없음",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                    driveSyncState.lastSyncedAt?.let {
                        Text("마지막 동기화: ${formatDateTime(it)}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    driveSyncState.lastError?.let {
                        Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                    }
                    if (driveSyncState.configured) {
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                            if (driveSyncState.signedInEmail == null) {
                                Button(onClick = onDriveSignIn, modifier = Modifier.weight(1f)) {
                                    Text("Firebase 로그인")
                                }
                            } else {
                                Button(
                                    onClick = { onDriveSyncNow(syncPassphrase.trim()) },
                                    modifier = Modifier.weight(1f),
                                    enabled = !driveSyncState.isSyncing && syncPassphrase.trim().length >= 8,
                                ) {
                                    Text(if (driveSyncState.isSyncing) "동기화 중…" else "지금 동기화")
                                }
                                OutlinedButton(
                                    onClick = { onDriveRestore(syncPassphrase.trim()) },
                                    modifier = Modifier.weight(1f),
                                    enabled = !driveSyncState.isSyncing && syncPassphrase.trim().length >= 8,
                                ) {
                                    Text("복원")
                                }
                            }
                        }
                        if (driveSyncState.signedInEmail != null) {
                            OutlinedButton(onClick = onDriveSignOut) { Text("Firebase 연결 해제") }
                        }
                    } else {
                        OutlinedButton(onClick = onDriveSignIn) { Text("OAuth 설정 필요") }
                    }
                }
            }
        }
    }
}

@Composable
private fun SystemStatusScreen(
    modifier: Modifier = Modifier,
    calendarGranted: Boolean,
    notificationsGranted: Boolean,
    onRequestCalendarPermission: () -> Unit,
    onRequestNotificationPermission: () -> Unit,
) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(16.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    StatusRow(
                        title = "알림",
                        granted = notificationsGranted,
                        onRequest = onRequestNotificationPermission,
                    )
                    HorizontalDivider()
                    StatusRow(
                        title = "캘린더",
                        granted = calendarGranted,
                        onRequest = onRequestCalendarPermission,
                    )
                }
            }
        }
    }
}

@Composable
private fun AppInfoScreen(
    modifier: Modifier = Modifier,
    settings: AppSettings,
    onSetLaunchBehavior: (LaunchBehavior) -> Unit,
    onSetLaunchTab: (AppTab) -> Unit,
    onReplayOnboarding: () -> Unit,
) {
    LazyColumn(modifier = modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Card(modifier = Modifier.padding(16.dp).fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("시작 화면", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    RadioSettingRow(
                        title = "마지막 사용 탭",
                        selected = settings.launchBehavior == LaunchBehavior.LAST_USED,
                        onClick = { onSetLaunchBehavior(LaunchBehavior.LAST_USED) },
                    )
                    RadioSettingRow(
                        title = "고정 탭",
                        selected = settings.launchBehavior == LaunchBehavior.FIXED,
                        onClick = { onSetLaunchBehavior(LaunchBehavior.FIXED) },
                    )
                    if (settings.launchBehavior == LaunchBehavior.FIXED) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            AppTab.entries.forEach { tab ->
                                FilterChip(
                                    selected = settings.launchTab == tab,
                                    onClick = { onSetLaunchTab(tab) },
                                    label = {
                                        Text(
                                            when (tab) {
                                                AppTab.TODO -> "할 일"
                                                AppTab.CALENDAR -> "캘린더"
                                                AppTab.MAIL -> "메일"
                                                AppTab.MEETING -> "회의"
                                            }
                                        )
                                    },
                                )
                            }
                        }
                    }
                    HorizontalDivider()
                    Text("안드로이드 포트 정보", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text("이 포트는 iOS SIFT의 핵심 탭 구조(할 일/캘린더/메일), 페르소나 설정, 패턴 분석, 휴리스틱 기반 AI 정렬을 안드로이드 스튜디오에서 바로 열 수 있는 Compose 앱으로 옮겼습니다.")
                    OutlinedButton(onClick = onReplayOnboarding) { Text("온보딩 다시 보기") }
                }
            }
        }
    }
}

@Composable
private fun SettingToggleRow(title: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, enabled: Boolean = true) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(title, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
    }
}

@Composable
private fun NumberSettingRow(title: String, value: String, onDecrease: () -> Unit, onIncrease: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(title, modifier = Modifier.weight(1f))
        OutlinedButton(onClick = onDecrease) { Text("-") }
        Text(value, modifier = Modifier.padding(horizontal = 8.dp))
        OutlinedButton(onClick = onIncrease) { Text("+") }
    }
}

@Composable
private fun RadioSettingRow(title: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onClick)
        Text(title)
    }
}

@Composable
private fun StatusRow(title: String, granted: Boolean, onRequest: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Text(title, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Text(if (granted) "허용됨" else "미허용", color = if (granted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.error)
        Spacer(modifier = Modifier.width(12.dp))
        if (!granted) {
            OutlinedButton(onClick = onRequest) { Text("허용") }
        }
    }
}

@Composable
private fun SectionTitle(title: String) {
    Text(
        title,
        modifier = Modifier.padding(horizontal = 16.dp),
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.SemiBold,
    )
}

@Composable
private fun EmptyStateCard(title: String, body: String, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
    Card(modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(body, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (actionLabel != null && onAction != null) {
                Button(onClick = onAction) { Text(actionLabel) }
            }
        }
    }
}

@Composable
private fun TodoEditorDialog(
    initialTodo: TodoItem?,
    onDismiss: () -> Unit,
    onSave: (TodoDraft) -> Unit,
) {
    val context = LocalContext.current
    var title by rememberSaveable(initialTodo?.id) { mutableStateOf(initialTodo?.title.orEmpty()) }
    var notes by rememberSaveable(initialTodo?.id) { mutableStateOf(initialTodo?.notes.orEmpty()) }
    var dueAt by rememberSaveable(initialTodo?.id) { mutableStateOf(initialTodo?.dueAt) }
    var manualPriority by rememberSaveable(initialTodo?.id) { mutableStateOf(initialTodo?.manualPriority) }
    var tagsText by rememberSaveable(initialTodo?.id) { mutableStateOf(initialTodo?.tags?.joinToString(", ").orEmpty()) }
    var durationText by rememberSaveable(initialTodo?.id) { mutableStateOf((initialTodo?.estimatedDurationMinutes ?: 30).toString()) }
    var triage by rememberSaveable(initialTodo?.id) { mutableStateOf(initialTodo?.triage ?: TodoTriage.TODO) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (initialTodo == null) "할 일 추가" else "할 일 수정") },
        text = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                item {
                    OutlinedTextField(value = title, onValueChange = { title = it }, label = { Text("제목") }, modifier = Modifier.fillMaxWidth())
                }
                item {
                    OutlinedTextField(value = notes, onValueChange = { notes = it }, label = { Text("메모") }, modifier = Modifier.fillMaxWidth(), minLines = 4)
                }
                item {
                    OutlinedTextField(value = tagsText, onValueChange = { tagsText = it }, label = { Text("태그 (쉼표 구분)") }, modifier = Modifier.fillMaxWidth())
                }
                item {
                    OutlinedTextField(value = durationText, onValueChange = { durationText = it.filter(Char::isDigit) }, label = { Text("예상 소요 시간(분)") }, modifier = Modifier.fillMaxWidth())
                }
                item {
                    Text("수동 우선순위", style = MaterialTheme.typography.labelLarge)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(selected = manualPriority == null, onClick = { manualPriority = null }, label = { Text("자동") })
                        (1..5).forEach { level ->
                            FilterChip(selected = manualPriority == level, onClick = { manualPriority = level }, label = { Text(level.toString()) })
                        }
                    }
                }
                item {
                    Text("목록 분류", style = MaterialTheme.typography.labelLarge)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(selected = triage == TodoTriage.TODO, onClick = { triage = TodoTriage.TODO }, label = { Text("진행 중") })
                        FilterChip(selected = triage == TodoTriage.REVIEW, onClick = { triage = TodoTriage.REVIEW }, label = { Text("등록 대기열") })
                    }
                }
                item {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                        OutlinedButton(onClick = {
                            openDatePicker(context, dueAt) { picked ->
                                val base = dueAt ?: picked
                                dueAt = mergeDate(base, picked)
                            }
                        }) {
                            Text(if (dueAt == null) "날짜 선택" else formatDate(dueAt!!))
                        }
                        OutlinedButton(onClick = {
                            val seed = dueAt ?: System.currentTimeMillis()
                            openTimePicker(context, seed) { picked ->
                                dueAt = mergeTime(dueAt ?: System.currentTimeMillis(), picked)
                            }
                        }) {
                            Text(if (dueAt == null) "시간 선택" else formatHour(dueAt!!))
                        }
                    }
                }
                if (dueAt != null) {
                    item {
                        TextButton(onClick = { dueAt = null }) { Text("마감 지우기") }
                    }
                }
            }
        },
        confirmButton = {
            Button(
                onClick = {
                    onSave(
                        TodoDraft(
                            id = initialTodo?.id,
                            title = title,
                            notes = notes,
                            dueAt = dueAt,
                            manualPriority = manualPriority,
                            tags = tagsText.split(',').map { it.trim() }.filter { it.isNotBlank() },
                            estimatedDurationMinutes = durationText.toIntOrNull() ?: 30,
                            triage = triage,
                        )
                    )
                },
                enabled = title.isNotBlank(),
            ) {
                Text("저장")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("취소") }
        },
    )
}

private fun openDatePicker(context: Context, seedMillis: Long?, onPicked: (Long) -> Unit) {
    val calendar = Calendar.getInstance().apply { timeInMillis = seedMillis ?: System.currentTimeMillis() }
    DatePickerDialog(
        context,
        { _, year, month, dayOfMonth ->
            val picked = Calendar.getInstance().apply {
                set(Calendar.YEAR, year)
                set(Calendar.MONTH, month)
                set(Calendar.DAY_OF_MONTH, dayOfMonth)
                set(Calendar.HOUR_OF_DAY, calendar.get(Calendar.HOUR_OF_DAY))
                set(Calendar.MINUTE, calendar.get(Calendar.MINUTE))
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            onPicked(picked.timeInMillis)
        },
        calendar.get(Calendar.YEAR),
        calendar.get(Calendar.MONTH),
        calendar.get(Calendar.DAY_OF_MONTH),
    ).show()
}

private fun openTimePicker(context: Context, seedMillis: Long, onPicked: (Long) -> Unit) {
    val calendar = Calendar.getInstance().apply { timeInMillis = seedMillis }
    TimePickerDialog(
        context,
        { _, hourOfDay, minute ->
            val picked = Calendar.getInstance().apply {
                timeInMillis = seedMillis
                set(Calendar.HOUR_OF_DAY, hourOfDay)
                set(Calendar.MINUTE, minute)
                set(Calendar.SECOND, 0)
                set(Calendar.MILLISECOND, 0)
            }
            onPicked(picked.timeInMillis)
        },
        calendar.get(Calendar.HOUR_OF_DAY),
        calendar.get(Calendar.MINUTE),
        true,
    ).show()
}

private fun mergeDate(baseMillis: Long, dateMillis: Long): Long {
    val base = Calendar.getInstance().apply { timeInMillis = baseMillis }
    val date = Calendar.getInstance().apply { timeInMillis = dateMillis }
    return Calendar.getInstance().apply {
        set(Calendar.YEAR, date.get(Calendar.YEAR))
        set(Calendar.MONTH, date.get(Calendar.MONTH))
        set(Calendar.DAY_OF_MONTH, date.get(Calendar.DAY_OF_MONTH))
        set(Calendar.HOUR_OF_DAY, base.get(Calendar.HOUR_OF_DAY))
        set(Calendar.MINUTE, base.get(Calendar.MINUTE))
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
}

private fun mergeTime(baseMillis: Long, timeMillis: Long): Long {
    val base = Calendar.getInstance().apply { timeInMillis = baseMillis }
    val time = Calendar.getInstance().apply { timeInMillis = timeMillis }
    return Calendar.getInstance().apply {
        set(Calendar.YEAR, base.get(Calendar.YEAR))
        set(Calendar.MONTH, base.get(Calendar.MONTH))
        set(Calendar.DAY_OF_MONTH, base.get(Calendar.DAY_OF_MONTH))
        set(Calendar.HOUR_OF_DAY, time.get(Calendar.HOUR_OF_DAY))
        set(Calendar.MINUTE, time.get(Calendar.MINUTE))
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis
}

private fun formatDateTime(millis: Long): String = SimpleDateFormat("M월 d일 HH:mm", Locale.KOREA).format(Date(millis))
private fun formatDate(millis: Long): String = SimpleDateFormat("yyyy-MM-dd", Locale.KOREA).format(Date(millis))
private fun formatHour(millis: Long): String = SimpleDateFormat("HH:mm", Locale.KOREA).format(Date(millis))

private fun notificationPermissionGranted(context: Context): Boolean {
    return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
}

@Preview(showSystemUi = true)
@Composable
private fun SiftAppPreview() {
    SIFTTheme {
        SiftApp()
    }
}
