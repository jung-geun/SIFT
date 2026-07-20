package xyz.pieroot.sift

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import java.util.TimeZone

private const val ONE_HOUR_MILLIS = 60L * 60L * 1000L

data class DeviceCalendarEvent(
    val id: Long,
    val title: String,
    val startMillis: Long,
    val endMillis: Long,
    val isAllDay: Boolean,
    val calendarId: Long,
    val calendarName: String,
    val description: String? = null,
    val isRecurring: Boolean = false,
) {
    val stableRef: String
        get() = "calendar:$id"
}

object DeviceCalendarStore {
    fun hasReadPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED

    fun hasWritePermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED

    fun queryUpcomingEvents(context: Context, days: Int = 30): List<DeviceCalendarEvent> {
        if (!hasReadPermission(context)) return emptyList()
        val now = System.currentTimeMillis()
        val end = now + days.coerceIn(1, 180) * 24L * 60L * 60L * 1000L
        val builder = CalendarContract.Instances.CONTENT_URI.buildUpon()
        ContentUris.appendId(builder, now)
        ContentUris.appendId(builder, end)

        val projection = arrayOf(
            CalendarContract.Instances.EVENT_ID,
            CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN,
            CalendarContract.Instances.END,
            CalendarContract.Instances.ALL_DAY,
            CalendarContract.Instances.CALENDAR_ID,
            CalendarContract.Instances.CALENDAR_DISPLAY_NAME,
            CalendarContract.Instances.DESCRIPTION,
            CalendarContract.Instances.RRULE,
        )

        val seen = linkedSetOf<String>()
        val events = mutableListOf<DeviceCalendarEvent>()
        context.contentResolver.query(
            builder.build(),
            projection,
            null,
            null,
            "${CalendarContract.Instances.BEGIN} ASC"
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.EVENT_ID)
            val titleIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.TITLE)
            val beginIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.BEGIN)
            val endIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.END)
            val allDayIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.ALL_DAY)
            val calendarIdIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.CALENDAR_ID)
            val calendarNameIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.CALENDAR_DISPLAY_NAME)
            val descriptionIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.DESCRIPTION)
            val rruleIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.RRULE)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIndex)
                val start = cursor.getLong(beginIndex)
                val dedupeKey = "$id:$start"
                if (!seen.add(dedupeKey)) continue
                events += DeviceCalendarEvent(
                    id = id,
                    title = cursor.getString(titleIndex).orEmpty(),
                    startMillis = start,
                    endMillis = cursor.getLong(endIndex),
                    isAllDay = cursor.getInt(allDayIndex) == 1,
                    calendarId = cursor.getLong(calendarIdIndex),
                    calendarName = cursor.getString(calendarNameIndex).orEmpty(),
                    description = cursor.getString(descriptionIndex),
                    isRecurring = !cursor.getString(rruleIndex).isNullOrBlank(),
                )
            }
        }
        return events
    }

    fun createOrUpdateTodoEvent(context: Context, todo: TodoItem, preferredCalendarId: Long? = null): Long? {
        if (!hasWritePermission(context) || todo.dueAt == null) return null
        val calendarId = preferredCalendarId ?: preferredWritableCalendarId(context) ?: return null
        val values = ContentValues().apply {
            put(CalendarContract.Events.CALENDAR_ID, calendarId)
            put(CalendarContract.Events.TITLE, if (todo.title.isBlank()) "할 일 마감" else todo.title)
            put(CalendarContract.Events.DESCRIPTION, todo.notes)
            put(CalendarContract.Events.DTSTART, todo.dueAt)
            put(CalendarContract.Events.DTEND, todo.dueAt + ONE_HOUR_MILLIS)
            put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
        }
        val resolver = context.contentResolver
        return if (todo.calendarEventId != null) {
            val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, todo.calendarEventId)
            resolver.update(uri, values, null, null)
            todo.calendarEventId
        } else {
            val uri = resolver.insert(CalendarContract.Events.CONTENT_URI, values) ?: return null
            val eventId = ContentUris.parseId(uri)
            insertDefaultReminder(context, eventId)
            eventId
        }
    }

    fun deleteEvent(context: Context, eventId: Long) {
        if (!hasWritePermission(context)) return
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
        context.contentResolver.delete(uri, null, null)
    }

    fun clearEventReminders(context: Context, eventId: Long) {
        if (!hasWritePermission(context)) return
        context.contentResolver.delete(
            CalendarContract.Reminders.CONTENT_URI,
            "${CalendarContract.Reminders.EVENT_ID}=?",
            arrayOf(eventId.toString()),
        )
    }

    private fun insertDefaultReminder(context: Context, eventId: Long) {
        val values = ContentValues().apply {
            put(CalendarContract.Reminders.EVENT_ID, eventId)
            put(CalendarContract.Reminders.MINUTES, 60)
            put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
        }
        context.contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, values)
    }

    private fun preferredWritableCalendarId(context: Context): Long? {
        if (!hasWritePermission(context)) return null
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.IS_PRIMARY,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
        )
        val selection = "${CalendarContract.Calendars.VISIBLE}=1 AND ${CalendarContract.Calendars.SYNC_EVENTS}=1"
        var primary: Long? = null
        var fallback: Long? = null
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            selection,
            null,
            null,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(CalendarContract.Calendars._ID)
            val primaryIndex = cursor.getColumnIndexOrThrow(CalendarContract.Calendars.IS_PRIMARY)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIndex)
                if (fallback == null) fallback = id
                if (cursor.getInt(primaryIndex) == 1) {
                    primary = id
                    break
                }
            }
        }
        return primary ?: fallback
    }
}
