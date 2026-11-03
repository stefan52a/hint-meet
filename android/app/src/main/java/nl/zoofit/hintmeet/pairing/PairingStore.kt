package nl.zoofit.hintmeet.pairing

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** De koppeling versleuteld op de telefoon (de sleutel geeft toegang tot je meetings op de Mac). */
class PairingStore(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "pairing",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun load(): Pairing? {
        val host = prefs.getString("host", null) ?: return null
        val token = prefs.getString("token", null) ?: return null
        return Pairing(host, prefs.getInt("port", 8790), token)
    }

    fun save(p: Pairing) {
        prefs.edit().putString("host", p.host).putInt("port", p.port).putString("token", p.token).apply()
    }

    fun clear() {
        prefs.edit().clear().apply()
    }
}
