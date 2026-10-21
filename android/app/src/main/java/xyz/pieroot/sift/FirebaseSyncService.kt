package xyz.pieroot.sift

import android.content.Context
import android.content.Intent
import android.util.Base64
import com.google.android.gms.auth.api.signin.GoogleSignIn
import com.google.android.gms.auth.api.signin.GoogleSignInAccount
import com.google.android.gms.auth.api.signin.GoogleSignInClient
import com.google.android.gms.auth.api.signin.GoogleSignInOptions
import com.google.android.gms.common.api.ApiException
import org.json.JSONObject
import java.security.SecureRandom
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val FIREBASE_SIGN_IN_ENDPOINT = "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp"
private const val FIRESTORE_BASE_ENDPOINT = "https://firestore.googleapis.com/v1/projects"
private const val FIREBASE_COLLECTION_PATH = "appData/snapshot"
private const val FIREBASE_ENCRYPTION_ITERATIONS = 210_000
private const val FIREBASE_KEY_LENGTH = 256
private const val FIREBASE_GCM_TAG_BITS = 128
private const val FIREBASE_GCM_IV_BYTES = 12
private const val FIREBASE_SALT_BYTES = 16

data class FirebaseSyncResult(
    val email: String,
    val syncedAt: Long,
)

private data class FirebaseSession(
    val uid: String,
    val idToken: String,
    val email: String,
)

internal data class EncryptedSnapshot(
    val ciphertext: String,
    val iv: String,
    val salt: String,
    val iterations: Int,
    val kdf: String = "PBKDF2WithHmacSHA256",
    val version: Int = 1,
)

object FirebaseSyncService {
    fun isConfigured(context: Context): Boolean =
        BuildConfig.HAS_GOOGLE_OAUTH_CLIENT && !webClientId(context).isNullOrBlank()

    fun client(context: Context): GoogleSignInClient =
        GoogleSignIn.getClient(context, signInOptions(context))

    fun signInIntent(context: Context): Intent = client(context).signInIntent

    suspend fun signOut(context: Context) {
        client(context).signOutAndAwait()
    }

    fun handleSignInIntent(data: Intent?): Result<String> = runCatching {
        val task = GoogleSignIn.getSignedInAccountFromIntent(data)
        val account = task.getResult(ApiException::class.java)
        require(account != null && !account.idToken.isNullOrBlank()) {
            "Firebase 동기화에 필요한 Google ID 토큰을 가져오지 못했습니다."
        }
        account.email.orEmpty()
    }

    fun signedInEmail(context: Context): String? =
        GoogleSignIn.getLastSignedInAccount(context)
            ?.takeIf { !it.idToken.isNullOrBlank() }
            ?.email

    fun signedInAccountId(context: Context): String? =
        GoogleSignIn.getLastSignedInAccount(context)
            ?.takeIf { !it.idToken.isNullOrBlank() }
            ?.let { it.id ?: it.email }

    fun hasFirebaseAccess(context: Context): Boolean =
        GoogleSignIn.getLastSignedInAccount(context)?.idToken?.isNotBlank() == true

    suspend fun uploadSnapshot(
        context: Context,
        snapshotJson: String,
        passphrase: String,
    ): FirebaseSyncResult {
        currentCoroutineContext().ensureActive()
        val account = requireAccount(context)
        val accountId = requireNotNull(account.id ?: account.email) { "Google 계정 정보를 찾을 수 없습니다." }
        return withContext(Dispatchers.IO) {
            ensureAccount(context, accountId)
            val session = firebaseSession(context, account)
            ensureAccount(context, accountId)
            val encrypted = encrypt(snapshotJson, passphrase)
            ensureAccount(context, accountId)
            val body = firestorePayload(session, encrypted)
            val url = firestoreDocumentUrl(projectId(context), session.uid)
            GoogleServiceHttp.request(
                url, "PATCH", "Firebase Firestore 업로드 실패", session.idToken, body.toString(), readResponse = false,
            )
            ensureAccount(context, accountId)
            FirebaseSyncResult(email = session.email, syncedAt = System.currentTimeMillis())
        }
    }

