package nl.zoofit.hintmeet.audio

import nl.zoofit.hintmeet.protocol.Frame

/** Stuurt de opname naar de Mac, strikt op volgorde van offset. Alles gaat eerst de buffer in; verzonden wordt alleen
 *  na audio_ready (dan staat de hele weg naar de pijplijn open) en vanaf het eerste niet-verzonden stuk. Na een
 *  nieuwe audio_ready begint hij opnieuw bij het eerste niet-bevestigde stuk: zou er eerst live audio aankomen, dan
 *  vult de Mac het gat met stilte en gooit hij de opnieuw verstuurde audio weg als dubbel. */
class Streamer(
    private val buffer: AudioBuffer,
    private val send: (ByteArray) -> Boolean,
    private val meeting: ULong,
) {
    private var seq = 0u
    private var online = false
    private var sentUpTo = 0L      // alles onder deze offset is op deze verbinding al verstuurd
    private var finalOffset = 0L

    @Synchronized
    fun onFrame(offset: Long, pcm: ShortArray) {
        buffer.append(offset, pcm)
        finalOffset = maxOf(finalOffset, offset + pcm.size)
        pump()
    }

    @Synchronized
    fun onAck(offset: Long) = buffer.ack(offset)

    /** De Mac (via de gateway) is er weer: alles wat niet bevestigd is opnieuw, oudste eerst. */
    @Synchronized
    fun onAudioReady() {
        online = true
        sentUpTo = 0
        pump()
    }

    @Synchronized
    fun onDisconnected() {
        online = false
    }

    private fun pump() {
        if (!online) return
        for ((offset, pcm) in buffer.unacked()) {
            val end = offset + pcm.size
            if (end <= sentUpTo) continue
            val skip = (sentUpTo - offset).coerceAtLeast(0).toInt()
            val part = if (skip > 0) pcm.copyOfRange(skip, pcm.size) else pcm
            if (!send(Frame.encode(meeting, seq++, (offset + skip).toUInt(), part))) {
                online = false   // weg; bij de volgende audio_ready opnieuw vanaf de laatste ack
                return
            }
            sentUpTo = end
        }
    }

    /** Tot waar de opname liep: dat gaat als final_offset mee met Stop. */
    @Synchronized
    fun stop(): Long = finalOffset

    val bufferedSeconds: Double get() = buffer.bufferedSeconds
    val droppedSeconds: Double get() = buffer.droppedSeconds
    val fill: Double get() = buffer.fill
}
