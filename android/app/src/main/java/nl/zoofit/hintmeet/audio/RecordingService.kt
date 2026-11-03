package nl.zoofit.hintmeet.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.IBinder
import android.os.PowerManager
import nl.zoofit.hintmeet.MainActivity
import nl.zoofit.hintmeet.session.Session
import kotlin.math.abs

/** Neemt de meeting op (16 kHz mono PCM16, frames van 100 ms) als voorgronddienst van het type microphone: loopt
 *  door met het scherm uit. De offset van elk frame = startoffset (klok van de Mac) + het aantal gelezen samples. */
class RecordingService : Service() {
    @Volatile private var running = false
    private var thread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (running) return START_NOT_STICKY
        val initial = intent?.getLongExtra(EXTRA_OFFSET, 0L) ?: 0L
        try {
            startForeground(NOTIFICATION_ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } catch (e: Exception) {   // bv. microfoonrecht ingetrokken, of de app niet op de voorgrond
            Session.onRecorderFailed(e.message ?: "the microphone isn't available")
            stopSelf()
            return START_NOT_STICKY
        }
        wakeLock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "HintMeet:recording").apply { acquire(4 * 60 * 60 * 1000L) }
        running = true
        thread = Thread({ record(initial) }, "hintmeet-recording").apply { start() }
        return START_NOT_STICKY   // na een crash sluit de app zelf weer aan (Session.rejoinIfNeeded)
    }

    private fun open(source: Int): AudioRecord? = try {
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        AudioRecord(source, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(min, FRAME * 2 * 4))
            .takeIf { it.state == AudioRecord.STATE_INITIALIZED }
    } catch (e: SecurityException) {
        null
    }

    private fun record(initial: Long) {
        val rec = open(MediaRecorder.AudioSource.VOICE_RECOGNITION) ?: open(MediaRecorder.AudioSource.MIC)
        if (rec == null) {
            running = false
            Session.onRecorderFailed("the microphone couldn't be opened")
            stopSelf()
            return
        }
        val buf = ShortArray(FRAME)
        var samples = 0L
        var failed = false
        try {
            rec.startRecording()
            while (running) {
                var filled = 0
                while (filled < FRAME && running) {
                    val n = rec.read(buf, filled, FRAME - filled)
                    if (n < 0) {
                        Session.onRecorderFailed("the microphone stopped delivering audio ($n)")
                        failed = true
                        running = false
                        break
                    }
                    filled += n
                }
                if (filled < FRAME) break
                var peak = 0
                for (s in buf) peak = maxOf(peak, abs(s.toInt()))
                Session.onCaptured(initial + samples, buf, peak)   // Streamer kopieert het frame
                samples += FRAME
            }
        } catch (e: Exception) {
            Session.onRecorderFailed(e.message ?: e.javaClass.simpleName)
            failed = true
        } finally {
            try { rec.stop() } catch (_: Exception) {}
            rec.release()
            if (failed) { running = false; stopSelf() }   // fout tijdens de opname: dienst en wake lock weg
        }
    }

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Meeting recording", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java),
                                             PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("HintMeet is recording")
            .setContentText("The meeting goes to your Mac; hints appear in the app.")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setUsesChronometer(true)
            .setWhen(System.currentTimeMillis())
            .setContentIntent(open)
            .build()
    }

    override fun onDestroy() {
        running = false
        thread?.join(1000)
        wakeLock?.takeIf { it.isHeld }?.release()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_OFFSET = "offset"
        const val RATE = 16_000
        const val FRAME = 1600
        private const val CHANNEL = "recording"
        private const val NOTIFICATION_ID = 1
    }
}
