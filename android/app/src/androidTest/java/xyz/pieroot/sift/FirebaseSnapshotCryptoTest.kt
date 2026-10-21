package xyz.pieroot.sift

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.security.GeneralSecurityException
import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FirebaseSnapshotCryptoTest {
    private val passphrase = "비밀번호 🔒 strong"
    private val plaintext = "{\"todos\":[{\"title\":\"메일 확인 🔒\"}]}"

    @Test
    fun writer_preservesVersionOneFormatAndAuthenticatedUnicodeRoundTrip() {
        val first = FirebaseSyncService.encrypt(plaintext, passphrase)
        val second = FirebaseSyncService.encrypt(plaintext, passphrase)
        assertEquals(1, first.version)
        assertEquals("PBKDF2WithHmacSHA256", first.kdf)
        assertEquals(210_000, first.iterations)
        assertEquals(16, decode(first.salt).size)
        assertEquals(12, decode(first.iv).size)
        assertEquals(plaintext.toByteArray(Charsets.UTF_8).size + 16, decode(first.ciphertext).size)
        assertFalse(first.salt == second.salt)
        assertFalse(first.iv == second.iv)
        assertEquals(plaintext, FirebaseSyncService.decrypt(first, passphrase))
        assertEquals(plaintext, FirebaseSyncService.decrypt(FirebaseSyncService.parseEncryptedSnapshot(fields(first)), passphrase))
    }

    @Test
    fun decrypt_rejectsUnsupportedAndUnboundedKdfParametersBeforeDerivation() {
        val encrypted = validShape()
        for (iterations in listOf(-1, 0, 1, 209_999, 210_001, Int.MAX_VALUE)) {
            assertThrows(IllegalArgumentException::class.java) {
                FirebaseSyncService.decrypt(encrypted.copy(iterations = iterations), passphrase)
            }
        }
        for (version in listOf(0, 2, Int.MAX_VALUE)) {
            assertThrows(IllegalArgumentException::class.java) {
                FirebaseSyncService.decrypt(encrypted.copy(version = version), passphrase)
            }
        }
        for (kdf in listOf("", "PBKDF2WithHmacSHA1", "pbkdf2withhmacsha256")) {
            assertThrows(IllegalArgumentException::class.java) {
                FirebaseSyncService.decrypt(encrypted.copy(kdf = kdf), passphrase)
            }
        }
    }

    @Test
    fun decrypt_rejectsMalformedSaltNonceAndTruncatedAuthenticationTag() {
        val encrypted = validShape()
        for (length in listOf(0, 1, 15, 17)) {
            assertThrows(IllegalArgumentException::class.java) {
                FirebaseSyncService.decrypt(encrypted.copy(salt = encode(ByteArray(length))), passphrase)
            }
        }
        for (length in listOf(0, 1, 11, 13)) {
            assertThrows(IllegalArgumentException::class.java) {
                FirebaseSyncService.decrypt(encrypted.copy(iv = encode(ByteArray(length))), passphrase)
            }
        }
        for (length in listOf(0, 1, 15)) {
            assertThrows(IllegalArgumentException::class.java) {
                FirebaseSyncService.decrypt(encrypted.copy(ciphertext = encode(ByteArray(length))), passphrase)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            FirebaseSyncService.decrypt(encrypted.copy(salt = "!not-base64!"), passphrase)
        }
    }

    @Test
    fun envelope_requiresExplicitVersionKdfAndIterationFieldsInsteadOfDefaults() {
        val encrypted = validShape()
        for (name in listOf("version", "kdf", "iterations", "salt", "iv", "ciphertext")) {
            val malformed = fields(encrypted).apply { remove(name) }
            assertThrows(JSONException::class.java) { FirebaseSyncService.parseEncryptedSnapshot(malformed) }
        }
        val malformed = fields(encrypted).apply {
            put("iterations", JSONObject().put("integerValue", "not-a-number"))
        }
        assertThrows(NumberFormatException::class.java) { FirebaseSyncService.parseEncryptedSnapshot(malformed) }
    }

    @Test
    fun modifiedCiphertextAndIncorrectPassword_failAuthentication() {
        val encrypted = FirebaseSyncService.encrypt(plaintext, passphrase)
        val damaged = decode(encrypted.ciphertext)
        damaged[damaged.lastIndex] = (damaged.last().toInt() xor 1).toByte()
        assertThrows(GeneralSecurityException::class.java) {
            FirebaseSyncService.decrypt(encrypted.copy(ciphertext = encode(damaged)), passphrase)
        }
        assertThrows(GeneralSecurityException::class.java) {
            FirebaseSyncService.decrypt(encrypted, "different-password")
        }
    }

    private fun validShape() = EncryptedSnapshot(
        ciphertext = encode(ByteArray(16)),
        iv = encode(ByteArray(12)),
        salt = encode(ByteArray(16)),
        iterations = 210_000,
    )

    private fun fields(encrypted: EncryptedSnapshot): JSONObject = JSONObject().apply {
        put("ciphertext", JSONObject().put("stringValue", encrypted.ciphertext))
        put("iv", JSONObject().put("stringValue", encrypted.iv))
        put("salt", JSONObject().put("stringValue", encrypted.salt))
        put("iterations", JSONObject().put("integerValue", encrypted.iterations.toString()))
        put("version", JSONObject().put("integerValue", encrypted.version.toString()))
        put("kdf", JSONObject().put("stringValue", encrypted.kdf))
    }

    private fun encode(value: ByteArray): String = Base64.encodeToString(value, Base64.NO_WRAP)
    private fun decode(value: String): ByteArray = Base64.decode(value, Base64.DEFAULT)
}
