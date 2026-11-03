package nl.zoofit.hintmeet.net

import org.junit.Assert.assertEquals
import org.junit.Test

class BackoffTest {
    @Test fun backoffSequence() {
        val b = Backoff()
        assertEquals(listOf(1000L, 2000, 4000, 8000, 10000, 10000), List(6) { b.next() })
        b.reset()
        assertEquals(1000L, b.next())
    }
}
