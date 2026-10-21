package xyz.pieroot.sift

import android.content.Context
import android.content.Intent
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.UserRecoverableAuthException
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

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

    fun signedInAccountId(context: Context): String? =
        GoogleSignIn.getLastSignedInAccount(context)
            ?.takeIf { GoogleSignIn.hasPermissions(it, gmailScope) }
            ?.let { it.id ?: it.email }

    suspend fun fetchRecentMessages(context: Context, maxResults: Int = 10): List<AndroidMailPreview> {
        currentCoroutineContext().ensureActive()
        val account = requireAccount(context)
        val accountId = requireNotNull(account.id ?: account.email) { "Google 계정 정보를 찾을 수 없습니다." }
        return withContext(Dispatchers.IO) {
            ensureAccount(context, accountId)
            val accessToken = accessToken(context, account)
            ensureAccount(context, accountId)
            val ids = listMessageIds(accessToken, maxResults)
            ensureAccount(context, accountId)
            ids.map { id ->
                ensureAccount(context, accountId)
                fetchMessage(accessToken, id).also { ensureAccount(context, accountId) }
            }
        }
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

    private suspend fun ensureAccount(context: Context, expectedId: String) {
        currentCoroutineContext().ensureActive()
        if (signedInAccountId(context) != expectedId) throw CancellationException("Google account changed")
    }

    private suspend fun listMessageIds(accessToken: String, maxResults: Int): List<String> {
        val payload = JSONObject(requireNotNull(GoogleServiceHttp.request(
            url = "$GMAIL_MESSAGES_ENDPOINT?maxResults=${maxResults.coerceIn(1, 25)}&q=-in:spam%20-in:trash%20newer_than:14d",
            method = "GET",
            label = "Gmail 목록 조회 실패",
            bearerToken = accessToken,
        )))
        val messages = payload.optJSONArray("messages") ?: return emptyList()
        return buildList {
            for (index in 0 until messages.length()) {
                add(messages.getJSONObject(index).getString("id"))
            }
        }
    }

    private suspend fun fetchMessage(accessToken: String, id: String): AndroidMailPreview {
        val payload = JSONObject(requireNotNull(GoogleServiceHttp.request(
            url = "$GMAIL_MESSAGES_ENDPOINT/$id?format=metadata&metadataHeaders=Subject&metadataHeaders=From",
            method = "GET",
            label = "Gmail 메시지 조회 실패",
            bearerToken = accessToken,
        )))
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

}
