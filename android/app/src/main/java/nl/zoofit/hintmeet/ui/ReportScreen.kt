package nl.zoofit.hintmeet.ui

import android.content.Intent
import android.widget.TextView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.Markwon
import nl.zoofit.hintmeet.protocol.MeetingUi
import nl.zoofit.hintmeet.protocol.StoppedBy

@Composable
fun ReportScreen(meeting: MeetingUi, done: () -> Unit) {
    val context = LocalContext.current
    val markwon = remember { Markwon.create(context) }
    val textColor = MaterialTheme.colorScheme.onBackground.toArgb()
    Column(Modifier.fillMaxSize().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(when (meeting.stoppedBy) {
            StoppedBy.MAC -> "Stopped on the Mac"
            StoppedBy.WATCHDOG -> "Stopped: no audio from the phone for 30 minutes"
            StoppedBy.UNEXPECTED -> "The Mac stopped unexpectedly"
            else -> "Meeting ended"
        }, style = MaterialTheme.typography.titleLarge,
             color = if (meeting.stoppedBy == StoppedBy.UNEXPECTED) MaterialTheme.colorScheme.error
                     else MaterialTheme.colorScheme.onBackground)
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            val report = meeting.report
            when {
                report != null -> AndroidView(
                    factory = { TextView(it).apply { setTextColor(textColor); textSize = 17f } },
                    update = { markwon.setMarkdown(it, report) },
                    modifier = Modifier.fillMaxWidth())
                meeting.stoppedBy == StoppedBy.UNEXPECTED ->
                    Text("No report: the pipeline on the Mac ended before it could write one. The transcript up to "
                         + "that moment is on the Mac in logs/.", style = MaterialTheme.typography.bodyLarge)
                else -> Text("Writing the report…", style = MaterialTheme.typography.bodyLarge)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            meeting.report?.let { md ->
                OutlinedButton(onClick = {
                    val share = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, md)
                    context.startActivity(Intent.createChooser(share, "Share report"))
                }) { Text("Share") }
            }
            Button(onClick = done) { Text("Done") }
        }
    }
}
