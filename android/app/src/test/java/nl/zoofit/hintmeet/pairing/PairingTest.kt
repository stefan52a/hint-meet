package nl.zoofit.hintmeet.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingTest {
    private val token = "x".repeat(40)

    @Test fun parsesValidPairing() {
        assertEquals(Pairing("100.101.102.103", 8790, token), Pairing.parse("hintmeet://pair?host=100.101.102.103&port=8790&token=$token"))
    }

    @Test fun parsesMagicDnsNameAndEncodedToken() {
        val p = Pairing.parse("hintmeet://pair?host=macbook.tail1234.ts.net&port=8790&token=a%2Bb%2F$token")
        assertEquals(Pairing("macbook.tail1234.ts.net", 8790, "a+b/$token"), p)
        assertEquals("ws://macbook.tail1234.ts.net:8790/", p!!.wsUrl())
    }

    @Test fun refusesNonTailnetHostAndShortToken() {
        assertNull(Pairing.parse("hintmeet://pair?host=192.168.1.2&port=8790&token=$token"))
        assertNull(Pairing.parse("hintmeet://pair?host=100.128.0.1&port=8790&token=$token"))
        assertNull(Pairing.parse("hintmeet://pair?host=evil.example&port=8790&token=$token"))
        assertNull(Pairing.parse("hintmeet://pair?host=100.101.102.103&port=8790&token=short"))
    }

    @Test fun refusesOtherSchemesAndBadPorts() {
        assertNull(Pairing.parse("https://pair?host=100.101.102.103&port=8790&token=$token"))
        assertNull(Pairing.parse("hintmeet://other?host=100.101.102.103&port=8790&token=$token"))
        assertNull(Pairing.parse("hintmeet://pair?host=100.101.102.103&port=0&token=$token"))
        assertNull(Pairing.parse("hintmeet://pair?host=100.101.102.103&port=70000&token=$token"))
        assertNull(Pairing.parse("not a uri at all"))
    }

    @Test fun loopbackOnlyWhenAllowed() {
        val uri = "hintmeet://pair?host=127.0.0.1&port=8790&token=$token"
        assertNull(Pairing.parse(uri))
        assertEquals(Pairing("127.0.0.1", 8790, token), Pairing.parse(uri, allowLoopback = true))
    }
}
