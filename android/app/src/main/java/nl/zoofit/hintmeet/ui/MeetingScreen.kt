package nl.zoofit.hintmeet.ui

import android.app.Activity
import android.view.WindowManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.Hearing
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.RecordVoiceOver
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.automirrored.outlined.Subject
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.FilledIconButton
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import nl.zoofit.hintmeet.health.Alarm
import nl.zoofit.hintmeet.protocol.MeetingUi
import nl.zoofit.hintmeet.session.Liveness
import nl.zoofit.hintmeet.session.SayState
import nl.zoofit.hintmeet.session.FindUi
import nl.zoofit.hintmeet.protocol.DocHit
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
    liveness: Liveness?,
    alarms: Set<Alarm>,
    feedback: (Int, Int) -> Unit,
    sayState: SayState,
    say: (String) -> String?,
    clearSayError: () -> Unit,
    find: FindUi,
    search: (String) -> Unit,
    stop: () -> Unit,
) {
    KeepScreenOn()
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var confirmStop by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        StatusBar(connected, startedAtMs, meeting.status, stopping = meeting.phase == Phase.STOPPING,
                  liveness = liveness, alarms = alarms)
        TabRow(selectedTabIndex = tab, containerColor = MaterialTheme.colorScheme.background) {
            val count = { n: Int -> if (n > 0) " $n" else "" }
            Tab(selected = tab == 0, onClick = { tab = 0 }, selectedContentColor = MaterialTheme.colorScheme.primary,
                unselectedContentColor = MaterialTheme.colorScheme.onSurfaceVariant, text = { Text("Hints" + count(meeting.hints.size), maxLines = 1) },
                icon = { Icon(Icons.Outlined.Lightbulb, null) })
            Tab(selected = tab == 1, onClick = { tab = 1 }, selectedContentColor = MaterialTheme.colorScheme.primary,
                unselectedContentColor = MaterialTheme.colorScheme.onSurfaceVariant, text = { Text("Backed", maxLines = 1) },
                icon = { Icon(Icons.Outlined.Verified, null) })
            Tab(selected = tab == 2, onClick = { tab = 2 }, selectedContentColor = MaterialTheme.colorScheme.primary,
                unselectedContentColor = MaterialTheme.colorScheme.onSurfaceVariant, text = { Text("Transcript", maxLines = 1) },
                icon = { Icon(Icons.AutoMirrored.Outlined.Subject, null) })
            Tab(selected = tab == 3, onClick = { tab = 3 }, selectedContentColor = MaterialTheme.colorScheme.primary,
                unselectedContentColor = MaterialTheme.colorScheme.onSurfaceVariant, text = { Text("Find", maxLines = 1) },
                icon = { Icon(Icons.Outlined.Search, null) })
        }
        Box(Modifier.weight(1f)) {
            when (tab) {
                0 -> Hints(meeting, feedback)
                1 -> Backed(meeting)
                2 -> Transcript(meeting)
                else -> Find(find, enabled = meeting.phase == Phase.RUNNING, search = { search(it) },
                             intro = "Find a document by what it says, in the knowledge base of this meeting.")
            }
        }
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 16.dp, top = 8.dp, bottom = 16.dp),
            verticalAlignment = Alignment.CenterVertically) {
            SayField(meeting.phase == Phase.RUNNING, sayState, say, clearSayError, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            Button(onClick = { confirmStop = true }, enabled = meeting.phase == Phase.RUNNING,
                   modifier = Modifier.padding(bottom = if (sayState is SayState.Failed || sayState is SayState.Sending) 20.dp else 0.dp),
                   colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFC62828), contentColor = Color.White)) {
                Icon(Icons.Filled.Stop, null, Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text(if (meeting.phase == Phase.STOPPING) "Stopping…" else "Stop")
            }
        }
    }
    if (confirmStop) {
        AlertDialog(
            onDismissRequest = { confirmStop = false },
            icon = { Icon(Icons.Filled.Stop, null) },
            title = { Text("Stop the meeting?") },
            text = { Text("HintMeet stops listening and writes the report.") },
            confirmButton = { TextButton(onClick = { confirmStop = false; stop() }) { Text("Stop") } },
            dismissButton = { TextButton(onClick = { confirmStop = false }) { Text("Keep going") } },
        )
    }
}