    suspend fun downloadSnapshot(
        context: Context,
        passphrase: String,
    ): String? {
        currentCoroutineContext().ensureActive()
        val account = requireAccount(context)
        val accountId = requireNotNull(account.id ?: account.email) { "Google 계정 정보를 찾을 수 없습니다." }
        return withContext(Dispatchers.IO) {
            ensureAccount(context, accountId)
            val session = firebaseSession(context, account)
            ensureAccount(context, accountId)
            val url = firestoreDocumentUrl(projectId(context), session.uid)
            val payload = GoogleServiceHttp.request(
                url, "GET", "Firebase Firestore 다운로드 실패", session.idToken, allowNotFound = true,
            )
            ensureAccount(context, accountId)
            if (payload == null) return@withContext null
            val encrypted = parseEncryptedSnapshot(JSONObject(payload).getJSONObject("fields"))
            decrypt(encrypted, passphrase).also { ensureAccount(context, accountId) }
        }
    }

    private fun signInOptions(context: Context): GoogleSignInOptions {
        val webClientId = requireNotNull(webClientId(context)) {
            "default_web_client_id 가 없습니다. google-services.json 에 Android OAuth 클라이언트를 추가하세요."
        }
        return GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestEmail()
            .requestIdToken(webClientId)
            .build()
    }

    private fun webClientId(context: Context): String? {
        val resourceId = context.resources.getIdentifier("default_web_client_id", "string", context.packageName)
        if (resourceId == 0) return null
        return context.getString(resourceId).takeIf { it.isNotBlank() && it != "null" }
    }

    private fun apiKey(context: Context): String {
        val resourceId = context.resources.getIdentifier("google_api_key", "string", context.packageName)
        require(resourceId != 0) { "google_api_key 가 없습니다. google-services.json 확인이 필요합니다." }
        return context.getString(resourceId)
    }

    private fun projectId(context: Context): String {
        val resourceId = context.resources.getIdentifier("project_id", "string", context.packageName)
        require(resourceId != 0) { "project_id 가 없습니다. google-services.json 확인이 필요합니다." }
        return context.getString(resourceId)
    }

    private suspend fun ensureAccount(context: Context, expectedId: String) {
        currentCoroutineContext().ensureActive()
        if (signedInAccountId(context) != expectedId) throw CancellationException("Google account changed")
    }

    private fun requireAccount(context: Context): GoogleSignInAccount =
        requireNotNull(GoogleSignIn.getLastSignedInAccount(context)?.takeIf { !it.idToken.isNullOrBlank() }) {
            "Google ID 토큰이 없습니다. 다시 로그인해 주세요."
        }

    private suspend fun firebaseSession(context: Context, account: GoogleSignInAccount): FirebaseSession {
        val accountId = requireNotNull(account.id ?: account.email) { "Google 계정 정보를 찾을 수 없습니다." }
        ensureAccount(context, accountId)
        require(isConfigured(context)) {
            "Firebase Google 로그인 설정이 없어 동기화를 시작할 수 없습니다. google-services.json 에 OAuth client 와 SHA-1 등록이 필요합니다."
        }
        val refreshedAccount = awaitGoogleTask(client(context).silentSignIn())
        ensureAccount(context, accountId)
        if ((refreshedAccount.id ?: refreshedAccount.email) != accountId) {
            throw CancellationException("Google account changed during token refresh")
        }
        val googleIdToken = requireNotNull(refreshedAccount.idToken?.takeIf { it.isNotBlank() }) {
            "Google ID 토큰이 없습니다. 다시 로그인해 주세요."
        }

        val body = JSONObject().apply {
            put("postBody", "id_token=$googleIdToken&providerId=google.com")
            put("requestUri", "http://localhost")
            put("returnIdpCredential", true)
            put("returnSecureToken", true)
        }

        val endpoint = "$FIREBASE_SIGN_IN_ENDPOINT?key=${apiKey(context)}"
        ensureAccount(context, accountId)
        val response = JSONObject(requireNotNull(GoogleServiceHttp.request(
            endpoint, "POST", "Firebase Auth 로그인 실패", body = body.toString(),
        )))
        ensureAccount(context, accountId)
        return FirebaseSession(
            uid = response.getString("localId"),
            idToken = response.getString("idToken"),
            email = response.optString("email", refreshedAccount.email.orEmpty()),
        )
    }

