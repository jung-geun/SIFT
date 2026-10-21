package xyz.pieroot.sift

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Calendar
class SiftCoreLogicTest {
    @Test
    fun effectivePriority_prefersManualPriority() {
        val todo = TodoItem(
            manualPriority = 4,
            computedPriorityScore = 0.15,
        )

        assertEquals(0.8, todo.effectivePriority, 0.0001)
    }

    @Test
    fun effectivePriority_fallsBackToComputedScore() {
        val todo = TodoItem(
            manualPriority = null,
            computedPriorityScore = 0.65,
        )

        assertEquals(0.65, todo.effectivePriority, 0.0001)
    }

    @Test
    fun isOverdue_trueOnlyForIncompletePastDueTodo() {
        val overdue = TodoItem(dueAt = System.currentTimeMillis() - 60_000)
        val completed = TodoItem(
            dueAt = System.currentTimeMillis() - 60_000,
            isCompleted = true,
            completedAt = System.currentTimeMillis(),
        )
        val future = TodoItem(dueAt = System.currentTimeMillis() + 60_000)

        assertTrue(overdue.isOverdue)
        assertFalse(completed.isOverdue)
        assertFalse(future.isOverdue)
    }
    @Test
    fun computeReminderTime_ignoresWorkStartRecommendationAndUsesSeventyTwoHourLead() {
        val now = 1_000L
        val dueAt = now + 79L * 60L * 60L * 1000L
        val recommended = now + 5L * 60L * 1000L
        val result = computeReminderTime(
            nowMillis = now,
            dueAt = dueAt,
            aiNeedsNotification = true,
            aiRecommendedTime = recommended,
        )

        assertEquals(dueAt - 72L * 60L * 60L * 1000L, result)
    }

    @Test
    fun computeReminderTime_usesFirstValidLeadFromOrderedClassifier() {
        val now = 1_000L
        val dueAt = now + 26L * 60L * 60L * 1000L
        val result = computeReminderTime(
            nowMillis = now,
            dueAt = dueAt,
            aiNeedsNotification = true,
            aiRecommendedTime = null,
        )

        assertEquals(dueAt - 24L * 60L * 60L * 1000L, result)
    }

    @Test
    fun computeReminderTime_returnsNullForNoValidWindow() {
        val now = 1_000L
        val dueAt = 2_000L
        val result = computeReminderTime(
            nowMillis = now,
            dueAt = dueAt,
            aiNeedsNotification = true,
            aiRecommendedTime = null,
        )

        assertNull(result)
    }

    @Test
    fun computeReminderTime_returnsNullWhenDueDateMissing() {
        val result = computeReminderTime(
            nowMillis = 1_000L,
            dueAt = null,
            aiNeedsNotification = true,
            aiRecommendedTime = 2_000L,
        )

        assertNull(result)
    }

    @Test
    fun computeReminderTime_returnsNullWhenNotificationDisabled() {
        val now = 1_000L
        val dueAt = 4_000_000L
        val result = computeReminderTime(
            nowMillis = now,
            dueAt = dueAt,
            aiNeedsNotification = false,
            aiRecommendedTime = 2_000_000L,
        )

        assertNull(result)
    }

    @Test
    fun isReminderSchedulable_returnsFalseForReviewTodo() {
        val todo = TodoItem(
            dueAt = System.currentTimeMillis() + 60_000L,
            triage = TodoTriage.REVIEW,
            aiNeedsNotification = true,
        )

        assertFalse(isReminderSchedulable(todo))
    }
    @Test
    fun normalizedMemoryHistory_migratesLegacyMemoryWhenHistoryMissing() {
        val legacy = MemoryInsight(summary = "legacy", createdAt = 10L)

        val snapshot = SiftSnapshot(memory = legacy).normalizedMemorySnapshot()

        assertEquals(listOf(legacy), snapshot.memoryHistory)
        assertEquals(legacy, snapshot.memory)
    }

    @Test
    fun normalizedMemoryHistory_prefersHistoryAndKeepsFiveNewest() {
        val legacy = MemoryInsight(summary = "legacy", createdAt = 999L)
        val history = (1L..6L).map { MemoryInsight(summary = "history-$it", createdAt = it) }

        val snapshot = SiftSnapshot(memory = legacy, memoryHistory = history).normalizedMemorySnapshot()

        assertEquals(5, snapshot.memoryHistory.size)
        assertEquals(6L, snapshot.memoryHistory.first().createdAt)
        assertEquals(2L, snapshot.memoryHistory.last().createdAt)
        assertEquals(snapshot.memoryHistory.first(), snapshot.memory)
        assertFalse(snapshot.memoryHistory.any { it.summary == "legacy" })
    }

