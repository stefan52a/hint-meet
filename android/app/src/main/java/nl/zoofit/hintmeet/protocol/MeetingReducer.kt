package nl.zoofit.hintmeet.protocol

enum class Phase { IDLE, STARTING, RUNNING, STOPPING, ENDED }

/** Wie de meeting stopte. UNEXPECTED: de Mac meldt "idle" zonder resultaat (pijplijn weg, Mac sliep). */
enum class StoppedBy { PHONE, MAC, WATCHDOG, UNEXPECTED }

data class HintUi(val id: Int, val text: String, val sources: List<String>, val final: Boolean,
                  val struck: Boolean = false, val reason: String? = null)

data class Line(val id: Int, val time: String, val speaker: String, val text: String)

/** Onderbouwing uit de kennisbank bij uitspraak [id]: confirms = wat gezegd is klopt, anders wat het dossier zegt. */
data class BackedUi(val id: Int, val text: String, val confirms: Boolean, val sources: List<String>)

data class ProgressUi(val heardS: Double, val processedS: Double)

data class MeetingUi(
    val phase: Phase = Phase.IDLE,
    val meeting: String? = null,
    val hints: List<HintUi> = emptyList(),
    val transcript: List<Line> = emptyList(),
    val backed: List<BackedUi> = emptyList(),
    val status: String? = null,
    val report: String? = null,
    val stoppedBy: StoppedBy? = null,
    val progress: ProgressUi? = null,
    val localStopSent: Boolean = false,
    /** De pijplijn op de Mac is klaar (state idle met resultaat): komt er geen verslag meer, dan ook niet later. */
    val pipelineDone: Boolean = false,
    /** 👍 = 1, 👎 = -1 per hint-id: één keer per hint, ook na wisselen van tab. */
    val ratings: Map<Int, Int> = emptyMap(),
)

fun rate(ui: MeetingUi, id: Int, rating: Int): MeetingUi = ui.copy(ratings = ui.ratings + (id to rating))

/** De telefoon stuurde zelf Stop: een "stopped" daarna is dus geen stop vanaf de Mac. */
fun markStopSent(ui: MeetingUi): MeetingUi = ui.copy(localStopSent = true, phase = Phase.STOPPING)

private val active = setOf(Phase.STARTING, Phase.RUNNING, Phase.STOPPING)

/** Pure toestandsovergang: alle berichten van de Mac gaan hierdoorheen. */
fun reduce(ui: MeetingUi, msg: ServerMessage): MeetingUi = when (msg) {
    // de hub speelt na elke (her)verbinding alles opnieuw af, beginnend met hello: dus opnieuw opbouwen
    is ServerMessage.Hello -> ui.copy(hints = emptyList(), transcript = emptyList(), backed = emptyList())
    is ServerMessage.Utterance -> {
        val line = Line(msg.id, msg.time, msg.speaker, msg.text)
        val i = ui.transcript.indexOfFirst { it.id == msg.id }
        ui.copy(transcript = if (i >= 0) ui.transcript.toMutableList().also { it[i] = line } else ui.transcript + line)
    }
    is ServerMessage.Hint -> {
        val i = ui.hints.indexOfFirst { it.id == msg.id }
        val previous = if (i >= 0) ui.hints[i] else null
        val hint = when (msg.state) {
            HintState.RETRACTED -> HintUi(msg.id, msg.text.ifEmpty { previous?.text ?: "" },
                                          previous?.sources ?: msg.sources, final = true, struck = true, reason = msg.reason)
            else -> HintUi(msg.id, msg.text, msg.sources, final = msg.state == HintState.FINAL)
        }
        ui.copy(hints = if (i >= 0) ui.hints.toMutableList().also { it[i] = hint } else ui.hints + hint)
    }
    is ServerMessage.Status -> ui.copy(status = msg.text)
    is ServerMessage.ApiError -> ui.copy(status = msg.text)
    is ServerMessage.Progress -> ui.copy(progress = ProgressUi(msg.heardS, msg.processedS))
    is ServerMessage.Summary -> ui.copy(report = msg.markdown)
    // "stopped" is een nette afloop: wint van een eerdere "unexpected"
    is ServerMessage.Stopped -> ui.copy(phase = Phase.ENDED, stoppedBy = when {
        ui.localStopSent -> StoppedBy.PHONE
        ui.stoppedBy == StoppedBy.WATCHDOG -> StoppedBy.WATCHDOG
        else -> StoppedBy.MAC
    })
    is ServerMessage.State -> reduceState(ui, msg)
    is ServerMessage.Confirm -> {
        val item = BackedUi(msg.id, msg.text, msg.kind == "confirms", msg.sources)
        // dezelfde uitspraak met dezelfde tekst niet dubbel (de hub speelt na een herverbinding alles opnieuw af)
        if (ui.backed.any { it.id == item.id && it.text == item.text }) ui else ui.copy(backed = ui.backed + item)
    }
    is ServerMessage.AudioReady, is ServerMessage.AudioAck,
    is ServerMessage.AudioReject, is ServerMessage.Projects, is ServerMessage.Said -> ui
}

private fun reduceState(current: MeetingUi, s: ServerMessage.State): MeetingUi {
    if (s.busyElsewhere) return current
    // een andere meeting dan die we tonen: met een schone lei beginnen (geen oud verslag, geen oude stop)
    val ui = if (s.meeting != null && current.meeting != null && s.meeting != current.meeting) MeetingUi() else current
    return when (s.phase) {
        "starting" -> ui.copy(phase = Phase.STARTING, meeting = s.meeting)
        "running" -> ui.copy(phase = if (ui.localStopSent) Phase.STOPPING else Phase.RUNNING, meeting = s.meeting)
        "stopping" -> ui.copy(phase = Phase.STOPPING, meeting = s.meeting ?: ui.meeting)
        "idle" -> {
            val last = s.last
            when {
                last != null && (ui.meeting == null || ui.meeting == last.meeting) -> ui.copy(
                    phase = Phase.ENDED,
                    pipelineDone = true,
                    meeting = last.meeting,
                    report = last.reportMd ?: ui.report,
                    stoppedBy = when {
                        last.stoppedBy == "watchdog" -> StoppedBy.WATCHDOG
                        ui.localStopSent -> StoppedBy.PHONE
                        // alleen een live "stopped" zonder eigen Stop zegt "op de Mac"; na een herstart weten we het niet
                        else -> ui.stoppedBy?.takeIf { it != StoppedBy.UNEXPECTED }
                    })
                ui.phase in active -> ui.copy(phase = Phase.ENDED, stoppedBy = StoppedBy.UNEXPECTED, pipelineDone = true)
                else -> ui
            }
        }
        else -> current   // onbekende fase (nieuwere Mac): niets aan de meeting veranderen
    }
}

/** Nieuwe meeting starten vanaf de telefoon: alles van de vorige weg. */
fun startingFresh(): MeetingUi = MeetingUi(phase = Phase.STARTING)
