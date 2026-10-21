package xyz.pieroot.sift

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import android.net.Uri
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
        get() = if (isRecurring) "calendar:$id:$startMillis" else "calendar:$id"
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
            CalendarContract.Instances.RDATE,
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
            val rdateIndex = cursor.getColumnIndexOrThrow(CalendarContract.Instances.RDATE)
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
                    isRecurring = !cursor.getString(rruleIndex).isNullOrBlank() || !cursor.getString(rdateIndex).isNullOrBlank(),
                )
            }
        }
        return events
    }

    fun createOrUpdateTodoEvent(context: Context, todo: TodoItem, preferredCalendarId: Long? = null): Long? {
        // Imported links identify someone else's event, not a SIFT-owned registration.
        if (todo.source == TodoSource.CALENDAR || !hasReadPermission(context) || !hasWritePermission(context) || todo.dueAt == null) return null
        val existingId = todo.calendarEventId
        if (existingId != null && !ownsEvent(context, existingId, todo.id)) return null
        val calendarId = if (existingId == null) {
            preferredCalendarId?.takeIf { isWritableCalendar(context, it) } ?: preferredWritableCalendarId(context) ?: return null
        } else null
        val values = ContentValues().apply {
            if (calendarId != null) put(CalendarContract.Events.CALENDAR_ID, calendarId)
            put(CalendarContract.Events.TITLE, if (todo.title.isBlank()) "할 일 마감" else todo.title)
            put(CalendarContract.Events.DESCRIPTION, todo.notes)
            put(CalendarContract.Events.DTSTART, todo.dueAt)
            put(CalendarContract.Events.DTEND, todo.dueAt + ONE_HOUR_MILLIS)
            put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
        }
        val resolver = context.contentResolver
        return if (existingId != null) {
            val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, existingId)
            if (resolver.update(uri, values, ownershipSelection(), ownershipArgs(context, todo.id)) == 1) existingId else null
        } else {
            values.put(CalendarContract.Events.CUSTOM_APP_PACKAGE, context.packageName)
            values.put(CalendarContract.Events.CUSTOM_APP_URI, ownedTodoUri(todo.id))
            val uri = resolver.insert(CalendarContract.Events.CONTENT_URI, values) ?: return null
            val eventId = ContentUris.parseId(uri)
            insertDefaultReminder(context, eventId)
            eventId
        }
    }

    fun deleteEvent(context: Context, eventId: Long): Boolean {
        if (!hasWritePermission(context) || !ownsEvent(context, eventId)) return false
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
        return context.contentResolver.delete(uri, "${CalendarContract.Events.CUSTOM_APP_PACKAGE}=?", arrayOf(context.packageName)) == 1
    }

    fun clearEventReminders(context: Context, eventId: Long) {
        if (!ownsEvent(context, eventId) || !hasWritePermission(context)) return
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

    private fun ownedTodoUri(todoId: String): String = Uri.Builder().scheme("sift").authority("todo").appendPath(todoId).build().toString()

    private fun ownershipSelection(): String = "${CalendarContract.Events.CUSTOM_APP_PACKAGE}=? AND ${CalendarContract.Events.CUSTOM_APP_URI}=?"
    private fun ownershipArgs(context: Context, todoId: String): Array<String> = arrayOf(context.packageName, ownedTodoUri(todoId))

    private fun ownsEvent(context: Context, eventId: Long, todoId: String? = null): Boolean {
        if (!hasReadPermission(context)) return false
        val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
        return context.contentResolver.query(uri, arrayOf(CalendarContract.Events.CUSTOM_APP_PACKAGE, CalendarContract.Events.CUSTOM_APP_URI), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst() || cursor.getString(0) != context.packageName) return@use false
            val ownerUri = cursor.getString(1) ?: return@use false
            if (todoId != null) ownerUri == ownedTodoUri(todoId) else {
                val parsed = Uri.parse(ownerUri)
                parsed.scheme == "sift" && parsed.authority == "todo" && parsed.pathSegments.size == 1 && parsed.lastPathSegment?.isNotBlank() == true
            }
        } ?: false
    }

    private fun isWritableCalendar(context: Context, id: Long): Boolean = context.contentResolver.query(
        ContentUris.withAppendedId(CalendarContract.Calendars.CONTENT_URI, id),
        arrayOf(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL), null, null, null,
    )?.use { it.moveToFirst() && it.getInt(0) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR } ?: false

    private fun preferredWritableCalendarId(context: Context): Long? {
        if (!hasReadPermission(context) || !hasWritePermission(context)) return null
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.IS_PRIMARY,
            CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
        )
        val selection = "${CalendarContract.Calendars.VISIBLE}=1 AND ${CalendarContract.Calendars.SYNC_EVENTS}=1 AND ${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL}>=${CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR}"
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
