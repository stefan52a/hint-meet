package nl.zoofit.hintmeet.pairing

import java.net.URI
import java.net.URLDecoder

/** Koppeling met de Mac, uit de QR in HintMeet → Settings → Phone: hintmeet://pair?host=…&port=…&token=… */
data class Pairing(val host: String, val port: Int, val token: String) {
    fun wsUrl(): String = "ws://$host:$port/"

    companion object {
        const val MIN_TOKEN = 32

        /** allowLoopback: alleen debug-builds, voor tests met `adb reverse tcp:8790 tcp:8790` (host 127.0.0.1). */
        fun parse(uri: String, allowLoopback: Boolean = false): Pairing? {
            val u = try { URI(uri.trim()) } catch (e: Exception) { return null }
            if (u.scheme != "hintmeet" || u.host != "pair") return null
            val params = (u.rawQuery ?: return null).split("&").mapNotNull {
                val (k, v) = it.split("=", limit = 2).takeIf { p -> p.size == 2 } ?: return@mapNotNull null
                k to URLDecoder.decode(v, "UTF-8")
            }.toMap()
            val host = params["host"]?.lowercase() ?: return null
            val port = params["port"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val token = params["token"]?.takeIf { it.length >= MIN_TOKEN } ?: return null
            if (!isTailnetHost(host) && !(allowLoopback && host == "127.0.0.1")) return null
            return Pairing(host, port, token)
        }

        /** Alleen het tailnet: 100.64.0.0/10 of een MagicDNS-naam (*.ts.net). */
        fun isTailnetHost(host: String): Boolean {
            if (host.endsWith(".ts.net") && host.length > ".ts.net".length) return true
            val parts = host.split(".")
            if (parts.size != 4) return false
            val o = parts.map { it.toIntOrNull()?.takeIf { n -> n in 0..255 } ?: return false }
            return o[0] == 100 && (o[1] and 0xC0) == 64
        }
    }
}
