package nl.zoofit.hintmeet.health

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AlarmsTest {
    private val now = 10_000_000L
    private val ok = Health(capturing = true, lastLevelAtMs = now, connectedSinceMs = now - 1000, lastDisconnectMs = null,
                            ackedS = 100.0, heardS = 100.0, processedS = 99.0, lagShrinking = false, bufferFill = 0.0,
                            droppedS = 0.0, batteryPct = 80, charging = false, macPhase = "running", localStopSent = false)

    @Test fun healthyMeetingHasNoAlarms() { assertTrue(alarms(ok, now).isEmpty()) }

    @Test fun connectionLostAfter30s() {
        assertTrue(Alarm.CONNECTION_LOST in alarms(ok.copy(connectedSinceMs = null, lastDisconnectMs = now - 31_000), now))
        assertFalse(Alarm.CONNECTION_LOST in alarms(ok.copy(connectedSinceMs = null, lastDisconnectMs = now - 29_000), now))
    }

    @Test fun bufferHalfFull() { assertTrue(Alarm.BUFFER_HALF_FULL in alarms(ok.copy(bufferFill = 0.51), now)) }

    @Test fun transcriptionBehind60s() {
        assertTrue(Alarm.TRANSCRIPTION_BEHIND in alarms(ok.copy(heardS = 200.0, processedS = 139.0), now))
        assertFalse(Alarm.TRANSCRIPTION_BEHIND in alarms(ok.copy(heardS = 200.0, processedS = 141.0), now))
    }

    @Test fun catchingUpIsNotAnAlarm() {
        assertFalse(Alarm.TRANSCRIPTION_BEHIND in alarms(ok.copy(heardS = 200.0, processedS = 139.0, lagShrinking = true), now))
    }

    @Test fun batteryLowOnlyWhenNotCharging() {
        assertTrue(Alarm.BATTERY_LOW in alarms(ok.copy(batteryPct = 14), now))
        assertFalse(Alarm.BATTERY_LOW in alarms(ok.copy(batteryPct = 14, charging = true), now))
    }

    @Test fun macGoneWhileRecordingRaisesAlarm() {
        assertTrue(Alarm.MAC_STOPPED in alarms(ok.copy(macPhase = "idle"), now))
        assertFalse(Alarm.MAC_STOPPED in alarms(ok.copy(macPhase = "idle", localStopSent = true), now))
        assertFalse(Alarm.MAC_STOPPED in alarms(ok.copy(macPhase = "idle", capturing = false), now))
    }

    @Test fun lostAudioAndSilentMic() {
        assertTrue(Alarm.AUDIO_LOST in alarms(ok.copy(droppedS = 1.0), now))
        assertTrue(Alarm.MIC_SILENT in alarms(ok.copy(lastLevelAtMs = now - 121_000), now))
        assertFalse(Alarm.MIC_SILENT in alarms(ok.copy(lastLevelAtMs = now - 60_000), now))
    }

    @Test fun lagShrinksWhenSmallerThan15sAgo() {
        val history = LagHistory()
        history.add(0, heard = 100.0, processed = 20.0)        // 80 s achter
        history.add(10_000, heard = 110.0, processed = 40.0)   // 70 s
        assertFalse(history.shrinking(10_000))                 // nog geen meting van 15 s geleden
        history.add(16_000, heard = 116.0, processed = 50.0)   // 66 s < 80 s
        assertTrue(history.shrinking(16_000))
        history.add(32_000, heard = 132.0, processed = 60.0)   // 72 s > 66 s (16 s geleden)
        assertFalse(history.shrinking(32_000))
    }
}
