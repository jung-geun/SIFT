package xyz.pieroot.sift

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class ReminderBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED -> {
                val pending = goAsync()
                Thread {
                    try {
                        ReminderNotificationService(context.applicationContext).rescheduleFromStoredState()
                    } finally {
                        pending.finish()
                    }
                }.start()
            }
        }
    }
}
