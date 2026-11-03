package nl.zoofit.hintmeet.ui

import android.app.Activity
import android.view.WindowManager
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Tab
import androidx.compose.material3.TabRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import nl.zoofit.hintmeet.protocol.MeetingUi
import nl.zoofit.hintmeet.protocol.Phase

/** Scherm aan zolang de meeting loopt (de telefoon ligt op tafel). */
@Composable
fun KeepScreenOn() {
    val activity = LocalContext.current as? Activity
    DisposableEffect(activity) {
        activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        onDispose { activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }
}

@Composable
fun MeetingScreen(
    meeting: MeetingUi,
    connected: Boolean,
    startedAtMs: Long?,
    feedback: (Int, Int) -> Unit,
    stop: () -> Unit,
) {
    KeepScreenOn()
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var confirmStop by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        StatusBar(connected, startedAtMs, meeting.status)
        TabRow(selectedTabIndex = tab) {
            Tab(selected = tab == 0, onClick = { tab = 0 }, text = { Text("Hints") })
            Tab(selected = tab == 1, onClick = { tab = 1 }, text = { Text("Transcript") })
        }
        Box(Modifier.weight(1f)) {
            if (tab == 0) Hints(meeting, feedback) else Transcript(meeting)
        }
        Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = androidx.compose.foundation.layout.Arrangement.End) {
            Button(onClick = { confirmStop = true }, enabled = meeting.phase == Phase.RUNNING,
                   colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFC62828), contentColor = Color.White)) {
                Text(if (meeting.phase == Phase.STOPPING) "Stopping…" else "Stop")
            }
        }
    }
    if (confirmStop) {
        AlertDialog(
            onDismissRequest = { confirmStop = false },
            title = { Text("Stop the meeting?") },
            text = { Text("HintMeet stops listening and writes the report.") },
            confirmButton = { TextButton(onClick = { confirmStop = false; stop() }) { Text("Stop") } },
            dismissButton = { TextButton(onClick = { confirmStop = false }) { Text("Keep going") } },
        )
    }
}

@Composable
private fun Hints(meeting: MeetingUi, feedback: (Int, Int) -> Unit) {
    val hints = meeting.hints
    if (hints.isEmpty()) {
        Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(if (meeting.phase == Phase.STARTING) "Starting…" else "Listening… hints appear here.",
                 style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        return
    }
    val pager = rememberPagerState { hints.size }
    val scope = rememberCoroutineScope()
    var lastCount by remember { mutableIntStateOf(hints.size) }
    // een nieuwe hint: alleen meespringen als je al bij de nieuwste was (terugbladeren wordt niet onderbroken)
    LaunchedEffect(hints.size) {
        if (hints.size > lastCount && pager.currentPage >= lastCount - 1) pager.animateScrollToPage(hints.size - 1)
        lastCount = hints.size
    }
    Column(Modifier.fillMaxSize()) {
        HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { page -> HintCard(hints[page], feedback) }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { scope.launch { pager.animateScrollToPage(pager.currentPage - 1) } },
                       enabled = pager.currentPage > 0) { Text("◀") }
            Text("${pager.currentPage + 1} / ${hints.size}", Modifier.weight(1f),
                 style = MaterialTheme.typography.bodyMedium, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            TextButton(onClick = { scope.launch { pager.animateScrollToPage(pager.currentPage + 1) } },
                       enabled = pager.currentPage < hints.size - 1) { Text("▶") }
        }
    }
}

@Composable
private fun Transcript(meeting: MeetingUi) {
    val list = rememberLazyListState()
    LaunchedEffect(meeting.transcript.size) {
        if (meeting.transcript.isNotEmpty()) list.animateScrollToItem(meeting.transcript.size - 1)
    }
    LazyColumn(state = list, modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        items(meeting.transcript, key = { it.id }) { line ->
            Column(Modifier.padding(vertical = 6.dp)) {
                Text("${line.time}  ${line.speaker}", style = MaterialTheme.typography.labelMedium,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(line.text, style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}
