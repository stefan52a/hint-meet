package nl.zoofit.hintmeet.session

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import nl.zoofit.hintmeet.BuildConfig
import nl.zoofit.hintmeet.audio.AudioBuffer
import nl.zoofit.hintmeet.audio.OffsetClock
import nl.zoofit.hintmeet.audio.RecordingService
import nl.zoofit.hintmeet.audio.Streamer
import nl.zoofit.hintmeet.health.Alarm
import nl.zoofit.hintmeet.health.Health
import nl.zoofit.hintmeet.health.LagHistory
import nl.zoofit.hintmeet.health.alarms
import nl.zoofit.hintmeet.net.GatewayClient
import nl.zoofit.hintmeet.pairing.Pairing
import nl.zoofit.hintmeet.pairing.PairingStore
import nl.zoofit.hintmeet.protocol.MeetingUi
import nl.zoofit.hintmeet.protocol.Phase
import nl.zoofit.hintmeet.protocol.ServerMessage
import nl.zoofit.hintmeet.protocol.markStopSent
import nl.zoofit.hintmeet.protocol.rate
import nl.zoofit.hintmeet.protocol.reduce
import nl.zoofit.hintmeet.protocol.startingFresh
import java.util.UUID

/** Wat de status-stippen tonen: hoe lang geleden er audio was, de Mac iets bevestigde en het transcript groeide. */
data class Liveness(val capturedAgoS: Long?, val ackedAgoS: Long?, val processedAgoS: Long?)

/** Eén sessie per proces: koppeling, verbinding, meeting, opname en alarmen. De schermen en de opnameservice
 *  delen hem, zodat een meeting doorloopt als het scherm uit gaat of de activity opnieuw wordt gemaakt. */
object Session {
    private lateinit var app: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var store: PairingStore

    val pairing = MutableStateFlow<Pairing?>(null)
    val connected = MutableStateFlow(false)
    val gateway = MutableStateFlow<ServerMessage.State?>(null)
    val projects = MutableStateFlow<ServerMessage.Projects?>(null)
    val meeting = MutableStateFlow(MeetingUi())
    val pendingPairing = MutableStateFlow<Pairing?>(null)
    val error = MutableStateFlow<String?>(null)
    val alarmsNow = MutableStateFlow<Set<Alarm>>(emptySet())
    val liveness = MutableStateFlow(Liveness(null, null, null))

    private var client: GatewayClient? = null
    private var jobs = mutableListOf<Job>()

    // opname
    @Volatile private var streamer: Streamer? = null
    @Volatile private var recordingMeeting: String? = null
    @Volatile private var lastCaptureAtMs = 0L
    @Volatile private var lastLevelAtMs = 0L
    private var lastAckAtMs = 0L
    private var lastProcessedAtMs = 0L
    private var lastProcessed = 0.0
    private var ackedS = 0.0
    private var progress = ServerMessage.Progress(0.0, 0.0)
    private val lag = LagHistory()
    private var connectedSinceMs: Long? = null
    private var lastDisconnectMs: Long? = null
    /** Klok van de Mac bij de laatste state: (now_ms van de Mac, elapsedRealtime van de telefoon op dat moment). */
    private var macClock: Pair<Long, Long>? = null
    private var stopJob: Job? = null

    private val prefs by lazy { app.getSharedPreferences("recording", Context.MODE_PRIVATE) }

    fun init(context: Context) {
        if (::app.isInitialized) return
        app = context.applicationContext
        store = PairingStore(app)
        pairing.value = store.load()
        pairing.value?.let(::connect)
        scope.launch { healthTicker() }
    }

    // ---------- koppelen ----------

    private fun parse(uri: String?) = uri?.let { Pairing.parse(it, allowLoopback = BuildConfig.DEBUG) }

    fun pair(uri: String?): String? {
        val p = parse(uri) ?: return "That isn't a HintMeet pairing code (Settings → Phone on the Mac)."
        if (meetingActive()) return "Stop the meeting first."
        apply(p)
        return null
    }

    fun offerPairing(uri: String?) {
        val p = parse(uri) ?: return
        if (meetingActive()) { error.value = "A pairing link was ignored: a meeting is running."; return }
        pendingPairing.value = p
    }

