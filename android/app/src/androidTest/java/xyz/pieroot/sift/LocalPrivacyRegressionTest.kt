package xyz.pieroot.sift

import android.app.PendingIntent
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.xmlpull.v1.XmlPullParser

@RunWith(AndroidJUnit4::class)
class LocalPrivacyRegressionTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test
    fun meetingStoreBindsDecodedIdentityAndCleansTemporaryWrites() {
        val store = MeetingStore(context)
        val first = UUID.randomUUID().toString()
        val second = UUID.randomUUID().toString()
        try {
            store.save(MeetingRecord(meetingId = first))
            assertEquals(first, store.load(first)?.meetingId)
            val copied = store.meetingFile(second)
            requireNotNull(copied.parentFile).mkdirs()
            copied.writeBytes(store.meetingFile(first).readBytes())
            assertNull(store.load(second))
            assertFalse(requireNotNull(store.meetingFile(first).parentFile).listFiles().orEmpty().any { it.name.endsWith(".tmp") })
            val root = requireNotNull(store.directory(first).parentFile)
            assertTrue(store.isBackupExcluded(root))
            assertTrue(store.isBackupExcluded(store.meetingFile(first)))
            assertFalse(store.isBackupExcluded(File(context.filesDir, "meetings-other/meeting.json")))
        } finally {
            store.delete(first)
            store.delete(second)
        }
    }

    @Test
    fun backupAndTransferRulesExcludeBothSnapshotVersionsAndMeetings() {
        for (resource in listOf(R.xml.backup_rules, R.xml.data_extraction_rules)) {
            val paths = mutableListOf<String>()
            context.resources.getXml(resource).use { parser ->
                while (parser.eventType != XmlPullParser.END_DOCUMENT) {
                    if (parser.eventType == XmlPullParser.START_TAG && parser.name == "exclude" && parser.getAttributeValue(null, "domain") == "file") {
                        paths += parser.getAttributeValue(null, "path")
                    }
                    parser.next()
                }
            }
            val copies = if (resource == R.xml.backup_rules) 1 else 2
            for (path in listOf("meetings", "sift_state.json", "sift_state.json.tmp")) {
                assertEquals(copies, paths.count { it == path })
            }
        }
        assertEquals(0, context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_ALLOW_BACKUP)
    }

    @Test
    fun hashCollidingTodoAlarmsRemainIndependent() {
        // Keep test scheduling markers isolated from an existing install's reminder preferences.
        val isolated = object : ContextWrapper(context) {
            override fun getSharedPreferences(name: String, mode: Int) = super.getSharedPreferences("regression.$name", mode)
        }
        val service = ReminderNotificationService(isolated)
        val due = System.currentTimeMillis() + 100L * 60 * 60 * 1_000
        assertEquals("Aa".hashCode(), "BB".hashCode())
        fun pending(id: String): PendingIntent? = PendingIntent.getBroadcast(
            isolated, id.hashCode(),
            Intent(isolated, ReminderReceiver::class.java).apply {
                action = REMINDER_ACTION
                data = Uri.Builder().scheme("sift").authority("reminder").appendPath(id).build()
            },
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )
        try {
            service.rescheduleForTodos(listOf(
                TodoItem(id = "Aa", dueAt = due, aiNeedsNotification = true),
                TodoItem(id = "BB", dueAt = due, aiNeedsNotification = true),
            ))
            val first = pending("Aa")
            val second = pending("BB")
            assertNotNull(first)
            assertNotNull(second)
            assertNotEquals(first, second)
            service.cancel("Aa")
            assertNull(pending("Aa"))
            assertNotNull(pending("BB"))
        } finally {
            service.cancel("Aa")
            service.cancel("BB")
            isolated.getSharedPreferences(REMINDER_PREFS_NAME, Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
    @Test
    fun importedCalendarLinkNeverReachesProviderMutation() {
        val guarded = object : ContextWrapper(context) {
            override fun checkPermission(permission: String, pid: Int, uid: Int): Int = android.content.pm.PackageManager.PERMISSION_GRANTED
            override fun getContentResolver(): android.content.ContentResolver = error("Imported todo must not access the provider for registration")
        }
        val imported = TodoItem(
            source = TodoSource.CALENDAR,
            sourceRef = "calendar:42:1000",
            calendarEventId = 42,
            dueAt = 10_000,
        )
        assertNull(DeviceCalendarStore.createOrUpdateTodoEvent(guarded, imported, preferredCalendarId = 7))
    }
    @Test
    fun queuedOldDeliveryCannotCancelRescheduledAlarmOrMarker() {
        val testId = UUID.randomUUID().toString()
        val testFiles = File(context.cacheDir, "reminder-regression-$testId").also { check(it.mkdirs()) }
        val isolated = object : ContextWrapper(context) {
            override fun getFilesDir(): File = testFiles
            override fun getSharedPreferences(name: String, mode: Int) = super.getSharedPreferences("regression.$testId.$name", mode)
        }
        val service = ReminderNotificationService(isolated)
        val oldDue = System.currentTimeMillis() + 100L * 60 * 60 * 1_000
        val oldTodo = TodoItem(id = testId, dueAt = oldDue, aiNeedsNotification = true)
        val replacement = oldTodo.copy(dueAt = oldDue + 24L * 60 * 60 * 1_000)
        val preferences = isolated.getSharedPreferences(REMINDER_PREFS_NAME, Context.MODE_PRIVATE)
        fun replacementPending(): PendingIntent? = PendingIntent.getBroadcast(
            isolated, testId.hashCode().let { if (it == Int.MIN_VALUE) 0 else kotlin.math.abs(it) },
            Intent(isolated, ReminderReceiver::class.java).apply {
                action = REMINDER_ACTION
                data = Uri.Builder().scheme("sift").authority("reminder").appendPath(testId).build()
            },
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE,
        )
        try {
            service.rescheduleForTodos(listOf(oldTodo))
            // Simulate an already queued old broadcast, followed by a durable due-date edit.
            File(testFiles, "sift_state.json").writeText(
                kotlinx.serialization.json.Json.encodeToString(
                    SiftSnapshot.serializer(), SiftSnapshot(todos = listOf(replacement)),
                ),
            )
            service.rescheduleForTodos(listOf(replacement))
            val scheduled = replacementPending()
            assertNotNull(scheduled)
            service.showReminderNotification(testId, oldDue)
            assertEquals(scheduled, replacementPending())
            assertTrue(preferences.getStringSet(REMINDER_PREFS_KEY_SCHEDULED, emptySet()).orEmpty().contains(testId))
        } finally {
            service.cancel(testId)
            preferences.edit().clear().commit()
            testFiles.deleteRecursively()
        }
    }
    @Test
    fun deletingNotifiedTodoRemovesPrivateNotification() {
        val manager = context.getSystemService(android.app.NotificationManager::class.java)
        org.junit.Assume.assumeTrue(manager.areNotificationsEnabled())
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            org.junit.Assume.assumeTrue(androidx.core.content.ContextCompat.checkSelfPermission(context, android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED)
        }
        val testId = UUID.randomUUID().toString()
        val testFiles = File(context.cacheDir, "notification-regression-$testId").also { check(it.mkdirs()) }
        val isolated = object : ContextWrapper(context) {
            override fun getFilesDir(): File = testFiles
            override fun getSharedPreferences(name: String, mode: Int) = super.getSharedPreferences("regression.$testId.$name", mode)
        }
        val service = ReminderNotificationService(isolated)
        val due = System.currentTimeMillis() + 100L * 60 * 60 * 1_000
        val todo = TodoItem(id = testId, title = "Private regression title", dueAt = due, aiNeedsNotification = true)
        val preferences = isolated.getSharedPreferences(REMINDER_PREFS_NAME, Context.MODE_PRIVATE)
        fun awaitNotificationVisibility(visible: Boolean) {
            val deadline = android.os.SystemClock.elapsedRealtime() + 2_000
            while (manager.activeNotifications.any { it.tag == testId } != visible && android.os.SystemClock.elapsedRealtime() < deadline) {
                android.os.SystemClock.sleep(20)
            }
            assertEquals(visible, manager.activeNotifications.any { it.tag == testId })
        }
        try {
            File(testFiles, "sift_state.json").writeText(kotlinx.serialization.json.Json.encodeToString(SiftSnapshot.serializer(), SiftSnapshot(todos = listOf(todo))))
            service.rescheduleForTodos(listOf(todo))
            service.showReminderNotification(testId, due)
            awaitNotificationVisibility(true)
            assertTrue(preferences.getStringSet(REMINDER_PREFS_KEY_SCHEDULED, emptySet()).orEmpty().contains(testId))
            File(testFiles, "sift_state.json").writeText(kotlinx.serialization.json.Json.encodeToString(SiftSnapshot.serializer(), SiftSnapshot()))
            service.rescheduleForTodos(emptyList())
            awaitNotificationVisibility(false)
            assertFalse(preferences.getStringSet(REMINDER_PREFS_KEY_SCHEDULED, emptySet()).orEmpty().contains(testId))
        } finally {
            service.cancel(testId)
            preferences.edit().clear().commit()
            testFiles.deleteRecursively()
        }
    }
    @Test
    fun calendarDeletionDoesNotClaimSuccessWithoutOwnershipReadAccess() {
        val unreadable = object : ContextWrapper(context) {
            override fun checkPermission(permission: String, pid: Int, uid: Int): Int =
                if (permission == android.Manifest.permission.WRITE_CALENDAR) android.content.pm.PackageManager.PERMISSION_GRANTED
                else android.content.pm.PackageManager.PERMISSION_DENIED
            override fun getContentResolver(): android.content.ContentResolver = error("Mutation cannot proceed without ownership read access")
        }
        assertFalse(DeviceCalendarStore.deleteEvent(unreadable, 42))
        DeviceCalendarStore.clearEventReminders(unreadable, 42)
    }
}
