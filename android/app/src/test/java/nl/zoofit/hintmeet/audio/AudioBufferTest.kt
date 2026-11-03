package nl.zoofit.hintmeet.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioBufferTest {
    private fun frame(n: Int = 1600, v: Short = 1) = ShortArray(n) { v }

    @Test fun ackTrimsAndResendStartsAtFirstUnacked() {
        val b = AudioBuffer()
        b.append(0, frame()); b.append(1600, frame()); b.append(3200, frame())
        b.ack(1600)
        assertEquals(1600L, b.unacked().first().first)
        b.ack(800)                                            // lager dan al bevestigd: genegeerd
        assertEquals(listOf(1600L, 3200L), b.unacked().map { it.first }.toList())
        assertEquals(3200.0 / 16000, b.bufferedSeconds, 1e-9)
    }

    @Test fun ackInsideAFrameTrimsItsStart() {
        val b = AudioBuffer()
        b.append(0, ShortArray(1600) { it.toShort() })
        b.ack(1000)
        val (offset, pcm) = b.unacked().first()
        assertEquals(1000L, offset)
        assertEquals(600, pcm.size)
        assertEquals(1000.toShort(), pcm[0])
    }

    @Test fun unackedSplitsIntoMaxSizedFrames() {
        val b = AudioBuffer()
        b.append(0, frame(4000))
        assertEquals(listOf(0L to 1600, 1600L to 1600, 3200L to 800),
                     b.unacked(maxSamples = 1600).map { it.first to it.second.size }.toList())
    }

    @Test fun overflowDropsOldestAndRecordsRange() {
        val b = AudioBuffer(capacitySamples = 3200)
        b.append(0, frame()); b.append(1600, frame()); b.append(3200, frame())
        assertEquals(listOf(0L..1599L), b.dropped)
        assertEquals(1.0, b.fill, 1e-9)
        assertEquals(1600L, b.unacked().first().first)
    }

    @Test fun adjacentDropsAreMerged() {
        val b = AudioBuffer(capacitySamples = 1600)
        b.append(0, frame()); b.append(1600, frame()); b.append(3200, frame())
        assertEquals(listOf(0L..3199L), b.dropped)
        assertTrue(b.droppedSeconds > 0.19)
    }
}
