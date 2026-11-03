package nl.zoofit.hintmeet.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MeetingReducerTest {
    private fun running() = MeetingUi(phase = Phase.RUNNING, meeting = "00000000000000aa")

    private fun parse(json: String) = parseServer(json) ?: error("not parsed: $json")

    @Test fun streamingHintIsReplacedByFinal() {
        var ui = running()
        ui = reduce(ui, parse("""{"type":"hint","id":5,"state":"streaming","text":"Ren"}"""))
        ui = reduce(ui, parse("""{"type":"hint","id":5,"state":"final","text":"Rente 3%.","sources":[{"ref":"Lening §2","path":"/x"}]}"""))
        assertEquals(1, ui.hints.size)
        assertEquals("Rente 3%.", ui.hints[0].text)
        assertEquals(listOf("Lening §2"), ui.hints[0].sources)
        assertTrue(ui.hints[0].final)
    }

    @Test fun retractedHintIsStruckThrough() {
        var ui = running()
        ui = reduce(ui, parse("""{"type":"hint","id":2,"state":"streaming","text":"Misschien"}"""))
        ui = reduce(ui, parse("""{"type":"hint","id":2,"state":"retracted","text":"","reason":"No source"}"""))
        assertTrue(ui.hints[0].struck)
        assertEquals("Misschien", ui.hints[0].text)
        assertEquals("No source", ui.hints[0].reason)
    }

    @Test fun stoppedFromMacEndsMeetingWithoutAlarm() {
        val ui = reduce(running(), parse("""{"type":"stopped"}"""))
        assertEquals(Phase.ENDED, ui.phase)
        assertEquals(StoppedBy.MAC, ui.stoppedBy)
    }

    @Test fun stoppedAfterOwnStopIsThePhone() {
        val ui = reduce(markStopSent(running()), parse("""{"type":"stopped"}"""))
        assertEquals(StoppedBy.PHONE, ui.stoppedBy)
    }

    @Test fun stateWithLastBringsTheReportAfterReopening() {
        val ui = reduce(MeetingUi(), parse(
            """{"type":"state","phase":"idle","meeting":null,"started_at_ms":null,"now_ms":1,"busy_elsewhere":false,
               "last":{"meeting":"00000000000000aa","stopped_by":"watchdog","report_md":"# Verslag"}}"""))
        assertEquals(Phase.ENDED, ui.phase)
        assertEquals(StoppedBy.WATCHDOG, ui.stoppedBy)
        assertEquals("# Verslag", ui.report)
    }

    @Test fun idleWithoutResultWhileRunningIsUnexpected() {
        val ui = reduce(running(), parse(
            """{"type":"state","phase":"idle","meeting":null,"started_at_ms":null,"now_ms":1,"busy_elsewhere":false,"last":null}"""))
        assertEquals(Phase.ENDED, ui.phase)
        assertEquals(StoppedBy.UNEXPECTED, ui.stoppedBy)
    }

    @Test fun helloStartsAFreshReplay() {
        var ui = running()
        ui = reduce(ui, parse("""{"type":"utterance","id":0,"time":"00:01","speaker":"Unknown","text":"hoi"}"""))
        ui = reduce(ui, parse("""{"type":"hello","project":"acme","version":1}"""))
        ui = reduce(ui, parse("""{"type":"utterance","id":0,"time":"00:01","speaker":"Unknown","text":"hoi"}"""))
        assertEquals(1, ui.transcript.size)
    }

    @Test fun parsesAudioAndStateMessages() {
        val ack = parse("""{"type":"audio_ack","meeting":"00000000000000aa","offset":3200}""") as ServerMessage.AudioAck
        assertEquals(3200L, ack.offset)
        val ready = parse("""{"type":"audio_ready","meeting":"00000000000000aa","started_at_ms":1793704487965}""")
            as ServerMessage.AudioReady
        assertEquals(1793704487965L, ready.startedAtMs)
        val progress = parse("""{"type":"progress","heard_s":12.5,"processed_s":10.0}""") as ServerMessage.Progress
        assertEquals(12.5, progress.heardS, 0.0)
    }

    @Test fun unknownMessageIsIgnored() {
        assertNull(parseServer("""{"type":"future_thing"}"""))
        assertNull(parseServer("not json"))
    }
}
