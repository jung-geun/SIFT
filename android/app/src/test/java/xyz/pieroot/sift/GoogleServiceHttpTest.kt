package xyz.pieroot.sift

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class GoogleServiceHttpTest {
    @Test
    fun success_configuresBoundedNonRedirectingAuthenticatedRequestAndClosesResources() = runBlocking {
        val connection = FakeConnection(response = "{\"text\":\"메일\"}")
        val body = "{\"snapshot\":\"할 일\"}"
        val response = GoogleServiceHttp.execute(connection, "PATCH", "Upload failed", "secret-token", body)

        assertEquals("{\"text\":\"메일\"}", response)
        assertEquals("PATCH", connection.requestMethod)
        assertFalse(connection.instanceFollowRedirects)
        assertEquals(15_000, connection.connectTimeout)
        assertEquals(30_000, connection.readTimeout)
        assertEquals("Bearer secret-token", connection.getRequestProperty("Authorization"))
        assertEquals("application/json; charset=UTF-8", connection.getRequestProperty("Content-Type"))
        assertEquals(body, connection.written.toString(Charsets.UTF_8.name()))
        assertTrue(connection.inputClosed)
        assertTrue(connection.outputClosed)
        assertTrue(connection.disconnected)
    }

    @Test
    fun successfulUpload_closesUnusedResponseWithoutReadingOrCopyingIt() = runBlocking {
        val connection = FakeConnection(failRead = true)
        assertEquals("", GoogleServiceHttp.execute(connection, "PATCH", "Upload failed", body = "{}", readResponse = false))
        assertTrue(connection.inputClosed)
        assertTrue(connection.disconnected)
    }

    @Test
    fun redirectAndHttpErrors_exposeOnlyStatusAndNeverReadProviderBodies() {
        for (code in listOf(301, 302, 307, 308, 400, 401, 403, 404, 500)) {
            val connection = FakeConnection(status = code, response = "token=private&mail=private")
            val error = assertThrows(IllegalStateException::class.java) {
                runBlocking { GoogleServiceHttp.execute(connection, "GET", "Request failed", "private-token") }
            }
            assertEquals("Request failed ($code)", error.message)
            assertFalse(connection.inputRequested)
            assertFalse(connection.errorRequested)
            assertFalse(connection.instanceFollowRedirects)
            assertTrue(connection.disconnected)
        }
    }

    @Test
    fun missingSnapshot_isNullAndStillDisconnects() = runBlocking {
        val connection = FakeConnection(status = 404)
        assertNull(GoogleServiceHttp.execute(connection, "GET", "Download failed", allowNotFound = true))
        assertFalse(connection.inputRequested)
        assertFalse(connection.errorRequested)
        assertTrue(connection.disconnected)
    }

    @Test
    fun writeResponseAndReadFailures_stillDisconnect() {
        val writeFailure = FakeConnection(failWrite = true)
        assertThrows(IOException::class.java) {
            runBlocking { GoogleServiceHttp.execute(writeFailure, "POST", "Auth failed", body = "id_token=secret") }
        }
        assertTrue(writeFailure.outputClosed)
        assertTrue(writeFailure.disconnected)

        val statusFailure = FakeConnection(failStatus = true)
        assertThrows(IOException::class.java) {
            runBlocking { GoogleServiceHttp.execute(statusFailure, "GET", "Download failed") }
        }
        assertTrue(statusFailure.disconnected)

        val readFailure = FakeConnection(failRead = true)
        assertThrows(IOException::class.java) {
            runBlocking { GoogleServiceHttp.execute(readFailure, "GET", "Download failed") }
        }
        assertTrue(readFailure.inputClosed)
        assertTrue(readFailure.disconnected)
    }

    @Test
    fun cancellationAfterStatus_doesNotConsumeResponseAndDisconnects() {
        val connection = FakeConnection()
        assertThrows(CancellationException::class.java) {
            runBlocking {
                val job = coroutineContext[Job]!!
                connection.onStatus = { job.cancel() }
                GoogleServiceHttp.execute(connection, "GET", "Download failed")
            }
        }
        assertFalse(connection.inputRequested)
        assertTrue(connection.disconnected)
    }

    @Test
    fun cancellationDuringWrite_preventsResponseRequestAndDisconnects() {
        val connection = FakeConnection()
        assertThrows(CancellationException::class.java) {
            runBlocking {
                val job = coroutineContext[Job]!!
                connection.onWrite = { job.cancel() }
                GoogleServiceHttp.execute(connection, "POST", "Auth failed", body = "secret")
            }
        }
        assertFalse(connection.statusRequested)
        assertTrue(connection.outputClosed)
        assertTrue(connection.disconnected)
    }

    private class FakeConnection(
        private val status: Int = 200,
        private val response: String = "{}",
        private val failWrite: Boolean = false,
        private val failStatus: Boolean = false,
        private val failRead: Boolean = false,
    ) : HttpURLConnection(URL("https://example.invalid/never-connected")) {
        var disconnected = false
        var inputRequested = false
        var errorRequested = false
        var statusRequested = false
        var inputClosed = false
        var outputClosed = false
        var onStatus: (() -> Unit)? = null
        var onWrite: (() -> Unit)? = null
        val written = ByteArrayOutputStream()

        override fun connect() = error("Fake connection must not contact a server")
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun setRequestMethod(method: String) { this.method = method }
        override fun getResponseCode(): Int {
            statusRequested = true
            if (failStatus) throw IOException("Response failure")
            onStatus?.invoke()
            return status
        }
        override fun getInputStream(): InputStream {
            inputRequested = true
            val source = ByteArrayInputStream(response.toByteArray(Charsets.UTF_8))
            return object : InputStream() {
                override fun read(): Int {
                    if (failRead) throw IOException("Read failure")
                    return source.read()
                }
                override fun close() { inputClosed = true; source.close() }
            }
        }
        override fun getErrorStream(): InputStream {
            errorRequested = true
            return ByteArrayInputStream(response.toByteArray(Charsets.UTF_8))
        }
        override fun getOutputStream(): OutputStream = object : OutputStream() {
            override fun write(value: Int) {
                if (failWrite) throw IOException("Write failure")
                written.write(value)
                onWrite?.invoke()
            }
            override fun close() { outputClosed = true }
        }
    }
}
