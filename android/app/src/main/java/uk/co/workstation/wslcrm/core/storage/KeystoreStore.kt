package uk.co.workstation.wslcrm.core.storage

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Minimal secret store: AES-256-GCM with a key that lives in the Android Keystore and never
 * leaves the device; the ciphertext sits in a private SharedPreferences file that is excluded
 * from backup (mirrors `KeychainStore` with `…AfterFirstUnlockThisDeviceOnly`).
 *
 * The key needs no user authentication, so queued offline writes can replay while the UI is
 * locked; biometric unlock gates the UI only (`BiometricGate`), exactly as on iOS.
 */
class KeystoreStore(context: Context, private val service: String = "uk.co.workstation.wslcrm") {
    private val prefs: SharedPreferences = context.getSharedPreferences("$service.secrets", Context.MODE_PRIVATE)

    fun data(account: String): ByteArray? {
        val stored = prefs.getString(account, null) ?: return null
        val bytes = Base64.decode(stored, Base64.NO_WRAP)
        if (bytes.size <= IV_BYTES) return null
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, bytes, 0, IV_BYTES))
        return cipher.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES)
    }

    fun set(data: ByteArray, account: String) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(data)
        prefs.edit().putString(account, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
    }

    fun remove(account: String) {
        prefs.edit().remove(account).apply()
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private val alias get() = "$service.tokens.key"

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}
