package nl.zoofit.hintmeet

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import nl.zoofit.hintmeet.net.GatewayClient
import nl.zoofit.hintmeet.pairing.Pairing
import nl.zoofit.hintmeet.pairing.PairingStore
import nl.zoofit.hintmeet.protocol.MeetingUi
import nl.zoofit.hintmeet.protocol.ServerMessage
import nl.zoofit.hintmeet.protocol.markStopSent
import nl.zoofit.hintmeet.protocol.reduce
import nl.zoofit.hintmeet.protocol.startingFresh
import java.util.UUID

/** Alles wat de schermen nodig hebben: koppeling, verbinding met de Mac, en de meeting (via de reducer). */
@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModel(app: Application) : AndroidViewModel(app) {
    private val store = PairingStore(app)
    val pairing = MutableStateFlow(store.load())
    private val client = MutableStateFlow<GatewayClient?>(null)
    val connected: StateFlow<Boolean> = client.flatMapLatest { it?.connected ?: flowOf(false) }
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)
    val gateway = MutableStateFlow<ServerMessage.State?>(null)
    val projects = MutableStateFlow<ServerMessage.Projects?>(null)
    val meeting = MutableStateFlow(MeetingUi())
    private var collector: Job? = null

    init { pairing.value?.let(::connect) }

    /** QR-inhoud of geplakte koppel-link. Geeft een foutmelding of null. */
    fun pair(uri: String?): String? {
        val p = uri?.let { Pairing.parse(it, allowLoopback = BuildConfig.DEBUG) } ?: return "That isn't a HintMeet pairing code (Settings → Phone on the Mac)."
        store.save(p)
        pairing.value = p
        connect(p)
        return null
    }

    fun unpair() {
        client.value?.close()
        client.value = null
        store.clear()
        pairing.value = null
        gateway.value = null
        projects.value = null
    }

    private fun connect(p: Pairing) {
        client.value?.close()
        val c = GatewayClient(p, viewModelScope)
        client.value = c
        collector?.cancel()
        collector = viewModelScope.launch {
            c.messages.collect { msg ->
                when (msg) {
                    is ServerMessage.State -> gateway.value = msg
                    is ServerMessage.Projects -> projects.value = msg
                    else -> Unit
                }
                meeting.update { reduce(it, msg) }
            }
        }
        viewModelScope.launch {
            c.connected.collect { if (it) c.sendText("""{"type":"projects"}""") }
        }
    }

    fun start(projects: List<String>, language: String, info: String) {
        meeting.value = startingFresh()
        val msg = buildJsonObject {
            put("type", "start")
            put("request_id", UUID.randomUUID().toString())
            put("projects", JsonArray(projects.map(::JsonPrimitive)))
            put("language", language)
            put("info", info)
        }
        client.value?.sendText(msg.toString())
    }

    /** finalOffset: tot waar de telefoon audio opnam (0 = nog geen opname: dan stopt de Mac meteen). */
    fun stop(finalOffset: Long = 0) {
        meeting.update(::markStopSent)
        val msg = buildJsonObject {
            put("type", "stop")
            if (finalOffset > 0) put("final_offset", finalOffset)
        }
        client.value?.sendText(msg.toString())
    }

    fun feedback(id: Int, rating: Int) {
        val msg = buildJsonObject {
            put("type", "feedback")
            put("id", id)
            put("rating", rating)
        }
        client.value?.sendText(msg.toString())
    }

    /** Na het verslag: terug naar het startscherm. */
    fun dismissMeeting() {
        meeting.value = MeetingUi()
    }

    fun gatewayClient(): GatewayClient? = client.value

    override fun onCleared() {
        client.value?.close()
    }
}
