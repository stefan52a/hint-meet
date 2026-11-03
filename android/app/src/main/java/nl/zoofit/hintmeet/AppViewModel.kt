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
    private var watcher: Job? = null
    /** Koppel-link van buiten de app (getikt, andere app): eerst bevestigen, nooit stil overnemen. */
    val pendingPairing = MutableStateFlow<Pairing?>(null)
    val error = MutableStateFlow<String?>(null)

    init { pairing.value?.let(::connect) }

    private fun parse(uri: String?) = uri?.let { Pairing.parse(it, allowLoopback = BuildConfig.DEBUG) }

    /** QR-inhoud of geplakte koppel-link (in de app zelf gekozen). Geeft een foutmelding of null. */
    fun pair(uri: String?): String? {
        val p = parse(uri) ?: return "That isn't a HintMeet pairing code (Settings → Phone on the Mac)."
        if (meetingActive()) return "Stop the meeting first."
        apply(p)
        return null
    }

    /** Link van buiten de app: alleen voorstellen; pas na "Pair" in de dialoog geldt hij. */
    fun offerPairing(uri: String?) {
        val p = parse(uri) ?: return
        if (meetingActive()) { error.value = "A pairing link was ignored: a meeting is running."; return }
        pendingPairing.value = p
    }

    /** shown: de koppeling die in de dialoog stond. Kwam er intussen een andere link, dan geldt deze niet. */
    fun confirmPairing(shown: Pairing, accept: Boolean) {
        if (pendingPairing.value != shown) return
        pendingPairing.value = null
        if (accept && !meetingActive()) apply(shown)
    }

    private fun meetingActive() = meeting.value.phase.let { it == nl.zoofit.hintmeet.protocol.Phase.STARTING ||
        it == nl.zoofit.hintmeet.protocol.Phase.RUNNING || it == nl.zoofit.hintmeet.protocol.Phase.STOPPING }

    private fun apply(p: Pairing) {
        store.save(p)
        pairing.value = p
        connect(p)
    }

    fun unpair() {
        disconnect()
        store.clear()
        pairing.value = null
    }

    /** Alles van de vorige koppeling weg: geen oude meeting of projecten bij een andere Mac. */
    private fun disconnect() {
        collector?.cancel()
        watcher?.cancel()
        client.value?.close()
        client.value = null
        gateway.value = null
        projects.value = null
        meeting.value = MeetingUi()
    }

    private fun connect(p: Pairing) {
        disconnect()
        val c = GatewayClient(p, viewModelScope)
        client.value = c
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
        watcher = viewModelScope.launch {
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
        if (client.value?.sendText(msg.toString()) != true) {
            meeting.value = MeetingUi()
            error.value = "The Mac isn't reachable; the meeting didn't start."
        }
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
        if (meeting.value.ratings.containsKey(id)) return
        val msg = buildJsonObject {
            put("type", "feedback")
            put("id", id)
            put("rating", rating)
        }
        if (client.value?.sendText(msg.toString()) == true) meeting.update { nl.zoofit.hintmeet.protocol.rate(it, id, rating) }
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
