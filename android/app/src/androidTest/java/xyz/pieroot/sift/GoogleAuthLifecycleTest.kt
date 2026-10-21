package xyz.pieroot.sift

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.android.gms.tasks.CancellationTokenSource
import com.google.android.gms.tasks.TaskCompletionSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GoogleAuthLifecycleTest {
    @Test
    fun signOutWaiter_doesNotCompleteUntilGoogleTaskCompletes() = runBlocking {
        val source = TaskCompletionSource<Void>()
        val waiter = async(start = CoroutineStart.UNDISPATCHED) { awaitGoogleTask(source.task) }
        assertFalse(waiter.isCompleted)
        source.setResult(null)
        waiter.await()
        assertTrue(waiter.isCompleted)
    }

    @Test
    fun failedSignOut_propagatesOriginalError() {
        val source = TaskCompletionSource<Void>()
        val failure = IllegalStateException("Google sign-out failed")
        source.setException(failure)
        val actual = assertThrows(IllegalStateException::class.java) {
            runBlocking { awaitGoogleTask(source.task) }
        }
        assertSame(failure, actual)
    }

    @Test
    fun cancelledGoogleTask_cancelsWaiter() {
        val cancellation = CancellationTokenSource()
        val source = TaskCompletionSource<Void>(cancellation.token)
        cancellation.cancel()
        assertThrows(CancellationException::class.java) {
            runBlocking { awaitGoogleTask(source.task) }
        }
    }

    @Test
    fun cancellingWaiter_allowsGoogleTaskToFinishWithoutResumingCaller() = runBlocking {
        val source = TaskCompletionSource<Void>()
        var callerResumed = false
        val waiter = launch(start = CoroutineStart.UNDISPATCHED) {
            awaitGoogleTask(source.task)
            callerResumed = true
        }
        waiter.cancelAndJoin()
        source.setResult(null)
        awaitGoogleTask(source.task)
        assertTrue(waiter.isCancelled)
        assertFalse(callerResumed)
    }
}