    @Test
    fun computeMemoryAnalysis_returnsPreviewWithoutStoreMutation() {
        val calendar = Calendar.getInstance().apply {
            set(2026, Calendar.JANUARY, 1, 10, 0, 0)
            set(Calendar.MILLISECOND, 0)
        }
        val completedAt = calendar.timeInMillis
        val nowMillis = completedAt + 1_000L
        val todo = TodoItem(
            title = "완료한 일",
            createdAt = completedAt - 60L * 60L * 1000L,
            dueAt = completedAt + 60L * 60L * 1000L,
            isCompleted = true,
            completedAt = completedAt,
            tags = listOf("work"),
        )

        val result = computeMemoryAnalysis(listOf(todo), nowMillis = nowMillis)

        assertTrue(result.summary.isNotBlank())
        assertEquals(calendar.get(Calendar.HOUR_OF_DAY), result.productiveHour)
        assertEquals(nowMillis, result.createdAt)
    }

    @Test
    fun cloudSnapshot_excludesMailAndDeviceBindings() {
        val email = TodoItem(id = "email", source = TodoSource.EMAIL, title = "private subject")
        val legacyMail = TodoItem(id = "legacy", sourceMessageId = "private-message")
        val threadMail = TodoItem(id = "thread", sourceThreadId = "private-thread")
        val senderMail = TodoItem(id = "sender", sourceSenderEmail = "private@example.com")
        val manual = TodoItem(id = "manual", calendarEventId = 42L)
        val local = SiftSnapshot(
            mail = MailFeatureState(gmailConnected = true, suppressedSenders = listOf("private@example.com")),
            todos = listOf(email, legacyMail, threadMail, senderMail, manual),
        )

        val cloud = local.forCloudSync()

        assertEquals(listOf("manual"), cloud.todos.map { it.id })
        assertNull(cloud.todos.single().calendarEventId)
        assertEquals(MailFeatureState(), cloud.mail)
        assertEquals(42L, local.todos.last().calendarEventId)
    }

    @Test
    fun cloudRestore_preservesLocalMailAndNewerEditsWithoutTrustingRemoteMail() {
        val localMail = TodoItem(id = "mail", source = TodoSource.EMAIL, title = "local private")
        val localEdit = TodoItem(id = "edited", title = "newer local", updatedAt = 20L, calendarEventId = 11L)
        val localOnly = TodoItem(id = "local-only")
        val local = SiftSnapshot(
            settings = AppSettings(cloudSyncMode = CloudSyncMode.LOCAL),
            mail = MailFeatureState(gmailConnected = true),
            todos = listOf(localMail, localEdit, localOnly),
        )
        val remote = SiftSnapshot(
            settings = AppSettings(cloudSyncMode = CloudSyncMode.FIREBASE),
            todos = listOf(
                TodoItem(id = "mail", title = "remote collision", updatedAt = Long.MAX_VALUE),
                TodoItem(id = "edited", title = "older remote", updatedAt = 10L, calendarEventId = 99L),
                TodoItem(id = "remote-only", calendarEventId = 123L),
                TodoItem(id = "remote-mail", source = TodoSource.EMAIL),
                TodoItem(id = "remote-legacy-mail", sourceSenderEmail = "secret@example.com"),
            ),
        )

        val restored = mergeCloudSnapshot(local, remote)

        assertEquals(setOf("mail", "edited", "local-only", "remote-only"), restored.todos.map { it.id }.toSet())
        assertEquals(localMail, restored.todos.single { it.id == "mail" })
        assertEquals(localEdit, restored.todos.single { it.id == "edited" })
        assertNull(restored.todos.single { it.id == "remote-only" }.calendarEventId)
        assertEquals(local.mail, restored.mail)
        assertEquals(CloudSyncMode.LOCAL, restored.settings.cloudSyncMode)
    }

    @Test
    fun cloudRestore_usesNewerRemoteTodoButNeverItsCalendarLink() {
        val local = SiftSnapshot(todos = listOf(TodoItem(id = "shared", title = "old", updatedAt = 1L, calendarEventId = 17L)))
        val remote = SiftSnapshot(todos = listOf(TodoItem(id = "shared", title = "new", updatedAt = 2L, calendarEventId = 88L)))

        val restored = mergeCloudSnapshot(local, remote)

        assertEquals("new", restored.todos.single().title)
        assertEquals(17L, restored.todos.single().calendarEventId)
    }

    @Test(expected = IllegalArgumentException::class)
    fun cloudRestore_rejectsForeignSnapshotInsteadOfDefaultingAwayState() {
        decodeAndroidCloudSnapshot(Json { ignoreUnknownKeys = true }, """{"exportedAt":"2026-10-10T00:00:00Z","personas":[],"todos":[],"audits":[],"analyses":[]}""")
    }

    @Test
    fun cloudRestore_acceptsCurrentAndroidSnapshotWithUnknownFutureFields() {
        val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }
        val snapshot = SiftSnapshot(persona = PersonaProfile(descriptionText = "persona"), todos = listOf(TodoItem(id = "restored")))
        val raw = json.encodeToString(snapshot).dropLast(1) + ",\"futureField\":true}"

        assertEquals(snapshot, decodeAndroidCloudSnapshot(json, raw))
    }

}
