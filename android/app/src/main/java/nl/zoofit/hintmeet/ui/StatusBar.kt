package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import nl.zoofit.hintmeet.health.Alarm
import nl.zoofit.hintmeet.session.Liveness

/** Bovenbalk tijdens de meeting: REC met de tijd, verbinding met de Mac, en wat de Mac doet.
 *  De gezondheid van de opname (Task 11) komt er later bij. */
@Composable
fun StatusBar(connected: Boolean, startedAtMs: Long?, status: String?, stopping: Boolean = false,
              liveness: Liveness? = null, alarms: Set<Alarm> = emptySet(), modifier: Modifier = Modifier) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }
    Row(modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        val rec = if (stopping) Color(0xFF9E9E9E) else Color(0xFFE53935)
        Row(Modifier.background(rec.copy(alpha = 0.16f), CircleShape).padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(10.dp).background(rec, if (stopping) RoundedCornerShape(2.dp) else CircleShape))
            Text((if (stopping) "  Stopping  " else "  REC  ") + (startedAtMs?.let { elapsed(now - it) } ?: "--:--"),
                 color = rec, style = MaterialTheme.typography.titleMedium)
        }
        ConnectionDot(connected)
    }
    status?.let {   // wat de Mac doet: eigen regel, zodat hij niet wordt afgekapt naast de tijd
        Text(it, Modifier.fillMaxWidth().padding(horizontal = 20.dp), style = MaterialTheme.typography.bodySmall,
             maxLines = 2, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    liveness?.let { l ->   // drie stippen: neemt op · Mac ontvangt · Mac verwerkt
        Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Dot("Recording", l.capturedAgoS, okWithin = 3)
            Dot("Mac received", l.ackedAgoS, okWithin = 5)
            Dot("Transcribed", l.processedAgoS, okWithin = 90)
        }
    }
    if (alarms.isNotEmpty()) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp)
                   .background(Color(0xFFB71C1C), RoundedCornerShape(8.dp)).padding(12.dp)) {
            alarms.forEach { Text(it.text, color = Color.White, style = MaterialTheme.typography.bodyMedium) }
        }
    }
}

@Composable
private fun Dot(label: String, agoS: Long?, okWithin: Long) {
    val color = when {
        agoS == null -> Color(0xFF616161)
        agoS <= okWithin -> Color(0xFF4CAF50)
        else -> Color(0xFFFFA000)
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Text(" $label" + (agoS?.let { if (it > okWithin) " ${it}s ago" else "" } ?: ""),
             style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

fun elapsed(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60)
}
