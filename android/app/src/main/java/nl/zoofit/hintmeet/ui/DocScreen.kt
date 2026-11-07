package nl.zoofit.hintmeet.ui

import android.widget.TextView
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import io.noties.markwon.Markwon
import nl.zoofit.hintmeet.session.DocUi

/** Document van de Mac openen: (ref, pad op de Mac of null = opzoeken in de bronnen van de meeting). */
val LocalOpenDoc = staticCompositionLocalOf<(String, String?) -> Unit> { { _, _ -> } }

/** Bronnen onder een hint of Backed-regel: tik = het document van de Mac halen. */
@Composable
fun SourceLinks(sources: List<String>, modifier: Modifier = Modifier) {
    if (sources.isEmpty()) return
    val open = LocalOpenDoc.current
    Column(modifier) {
        sources.forEach { ref ->
            TextButton(onClick = { open(ref, null) }, contentPadding = androidx.compose.foundation.layout.PaddingValues(
                horizontal = 0.dp, vertical = 0.dp)) {
                Text("📄 " + ref.substringAfterLast('/'), style = MaterialTheme.typography.bodySmall, maxLines = 1,
                     overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** Ophalen, de tekst tonen (Markdown, txt …), of een melding. Pdf, Word e.d. opent Android met een eigen app. */
@Composable
fun DocViewer(doc: DocUi?, close: () -> Unit) {
    doc ?: return
    when {
        doc.loading -> AlertDialog(onDismissRequest = close,
            text = { Text("Getting ${doc.name} from the Mac…") },
            confirmButton = { TextButton(onClick = close) { Text("Cancel") } })
        doc.error != null -> AlertDialog(onDismissRequest = close,
            title = { Text(doc.name, maxLines = 2, overflow = TextOverflow.Ellipsis) },
            text = { Text(doc.error) },
            confirmButton = { TextButton(onClick = close) { Text("OK") } })
        doc.text != null -> Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            val context = LocalContext.current
            val markwon = remember { Markwon.create(context) }
            val color = MaterialTheme.colorScheme.onBackground.toArgb()
            val markdown = doc.name.endsWith(".md", ignoreCase = true)
            Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(doc.name, Modifier.weight(1f), style = MaterialTheme.typography.titleMedium, maxLines = 1,
                             overflow = TextOverflow.Ellipsis)
                        TextButton(onClick = close) { Text("Close") }
                    }
                    // lang drukken: selecteren en kopiëren
                    AndroidView(
                        factory = { TextView(it).apply { setTextColor(color); textSize = 16f; setTextIsSelectable(true) } },
                        update = { if (markdown) markwon.setMarkdown(it, doc.text) else it.text = doc.text },
                        modifier = Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()))
                }
            }
        }
    }
}
