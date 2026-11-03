package nl.zoofit.hintmeet.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class FrameTest {
    // gemaakt met: python -c "from hint_meet.phone import encode_frame; import numpy as np;
    //   print(encode_frame(0xaa, 3, 1600, np.array([1,-1,32767,-32768], np.int16)).hex())"
    private val golden = "aa0000000000000003000000400600000100ffffff7f0080"

    @Test fun frameMatchesPython() {
        assertEquals(golden, Frame.encode(0xaaUL, 3u, 1600u, shortArrayOf(1, -1, 32767, -32768)).toHex())
    }

    @Test fun largeMeetingIdAndOffsetUseAllBits() {
        val bytes = Frame.encode(ULong.MAX_VALUE, UInt.MAX_VALUE, UInt.MAX_VALUE, shortArrayOf())
        assertEquals("ff".repeat(16), bytes.toHex())
    }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}
