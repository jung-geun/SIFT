package xyz.pieroot.sift

import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** One request owns one connection, including failed writes and missing documents. */
internal object GoogleServiceHttp {
    private const val CONNECT_TIMEOUT_MS = 15_000
    private const val READ_TIMEOUT_MS = 30_000

    suspend fun request(
        url: String,
        method: String,
        label: String,
        bearerToken: String? = null,
        body: String? = null,
        allowNotFound: Boolean = false,
        readResponse: Boolean = true,
    ): String? {
        currentCoroutineContext().ensureActive()
        return execute(URL(url).openConnection() as HttpURLConnection, method, label, bearerToken, body, allowNotFound, readResponse)
    }

    internal suspend fun execute(
        connection: HttpURLConnection,
        method: String,
        label: String,
        bearerToken: String? = null,
        body: String? = null,
        allowNotFound: Boolean = false,
        readResponse: Boolean = true,
    ): String? = try {
        currentCoroutineContext().ensureActive()
        connection.instanceFollowRedirects = false
        connection.connectTimeout = CONNECT_TIMEOUT_MS
        connection.readTimeout = READ_TIMEOUT_MS
        connection.requestMethod = method
        connection.doInput = true
        connection.doOutput = body != null
        connection.setRequestProperty("Accept", "application/json")
        if (bearerToken != null) connection.setRequestProperty("Authorization", "Bearer $bearerToken")
        if (body != null) {
            connection.setRequestProperty("Content-Type", "application/json; charset=UTF-8")
            connection.outputStream.bufferedWriter(Charsets.UTF_8).use { it.write(body) }
        }
        currentCoroutineContext().ensureActive()
        val code = connection.responseCode
        currentCoroutineContext().ensureActive()
        when {
            code in 200..299 -> {
                val text = if (readResponse) {
                    connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                } else {
                    connection.inputStream.use { "" }
                }
                currentCoroutineContext().ensureActive()
                text
            }
            code == 404 && allowNotFound -> null
            // Never read or expose provider error bodies: they can contain credentials or user data.
            else -> error("$label ($code)")
        }
    } finally {
        connection.disconnect()
    }
}
