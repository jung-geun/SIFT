package xyz.pieroot.sift

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.serialization.json.Json
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.abs


internal const val REMINDER_PREFS_NAME = "todo.reminder.notifications"
internal const val REMINDER_PREFS_KEY_SCHEDULED = "scheduled_todo_ids"
private const val STATE_FILE_NAME = "sift_state.json"
internal const val REMINDER_ACTION = "xyz.pieroot.sift.ACTION_TODO_REMINDER"
internal const val REMINDER_CHANNEL_ID = "todo_reminders"
private const val NOTIFICATION_ID_SEED = 72_000

internal const val EXTRA_TODO_ID = "xyz.pieroot.sift.EXTRA_TODO_ID"
internal const val REMINDER_NOTIFICATION_ID = 1
internal const val EXTRA_DUE_AT = "xyz.pieroot.sift.EXTRA_DUE_AT"
internal const val EXTRA_OPEN_TODO_ID = "xyz.pieroot.sift.EXTRA_OPEN_TODO_ID"
internal const val REMINDER_MIN_LEAD_MILLIS = 60_000L
internal val AUTO_REMINDER_LEAD_MILLIS = listOf(
    72L * 60L * 60L * 1000L,
    24L * 60L * 60L * 1000L,
    6L * 60L * 60L * 1000L,
    2L * 60L * 60L * 1000L,
    60L * 60L * 1000L,
    15L * 60L * 1000L,
)

internal fun computeReminderTime(
    nowMillis: Long,
    dueAt: Long?,
    aiNeedsNotification: Boolean,
    aiRecommendedTime: Long?,
): Long? {
    if (!aiNeedsNotification) return null
    val due = dueAt ?: return null
    val earliestAllowed = nowMillis + REMINDER_MIN_LEAD_MILLIS

    return AUTO_REMINDER_LEAD_MILLIS
        .map { due - it }
        .firstOrNull { reminderAt -> reminderAt > earliestAllowed }
}

internal fun isReminderSchedulable(todo: TodoItem): Boolean =
    !todo.isCompleted && todo.triage == TodoTriage.TODO && todo.dueAt != null

internal fun reminderMatchesStoredTodo(todo: TodoItem?, expectedDueAt: Long): Boolean =
    todo != null && isReminderSchedulable(todo) && todo.aiNeedsNotification && todo.dueAt == expectedDueAt

class ReminderNotificationService(private val context: Context) {
    private val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
    private val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val preferences = context.getSharedPreferences(REMINDER_PREFS_NAME, Context.MODE_PRIVATE)
    private val json = Json {
        ignoreUnknownKeys = true
        prettyPrint = true
        encodeDefaults = true
    }

    fun rescheduleForTodos(todos: List<TodoItem>): Unit = synchronized(scheduleLock) {
        ensureChannel()

        val targetIds = linkedSetOf<String>()
        val now = System.currentTimeMillis()

        for (todo in todos) {
            if (!isReminderSchedulable(todo)) {
                cancel(todo.id)
                continue
            }

            val reminderAt = computeReminderTime(
                nowMillis = now,
                dueAt = todo.dueAt,
                aiNeedsNotification = todo.aiNeedsNotification,
                aiRecommendedTime = todo.aiRecommendedTime,
            ) ?: run {
                cancel(todo.id)
                continue
            }

            scheduleTodoReminder(todo, reminderAt)
            targetIds.add(todo.id)
        }

        val previouslyScheduled = scheduledTodoIds()
        for (id in previouslyScheduled - targetIds) {
            cancel(id)
        }
        persistScheduledIds(targetIds)
    }

    fun rescheduleFromStoredState(): Unit = synchronized(scheduleLock) {
        val snapshot = loadStoredSnapshot() ?: run {
            scheduledTodoIds().forEach(::cancel)
            persistScheduledIds(emptySet())
            return@synchronized
        }
        rescheduleForTodos(snapshot.todos)
    }

    fun cancel(todoId: String): Unit = synchronized(scheduleLock) {
        if (todoId.isBlank()) return@synchronized

        cancelLegacyAlarm(todoId)
        val alarmIntent = reminderAlarmIntent(todoId)
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            reminderRequestCode(todoId),
            alarmIntent,
            pendingIntentFlags(),
        )
        alarmManager.cancel(pendingIntent)
        pendingIntent.cancel()

