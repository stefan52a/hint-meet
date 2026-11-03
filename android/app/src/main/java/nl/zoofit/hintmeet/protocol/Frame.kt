package nl.zoofit.hintmeet.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Audioframe naar de Mac, byte voor byte gelijk aan `phone.encode_frame` in Python:
 *  little-endian uint64 meeting, uint32 seq, uint32 offset (sample-index), daarna PCM16-samples. */
object Frame {
    const val HEADER = 16
    const val RATE_HZ = 16_000

    fun encode(meeting: ULong, seq: UInt, offset: UInt, pcm: ShortArray): ByteArray {
        val buf = ByteBuffer.allocate(HEADER + pcm.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        buf.putLong(meeting.toLong())
        buf.putInt(seq.toInt())
        buf.putInt(offset.toInt())
        for (s in pcm) buf.putShort(s)
        return buf.array()
    }
}
