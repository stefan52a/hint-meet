package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.layout.Arrangement
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

/** Bovenbalk tijdens de meeting: REC met de tijd, verbinding met de Mac, en wat de Mac doet.
 *  De gezondheid van de opname (Task 11) komt er later bij. */
@Composable
fun StatusBar(connected: Boolean, startedAtMs: Long?, status: String?, stopping: Boolean = false,
              modifier: Modifier = Modifier) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1000)
            now = System.currentTimeMillis()
        }
    }
    Row(modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Text((if (stopping) "■ Stopping " else "● REC ") + (startedAtMs?.let { elapsed(now - it) } ?: "--:--"),
             color = if (stopping) Color(0xFF9E9E9E) else Color(0xFFE53935), style = MaterialTheme.typography.titleMedium)
        ConnectionDot(connected)
        status?.let { Text(it, style = MaterialTheme.typography.bodySmall, maxLines = 1,
                           color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

fun elapsed(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60)
}
