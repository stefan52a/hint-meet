package nl.zoofit.hintmeet.audio

/** Sample-offset volgens de klok van de Mac: de telefoonklok mag minuten afwijken. Eén keer gelijkgezet bij het
 *  (opnieuw) aansluiten met de now_ms van de Mac, daarna de telefoonklok erbij opgeteld. 16 samples per ms.
 *  Geef als telefoontijd SystemClock.elapsedRealtime(): die springt niet als iemand de klok verzet. */
class OffsetClock(private val startedAtMs: Long, macNowMs: Long, phoneNowAtJoinMs: Long) {
    private val skew = macNowMs - phoneNowAtJoinMs

    fun offsetAt(phoneNowMs: Long): Long = ((phoneNowMs + skew - startedAtMs) * 16).coerceAtLeast(0)
}