    private fun firestoreDocumentUrl(projectId: String, uid: String): String =
        "$FIRESTORE_BASE_ENDPOINT/$projectId/databases/(default)/documents/users/$uid/$FIREBASE_COLLECTION_PATH"

    private fun firestorePayload(session: FirebaseSession, encrypted: EncryptedSnapshot): JSONObject =
        JSONObject().apply {
            put("fields", JSONObject().apply {
                put("version", JSONObject().put("integerValue", encrypted.version.toString()))
                put("provider", JSONObject().put("stringValue", "firebase-google"))
                put("email", JSONObject().put("stringValue", session.email))
                put("updatedAt", JSONObject().put("timestampValue", Instant.now().toString()))
                put("kdf", JSONObject().put("stringValue", encrypted.kdf))
                put("ciphertext", JSONObject().put("stringValue", encrypted.ciphertext))
                put("iv", JSONObject().put("stringValue", encrypted.iv))
                put("salt", JSONObject().put("stringValue", encrypted.salt))
                put("iterations", JSONObject().put("integerValue", encrypted.iterations.toString()))
            })
        }

    internal fun encrypt(plainText: String, passphrase: String): EncryptedSnapshot {
        require(passphrase.length >= 8) { "암호화 비밀번호는 8자 이상이어야 합니다." }
        val salt = ByteArray(FIREBASE_SALT_BYTES).also { SecureRandom().nextBytes(it) }
        val iv = ByteArray(FIREBASE_GCM_IV_BYTES).also { SecureRandom().nextBytes(it) }
        val key = deriveKey(passphrase, salt, FIREBASE_ENCRYPTION_ITERATIONS)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(FIREBASE_GCM_TAG_BITS, iv))
        val ciphertext = cipher.doFinal(plainText.toByteArray(Charsets.UTF_8))
        return EncryptedSnapshot(
            ciphertext = base64(ciphertext),
            iv = base64(iv),
            salt = base64(salt),
            iterations = FIREBASE_ENCRYPTION_ITERATIONS,
            kdf = "PBKDF2WithHmacSHA256"
        )
    }

    internal fun parseEncryptedSnapshot(fields: JSONObject): EncryptedSnapshot = EncryptedSnapshot(
        ciphertext = fields.getJSONObject("ciphertext").getString("stringValue"),
        iv = fields.getJSONObject("iv").getString("stringValue"),
        salt = fields.getJSONObject("salt").getString("stringValue"),
        iterations = fields.getJSONObject("iterations").getString("integerValue").toInt(),
        kdf = fields.getJSONObject("kdf").getString("stringValue"),
        version = fields.getJSONObject("version").getString("integerValue").toInt(),
    )

    internal fun decrypt(encrypted: EncryptedSnapshot, passphrase: String): String {
        require(passphrase.length >= 8) { "암호화 비밀번호는 8자 이상이어야 합니다." }
        require(encrypted.version == 1 && encrypted.kdf == "PBKDF2WithHmacSHA256" &&
            encrypted.iterations == FIREBASE_ENCRYPTION_ITERATIONS) { "지원하지 않는 Firebase 암호화 형식입니다." }
        val salt = base64Decode(encrypted.salt)
        val iv = base64Decode(encrypted.iv)
        val ciphertext = base64Decode(encrypted.ciphertext)
        require(salt.size == FIREBASE_SALT_BYTES && iv.size == FIREBASE_GCM_IV_BYTES &&
            ciphertext.size >= FIREBASE_GCM_TAG_BITS / 8) { "잘못된 Firebase 암호화 데이터입니다." }
        val key = deriveKey(passphrase, salt, FIREBASE_ENCRYPTION_ITERATIONS)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(FIREBASE_GCM_TAG_BITS, iv))
        val plaintext = cipher.doFinal(ciphertext)
        return plaintext.toString(Charsets.UTF_8)
    }

    private fun deriveKey(passphrase: String, salt: ByteArray, iterations: Int): SecretKeySpec {
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val spec = PBEKeySpec(passphrase.toCharArray(), salt, iterations, FIREBASE_KEY_LENGTH)
        return try {
            SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
        } finally {
            spec.clearPassword()
        }
    }

    private fun base64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    private fun base64Decode(value: String): ByteArray = Base64.decode(value, Base64.DEFAULT)

}