    fun confirmPairing(shown: Pairing, accept: Boolean) {
        if (pendingPairing.value != shown) return
        pendingPairing.value = null
        if (accept && !meetingActive()) apply(shown)
    }

    fun unpair() {
        disconnect()
        store.clear()
        pairing.value = null
    }

    private fun meetingActive() = meeting.value.phase in setOf(Phase.STARTING, Phase.RUNNING, Phase.STOPPING)

    private fun apply(p: Pairing) {
        store.save(p)
        pairing.value = p
        connect(p)
    }

    private fun disconnect() {
        jobs.forEach { it.cancel() }
        jobs.clear()
        client?.close()
        client = null
        connected.value = false
        gateway.value = null
        projects.value = null
        meeting.value = MeetingUi()
    }

    private fun connect(p: Pairing) {
        disconnect()
        val c = GatewayClient(p, scope)
        client = c
        jobs += scope.launch { c.messages.collect(::onMessage) }
        jobs += scope.launch {
            c.connected.collect { up ->
                connected.value = up
                val now = System.currentTimeMillis()
                if (up) {
                    connectedSinceMs = now
                    c.sendText("""{"type":"projects"}""")
                } else {
                    if (connectedSinceMs != null) lastDisconnectMs = now
                    connectedSinceMs = null
                    streamer?.onDisconnected()
                }
            }
        }
    }

    // ---------- berichten van de Mac ----------

    private fun onMessage(msg: ServerMessage) {
        when (msg) {
            is ServerMessage.State -> {
                gateway.value = msg
                macClock = msg.nowMs to SystemClock.elapsedRealtime()
                rejoinIfNeeded(msg)
            }
            is ServerMessage.Projects -> projects.value = msg
            is ServerMessage.AudioReady -> onAudioReady(msg)
            is ServerMessage.AudioAck -> if (msg.meeting == recordingMeeting) {
                streamer?.onAck(msg.offset)
                ackedS = msg.offset / 16_000.0
                lastAckAtMs = System.currentTimeMillis()
            }
            is ServerMessage.Progress -> {
                val now = System.currentTimeMillis()
                if (msg.processedS > lastProcessed) { lastProcessed = msg.processedS; lastProcessedAtMs = now }
                progress = msg
                lag.add(now, msg.heardS, msg.processedS)
            }
            else -> Unit
        }
        meeting.update { reduce(it, msg) }
        if (meeting.value.phase == Phase.ENDED && recordingMeeting != null && stopJob == null) stopRecording()
    }

    private fun onAudioReady(msg: ServerMessage.AudioReady) {
        val ui = meeting.value
        if (recordingMeeting == null && ui.phase in setOf(Phase.STARTING, Phase.RUNNING) && !ui.localStopSent &&
            (ui.meeting == null || ui.meeting == msg.meeting)) {
            startRecording(msg.meeting, msg.startedAtMs)
        }
        if (msg.meeting == recordingMeeting) streamer?.onAudioReady()
    }

    /** App was weg (gekilld) tijdens een meeting: weer aansluiten op dezelfde meeting. audio_ready volgt vanzelf. */
    private fun rejoinIfNeeded(s: ServerMessage.State) {
        val saved = prefs.getString("meeting", null) ?: return
        if (recordingMeeting != null) return
        if (s.meeting == saved && (s.phase == "running" || s.phase == "starting") && s.startedAtMs != null) {
            startRecording(saved, s.startedAtMs, ready = false)
        } else if (s.phase == "idle") {
            prefs.edit().remove("meeting").apply()
        }
    }

    // ---------- opname ----------

    private fun startRecording(meetingHex: String, startedAtMs: Long, ready: Boolean = true) {
        val clock = macClock
        val initial = clock?.let { (macNow, at) -> OffsetClock(startedAtMs, macNow, at).offsetAt(SystemClock.elapsedRealtime()) } ?: 0L
        val s = Streamer(AudioBuffer(), { bytes -> client?.sendBinary(bytes) ?: false }, meetingHex.toULong(16))
        streamer = s
        recordingMeeting = meetingHex
        lastCaptureAtMs = System.currentTimeMillis()
        lastLevelAtMs = lastCaptureAtMs
        prefs.edit().putString("meeting", meetingHex).putLong("startedAt", startedAtMs).apply()
        try {
            app.startForegroundService(Intent(app, RecordingService::class.java).putExtra(RecordingService.EXTRA_OFFSET, initial))
        } catch (e: Exception) {   // bv. geen microfoonrecht, of de app staat niet op de voorgrond
            error.value = "Recording couldn't start: ${e.message}"
            streamer = null
            recordingMeeting = null
            return
        }
        if (ready) s.onAudioReady()
    }

