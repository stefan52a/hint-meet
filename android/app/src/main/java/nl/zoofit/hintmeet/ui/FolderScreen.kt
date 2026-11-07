package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
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
        ScreenHeader("Add a folder on the Mac", back)
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer, MaterialTheme.shapes.small)
                    .padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Computer, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("  " + folders.path.ifEmpty { if (folders.loading) "…" else "" }, Modifier.weight(1f),
                     style = MaterialTheme.typography.bodyMedium, maxLines = 3)
                if (folders.loading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            }
            folders.note?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            androidx.compose.material3.FilledTonalButton(onClick = { confirm = true }, enabled = connected && folders.path.isNotEmpty() && !folders.adding,
                   modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.Add, null, Modifier.size(18.dp))
                Text("  " + if (folders.adding) "Adding…" else "Add “${folders.path.substringAfterLast('/')}” as knowledge base",
                     maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        LazyColumn(Modifier.fillMaxSize().padding(top = 8.dp)) {
            folders.parent?.let { up ->
                item { FolderRow(Icons.Filled.ArrowUpward, "Up", enabled = !folders.loading) { listDirs(up) } }
            }
            items(folders.dirs, key = { it }) { name ->
                FolderRow(Icons.Filled.Folder, name, enabled = !folders.loading) { listDirs(folders.path + "/" + name) }
            }
            if (!folders.loading && folders.path.isNotEmpty() && folders.dirs.isEmpty()) {
                item { Text("No folders in here.", Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
            }
        }
    }
    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        icon = { Icon(Icons.Outlined.FolderOpen, null) },
        title = { Text("Add this folder?") },
        text = { Text("The Mac converts the documents in ${folders.path} into a knowledge base and embeds them. The "
                      + "first time this can take a long time (hours for very large folders). You can follow it on the "
                      + "start screen.") },
        confirmButton = { TextButton(onClick = { confirm = false; add(folders.path) }) { Text("Add") } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text("Cancel") } },
    )
}

@Composable
private fun FolderRow(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, enabled: Boolean, onClick: () -> Unit) {
    ListItem(
        headlineContent = { Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        leadingContent = { Icon(icon, null, tint = MaterialTheme.colorScheme.primary) },
        trailingContent = { Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant) },
        modifier = Modifier.clickable(enabled = enabled, onClick = onClick),
        colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.background),
    )
}
