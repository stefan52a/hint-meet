package nl.zoofit.hintmeet.audio

import org.junit.Assert.assertEquals
import org.junit.Test

class OffsetClockTest {
    @Test fun rejoinOffsetUsesMacClock() {
        val c = OffsetClock(startedAtMs = 1_000_000, macNowMs = 1_060_000, phoneNowAtJoinMs = 5_000_000) // telefoonklok ver weg
        assertEquals(60_000L * 16, c.offsetAt(5_000_000))
        assertEquals(61_000L * 16, c.offsetAt(5_001_000))
    }

    @Test fun neverNegative() {
        val c = OffsetClock(startedAtMs = 2_000, macNowMs = 1_000, phoneNowAtJoinMs = 1_000)
        assertEquals(0L, c.offsetAt(1_000))
    }
}