    /** Uit de opnameservice (eigen draad): een frame van 100 ms met zijn offset. */
    fun onCaptured(offset: Long, pcm: ShortArray, peak: Int) {
        val now = System.currentTimeMillis()
        lastCaptureAtMs = now
        if (peak > 300) lastLevelAtMs = now
        streamer?.onFrame(offset, pcm)
    }

    private fun stopRecording() {
        app.stopService(Intent(app, RecordingService::class.java))
        prefs.edit().remove("meeting").apply()
        recordingMeeting = null
        streamer = null
    }

    // ---------- start / stop ----------

    fun start(projects: List<String>, language: String, info: String) {
        meeting.value = startingFresh()
        val msg = buildJsonObject {
            put("type", "start")
            put("request_id", UUID.randomUUID().toString())
            put("projects", JsonArray(projects.map(::JsonPrimitive)))
            put("language", language)
            put("info", info)
        }
        if (client?.sendText(msg.toString()) != true) {
            meeting.value = MeetingUi()
            error.value = "The Mac isn't reachable; the meeting didn't start."
        }
    }

    /** Microfoon meteen uit; Stop gaat pas weg als de Mac alles heeft (hooguit 60 s, offline: zodra hij terug is). */
    fun stop() {
        meeting.update(::markStopSent)
        val s = streamer
        app.stopService(Intent(app, RecordingService::class.java))
        if (s == null) {
            client?.sendText("""{"type":"stop"}""")
            return
        }
        val final = s.stop()
        stopJob = scope.launch {
            val end = SystemClock.elapsedRealtime() + 60_000
            while (SystemClock.elapsedRealtime() < end && (s.bufferedSeconds > 0 || !connected.value)) delay(200)
            while (!connected.value) delay(500)
            client?.sendText(buildJsonObject { put("type", "stop"); put("final_offset", final) }.toString())
            stopRecording()
            stopJob = null
        }
    }

    fun feedback(id: Int, rating: Int) {
        if (meeting.value.ratings.containsKey(id)) return
        val msg = buildJsonObject { put("type", "feedback"); put("id", id); put("rating", rating) }
        if (client?.sendText(msg.toString()) == true) meeting.update { rate(it, id, rating) }
    }

    fun dismissMeeting() {
        meeting.value = MeetingUi()
    }

    // ---------- gezondheid ----------

    private suspend fun healthTicker() {
        val vibrator = app.getSystemService(Vibrator::class.java)
        while (true) {
            delay(1000)
            val now = System.currentTimeMillis()
            val recording = recordingMeeting != null
            if (!recording) {
                alarmsNow.value = emptySet()
                liveness.value = Liveness(null, null, null)
                continue
            }
            val battery = app.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = battery?.let { it.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) * 100 /
                                        it.getIntExtra(BatteryManager.EXTRA_SCALE, 100).coerceAtLeast(1) } ?: -1
            val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
            val health = Health(
                capturing = now - lastCaptureAtMs < 3000,
                lastLevelAtMs = lastLevelAtMs,
                connectedSinceMs = connectedSinceMs,
                lastDisconnectMs = lastDisconnectMs,
                ackedS = ackedS,
                heardS = progress.heardS,
                processedS = progress.processedS,
                lagShrinking = lag.shrinking(now),
                bufferFill = streamer?.fill ?: 0.0,
                droppedS = streamer?.droppedSeconds ?: 0.0,
                batteryPct = level,
                charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL,
                macPhase = gateway.value?.phase,
                localStopSent = meeting.value.localStopSent,
            )
            val found = alarms(health, now)
            if ((found - alarmsNow.value).isNotEmpty()) {
                vibrator?.vibrate(VibrationEffect.createOneShot(400, VibrationEffect.DEFAULT_AMPLITUDE))
            }
            alarmsNow.value = found
            fun ago(t: Long) = if (t == 0L) null else (now - t) / 1000
            liveness.value = Liveness(ago(lastCaptureAtMs), ago(lastAckAtMs), ago(lastProcessedAtMs))
        }
    }
}
