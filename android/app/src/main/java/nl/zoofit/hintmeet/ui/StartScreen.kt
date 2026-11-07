package nl.zoofit.hintmeet.ui

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import nl.zoofit.hintmeet.protocol.MeetingUi
import nl.zoofit.hintmeet.protocol.Phase
import nl.zoofit.hintmeet.protocol.ServerMessage

/** Verbinding met de Mac als een klein label met een stip. */
@Composable
fun ConnectionDot(connected: Boolean) {
    Row(Modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh, CircleShape).padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).background(if (connected) Color(0xFF4CAF50) else Color(0xFF9E9E9E), CircleShape))
        Spacer(Modifier.width(6.dp))
        Text(if (connected) "Mac connected" else "Looking for the Mac…", style = MaterialTheme.typography.labelMedium,
             color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Voor de meeting: project(en), taal, met wie, Start. */
@Composable
fun StartScreen(
    connected: Boolean,
    gateway: ServerMessage.State?,
    projects: ServerMessage.Projects?,
    meeting: MeetingUi,
    kbTask: ServerMessage.KbTask?,
    /** Project waarin de Mac een vanaf de telefoon toegevoegde map omzet (om het meteen aan te vinken). */
    added: String?,
    /** Project dat de Mac nu verwijdert. */
    removing: String?,
    start: (List<String>, String, String) -> Unit,
    openFind: (List<String>) -> Unit,
    addFolder: () -> Unit,
    removeProject: (String) -> Unit,
    unpair: () -> Unit,
) {
    var chosen by rememberSaveable { mutableStateOf<List<String>>(emptyList()) }
    var language by rememberSaveable { mutableStateOf("nl") }
    var info by rememberSaveable { mutableStateOf("") }
    var languageMenu by remember { mutableStateOf(false) }
    val context = LocalContext.current
    var micRefused by remember { mutableStateOf(false) }
    var confirmRemove by remember { mutableStateOf<String?>(null) }
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
    LaunchedEffect(projects) {   // verwijderd (hier of op de Mac): niet meer gekozen
        if (projects != null) chosen = chosen.filter { it in projects.items }
    }
    LaunchedEffect(added, projects) {   // toegevoegde map: aanvinken zodra hij als project bestaat
        if (added != null && projects != null && added in projects.items && added !in chosen) chosen = chosen + added
    }
    val busy = gateway?.busyElsewhere == true || (gateway != null && gateway.phase != "idle" && meeting.phase == Phase.IDLE)
    val starting = meeting.phase == Phase.STARTING
    val taskRunning = kbTask?.state == "running"
    var overflow by remember { mutableStateOf(false) }
    var editing by rememberSaveable { mutableStateOf(false) }   // prullenbakken alleen in Edit: niet per ongeluk

    Column(Modifier.fillMaxSize()) {
    Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
           verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("💡 HintMeet", style = MaterialTheme.typography.headlineLarge)
                ConnectionDot(connected)
            }
            Box {
                IconButton(onClick = { overflow = true }) { Icon(Icons.Filled.MoreVert, "More") }
                DropdownMenu(expanded = overflow, onDismissRequest = { overflow = false }) {
                    DropdownMenuItem(text = { Text("Unpair this phone") }, onClick = { overflow = false; unpair() })
                }
            }
        }
        if (busy) Banner("A meeting is already running on the Mac.")

        Section("Knowledge bases", Icons.AutoMirrored.Outlined.LibraryBooks, action = {
            if (!projects?.items.isNullOrEmpty()) TextButton(onClick = { editing = !editing }) { Text(if (editing) "Done" else "Edit") }
        }) {
            when {
                projects == null -> Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text("  Asking the Mac…", style = MaterialTheme.typography.bodyMedium)
                }
                projects.items.isEmpty() -> Text("No knowledge bases on the Mac yet. Add a folder below.",
                                                 style = MaterialTheme.typography.bodyMedium,
                                                 color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            projects?.items?.forEach { name ->
                val on = name in chosen
                Row(Modifier.fillMaxWidth().clickable { chosen = if (on) chosen - name else chosen + name },
                    verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = on, onCheckedChange = { chosen = if (it) chosen + name else chosen - name })
                    Text(name, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge, maxLines = 1,
                         overflow = TextOverflow.Ellipsis)
                    if (removing == name) CircularProgressIndicator(Modifier.padding(12.dp).size(20.dp), strokeWidth = 2.dp)
                    else if (editing) IconButton(onClick = { confirmRemove = name },
                                    enabled = connected && !busy && !starting && removing == null && !taskRunning) {
                        Icon(Icons.Outlined.Delete, "Remove $name", tint = MaterialTheme.colorScheme.error)
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = { openFind(chosen) }, enabled = connected && chosen.isNotEmpty() && !busy && !starting,
                                  modifier = Modifier.weight(1f)) {
                    Icon(Icons.Filled.Search, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Find")
                }
                OutlinedButton(onClick = addFolder, enabled = connected && !busy && !starting && !taskRunning,
                               modifier = Modifier.weight(1f)) {
                    Icon(Icons.Filled.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text("Add folder")
                }
            }
            kbTask?.takeIf { it.state != "idle" }?.let { t -> TaskStatus(t) }
        }

        Section("Meeting", Icons.Filled.People) {
            OutlinedTextField(value = info, onValueChange = { info = it }, label = { Text("With whom, where") },
                              singleLine = true, modifier = Modifier.fillMaxWidth())
            Box {
                OutlinedButton(onClick = { languageMenu = true }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Filled.Language, null, Modifier.size(18.dp)); Spacer(Modifier.width(8.dp))
                    Text(LANGUAGES.firstOrNull { it.first == language }?.second ?: language, Modifier.weight(1f))
                    Icon(Icons.Filled.ArrowDropDown, null)
                }
                DropdownMenu(expanded = languageMenu, onDismissRequest = { languageMenu = false }) {
                    LANGUAGES.forEach { (code, name) ->
                        DropdownMenuItem(text = { Text(name) }, onClick = { language = code; languageMenu = false })
                    }
                }
            }
        }

        if (micRefused) Banner("HintMeet needs the microphone to record the meeting (Android settings → Apps → HintMeet).")
    }
    // vast onderaan: ook met veel kennisbanken altijd in beeld
    androidx.compose.material3.Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, tonalElevation = 2.dp) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (chosen.isNotEmpty()) Text("In: " + chosen.joinToString(" + "), style = MaterialTheme.typography.labelMedium,
                                          maxLines = 1, overflow = TextOverflow.Ellipsis,
                                          color = MaterialTheme.colorScheme.onSurfaceVariant)
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
                   modifier = Modifier.fillMaxWidth().height(56.dp)) {
                if (starting) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp, color = MaterialTheme.colorScheme.onPrimary)
                else Icon(Icons.Filled.Mic, null)
                Spacer(Modifier.width(8.dp))
                Text(if (starting) "Starting…" else "Start Meeting", style = MaterialTheme.typography.titleMedium)
            }
            if (starting) Text(meeting.status ?: "Starting the pipeline on the Mac…", style = MaterialTheme.typography.bodyMedium,
                               color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (connected && chosen.isEmpty() && !projects?.items.isNullOrEmpty())
                Text("Tick one or more knowledge bases to start.", style = MaterialTheme.typography.bodySmall,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    }

    confirmRemove?.let { name ->
        AlertDialog(
            onDismissRequest = { confirmRemove = null },
            icon = { Icon(Icons.Outlined.Delete, null) },
            title = { Text("Remove “$name”?") },
            text = { Text("Its knowledge base on the Mac moves to the Trash there: the converted documents, the index "
                          + "and the meeting reports in it. Your original documents stay where they are. You can put "
                          + "it back from the Trash on the Mac.") },
            confirmButton = { TextButton(onClick = { confirmRemove = null; removeProject(name) }) { Text("Move to Trash") } },
            dismissButton = { TextButton(onClick = { confirmRemove = null }) { Text("Cancel") } },
        )
    }
}

/** Wat de Mac aan het omzetten of laden is, met een voortgangsbalk. */
@Composable
private fun TaskStatus(t: ServerMessage.KbTask) {
    Column(Modifier.fillMaxWidth().padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.FolderOpen, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text("  " + when (t.state) {
                "running" -> "${t.title}: ${t.step}"
                "failed" -> t.message ?: "${t.title} failed"
                else -> "${t.title}: ${t.message ?: "done"}"
            }, style = MaterialTheme.typography.bodySmall, maxLines = 3,
                 color = if (t.state == "failed") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (t.state == "running") {
            val f = t.fraction
            if (f != null) LinearProgressIndicator(progress = { f.toFloat() }, modifier = Modifier.fillMaxWidth())
            else LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}

/** Melding die opvalt: rode kaart. */
@Composable
fun Banner(text: String) {
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer,
                                          contentColor = MaterialTheme.colorScheme.onErrorContainer),
         modifier = Modifier.fillMaxWidth()) {
        Text(text, Modifier.padding(14.dp), style = MaterialTheme.typography.bodyMedium)
    }
}
