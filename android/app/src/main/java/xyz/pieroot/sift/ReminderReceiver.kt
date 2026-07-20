package xyz.pieroot.sift

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != REMINDER_ACTION) return

        val todoId = intent.getStringExtra(EXTRA_TODO_ID).orEmpty()
        if (todoId.isBlank()) return

        val title = intent.getStringExtra(EXTRA_TODO_TITLE).orEmpty()
        val dueAt = intent.getLongExtra(EXTRA_DUE_AT, -1L)
        ReminderNotificationService(context).showReminderNotification(todoId, title, dueAt)
    }
}
