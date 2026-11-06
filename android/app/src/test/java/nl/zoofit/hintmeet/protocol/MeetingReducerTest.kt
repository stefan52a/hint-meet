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

    private fun state(phase: String, meeting: String?, last: String = "null") = parse(
        """{"type":"state","phase":"$phase","meeting":${meeting?.let { "\"$it\"" } ?: "null"},"started_at_ms":1,"now_ms":2,
           "busy_elsewhere":false,"last":$last}""")

    @Test fun nextMeetingStartsClean() {
        var ui = markStopSent(running())
        ui = reduce(ui, parse("""{"type":"summary","markdown":"# A"}"""))
        ui = reduce(ui, state("running", "00000000000000bb"))
        assertEquals(Phase.RUNNING, ui.phase)
        assertNull(ui.report)
        assertEquals(false, ui.localStopSent)
    }

    @Test fun unknownOrMissingPhaseKeepsTheMeeting() {
        assertEquals(Phase.RUNNING, reduce(running(), state("paused", "00000000000000aa")).phase)
        assertNull(parseServer("""{"type":"state","meeting":null,"now_ms":1,"busy_elsewhere":false,"last":null}"""))
    }

    @Test fun cleanStopWinsOverUnexpected() {
        var ui = reduce(running(), state("idle", null))
        assertEquals(StoppedBy.UNEXPECTED, ui.stoppedBy)
        ui = reduce(ui, parse("""{"type":"stopped"}"""))
        assertEquals(StoppedBy.MAC, ui.stoppedBy)
    }

    @Test fun endWithoutReportIsFinal() {
        var ui = reduce(running(), parse("""{"type":"stopped"}"""))
        assertEquals(false, ui.pipelineDone)                      // verslag kan nog komen
        ui = reduce(ui, state("idle", null, """{"meeting":"00000000000000aa","stopped_by":"user","report_md":null}"""))
        assertTrue(ui.pipelineDone)
        assertNull(ui.report)
    }

    @Test fun ratingIsRememberedPerHint() {
        val ui = rate(running(), 5, 1)
        assertEquals(1, ui.ratings[5])
    }

    @Test fun backedByTheKnowledgeBase() {
        var ui = running()
        val msg = """{"type":"confirm","id":4,"text":"Rente 5,5% klopt","kind":"confirms","sources":[{"ref":"Lening §2","path":"/x"}]}"""
        ui = reduce(ui, parse(msg))
        ui = reduce(ui, parse(msg))                               // opnieuw afgespeeld: niet dubbel
        ui = reduce(ui, parse("""{"type":"confirm","id":5,"text":"Het dossier noemt 2027","kind":"about","sources":[]}"""))
        assertEquals(2, ui.backed.size)
        assertTrue(ui.backed[0].confirms)
        assertEquals(listOf("Lening §2"), ui.backed[0].sources)
        assertEquals(false, ui.backed[1].confirms)
    }

    @Test fun saidParsesAndLeavesMeetingAlone() {
        val said = parse("""{"type":"said","say_id":"x1","ok":true,"session":"s"}""")
        assertEquals(ServerMessage.Said("x1", true), said)
        assertEquals(ServerMessage.Said("x2", false), parse("""{"type":"said","say_id":"x2","ok":false}"""))
        assertNull(parseServer("""{"type":"said","ok":true}"""))
        val ui = MeetingUi()
        assertEquals(ui, reduce(ui, said))
    }

    @Test fun unknownMessageIsIgnored() {
        assertNull(parseServer("""{"type":"future_thing"}"""))
        assertNull(parseServer("not json"))
    }
}
