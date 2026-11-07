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
    /** Getypte tekst onderweg naar de Mac, of waarom hij niet aankwam. */
    val sayState = MutableStateFlow<SayState>(SayState.Idle())
    private var sayTimeout: Job? = null
    /** Find: de laatste zoekvraag in de KB van de meeting en wat die opleverde. */
    val find = MutableStateFlow(FindUi())
    private var findTimeout: Job? = null
    private const val FIND_TIMEOUT_MS = 30_000L
    private const val SAY_TIMEOUT_MS = 8_000L
    val connected = MutableStateFlow(false)
    val gateway = MutableStateFlow<ServerMessage.State?>(null)
    val projects = MutableStateFlow<ServerMessage.Projects?>(null)
    val meeting = MutableStateFlow(MeetingUi())
    val pendingPairing = MutableStateFlow<Pairing?>(null)
    val error = MutableStateFlow<String?>(null)
    val alarmsNow = MutableStateFlow<Set<Alarm>>(emptySet())
    val liveness = MutableStateFlow(Liveness(null, null, null))
    /** Add Folder: mappen op de Mac bekijken en er een als kennisbank toevoegen. */
    val folders = MutableStateFlow(FolderUi())
    /** Wat de Mac aan het omzetten of laden is (Add Folder, Preload KB); null: niets bekend. */
    val kbTask = MutableStateFlow<ServerMessage.KbTask?>(null)
    /** Project dat de Mac nu verwijdert (wacht op project_removed). */
    val removing = MutableStateFlow<String?>(null)
    private var removeId: String? = null
    /** Een document dat van de Mac komt (tik op een bron of zoekresultaat). */
    val doc = MutableStateFlow<DocUi?>(null)
    /** Bron → pad op de Mac, uit de hints en Backed van de meeting. */
    private val docPaths = mutableMapOf<String, String>()
    private var docTimeout: Job? = null
    private const val DOC_TIMEOUT_MS = 60_000L

    private var client: GatewayClient? = null
    private var jobs = mutableListOf<Job>()

    // opname
    @Volatile private var streamer: Streamer? = null
    @Volatile private var recordingMeeting: String? = null
    @Volatile private var acceptFrames = false   // uit zodra Stop is gedrukt: final_offset ligt dan vast
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
            is ServerMessage.Said -> { onSaid(msg); return }   // geen meetingstand
            is ServerMessage.SearchResults -> { onSearchResults(msg); return }
            is ServerMessage.SearchStatus -> { onSearchStatus(msg); return }
            is ServerMessage.Dirs -> { onDirs(msg); return }
            is ServerMessage.FolderAdded -> { onFolderAdded(msg); return }
            is ServerMessage.KbTask -> { kbTask.value = msg; return }
            is ServerMessage.ProjectRemoved -> { onProjectRemoved(msg); return }
            is ServerMessage.Doc -> { onDoc(msg); return }
            is ServerMessage.Hint -> docPaths.putAll(msg.paths)
            is ServerMessage.Confirm -> docPaths.putAll(msg.paths)
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
        if (meeting.value.phase == Phase.ENDED && recordingMeeting != null) stopRecording()   // voorbij op de Mac
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
        if (recordingMeeting != null || stopJob != null) return
        val alive = s.meeting == saved && (s.phase == "running" || s.phase == "starting" || s.phase == "stopping")
        when {
            // Stop was al gedrukt toen de app wegviel: niet opnieuw opnemen, alleen Stop nog eens sturen
            alive && prefs.getBoolean("stopRequested", false) -> {
                meeting.update(::markStopSent)
                client?.sendText("""{"type":"stop"}""")
            }
            alive && s.phase != "stopping" && s.startedAtMs != null -> startRecording(saved, s.startedAtMs, ready = false)
            s.phase == "idle" -> prefs.edit().remove("meeting").remove("stopRequested").apply()
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
        lastAckAtMs = 0; lastProcessedAtMs = 0; lastProcessed = 0.0; ackedS = 0.0   // niets van een vorige meeting
        progress = ServerMessage.Progress(0.0, 0.0)
        lag.clear()
        acceptFrames = true
        prefs.edit().putString("meeting", meetingHex).putLong("startedAt", startedAtMs).putBoolean("stopRequested", false).apply()
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
        if (!acceptFrames) return
        val now = System.currentTimeMillis()
        lastCaptureAtMs = now
        if (peak > 300) lastLevelAtMs = now
        streamer?.onFrame(offset, pcm)
    }

    /** Alles opruimen: pas als de meeting op de Mac echt voorbij is (dan is er niets meer opnieuw te sturen). */
    private fun stopRecording() {
        acceptFrames = false
        app.stopService(Intent(app, RecordingService::class.java))
        prefs.edit().remove("meeting").remove("stopRequested").apply()
        recordingMeeting = null
        streamer = null
        stopJob?.cancel()
        stopJob = null
    }

    /** Uit de opnameservice: de microfoon gaat niet open of geeft het op. */
    fun onRecorderFailed(why: String) {
        acceptFrames = false
        error.value = "Recording stopped: $why"
    }

    // ---------- start / stop ----------

    fun start(projects: List<String>, language: String, info: String) {
        find.value = FindUi()
        docPaths.clear()
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
        acceptFrames = false                      // eerst dicht: daarna staat final_offset vast
        val s = streamer
        app.stopService(Intent(app, RecordingService::class.java))
        prefs.edit().putBoolean("stopRequested", true).apply()
        val final = s?.stop() ?: 0L
        val msg = if (final > 0) buildJsonObject { put("type", "stop"); put("final_offset", final) }.toString()
                  else """{"type":"stop"}"""
        stopJob?.cancel()
        stopJob = scope.launch {
            // wachten tot de Mac alles heeft (hooguit 60 s); offline: tot hij terug is. De streamer blijft
            // bestaan tot de meeting voorbij is, zodat een late audio_ready de rest nog opnieuw stuurt.
            val end = SystemClock.elapsedRealtime() + 60_000
            while (s != null && SystemClock.elapsedRealtime() < end && (s.bufferedSeconds > 0 || !connected.value)) delay(200)
            while (!(connected.value && client?.sendText(msg) == true)) delay(500)
        }
    }

    fun feedback(id: Int, rating: Int) {
        if (meeting.value.ratings.containsKey(id)) return
        val msg = buildJsonObject { put("type", "feedback"); put("id", id); put("rating", rating) }
        if (client?.sendText(msg.toString()) == true) meeting.update { rate(it, id, rating) }
    }

    /** Getypt alsof je het zei: de Mac verwerkt het als een uitspraak van jou (zoals het invoerveld op de Mac).
     *  Pas als de Mac antwoordt (`said`) is het binnen; zonder antwoord binnen 8 s blijft de tekst staan met een melding.
     *  Dezelfde tekst opnieuw sturen gebruikt hetzelfde say_id: kwam hij toch al aan, dan zet de Mac hem er niet
     *  nog eens in. Geeft het say_id terug, of null als er niets verstuurd is. */
    fun say(text: String): String? {
        val t = text.trim()
        if (t.isEmpty() || sayState.value is SayState.Sending) return null
        val prev = sayState.value
        val id = when {
            prev is SayState.Failed && prev.text == t -> prev.id
            prev is SayState.Idle && prev.retryText == t && prev.retryId != null -> prev.retryId
            else -> UUID.randomUUID().toString()
        }
        if (meeting.value.phase != Phase.RUNNING) { sayState.value = SayState.Failed(id, t, "The meeting isn't listening."); return null }
        sayState.value = SayState.Sending(id, t)
        val msg = buildJsonObject { put("type", "say"); put("text", t); put("say_id", id) }
        if (client?.sendText(msg.toString()) != true) {
            sayState.value = SayState.Failed(id, t, "The Mac isn't reachable. Try again.")
            return id
        }
        sayTimeout?.cancel()
        sayTimeout = scope.launch {
            delay(SAY_TIMEOUT_MS)
            val s = sayState.value
            if (s is SayState.Sending && s.id == id) {
                sayState.value = SayState.Failed(id, t, "The Mac didn't confirm it. Try again.")
            }
        }
        return id
    }

    /** Je past de tekst aan na een melding: de melding weg (opnieuw sturen van dezelfde tekst houdt het say_id). */
    fun clearSayError() {
        val s = sayState.value
        if (s is SayState.Failed) sayState.value = SayState.Idle(retryId = s.id, retryText = s.text)
    }

    private fun onSaid(msg: ServerMessage.Said) {
        // ook een laat antwoord op de laatste poging telt (na de 8 s): dan is de tekst toch binnen
        val (id, text) = when (val s = sayState.value) {
            is SayState.Sending -> s.id to s.text
            is SayState.Failed -> s.id to s.text
            is SayState.Idle -> s.retryId to (s.retryText ?: "")
            is SayState.Sent -> return
        }
        if (id != msg.sayId) return
        sayTimeout?.cancel()
        sayState.value = if (msg.ok) SayState.Sent(msg.sayId)
                         else SayState.Failed(msg.sayId, text, "The Mac didn't take it: the meeting isn't listening.")
    }

    /** Zoeken in de kennisbank, zoals Find Documents op de Mac. Tijdens een meeting van de telefoon in de KB die de
     *  meeting al geladen heeft; anders laadt de Mac `projects` zelf (de eerste keer duurt dat even). */
    fun search(query: String, projects: List<String> = emptyList()) {
        val q = query.trim().replace('\n', ' ')
        if (q.isEmpty() || find.value.searching) return
        val id = "phone-" + UUID.randomUUID().toString()   // tekst: botst niet met de getallen van de Mac
        val msg = buildJsonObject {
            put("type", "search"); put("id", id); put("query", q)
            if (meeting.value.phase != Phase.RUNNING) put("projects", JsonArray(projects.map { JsonPrimitive(it) }))
        }
        if (client?.sendText(msg.toString()) != true) {
            find.value = FindUi(query = q, note = "The Mac isn't reachable. Try again.", projects = find.value.projects); return   // geen oude vraag meer open
        }
        find.value = FindUi(query = q, requestId = id, searching = true, projects = find.value.projects)   // oude resultaten weg: die horen bij een andere vraag
        armFindTimeout(id)
    }

    private fun armFindTimeout(id: String) {
        findTimeout?.cancel()
        findTimeout = scope.launch {
            delay(FIND_TIMEOUT_MS)
            val f = find.value
            if (f.searching && f.requestId == id) find.value = f.copy(searching = false, note = "No answer from the Mac. Search again.")
        }
    }

    /** Find openen voor andere projecten: geen resultaten (of open vraag) van de vorige laten staan. */
    fun openFind(projects: List<String>) {
        if (find.value.projects != projects) { findTimeout?.cancel(); find.value = FindUi(projects = projects) }
    }

    /** De Mac laadt de kennisbank nog: voortgang tonen en langer wachten. */
    private fun onSearchStatus(msg: ServerMessage.SearchStatus) {
        val f = find.value
        if (msg.id != f.requestId || !f.searching) return
        find.value = f.copy(note = msg.text)
        armFindTimeout(msg.id)
    }

    private fun onSearchResults(msg: ServerMessage.SearchResults) {
        val f = find.value
        if (msg.id != f.requestId) return   // antwoord op een eerdere vraag, of op de Mac
        findTimeout?.cancel()
        find.value = when (msg.error) {
            null -> f.copy(searching = false, results = msg.results, reranked = msg.reranked, searched = true, note = null)
            "loading" -> f.copy(searching = false, note = "The Mac is still loading the knowledge base; try again in a moment.")
            "no_project" -> f.copy(searching = false, note = "Choose a project first.")
            "busy" -> f.copy(searching = false, note = "A meeting is running on the Mac. Search when it's over.")
            else -> f.copy(searching = false, note = "Searching failed on the Mac. Try again.")
        }
    }

    // ---------- mappen op de Mac (Add Folder) ----------

    /** path null: de standaardmap op de Mac (~/projects). */
    fun listDirs(path: String?) {
        val id = "dirs-" + UUID.randomUUID().toString()
        val msg = buildJsonObject { put("type", "list_dirs"); put("id", id); if (path != null) put("path", path) }
        if (client?.sendText(msg.toString()) != true) {
            folders.update { it.copy(loading = false, note = "The Mac isn't reachable. Try again.") }; return
        }
        folders.update { it.copy(requestId = id, loading = true, note = null) }
    }

    private fun onDirs(msg: ServerMessage.Dirs) {
        val f = folders.value
        if (msg.id != f.requestId) return
        folders.value = if (msg.error != null || msg.path == null)
            f.copy(loading = false, note = "HintMeet can only show folders in your home folder on the Mac.")
        else f.copy(loading = false, path = msg.path, parent = msg.parent, dirs = msg.dirs, note = null)
    }

    fun addFolder(path: String) {
        val id = "add-" + UUID.randomUUID().toString()
        val msg = buildJsonObject { put("type", "add_folder"); put("id", id); put("path", path) }
        if (client?.sendText(msg.toString()) != true) {
            folders.update { it.copy(note = "The Mac isn't reachable. Try again.") }; return
        }
        folders.update { it.copy(addId = id, adding = true, note = null) }
    }

    private fun onFolderAdded(msg: ServerMessage.FolderAdded) {
        val f = folders.value
        if (msg.id != f.addId) return
        folders.value = if (msg.ok) f.copy(adding = false, added = msg.project ?: f.path.substringAfterLast('/'))
        else f.copy(adding = false, note = when (msg.error) {
            "busy" -> "The Mac is busy (a meeting, or another folder or KB is loading). Try again when it's done."
            "not_allowed" -> "HintMeet can only add folders in your home folder on the Mac."
            else -> "Adding the folder failed on the Mac."
        })
    }

    fun closeFolders() { folders.value = FolderUi() }

    // ---------- project verwijderen ----------

    /** Na bevestiging op de telefoon: de Mac zet de kennisbank van `project` in de Prullenmand. */
    fun removeProject(project: String) {
        val id = "rm-" + UUID.randomUUID().toString()
        val msg = buildJsonObject { put("type", "remove_project"); put("id", id); put("project", project) }
        if (client?.sendText(msg.toString()) != true) { error.value = "The Mac isn't reachable. Try again."; return }
        removeId = id
        removing.value = project
        scope.launch {
            delay(15_000)
            if (removeId == id) { removeId = null; removing.value = null; error.value = "No answer from the Mac. Check the project list." }
        }
    }

    private fun onProjectRemoved(msg: ServerMessage.ProjectRemoved) {
        if (msg.id != removeId) return
        removeId = null
        removing.value = null
        if (!msg.ok) error.value = when (msg.error) {
            "busy" -> "The Mac is busy (a meeting, or a folder or KB is loading). Remove “${msg.project}” when it's done."
            "not_found" -> "“${msg.project}” isn't on the Mac anymore."
            else -> "Removing “${msg.project}” failed on the Mac: ${msg.error}"
        }
    }

    // ---------- documenten van de Mac ----------

    /** Pad van een bron uit de meeting (hint of Backed), als de Mac het meestuurde. */
    fun docPath(ref: String): String? = docPaths[ref]

    fun openDoc(ref: String, path: String?) {
        val p = path ?: docPaths[ref]
        val name = ref.substringAfterLast('/')
        if (p == null) { doc.value = DocUi(name = name, error = "The Mac didn't say where this document is."); return }
        val id = "doc-" + UUID.randomUUID().toString()
        val msg = buildJsonObject { put("type", "get_doc"); put("id", id); put("path", p) }
        if (client?.sendText(msg.toString()) != true) {
            doc.value = DocUi(name = name, error = "The Mac isn't reachable. Try again."); return
        }
        doc.value = DocUi(requestId = id, name = name, loading = true)
        docTimeout?.cancel()
        docTimeout = scope.launch {
            delay(DOC_TIMEOUT_MS)
            val d = doc.value
            if (d?.requestId == id && d.loading) doc.value = d.copy(loading = false, error = "No answer from the Mac. Try again.")
        }
    }

    fun closeDoc() { docTimeout?.cancel(); doc.value = null }

    private fun onDoc(msg: ServerMessage.Doc) {
        val d = doc.value ?: return
        if (msg.id != d.requestId) return
        docTimeout?.cancel()
        if (msg.error != null || msg.data == null) {
            doc.value = d.copy(loading = false, error = when (msg.error) {
                "too_large" -> "This document is too large to send to the phone (over 12 MB)."
                "not_found" -> "The document isn't on the Mac anymore."
                else -> "HintMeet only sends documents from your knowledge bases."
            })
            return
        }
        scope.launch {
            val opened = kotlinx.coroutines.withContext(Dispatchers.IO) {
                runCatching { DocFiles.save(app, msg.name ?: d.name, msg.data) }.getOrNull()
            }
            if (doc.value?.requestId != msg.id) return@launch   // intussen gesloten of een ander document
            if (opened == null) { doc.value = d.copy(loading = false, error = "Couldn't save the document on the phone."); return@launch }
            val mime = msg.mime ?: "application/octet-stream"
            doc.value = if (DocFiles.isText(mime, opened.name)) {
                val text = kotlinx.coroutines.withContext(Dispatchers.IO) { opened.readText() }
                d.copy(loading = false, name = opened.name, text = text)
            } else if (DocFiles.view(app, opened, mime)) null
            else d.copy(loading = false, name = opened.name,
                        error = "No app on this phone opens this kind of document ($mime).")
        }
    }

    fun dismissMeeting() {
        docPaths.clear()
        find.value = FindUi()
        sayState.value = SayState.Idle()
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

/** Getypte tekst: niets onderweg, wacht op de Mac, bevestigd, of niet aangekomen (de tekst blijft dan staan). */
sealed interface SayState {
    /** retryId/retryText: na een melding die je wegtypte, zodat dezelfde tekst opnieuw hetzelfde say_id krijgt. */
    data class Idle(val retryId: String? = null, val retryText: String? = null) : SayState
    data class Sending(val id: String, val text: String) : SayState
    data class Sent(val id: String) : SayState
    data class Failed(val id: String, val text: String, val reason: String) : SayState
}

/** Find-tab: zoekvraag, of er gezocht wordt, de resultaten en een eventuele melding. */
data class FindUi(
    val query: String = "",
    val requestId: String? = null,
    val searching: Boolean = false,
    val searched: Boolean = false,
    val results: List<nl.zoofit.hintmeet.protocol.DocHit> = emptyList(),
    val reranked: Boolean = false,
    val note: String? = null,
    /** Voor welke projecten (Find vanaf het startscherm); leeg tijdens een meeting. */
    val projects: List<String> = emptyList(),
)

/** Add Folder: de map die nu getoond wordt, zijn submappen, en of er een toegevoegd is. */
data class FolderUi(
    val requestId: String? = null,
    val loading: Boolean = false,
    val path: String = "",
    val parent: String? = null,
    val dirs: List<String> = emptyList(),
    val addId: String? = null,
    val adding: Boolean = false,
    /** Project waarin de Mac de toegevoegde map omzet. */
    val added: String? = null,
    val note: String? = null,
)

/** Document van de Mac: aan het ophalen, als tekst in de app, of een melding. Andere soorten opent Android zelf. */
data class DocUi(
    val requestId: String? = null,
    val name: String = "",
    val loading: Boolean = false,
    val text: String? = null,
    val error: String? = null,
)