        notificationManager.cancel(todoId, REMINDER_NOTIFICATION_ID)
        // Remove notifications created by the old hash-only identity after upgrade.
        notificationManager.cancel(NOTIFICATION_ID_SEED + reminderRequestCode(todoId))
        removeScheduledMarker(todoId)
    }

    fun showReminderNotification(todoId: String, expectedDueAt: Long): Unit = synchronized(scheduleLock) {
        val todo = loadStoredSnapshot()?.todos?.firstOrNull { it.id == todoId }
        if (!reminderMatchesStoredTodo(todo, expectedDueAt)) {
            // An older broadcast may already be queued when this todo is rescheduled.
            // Ignore it without touching the replacement alarm or its schedule marker.
            return@synchronized
        }
        // Keep delivered IDs tracked until cancel/reconciliation, so deleting a todo
        // also removes its already-visible notification and private title.
        if (!canPostReminderNotification()) return@synchronized
        val currentTodo = requireNotNull(todo)

        ensureChannel()

        val title = currentTodo.title.ifBlank { "할 일 알림" }
        val dueText = formatDueText(expectedDueAt)
        val body = if (dueText == null) {
            "등록된 마감 일정이 곧 예정되어 있습니다."
        } else {
            "마감 예정 시각 $dueText 입니다."
        }

        val openIntent = openTodoPendingIntent(todoId)

        val notification = NotificationCompat.Builder(context, REMINDER_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setContentIntent(openIntent)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        notificationManager.notify(todoId, REMINDER_NOTIFICATION_ID, notification)
    }

    private fun canPostReminderNotification(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true

        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun scheduleTodoReminder(todo: TodoItem, reminderAtMillis: Long) {
        if (reminderAtMillis <= System.currentTimeMillis()) {
            cancel(todo.id)
            return
        }

        cancelLegacyAlarm(todo.id)
        val intent = reminderAlarmIntent(todo.id).apply {
            putExtra(EXTRA_TODO_ID, todo.id)
            putExtra(EXTRA_DUE_AT, todo.dueAt ?: -1L)
        }

        val pendingIntent = PendingIntent.getBroadcast(
            context,
            reminderRequestCode(todo.id),
            intent,
            pendingIntentFlags(),
        )

        alarmManager.cancel(pendingIntent)
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarmManager.canScheduleExactAlarms()) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminderAtMillis, pendingIntent)
            } else {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminderAtMillis, pendingIntent)
            }
        } catch (_: SecurityException) {
            // Exact-alarm access can be revoked between the capability check and scheduling.
            alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, reminderAtMillis, pendingIntent)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            REMINDER_CHANNEL_ID,
            "할 일 알림",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "할 일 마감 알림 채널"
            lockscreenVisibility = NotificationCompat.VISIBILITY_PRIVATE
        }
        notificationManager.createNotificationChannel(channel)
    }

    private fun scheduledTodoIds(): Set<String> {
        return preferences.getStringSet(REMINDER_PREFS_KEY_SCHEDULED, emptySet()) ?: emptySet()
    }

    private fun persistScheduledIds(ids: Set<String>) {
        preferences.edit().putStringSet(REMINDER_PREFS_KEY_SCHEDULED, ids).apply()
    }

    private fun removeScheduledMarker(todoId: String) {
        val mutableIds = scheduledTodoIds().toMutableSet()
        if (mutableIds.remove(todoId)) {
            persistScheduledIds(mutableIds)
        }
    }

    private fun loadStoredSnapshot(): SiftSnapshot? {
        return try {
            val file = File(context.filesDir, STATE_FILE_NAME)
            if (!file.exists()) return null
            val raw = file.readText()
            json.decodeFromString(raw)
        } catch (_: Exception) {
            null
        }
    }

    private fun reminderRequestCode(todoId: String): Int {
        val raw = todoId.hashCode()
        return if (raw == Int.MIN_VALUE) 0 else abs(raw)
    }

    private fun cancelLegacyAlarm(todoId: String) {
        val legacy = Intent(context, ReminderReceiver::class.java).apply { action = REMINDER_ACTION }
        val pending = PendingIntent.getBroadcast(context, reminderRequestCode(todoId), legacy, PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE) ?: return
        alarmManager.cancel(pending)
        pending.cancel()
    }

    private fun reminderAlarmIntent(todoId: String): Intent {
        return Intent(context, ReminderReceiver::class.java).apply {
            action = REMINDER_ACTION
            setClass(context, ReminderReceiver::class.java)
            data = Uri.Builder().scheme("sift").authority("reminder").appendPath(todoId).build()
            putExtra(EXTRA_TODO_ID, todoId)
        }
    }

    private fun openTodoPendingIntent(todoId: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            data = Uri.Builder().scheme("sift").authority("todo").appendPath(todoId).build()
            putExtra(EXTRA_OPEN_TODO_ID, todoId)
        }

        return PendingIntent.getActivity(
            context,
            reminderRequestCode(todoId) + NOTIFICATION_ID_SEED,
            intent,
            pendingIntentFlags(),
        )
    }

    private fun formatDueText(dueAt: Long): String? {
        if (dueAt <= 0L) return null
        val formatter = SimpleDateFormat("M월 d일 HH:mm", Locale.getDefault())
        return formatter.format(Date(dueAt))
    }

    private fun pendingIntentFlags(): Int {
        return PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    }
    private companion object {
        // Broadcast work and Compose callers share the same alarms/preferences.
        val scheduleLock = Any()
    }
}
