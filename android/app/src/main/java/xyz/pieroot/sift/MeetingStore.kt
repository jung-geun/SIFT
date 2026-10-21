package xyz.pieroot.sift

import android.content.Context
import android.system.Os
import android.system.OsConstants
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.time.Instant

/**
 * App-private meeting persistence. Meeting payloads deliberately live outside
 * sift_state.json so Firebase snapshot sync can never include transcripts or audio.
 */
class MeetingStore(context: Context) {
    private val root = File(context.applicationContext.filesDir, "meetings")
    private val json = Json { encodeDefaults = true; ignoreUnknownKeys = true }

    init {
        check(root.exists() || root.mkdirs()) { "unable to create meeting directory" }
    }

    fun directory(meetingId: String): File {
        require(MEETING_ID.matches(meetingId)) { "invalid meeting ID" }
        return File(root, meetingId).also { require(it.parentFile == root) }
    }

    fun meetingFile(meetingId: String): File = File(directory(meetingId), "meeting.json")
    fun audioDirectory(meetingId: String): File = File(directory(meetingId), "audio")

    /** Temp-file fsync, same-directory rename, then directory fsync survive interruption. */
    fun save(record: MeetingRecord) {
        val target = meetingFile(record.meetingId)
        val parent = requireNotNull(target.parentFile)
        check(parent.exists() || parent.mkdirs()) { "unable to create meeting directory" }
        val temp = File(parent, ".meeting.json.${Thread.currentThread().id}.tmp")
        try {
            FileOutputStream(temp).use { output ->
                output.write(json.encodeToString(record).toByteArray(Charsets.UTF_8))
                output.fd.sync()
            }
            check(temp.renameTo(target)) { "unable to atomically replace meeting" }
            fsyncDirectory(parent)
        } finally {
            temp.delete()
        }
    }

    fun load(meetingId: String): MeetingRecord? = runCatching {
        val file = meetingFile(meetingId)
        if (!file.isFile) null else json.decodeFromString<MeetingRecord>(file.readText(Charsets.UTF_8)).also {
            require(it.meetingId == meetingId) { "meeting identity mismatch" }
        }
    }.getOrNull()

    fun list(): List<MeetingRecord> = root.listFiles()
        ?.asSequence()
        ?.filter(File::isDirectory)
        ?.mapNotNull { load(it.name) }
        ?.sortedByDescending(MeetingRecord::updatedAtEpochMillis)
        ?.toList()
        ?: emptyList()

    fun delete(meetingId: String): Boolean = directory(meetingId).deleteRecursively()
    fun deleteAudio(meetingId: String): Boolean {
        val directory = audioDirectory(meetingId)
        return !directory.exists() || directory.deleteRecursively()
    }

    fun deleteAll(): Int = root.listFiles()?.count { it.isDirectory && it.deleteRecursively() } ?: 0

    /** Backup rules must separately exclude files/meetings; this supports direct assertions. */
    fun isBackupExcluded(path: File): Boolean {
        val canonicalRoot = root.canonicalPath
        return path.canonicalPath == canonicalRoot || path.canonicalPath.startsWith(canonicalRoot + File.separator)
    }

    private fun fsyncDirectory(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY, 0)
        try {
            Os.fsync(fd)
        } finally {
            Os.close(fd)
        }
    }

    private companion object {
        val MEETING_ID = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    }
}

/** Imports only explicit user-selected drafts; it never creates scheduled or AI-sortable todos. */
object MeetingTodoImporter {
    fun confirm(
        meetingStore: MeetingStore,
        store: SiftStore,
        meetingID: String,
        draft: MeetingActionDraft,
        draftRevision: Int,
    ): TodoItem {
        val meeting = requireNotNull(meetingStore.load(meetingID)) { "meeting not found" }
        require(draftRevision == meeting.transcriptRevision) { "stale meeting draft" }
        val authoritativeDraft = requireNotNull(meeting.result?.actionDrafts?.firstOrNull { it.id == draft.id }) {
            "unknown meeting draft"
        }
        val sourceRef = "meeting:${meeting.meetingId}:action:${authoritativeDraft.id}"
        val todo = store.snapshot.todos.firstOrNull {
            it.source == TodoSource.MEETING && it.sourceRef == sourceRef
        } ?: store.saveMeetingTodo(
            title = authoritativeDraft.title,
            notes = buildString {
                if (authoritativeDraft.notes.isNotBlank()) append(authoritativeDraft.notes.trim())
                authoritativeDraft.assignee?.takeIf(String::isNotBlank)?.let {
                    if (isNotEmpty()) append('\n')
                    append("담당자: ").append(it.trim())
                }
                if (isNotEmpty()) append('\n')
                append("회의: ").append(meeting.meetingId)
            },
            dueAt = parseDueAt(authoritativeDraft.dueAtISO8601),
            sourceRef = sourceRef,
        )
        if (todo.id !in meeting.confirmedTodoIDs) {
            // MeetingStore.save is an atomic temp+fsync+rename write.
            meetingStore.save(meeting.copy(
                confirmedTodoIDs = meeting.confirmedTodoIDs + todo.id,
                updatedAtEpochMillis = System.currentTimeMillis(),
            ))
        }
        return todo
    }

    private fun parseDueAt(value: String?): Long? = value?.let(MeetingCanonicalIds::validatedDueAtMillis)
}
