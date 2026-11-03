package nl.zoofit.hintmeet.audio

/** Ringbuffer met wat de Mac nog niet bevestigde (standaard 10 minuten, ~19 MB). Acks zijn cumulatief: alles onder
 *  de offset is binnen. Loopt hij vol, dan valt het oudste eruit en wordt dat stuk onthouden (voor de melding). */
class AudioBuffer(private val capacitySamples: Int = 9_600_000) {
    private val frames = ArrayDeque<Pair<Long, ShortArray>>()
    private var total = 0L
    private var acked = 0L
    private val _dropped = mutableListOf<LongRange>()

    @Synchronized
    fun append(offset: Long, pcm: ShortArray) {
        if (pcm.isEmpty()) return
        frames.addLast(offset to pcm)
        total += pcm.size
        while (total > capacitySamples && frames.isNotEmpty()) {
            val (o, p) = frames.removeFirst()
            total -= p.size
            recordDrop(o until o + p.size)
        }
    }

    private fun recordDrop(range: LongRange) {
        val last = _dropped.lastOrNull()
        if (last != null && last.last + 1 >= range.first) _dropped[_dropped.lastIndex] = last.first..maxOf(last.last, range.last)
        else _dropped.add(range)
    }

    @Synchronized
    fun ack(offset: Long) {
        if (offset <= acked) return
        acked = offset
        while (frames.isNotEmpty()) {
            val (o, p) = frames.first()
            val end = o + p.size
            when {
                end <= offset -> { frames.removeFirst(); total -= p.size }
                o < offset -> {   // ack midden in een frame: het begin eraf
                    val cut = (offset - o).toInt()
                    frames[0] = offset to p.copyOfRange(cut, p.size)
                    total -= cut
                    return
                }
                else -> return
            }
        }
    }

    /** Alles wat nog niet bevestigd is, oudste eerst, in stukken van hooguit maxSamples (momentopname). */
    @Synchronized
    fun unacked(maxSamples: Int = 1600): Sequence<Pair<Long, ShortArray>> {
        val out = ArrayList<Pair<Long, ShortArray>>()
        for ((o, p) in frames) {
            var i = 0
            while (i < p.size) {
                val n = minOf(maxSamples, p.size - i)
                out.add(o + i to p.copyOfRange(i, i + n))
                i += n
            }
        }
        return out.asSequence()
    }

    val bufferedSeconds: Double @Synchronized get() = total / 16_000.0
    val fill: Double @Synchronized get() = total.toDouble() / capacitySamples
    val dropped: List<LongRange> @Synchronized get() = _dropped.toList()
    val droppedSeconds: Double @Synchronized get() = _dropped.sumOf { it.last - it.first + 1 } / 16_000.0
}
