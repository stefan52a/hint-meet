package nl.zoofit.hintmeet.health

/** Momentopname van alles wat kan misgaan tijdens een meeting met de telefoon. Tijden in ms (wandklok). */
data class Health(
    val capturing: Boolean,
    val lastLevelAtMs: Long,          // laatste keer dat de microfoon iets boven ruis hoorde
    val connectedSinceMs: Long?,
    val lastDisconnectMs: Long?,
    val ackedS: Double,               // zo ver bevestigde de Mac de audio
    val heardS: Double,               // zo ver haalde de pijplijn audio uit de wachtrij
    val processedS: Double,           // zo ver is het transcript
    val lagShrinking: Boolean,
    val bufferFill: Double,
    val droppedS: Double,
    val batteryPct: Int,
    val charging: Boolean,
    val macPhase: String?,
    val localStopSent: Boolean,
)

enum class Alarm(val text: String) {
    CONNECTION_LOST("No connection to the Mac for more than 30 s. Recording continues and is sent when it's back."),
    BUFFER_HALF_FULL("The phone's audio buffer is more than half full: the Mac hasn't received audio for a while."),
    MAC_STOPPED("The Mac stopped the meeting unexpectedly."),
    TRANSCRIPTION_BEHIND("The Mac is more than a minute behind with the transcript."),
    BATTERY_LOW("Battery below 15 %. Plug in the phone."),
    AUDIO_LOST("Some audio was lost: the buffer was full."),
    MIC_SILENT("The microphone hears nothing. Is it covered?"),
}

const val CONNECTION_GRACE_MS = 30_000L
const val BEHIND_S = 60.0
const val MIC_SILENT_MS = 120_000L

fun alarms(h: Health, nowMs: Long): Set<Alarm> = buildSet {
    if (h.connectedSinceMs == null && h.lastDisconnectMs != null && nowMs - h.lastDisconnectMs > CONNECTION_GRACE_MS) {
        add(Alarm.CONNECTION_LOST)
    }
    if (h.bufferFill > 0.5) add(Alarm.BUFFER_HALF_FULL)
    if (h.capturing && h.macPhase == "idle" && !h.localStopSent) add(Alarm.MAC_STOPPED)
    if (h.heardS - h.processedS > BEHIND_S && !h.lagShrinking) add(Alarm.TRANSCRIPTION_BEHIND)
    if (h.batteryPct in 0 until 15 && !h.charging) add(Alarm.BATTERY_LOW)
    if (h.droppedS > 0) add(Alarm.AUDIO_LOST)
    if (h.capturing && nowMs - h.lastLevelAtMs > MIC_SILENT_MS) add(Alarm.MIC_SILENT)
}

/** Achterstand (heard − processed) over tijd: krimpt hij t.o.v. ~15 s geleden, dan is de Mac aan het inhalen. */
class LagHistory(private val windowMs: Long = 15_000) {
    private val points = ArrayDeque<Pair<Long, Double>>()

    @Synchronized
    fun add(atMs: Long, heard: Double, processed: Double) {
        points.addLast(atMs to (heard - processed))
        while (points.size > 2 && points[1].first <= atMs - windowMs) points.removeFirst()
    }

    @Synchronized
    fun shrinking(nowMs: Long): Boolean {
        val then = points.lastOrNull { it.first <= nowMs - windowMs } ?: return false
        val current = points.lastOrNull() ?: return false
        return current.second < then.second
    }
}