/** Typen alsof je het zei, zoals onderaan het transcript op de Mac: de Mac verwerkt het als een uitspraak van jou.
 *  De tekst gaat pas weg als de Mac hem bevestigt; anders blijft hij staan met de reden eronder. */
@Composable
private fun SayField(enabled: Boolean, state: SayState, say: (String) -> String?, clearError: () -> Unit,
                     modifier: Modifier = Modifier) {
    var text by rememberSaveable { mutableStateOf("") }
    var waitingFor by rememberSaveable { mutableStateOf<String?>(null) }   // say_id van de verstuurde tekst
    var sentText by rememberSaveable { mutableStateOf("") }
    // alleen de bevestiging van precies deze tekst wist het veld, en niet als je intussen iets anders typte
    LaunchedEffect(state, waitingFor) {
        if (state is SayState.Sent && state.id == waitingFor) {
            if (text.trim() == sentText) text = ""
            waitingFor = null
        }
    }
    val sending = state is SayState.Sending
    val send = { if (text.isNotBlank() && !sending) say(text)?.let { waitingFor = it; sentText = text.trim() } }
    OutlinedTextField(
        value = text,
        onValueChange = { text = it; clearError() },
        enabled = enabled && !sending,
        modifier = modifier,
        shape = MaterialTheme.shapes.large,
        placeholder = { Text(if (enabled) "Type as if you said it…" else "Typing works while the meeting is listening") },
        singleLine = true,
        isError = state is SayState.Failed,
        supportingText = when (state) {
            is SayState.Sending -> ({ Text("Sending to the Mac…") })
            is SayState.Failed -> ({ Text(state.reason) })
            is SayState.Idle, is SayState.Sent -> null
        },
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(onSend = { send() }),
        trailingIcon = {
            IconButton(onClick = send, enabled = enabled && !sending && text.isNotBlank()) {
                Icon(Icons.AutoMirrored.Filled.Send, "Add to the transcript as if you said it",
                     tint = if (enabled && text.isNotBlank()) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        },
    )
}

@Composable
private fun Hints(meeting: MeetingUi, feedback: (Int, Int) -> Unit) {
    val hints = meeting.hints
    if (hints.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            EmptyState(Icons.Outlined.Hearing, if (meeting.phase == Phase.STARTING) "Starting…" else "Listening… hints appear here.")
        }
        return
    }
    val pager = rememberPagerState(initialPage = hints.size - 1) { hints.size }   // openen bij de nieuwste
    val scope = rememberCoroutineScope()
    var lastCount by remember { mutableIntStateOf(hints.size) }
    // een nieuwe hint: alleen meespringen als je al bij de nieuwste was (terugbladeren wordt niet onderbroken)
    LaunchedEffect(hints.size) {
        if (hints.size > lastCount && pager.currentPage >= lastCount - 1) pager.animateScrollToPage(hints.size - 1)
        lastCount = hints.size
    }
    Column(Modifier.fillMaxSize()) {
        HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { page ->
            HintCard(hints[page], meeting.ratings[hints[page].id] ?: 0, feedback)
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = { scope.launch { pager.animateScrollToPage(pager.currentPage - 1) } },
                       enabled = pager.currentPage > 0) { Icon(Icons.Filled.ChevronLeft, "Previous hint") }
            Text("${pager.currentPage + 1} / ${hints.size}", Modifier.weight(1f),
                 style = MaterialTheme.typography.bodyMedium, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            IconButton(onClick = { scope.launch { pager.animateScrollToPage(pager.currentPage + 1) } },
                       enabled = pager.currentPage < hints.size - 1) { Icon(Icons.Filled.ChevronRight, "Next hint") }
        }
    }
}

/** Nieuwe regels scrollen altijd mee, behalve tot 10 s nadat je zelf omhoog scrolde (rustig teruglezen). */
@Composable
private fun FollowNewest(list: androidx.compose.foundation.lazy.LazyListState, size: Int) {
    var holdUntil by remember { mutableStateOf(0L) }
    var auto by remember { mutableStateOf(false) }
    LaunchedEffect(list) {
        androidx.compose.runtime.snapshotFlow { list.isScrollInProgress }.collect { scrolling ->
            if (scrolling && !auto) {   // jouw vinger, niet ons eigen meescrollen
                val atBottom = !list.canScrollForward
                holdUntil = if (atBottom) 0L else System.currentTimeMillis() + 10_000
            }
        }
    }
    LaunchedEffect(list) {   // na het slepen: onderaan losgelaten = meteen weer volgen
        androidx.compose.runtime.snapshotFlow { list.canScrollForward }.collect { more ->
            if (!more && !auto) holdUntil = 0L
        }
    }
    LaunchedEffect(size) {
        if (size > 0 && System.currentTimeMillis() >= holdUntil) {
            auto = true
            try { list.animateScrollToItem(size - 1) } finally { auto = false }
        }
    }
}

/** "Backed by the knowledge base", zoals de linkerkolom op de Mac: ✓ klopt met het dossier, 📄 wat het dossier zegt. */
@Composable
private fun Backed(meeting: MeetingUi) {
    if (meeting.backed.isEmpty()) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            EmptyState(Icons.Outlined.Verified, "What was said and matches your documents appears here.")
        }
        return
    }
    val list = rememberLazyListState(initialFirstVisibleItemIndex = meeting.backed.size - 1)
    FollowNewest(list, meeting.backed.size)
    val times = meeting.transcript.associate { it.id to it.time }
    LazyColumn(state = list, modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        items(meeting.backed, key = { "${it.id}-${it.text.hashCode()}" }) { b -> Column {
            Row(Modifier.padding(vertical = 10.dp)) {
                // ✓ klopt met het dossier, 📄 wat het dossier erover zegt
                Icon(if (b.confirms) Icons.Filled.CheckCircle else Icons.Outlined.Description, null,
                     Modifier.padding(top = 3.dp, end = 12.dp).size(20.dp),
                     tint = if (b.confirms) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.secondary)
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    SelectionContainer {   // lang drukken: selecteren en kopiëren
                        Text(b.text, style = MaterialTheme.typography.bodyLarge)
                    }
                    times[b.id]?.let { Text(it, style = MaterialTheme.typography.labelMedium,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    SourceLinks(b.sources)   // tik: het document van de Mac
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
        } }
    }
}

@Composable
private fun Transcript(meeting: MeetingUi) {
    val list = rememberLazyListState(initialFirstVisibleItemIndex = (meeting.transcript.size - 1).coerceAtLeast(0))
    FollowNewest(list, meeting.transcript.size)
    LazyColumn(state = list, modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp)) {
        items(meeting.transcript, key = { it.id }) { line ->
            SelectionContainer { Column(Modifier.padding(vertical = 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).background(speakerColor(line.speaker), CircleShape))
                    Text("  ${line.speaker}", style = MaterialTheme.typography.labelLarge, color = speakerColor(line.speaker))
                    Text("  ${line.time}", style = MaterialTheme.typography.labelMedium,
                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(line.text, style = MaterialTheme.typography.bodyLarge)
            } }
        }
    }
}

/** Vaste kleur per spreker, zodat je in het transcript snel ziet wie wat zei. */
private val speakerColors = listOf(Color(0xFFFFC94D), Color(0xFF8FB8FF), Color(0xFF7FD99A), Color(0xFFF4A7C4),
                                   Color(0xFFB5A3FF), Color(0xFFFFAB76))

private fun speakerColor(name: String): Color = speakerColors[Math.floorMod(name.hashCode(), speakerColors.size)]
