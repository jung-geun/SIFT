package xyz.pieroot.sift

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != REMINDER_ACTION) return

        val todoId = intent.getStringExtra(EXTRA_TODO_ID).orEmpty()
        if (todoId.isBlank()) return

        val dueAt = intent.getLongExtra(EXTRA_DUE_AT, -1L)
        val pending = goAsync()
        Thread {
            try {
                ReminderNotificationService(context.applicationContext).showReminderNotification(todoId, dueAt)
            } finally {
                pending.finish()
            }
        }.start()
    }
}
