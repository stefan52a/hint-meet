package nl.zoofit.hintmeet.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import nl.zoofit.hintmeet.protocol.MeetingUi
import nl.zoofit.hintmeet.protocol.Phase
import nl.zoofit.hintmeet.protocol.ServerMessage

@Composable
fun ConnectionDot(connected: Boolean) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(10.dp).background(if (connected) Color(0xFF4CAF50) else Color(0xFF9E9E9E), CircleShape))
        Spacer(Modifier.width(8.dp))
        Text(if (connected) "Mac reachable" else "Looking for the Mac…", style = MaterialTheme.typography.bodyMedium)
    }
}

/** Voor de meeting: project(en), taal, met wie, Start. */
@Composable
fun StartScreen(
    connected: Boolean,
    gateway: ServerMessage.State?,
    projects: ServerMessage.Projects?,
    meeting: MeetingUi,
    start: (List<String>, String, String) -> Unit,
    openFind: (List<String>) -> Unit,
    unpair: () -> Unit,
) {
    var chosen by rememberSaveable { mutableStateOf<List<String>>(emptyList()) }
    var language by rememberSaveable { mutableStateOf("nl") }
    var info by rememberSaveable { mutableStateOf("") }
    var languageMenu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    var micRefused by remember { mutableStateOf(false) }
    // microfoon (en meldingen voor de opname) pas vragen bij Start: dan is duidelijk waarvoor
    val askPermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        // meldingen weigeren mag; alleen de microfoon is nodig (die kan al eerder gegeven zijn)
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            micRefused = false
            start(chosen, language, info.trim())
        } else micRefused = true
    }
    LaunchedEffect(projects) {   // eerste keer: wat op de Mac gekozen is
        if (chosen.isEmpty() && projects != null) chosen = projects.selected.filter { it in projects.items }
    }
    val busy = gateway?.busyElsewhere == true || (gateway != null && gateway.phase != "idle" && meeting.phase == Phase.IDLE)
    val starting = meeting.phase == Phase.STARTING

    Column(Modifier.fillMaxSize().padding(24.dp).verticalScroll(rememberScrollState()),
           verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("HintMeet", style = MaterialTheme.typography.headlineLarge)
        ConnectionDot(connected)
        if (busy) Text("A meeting is already running on the Mac.", color = MaterialTheme.colorScheme.error)

        Text("Projects", style = MaterialTheme.typography.titleMedium)
        if (projects == null) Text("…", style = MaterialTheme.typography.bodyMedium)
        projects?.items?.forEach { name ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = name in chosen, onCheckedChange = { on -> chosen = if (on) chosen + name else chosen - name })
                Text(name)
            }
        }

        Text("Language", style = MaterialTheme.typography.titleMedium)
        Box {
            OutlinedButton(onClick = { languageMenu = true }) {
                Text(LANGUAGES.firstOrNull { it.first == language }?.second ?: language)
            }
            DropdownMenu(expanded = languageMenu, onDismissRequest = { languageMenu = false }) {
                LANGUAGES.forEach { (code, name) ->
                    DropdownMenuItem(text = { Text(name) }, onClick = { language = code; languageMenu = false })
                }
            }
        }

        OutlinedTextField(value = info, onValueChange = { info = it }, label = { Text("With whom, where") },
                          singleLine = true, modifier = Modifier.fillMaxWidth())

        Button(onClick = {
                   // alleen vragen wat nog ontbreekt: wie "While using the app" koos, krijgt geen dialoog meer
                   val missing = buildList {
                       add(Manifest.permission.RECORD_AUDIO)
                       if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
                   }.filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }
                   if (missing.isEmpty()) start(chosen, language, info.trim())
                   else askPermissions.launch(missing.toTypedArray())
               },
               enabled = connected && chosen.isNotEmpty() && !busy && !starting,
               modifier = Modifier.fillMaxWidth()) { Text(if (starting) "Starting…" else "Start Meeting") }
        if (starting) Text(meeting.status ?: "Starting the pipeline on the Mac…", style = MaterialTheme.typography.bodyMedium)
        OutlinedButton(onClick = { openFind(chosen) }, enabled = connected && chosen.isNotEmpty() && !busy && !starting,
                       modifier = Modifier.fillMaxWidth()) { Text("Find in Documents…") }
        if (micRefused) Text("HintMeet needs the microphone to record the meeting (Android settings → Apps → HintMeet).",
                             color = MaterialTheme.colorScheme.error)

        Spacer(Modifier.size(24.dp))
        TextButton(onClick = unpair) { Text("Unpair this phone") }
    }
}
