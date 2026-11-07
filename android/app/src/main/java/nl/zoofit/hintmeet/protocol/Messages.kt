package nl.zoofit.hintmeet.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

enum class HintState { STREAMING, FINAL, RETRACTED }

/** Wat er van de Mac komt: de berichten van de overlay-hub, de audiobron en de gateway. */
sealed interface ServerMessage {
    data class Hello(val project: String) : ServerMessage
    data class Utterance(val id: Int, val time: String, val speaker: String, val text: String) : ServerMessage
    /** paths: bron → pad op de Mac, om het document op te halen (get_doc). */
    data class Hint(val id: Int, val state: HintState, val text: String, val sources: List<String>,
                    val reason: String?, val paths: Map<String, String> = emptyMap()) : ServerMessage
    /** Linkerkolom op de Mac, "Backed by the knowledge base": kind "confirms" (✓) of "about" (📄). */
    data class Confirm(val id: Int, val text: String, val kind: String, val sources: List<String>,
                       val paths: Map<String, String> = emptyMap()) : ServerMessage
    data class Status(val text: String) : ServerMessage
    data class Progress(val heardS: Double, val processedS: Double) : ServerMessage
    data class Summary(val markdown: String) : ServerMessage
    data class ApiError(val text: String) : ServerMessage
    data object Stopped : ServerMessage
    data class AudioReady(val meeting: String, val startedAtMs: Long) : ServerMessage
    data class AudioAck(val meeting: String, val offset: Long) : ServerMessage
    data class AudioReject(val meeting: String, val reason: String) : ServerMessage
    data class State(val phase: String, val meeting: String?, val startedAtMs: Long?, val nowMs: Long,
                     val busyElsewhere: Boolean, val last: Last?) : ServerMessage {
        data class Last(val meeting: String, val stoppedBy: String, val reportMd: String?)
    }
    data class Projects(val items: List<String>, val selected: List<String>) : ServerMessage
    /** Antwoord van de Mac op getypte tekst (`say`): ok = in het transcript gezet. */
    data class Said(val sayId: String, val ok: Boolean) : ServerMessage
    /** Antwoord op een zoekvraag (Find): per document het best passende stukje. error "loading": KB nog niet klaar. */
    /** Voortgang terwijl de Mac de kennisbank voor een zoekvraag laadt (buiten een meeting). */
    data class SearchStatus(val id: String, val text: String) : ServerMessage
    data class SearchResults(val id: String, val results: List<DocHit>, val reranked: Boolean, val error: String?) : ServerMessage
    /** Mappen op de Mac (Add Folder): path de map zelf, parent nil in de thuismap. error "not_allowed". */
    data class Dirs(val id: String, val path: String?, val parent: String?, val dirs: List<String>, val error: String?) : ServerMessage
    /** Antwoord op add_folder: de Mac zet de map om tot kennisbank `project`. error: busy, not_allowed, failed. */
    data class FolderAdded(val id: String, val ok: Boolean, val project: String?, val error: String?) : ServerMessage
    /** Antwoord op remove_project. error: busy, not_found, of een melding van de Mac. */
    data class ProjectRemoved(val id: String, val project: String, val ok: Boolean, val error: String?) : ServerMessage
    /** Wat de Mac aan het omzetten of laden is. state: idle, running, done, failed. */
    data class KbTask(val title: String, val step: String, val fraction: Double?, val state: String,
                      val message: String?) : ServerMessage
    /** Een document van de Mac (base64), of error: not_allowed, not_found, too_large. */
    data class Doc(val id: String, val name: String?, val mime: String?, val data: String?, val error: String?) : ServerMessage {
        override fun toString() = "Doc(id=$id, name=$name, mime=$mime, ${data?.length ?: 0} chars, error=$error)"
    }
}

/** Eén gevonden document. relevance (0…1) als Jev meebeoordeelde; injection: lijkt instructies aan een AI te bevatten. */
data class DocHit(val ref: String, val heading: String, val snippet: String, val relevance: Double?, val injection: Boolean,
                  val path: String? = null) {
    val name: String get() = ref.substringAfterLast('/')
}

private val json = Json { ignoreUnknownKeys = true }

private fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.longOrNull
private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull
private fun JsonObject.double(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
private fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.booleanOrNull
private fun JsonObject.strings(key: String): List<String> =
    (this[key] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content } ?: emptyList()

/** Bronnen komen als {"ref":…, "path":…} (hub) of als tekst. */
private fun sourceRef(e: JsonElement): String? = when (e) {
    is JsonPrimitive -> e.content
    is JsonObject -> e.str("ref")
    else -> null
}

/** ref → path van bronnen die als {"ref":…, "path":…} komen. */
private fun sourcePaths(o: JsonObject): Map<String, String> =
    (o["sources"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { e ->
        (e as? JsonObject)?.let { s -> s.str("ref")?.let { r -> s.str("path")?.let { r to it } } }
    }?.toMap() ?: emptyMap()

/** Eén bericht van de Mac, of null voor iets onbekends of kapots (dan negeren, nooit crashen). */
fun parseServer(text: String): ServerMessage? {
    val o = try {
        json.parseToJsonElement(text) as? JsonObject ?: return null
    } catch (e: Exception) {
        return null
    }
    return when (o.str("type")) {
        "hello" -> ServerMessage.Hello(o.str("project") ?: "")
        "utterance" -> ServerMessage.Utterance(o.int("id") ?: return null, o.str("time") ?: "",
                                               o.str("speaker") ?: "", o.str("text") ?: "")
        "hint" -> ServerMessage.Hint(
            o.int("id") ?: return null,
            when (o.str("state")) {
                "final" -> HintState.FINAL
                "retracted" -> HintState.RETRACTED
                else -> HintState.STREAMING
            },
            o.str("text") ?: "",
            (o["sources"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull(::sourceRef) ?: emptyList(),
            o.str("reason"), sourcePaths(o))
        "confirm" -> ServerMessage.Confirm(
            o.int("id") ?: return null, o.str("text") ?: "", o.str("kind") ?: "confirms",
            (o["sources"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull(::sourceRef) ?: emptyList(),
            sourcePaths(o))
        "status" -> ServerMessage.Status(o.str("text") ?: "")
        "progress" -> ServerMessage.Progress(o.double("heard_s") ?: 0.0, o.double("processed_s") ?: 0.0)
        "summary" -> ServerMessage.Summary(o.str("markdown") ?: "")
        "api_error" -> ServerMessage.ApiError(o.str("text") ?: "")
        "stopped" -> ServerMessage.Stopped
        "audio_ready" -> ServerMessage.AudioReady(o.str("meeting") ?: return null, o.long("started_at_ms") ?: return null)
        "audio_ack" -> ServerMessage.AudioAck(o.str("meeting") ?: return null, o.long("offset") ?: return null)
        "audio_reject" -> ServerMessage.AudioReject(o.str("meeting") ?: "", o.str("reason") ?: "")
        "state" -> {
            val last = (o["last"] as? JsonObject)?.let {
                ServerMessage.State.Last(it.str("meeting") ?: return null, it.str("stopped_by") ?: "user", it.str("report_md"))
            }
            ServerMessage.State(o.str("phase") ?: return null, o.str("meeting"), o.long("started_at_ms"), o.long("now_ms") ?: 0,
                                o.bool("busy_elsewhere") ?: false, last)
        }
        "projects" -> ServerMessage.Projects(o.strings("items"), o.strings("selected"))
        "search_results" -> ServerMessage.SearchResults(
            o.str("id") ?: return null,   // de Mac zoekt met getallen als id; de telefoon met tekst
            (o["results"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { e ->
                (e as? JsonObject)?.let {
                    DocHit(it.str("ref") ?: return@let null, it.str("heading") ?: "", it.str("snippet") ?: "",
                           it.double("relevance"), it.bool("injection") ?: false, it.str("path"))
                }
            } ?: emptyList(),
            o.bool("reranked") ?: false, o.str("error"))
        "search_status" -> ServerMessage.SearchStatus(o.str("id") ?: return null, o.str("text") ?: "")
        "said" -> ServerMessage.Said(o.str("say_id") ?: return null, o.bool("ok") ?: false)
        "dirs" -> ServerMessage.Dirs(o.str("id") ?: return null, o.str("path"), o.str("parent"), o.strings("dirs"), o.str("error"))
        "folder_added" -> ServerMessage.FolderAdded(o.str("id") ?: return null, o.bool("ok") ?: false, o.str("project"),
                                                    o.str("error"))
        "project_removed" -> ServerMessage.ProjectRemoved(o.str("id") ?: return null, o.str("project") ?: "",
                                                          o.bool("ok") ?: false, o.str("error"))
        "kb_task" -> ServerMessage.KbTask(o.str("title") ?: "", o.str("step") ?: "", o.double("fraction"),
                                          o.str("state") ?: "idle", o.str("message"))
        "doc" -> ServerMessage.Doc(o.str("id") ?: return null, o.str("name"), o.str("mime"), o.str("data"), o.str("error"))
        else -> null
    }
}
