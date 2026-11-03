package nl.zoofit.hintmeet.net

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import nl.zoofit.hintmeet.pairing.Pairing
import nl.zoofit.hintmeet.protocol.ServerMessage
import nl.zoofit.hintmeet.protocol.parseServer
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit

/** WebSocket naar de gateway van HintMeet.app. Verbindt opnieuw (Backoff) tot close(); na elke verbinding
 *  vraagt hij de toestand op, zodat de telefoon na een netwerkwissel meteen weer weet waar de Mac is. */
class GatewayClient(
    private val pairing: Pairing,
    private val scope: CoroutineScope,
    private val http: OkHttpClient = defaultClient,
) {
    private val _messages = MutableSharedFlow<ServerMessage>(extraBufferCapacity = 512)
    val messages: SharedFlow<ServerMessage> = _messages
    private val _connected = MutableStateFlow(false)
    val connected: StateFlow<Boolean> = _connected

    @Volatile private var socket: WebSocket? = null
    @Volatile private var closed = false
    private val backoff = Backoff()
    private var retry: Job? = null

    init { connect() }

    private fun connect() {
        if (closed) return
        val request = Request.Builder()
            .url(pairing.wsUrl())
            .header("Authorization", "Bearer ${pairing.token}")   // niet in de URL: zie het wire-protocol
            .build()
        socket = http.newWebSocket(request, Listener())
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            if (webSocket !== socket) return
            backoff.reset()
            _connected.value = true
            webSocket.send("""{"type":"state"}""")
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (webSocket !== socket) return
            parseServer(text)?.let { _messages.tryEmit(it) }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = Unit

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            lost(webSocket)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = lost(webSocket)

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = lost(webSocket)
    }

    private fun lost(webSocket: WebSocket) {
        if (webSocket !== socket) return
        _connected.value = false
        socket = null
        if (closed) return
        retry?.cancel()
        retry = scope.launch {
            delay(backoff.next())
            connect()
        }
    }

    fun sendText(json: String): Boolean = socket?.send(json) ?: false

    /** false als er nu geen verbinding is: dan blijft de audio in de buffer en gaat hij later opnieuw. */
    fun sendBinary(bytes: ByteArray): Boolean =
        if (_connected.value) socket?.send(bytes.toByteString()) ?: false else false

    fun close() {
        closed = true
        retry?.cancel()
        socket?.close(1000, null)
        socket = null
        _connected.value = false
    }

    companion object {
        val defaultClient: OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .pingInterval(15, TimeUnit.SECONDS)   // half-open verbinding (netwerkwissel) binnen ~30 s merken
            .build()
    }
}
