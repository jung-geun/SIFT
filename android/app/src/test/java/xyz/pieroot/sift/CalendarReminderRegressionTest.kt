package xyz.pieroot.sift

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarReminderRegressionTest {
    @Test
    fun recurringImportsHaveOccurrenceIdentity() {
        val first = DeviceCalendarEvent(42, "Meeting", 1_000, 2_000, false, 7, "Work", isRecurring = true)
        val second = first.copy(startMillis = 3_000, endMillis = 4_000)
        assertNotEquals(first.stableRef, second.stableRef)
        assertEquals("calendar:42:1000", first.stableRef)
        assertEquals(first.stableRef, first.copy(title = "Renamed").stableRef)
        assertEquals("calendar:42", first.copy(isRecurring = false).stableRef)
    }

    @Test
    fun staleAlarmsCannotNotifyCompletedRemovedOrChangedTodos() {
        val todo = TodoItem(id = "todo", dueAt = 10_000, aiNeedsNotification = true)
        assertTrue(reminderMatchesStoredTodo(todo, 10_000))
        assertFalse(reminderMatchesStoredTodo(null, 10_000))
        assertFalse(reminderMatchesStoredTodo(todo.copy(isCompleted = true), 10_000))
        assertFalse(reminderMatchesStoredTodo(todo.copy(triage = TodoTriage.REVIEW), 10_000))
        assertFalse(reminderMatchesStoredTodo(todo.copy(aiNeedsNotification = false), 10_000))
        assertFalse(reminderMatchesStoredTodo(todo.copy(dueAt = 20_000), 10_000))
    }
}
