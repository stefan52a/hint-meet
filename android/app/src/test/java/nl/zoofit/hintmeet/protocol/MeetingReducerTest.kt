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

    @Test fun searchResultsParse() {
        val r = parse("""{"type":"search_results","id":"phone-1","reranked":true,"results":[
            {"ref":"acme/lening.md","heading":"§2","snippet":"Rente 4%","path":"/x","score":0.8,"relevance":0.91,"injection":false},
            {"ref":"b.md","heading":"","snippet":"…","injection":true}]}""") as ServerMessage.SearchResults
        assertEquals("phone-1", r.id)
        assertTrue(r.reranked)
        assertEquals("lening.md", r.results[0].name)
        assertEquals(0.91, r.results[0].relevance!!, 1e-9)
        assertTrue(r.results[1].injection)
        assertNull(parseServer("""{"type":"search_results","id":3,"results":[]}"""))   // die van de Mac
        assertEquals("loading", (parse("""{"type":"search_results","id":"p","error":"loading"}""") as ServerMessage.SearchResults).error)
        assertEquals(ServerMessage.SearchStatus("p", "Loading acme…"), parse("""{"type":"search_status","id":"p","text":"Loading acme…"}"""))
    }

    @Test fun sourcePathsAndDocHitPath() {
        val h = parse("""{"type":"hint","id":1,"state":"final","text":"x","sources":[{"ref":"a/b.md","path":"/Users/s/KB/a/b.pdf"},"c.md"]}""")
            as ServerMessage.Hint
        assertEquals(listOf("a/b.md", "c.md"), h.sources)
        assertEquals(mapOf("a/b.md" to "/Users/s/KB/a/b.pdf"), h.paths)
        val c = parse("""{"type":"confirm","id":2,"text":"y","sources":[{"ref":"r","path":"/p"}]}""") as ServerMessage.Confirm
        assertEquals(mapOf("r" to "/p"), c.paths)
        val r = parse("""{"type":"search_results","id":"p","results":[{"ref":"x.md","heading":"","snippet":"s","path":"/k/x.pdf"}]}""")
            as ServerMessage.SearchResults
        assertEquals("/k/x.pdf", r.results[0].path)
    }

    @Test fun folderAndDocMessagesParse() {
        assertEquals(ServerMessage.Dirs("d", "/Users/s/projects", "/Users/s", listOf("a", "b"), null),
                     parse("""{"type":"dirs","id":"d","path":"/Users/s/projects","parent":"/Users/s","dirs":["a","b"],"home":"/Users/s"}"""))
        assertEquals(ServerMessage.Dirs("d", "/Users/s", null, emptyList(), null),
                     parse("""{"type":"dirs","id":"d","path":"/Users/s","parent":null,"dirs":[]}"""))
        assertEquals("not_allowed", (parse("""{"type":"dirs","id":"d","error":"not_allowed"}""") as ServerMessage.Dirs).error)
        assertEquals(ServerMessage.FolderAdded("a", true, "acme", null),
                     parse("""{"type":"folder_added","id":"a","ok":true,"project":"acme","error":null}"""))
        assertEquals(ServerMessage.KbTask("Adding acme", "Embeddings", 0.5, "running", null),
                     parse("""{"type":"kb_task","title":"Adding acme","step":"Embeddings","fraction":0.5,"state":"running"}"""))
        assertEquals(ServerMessage.Doc("g", "b.pdf", "application/pdf", "AAEC", null),
                     parse("""{"type":"doc","id":"g","name":"b.pdf","mime":"application/pdf","data":"AAEC"}"""))
        assertEquals("too_large", (parse("""{"type":"doc","id":"g","error":"too_large"}""") as ServerMessage.Doc).error)
        val m = nl.zoofit.hintmeet.protocol.MeetingUi()
        assertEquals(m, reduce(m, parse("""{"type":"kb_task","state":"idle"}""")!!))
    }

    @Test fun unknownMessageIsIgnored() {
        assertNull(parseServer("""{"type":"future_thing"}"""))
        assertNull(parseServer("not json"))
    }
}
