package nl.zoofit.hintmeet.audio

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class StreamerTest {
    private val sent = mutableListOf<Long>()
    private var online = true
    private fun streamer(buffer: AudioBuffer = AudioBuffer()) = Streamer(buffer, { bytes ->
        if (online) sent.add(ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).getInt(12).toLong() and 0xffffffffL)
        online
    }, meeting = 0xaaUL)
    private fun frame() = ShortArray(1600) { 1 }

    @Test fun resendAfterReconnectStartsAtFirstUnacked() {
        val s = streamer()
        s.onAudioReady()
        for (i in 0 until 5) s.onFrame(i * 1600L, frame())
        s.onAck(3200)
        s.onDisconnected()
        sent.clear()
        s.onAudioReady()                                    // gateway en pijplijn weer verbonden
        assertEquals(listOf(3200L, 4800L, 6400L), sent)
    }

    @Test fun liveFramesWaitBehindResend() {
        val s = streamer()
        s.onAudioReady()
        online = false
        for (i in 0 until 3) s.onFrame(i * 1600L, frame()) // offline: alleen in de buffer
        online = true
        s.onAudioReady()
        s.onFrame(3 * 1600L, frame())
        assertEquals(listOf(0L, 1600L, 3200L, 4800L), sent)
    }

    @Test fun nothingIsSentBeforeAudioReady() {
        val s = streamer()
        s.onFrame(0, frame())
        assertEquals(emptyList<Long>(), sent)
        s.onAudioReady()
        assertEquals(listOf(0L), sent)
    }

    @Test fun stopReturnsFinalOffset() {
        val s = streamer()
        s.onAudioReady()
        for (i in 0 until 5) s.onFrame(i * 1600L, frame())
        assertEquals(8000L, s.stop())
    }
}
