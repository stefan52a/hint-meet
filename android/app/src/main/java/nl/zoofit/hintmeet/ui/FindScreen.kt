package nl.zoofit.hintmeet.ui

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
        Row(Modifier.fillMaxWidth().padding(start = 4.dp, end = 16.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = back) { Text("‹ Back") }
            Text("Find in " + projects.joinToString(" + "), style = MaterialTheme.typography.titleMedium, maxLines = 1,
                 overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
        }
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
            placeholder = { Text("Search the documents…") },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { if (!find.searching) search(query) }),
            trailingIcon = {
                TextButton(onClick = { search(query) }, enabled = enabled && query.isNotBlank() && !find.searching) {
                    Text("Find")
                }
            },
            supportingText = when {
                find.searching -> ({ Text(find.note ?: "Searching on the Mac…") })   // voortgang van het laden
                find.note != null -> ({ Text(find.note) })
                else -> null
            },
        )
        when {
            find.results.isNotEmpty() -> LazyColumn(Modifier.fillMaxSize()) {
                items(find.results, key = { it.ref }) { DocRow(it) }
            }
            find.searched && !find.searching -> Text(
                if (find.reranked) "Nothing relevant found." else "Nothing found.",
                Modifier.padding(top = 24.dp), style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            !find.searching -> Text(intro,
                Modifier.padding(top = 24.dp), style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun DocRow(hit: DocHit) {
    var open by remember(hit.ref) { mutableStateOf(false) }   // tik: het hele stukje
    Column(Modifier.fillMaxWidth().clickable { open = !open }.padding(vertical = 10.dp)) {
        Text(hit.name + (if (hit.heading.isNotEmpty()) "  ›  ${hit.heading}" else ""),
             style = MaterialTheme.typography.titleMedium, maxLines = 2)
        val meta = listOfNotNull(
            hit.ref.substringBeforeLast('/', "").ifEmpty { null },
            hit.relevance?.let { "${(it * 100).toInt()}% relevant" },
            if (hit.injection) "⚠ contains instructions to an AI" else null,
        ).joinToString("  ·  ")
        if (meta.isNotEmpty()) Text(meta, style = MaterialTheme.typography.labelMedium,
                                    color = if (hit.injection) MaterialTheme.colorScheme.error
                                            else MaterialTheme.colorScheme.onSurfaceVariant)
        // open: lang drukken selecteert en kopieert; dicht: tikken klapt open
        if (open) {
            SelectionContainer { Text(hit.snippet, style = MaterialTheme.typography.bodyMedium) }
            val openDoc = LocalOpenDoc.current
            TextButton(onClick = { openDoc(hit.ref, hit.path) }, enabled = hit.path != null) { Text("Open document") }
        }
        else Text(hit.snippet, style = MaterialTheme.typography.bodyMedium, maxLines = 3,
                  overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
    }
}
