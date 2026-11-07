package nl.zoofit.hintmeet.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import nl.zoofit.hintmeet.session.FolderUi

/** Add Folder vanaf de telefoon: blader door de mappen op de Mac (begint in ~/projects) en voeg er een toe als
 *  kennisbank. De Mac zet hem om zoals Add Folder… daar; de voortgang staat daarna op het startscherm. */
@Composable
fun FolderScreen(folders: FolderUi, connected: Boolean, listDirs: (String?) -> Unit, add: (String) -> Unit,
                 back: () -> Unit) {
    BackHandler(onBack = back)
    var confirm by remember { mutableStateOf(false) }
    LaunchedEffect(connected) { if (connected && folders.path.isEmpty() && !folders.loading) listDirs(null) }
    LaunchedEffect(folders.added) { if (folders.added != null) back() }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 16.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = back) { Text("‹ Back") }
            Text("Add a folder on the Mac", style = MaterialTheme.typography.titleMedium)
        }
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(folders.path.ifEmpty { if (folders.loading) "…" else "" }, style = MaterialTheme.typography.bodyMedium,
                 maxLines = 3)
            folders.note?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(onClick = { confirm = true }, enabled = connected && folders.path.isNotEmpty() && !folders.adding,
                   modifier = Modifier.fillMaxWidth()) {
                Text(if (folders.adding) "Adding…" else "Add “${folders.path.substringAfterLast('/')}” as Knowledge Base")
            }
        }
        LazyColumn(Modifier.fillMaxSize().padding(top = 8.dp)) {
            folders.parent?.let { up ->
                item { FolderRow("‹ Up", enabled = !folders.loading) { listDirs(up) } }
            }
            items(folders.dirs, key = { it }) { name ->
                FolderRow("📁 $name", enabled = !folders.loading) { listDirs(folders.path + "/" + name) }
            }
            if (!folders.loading && folders.path.isNotEmpty() && folders.dirs.isEmpty()) {
                item { Text("No folders in here.", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }
    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text("Add this folder?") },
        text = { Text("The Mac converts the documents in ${folders.path} into a knowledge base and embeds them. The "
                      + "first time this can take a long time (hours for very large folders). You can follow it on the "
                      + "start screen.") },
        confirmButton = { TextButton(onClick = { confirm = false; add(folders.path) }) { Text("Add") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
    )
}

@Composable
private fun FolderRow(label: String, enabled: Boolean, onClick: () -> Unit) {
    Text(label, Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp),
         style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
    HorizontalDivider()
}
