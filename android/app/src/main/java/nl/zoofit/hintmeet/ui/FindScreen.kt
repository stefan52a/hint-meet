package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.automirrored.outlined.ManageSearch
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.SearchOff
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.ui.text.style.TextOverflow
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import nl.zoofit.hintmeet.protocol.DocHit
import nl.zoofit.hintmeet.session.FindUi

/** Find vanaf het startscherm: zoeken in de gekozen projecten, zonder meeting (de Mac laadt ze zelf). */
@Composable
fun FindScreen(find: FindUi, projects: List<String>, connected: Boolean, search: (String) -> Unit, back: () -> Unit) {
    BackHandler(onBack = back)
    Column(Modifier.fillMaxSize()) {
        ScreenHeader("Find in " + projects.joinToString(" + "), back)
        Find(find, enabled = connected, search = search,
             intro = "Find a document by what it says. The first search loads the knowledge base on the Mac, "
                     + "which can take a little while; after that answers come quickly.")
    }
}

/** Find, zoals Find Documents op de Mac: documenten op inhoud zoeken in de kennisbank van de meeting. */
@Composable
fun Find(find: FindUi, enabled: Boolean, search: (String) -> Unit, intro: String) {
    var query by rememberSaveable { mutableStateOf(find.query) }
    Column(Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        OutlinedTextField(
            value = query, onValueChange = { query = it }, enabled = enabled, singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
            shape = MaterialTheme.shapes.large,
            placeholder = { Text("Search the documents…", maxLines = 1) },
            leadingIcon = { Icon(Icons.Outlined.Search, null) },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { if (!find.searching && query.isNotBlank()) search(query) }),
            trailingIcon = {
                if (find.searching) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                else IconButton(onClick = { search(query) }, enabled = enabled && query.isNotBlank()) {
                    Icon(Icons.AutoMirrored.Filled.ArrowForward, "Find",
                         tint = if (enabled && query.isNotBlank()) MaterialTheme.colorScheme.primary
                                else MaterialTheme.colorScheme.onSurfaceVariant)
                }
            },
            supportingText = when {
                find.searching -> ({ Text(find.note ?: "Searching on the Mac…") })   // voortgang van het laden
                find.note != null -> ({ Text(find.note) })
                else -> null
            },
        )
        when {
            find.results.isNotEmpty() -> {
                Text("${find.results.size} ${if (find.reranked) "relevant " else ""}documents, best match first",
                     Modifier.padding(vertical = 4.dp), style = MaterialTheme.typography.labelMedium,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
                LazyColumn(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(find.results, key = { it.ref }) { DocRow(it) }
                    item { Spacer(Modifier.size(8.dp)) }
                }
            }
            find.searched && !find.searching ->
                EmptyState(Icons.Outlined.SearchOff, if (find.reranked) "Nothing relevant found." else "Nothing found.",
                           Modifier.fillMaxWidth())
            !find.searching -> EmptyState(Icons.AutoMirrored.Outlined.ManageSearch, intro, Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun DocRow(hit: DocHit) {
    var open by remember(hit.ref) { mutableStateOf(false) }   // tik: het hele stukje
    val openDoc = LocalOpenDoc.current
    Card(onClick = { open = !open }, modifier = Modifier.fillMaxWidth(),
         colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Description, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.secondary)
                Text("  " + hit.name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, maxLines = 1,
                     overflow = TextOverflow.Ellipsis)
                hit.relevance?.let {
                    Text("${(it * 100).toInt()}%", Modifier.background(MaterialTheme.colorScheme.primaryContainer, CircleShape)
                        .padding(horizontal = 8.dp, vertical = 2.dp), style = MaterialTheme.typography.labelMedium,
                         color = MaterialTheme.colorScheme.onPrimaryContainer)
                }
            }
            val meta = listOfNotNull(hit.ref.substringBeforeLast('/', "").ifEmpty { null },
                                     hit.heading.ifEmpty { null }).joinToString("  ›  ")
            if (meta.isNotEmpty()) Text(meta, style = MaterialTheme.typography.labelMedium, maxLines = 1,
                                        overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (hit.injection) Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.WarningAmber, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.error)
                Text("  Contains instructions to an AI", style = MaterialTheme.typography.labelMedium,
                     color = MaterialTheme.colorScheme.error)
            }
            // open: lang drukken selecteert en kopieert; dicht: tikken klapt open
            if (open) {
                SelectionContainer { Text(hit.snippet, style = MaterialTheme.typography.bodyMedium) }
                FilledTonalButton(onClick = { openDoc(hit.ref, hit.path) }, enabled = hit.path != null) {
                    Icon(Icons.AutoMirrored.Filled.OpenInNew, null, Modifier.size(18.dp))
                    Text("  Open document")
                }
            } else Text(hit.snippet, style = MaterialTheme.typography.bodyMedium, maxLines = 3, overflow = TextOverflow.Ellipsis,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
