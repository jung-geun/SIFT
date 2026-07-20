package xyz.pieroot.sift

import android.content.Context
import android.content.Intent
import android.content.IntentSender
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.UserRecoverableAuthException
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

private const val GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
private const val GMAIL_MESSAGES_ENDPOINT = "https://gmail.googleapis.com/gmail/v1/users/me/messages"

data class AndroidMailPreview(
    val id: String,
    val subject: String,
    val from: String,
    val snippet: String,
)

object AndroidGmailService {
    private val gmailScope = Scope(GMAIL_SCOPE)

    fun isConfigured(context: Context): Boolean =
        BuildConfig.HAS_GOOGLE_OAUTH_CLIENT && !webClientId(context).isNullOrBlank()

    fun client(context: Context): GoogleSignInClient =
        GoogleSignIn.getClient(context, signInOptions(context))

    fun signInIntent(context: Context): Intent = client(context).signInIntent

    fun signOut(context: Context) {
        client(context).signOut()
    }

    fun handleSignInIntent(data: Intent?): Result<String> = runCatching {
        val task = GoogleSignIn.getSignedInAccountFromIntent(data)
        val account = task.getResult(ApiException::class.java)
        require(account != null && GoogleSignIn.hasPermissions(account, gmailScope)) {
            "Gmail 읽기 권한을 승인하지 않았습니다."
        }
        account.email.orEmpty()
    }

    fun recoverableIntent(error: Throwable): Intent? =
        (error as? UserRecoverableAuthException)?.intent

    fun signedInEmail(context: Context): String? =
        GoogleSignIn.getLastSignedInAccount(context)
            ?.takeIf { GoogleSignIn.hasPermissions(it, gmailScope) }
            ?.email

    suspend fun fetchRecentMessages(context: Context, maxResults: Int = 10): List<AndroidMailPreview> = withContext(Dispatchers.IO) {
        val account = requireAccount(context)
        val accessToken = accessToken(context, account)
        val ids = listMessageIds(accessToken, maxResults)
        ids.mapNotNull { fetchMessage(accessToken, it) }
    }

    private fun signInOptions(context: Context): GoogleSignInOptions {
        val webClientId = requireNotNull(webClientId(context)) {
            "default_web_client_id 가 없습니다. Android OAuth 클라이언트를 먼저 설정하세요."
        }
        return GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
            .requestIdToken(webClientId)
            .requestScopes(gmailScope)
            .build()
    }

    private fun webClientId(context: Context): String? {
        val resourceId = context.resources.getIdentifier("default_web_client_id", "string", context.packageName)
        if (resourceId == 0) return null
        return context.getString(resourceId).takeIf { it.isNotBlank() && it != "null" }
    }

    private fun requireAccount(context: Context): GoogleSignInAccount {
        val account = GoogleSignIn.getLastSignedInAccount(context)
        require(account != null && GoogleSignIn.hasPermissions(account, gmailScope)) {
            "Gmail OAuth 계정이 연결되지 않았습니다."
        }
        return account
    }

    private fun accessToken(context: Context, account: GoogleSignInAccount): String {
        val coreAccount = requireNotNull(account.account) { "Google 계정 정보를 찾을 수 없습니다." }
        return GoogleAuthUtil.getToken(context, coreAccount, "oauth2:$GMAIL_SCOPE")
    }

    private fun listMessageIds(accessToken: String, maxResults: Int): List<String> {
        val connection = authorizedConnection(
            "$GMAIL_MESSAGES_ENDPOINT?maxResults=${maxResults.coerceIn(1, 25)}&q=-in:spam%20-in:trash%20newer_than:14d",
            accessToken,
        )
        val payload = readJson(connection, "Gmail 목록 조회 실패")
        val messages = payload.optJSONArray("messages") ?: return emptyList()
        return buildList {
            for (index in 0 until messages.length()) {
                add(messages.getJSONObject(index).getString("id"))
            }
        }
    }

    private fun fetchMessage(accessToken: String, id: String): AndroidMailPreview? {
        val connection = authorizedConnection(
            "$GMAIL_MESSAGES_ENDPOINT/$id?format=metadata&metadataHeaders=Subject&metadataHeaders=From",
            accessToken,
        )
        val payload = readJson(connection, "Gmail 메시지 조회 실패")
        val headers = payload.optJSONObject("payload")?.optJSONArray("headers")
        var subject = "(제목 없음)"
        var from = "알 수 없는 발신자"
        if (headers != null) {
            for (index in 0 until headers.length()) {
                val header = headers.getJSONObject(index)
                when (header.optString("name")) {
                    "Subject" -> subject = header.optString("value", subject)
                    "From" -> from = header.optString("value", from)
                }
            }
        }
        return AndroidMailPreview(
            id = id,
            subject = subject,
            from = from,
            snippet = payload.optString("snippet", ""),
        )
    }

    private fun authorizedConnection(rawUrl: String, accessToken: String): HttpURLConnection =
        (URL(rawUrl).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            doInput = true
            setRequestProperty("Authorization", "Bearer $accessToken")
            setRequestProperty("Accept", "application/json")
        }

    private fun readJson(connection: HttpURLConnection, label: String): JSONObject {
        val code = connection.responseCode
        val text = if (code in 200..299) {
            connection.inputStream.bufferedReader().use { it.readText() }
        } else {
            val errorText = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
            error("$label ($code): $errorText")
        }
        return JSONObject(text)
    }
}
