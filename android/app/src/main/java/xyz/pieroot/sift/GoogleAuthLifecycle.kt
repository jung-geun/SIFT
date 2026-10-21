package xyz.pieroot.sift

import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.tasks.Task
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine

/** Await the shared Google account sign-out before callers refresh either integration. */
internal suspend fun GoogleSignInClient.signOutAndAwait() {
    currentCoroutineContext().ensureActive()
    awaitGoogleTask(signOut())
}

internal suspend fun <T> awaitGoogleTask(task: Task<T>): T = suspendCancellableCoroutine { continuation ->
    task
        .addOnSuccessListener { continuation.resume(it) }
        .addOnFailureListener { continuation.resumeWithException(it) }
        .addOnCanceledListener { continuation.cancel(CancellationException("Google operation was cancelled")) }
}
