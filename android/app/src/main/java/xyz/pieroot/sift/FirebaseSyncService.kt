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
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import java.time.Instant
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
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

private data class EncryptedSnapshot(
    val ciphertext: String,
    val iv: String,
    val salt: String,
    val iterations: Int,
    val kdf: String = "PBKDF2WithHmacSHA256"
)

object FirebaseSyncService {
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
        require(account != null && !account.idToken.isNullOrBlank()) {
            "Firebase 동기화에 필요한 Google ID 토큰을 가져오지 못했습니다."
        }
        account.email.orEmpty()
    }

    fun signedInEmail(context: Context): String? =
        GoogleSignIn.getLastSignedInAccount(context)
            ?.takeIf { !it.idToken.isNullOrBlank() }
            ?.email

    fun hasFirebaseAccess(context: Context): Boolean =
        GoogleSignIn.getLastSignedInAccount(context)?.idToken?.isNotBlank() == true

    suspend fun uploadSnapshot(
        context: Context,
        snapshotJson: String,
        passphrase: String,
    ): FirebaseSyncResult = withContext(Dispatchers.IO) {
        val session = firebaseSession(context)
        val encrypted = encrypt(snapshotJson, passphrase)
        val body = firestorePayload(session, encrypted)
        val url = firestoreDocumentUrl(projectId(context), session.uid)
        val connection = authorizedJsonConnection(url, session.idToken, "PATCH")
        connection.outputStream.bufferedWriter().use { it.write(body.toString()) }
        drainSuccess(connection, "Firebase Firestore 업로드 실패")
        FirebaseSyncResult(email = session.email, syncedAt = System.currentTimeMillis())
    }

    suspend fun downloadSnapshot(
        context: Context,
        passphrase: String,
    ): String? = withContext(Dispatchers.IO) {
        val session = firebaseSession(context)
        val url = firestoreDocumentUrl(projectId(context), session.uid)
        val connection = authorizedJsonConnection(url, session.idToken, "GET")
        val code = connection.responseCode
        if (code == 404) return@withContext null
        val payload = if (code in 200..299) {
            connection.inputStream.bufferedReader().use { it.readText() }
        } else {
            val error = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
            error("Firebase Firestore 다운로드 실패 ($code): $error")
        }
        val fields = JSONObject(payload).optJSONObject("fields") ?: return@withContext null
        val encrypted = EncryptedSnapshot(
            ciphertext = fields.getJSONObject("ciphertext").getString("stringValue"),
            iv = fields.getJSONObject("iv").getString("stringValue"),
            salt = fields.getJSONObject("salt").getString("stringValue"),
            iterations = fields.getJSONObject("iterations").optInt("integerValue", FIREBASE_ENCRYPTION_ITERATIONS),
            kdf = fields.optJSONObject("kdf")?.getString("stringValue").takeUnless { it.isNullOrBlank() } ?: "PBKDF2WithHmacSHA256"
        )
        return@withContext decrypt(encrypted, passphrase)
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

    private suspend fun firebaseSession(context: Context): FirebaseSession = withContext(Dispatchers.IO) {
        require(isConfigured(context)) {
            "Firebase Google 로그인 설정이 없어 동기화를 시작할 수 없습니다. google-services.json 에 OAuth client 와 SHA-1 등록이 필요합니다."
        }
        val account = requireNotNull(GoogleSignIn.getLastSignedInAccount(context)) {
            "Google 계정이 연결되지 않았습니다."
        }
        val googleIdToken = requireNotNull(account.idToken?.takeIf { it.isNotBlank() }) {
            "Google ID 토큰이 없습니다. 다시 로그인해 주세요."
        }

        val body = JSONObject().apply {
            put("postBody", "id_token=$googleIdToken&providerId=google.com")
            put("requestUri", "http://localhost")
            put("returnIdpCredential", true)
            put("returnSecureToken", true)
        }

        val endpoint = "$FIREBASE_SIGN_IN_ENDPOINT?key=${apiKey(context)}"
        val connection = jsonConnection(endpoint, "POST")
        connection.outputStream.bufferedWriter().use { it.write(body.toString()) }
        val response = readJson(connection, "Firebase Auth 로그인 실패")
        FirebaseSession(
            uid = response.getString("localId"),
            idToken = response.getString("idToken"),
            email = response.optString("email", account.email.orEmpty()),
        )
    }

    private fun firestoreDocumentUrl(projectId: String, uid: String): String =
        "$FIRESTORE_BASE_ENDPOINT/$projectId/databases/(default)/documents/users/$uid/$FIREBASE_COLLECTION_PATH"

    private fun firestorePayload(session: FirebaseSession, encrypted: EncryptedSnapshot): JSONObject =
        JSONObject().apply {
            put("fields", JSONObject().apply {
                put("version", JSONObject().put("integerValue", "1"))
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

    private fun encrypt(plainText: String, passphrase: String): EncryptedSnapshot {
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

    private fun decrypt(encrypted: EncryptedSnapshot, passphrase: String): String {
        require(passphrase.length >= 8) { "암호화 비밀번호는 8자 이상이어야 합니다." }
        val salt = base64Decode(encrypted.salt)
        val iv = base64Decode(encrypted.iv)
        val key = deriveKey(passphrase, salt, encrypted.iterations)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(FIREBASE_GCM_TAG_BITS, iv))
        val plaintext = cipher.doFinal(base64Decode(encrypted.ciphertext))
        return plaintext.toString(Charsets.UTF_8)
    }

    private fun deriveKey(passphrase: String, salt: ByteArray, iterations: Int): SecretKeySpec {
        val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        val spec = PBEKeySpec(passphrase.toCharArray(), salt, iterations, FIREBASE_KEY_LENGTH)
        return SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
    }

    private fun base64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    private fun base64Decode(value: String): ByteArray = Base64.decode(value, Base64.DEFAULT)

    private fun authorizedJsonConnection(url: String, bearerToken: String, method: String): HttpURLConnection =
        jsonConnection(url, method).apply {
            setRequestProperty("Authorization", "Bearer $bearerToken")
        }

    private fun jsonConnection(url: String, method: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            doInput = true
            doOutput = method != "GET"
            setRequestProperty("Accept", "application/json")
            setRequestProperty("Content-Type", "application/json; charset=UTF-8")
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

    private fun drainSuccess(connection: HttpURLConnection, label: String) {
        val code = connection.responseCode
        if (code in 200..299) {
            connection.inputStream.bufferedReader().use { it.readText() }
            return
        }
        val errorText = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
        error("$label ($code): $errorText")
    }
}
