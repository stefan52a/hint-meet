package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Lightbulb
import androidx.compose.material.icons.outlined.ThumbDown
import androidx.compose.material.icons.outlined.ThumbUp
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalIconToggleButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import nl.zoofit.hintmeet.protocol.HintUi

/** Eén hint, groot genoeg om van 60 cm te lezen met de telefoon plat op tafel. */
@Composable
fun HintCard(hint: HintUi, rated: Int, feedback: (Int, Int) -> Unit, modifier: Modifier = Modifier) {
    val clipboard = LocalClipboardManager.current
    Card(modifier.fillMaxSize().padding(horizontal = 12.dp, vertical = 8.dp),
         colors = CardDefaults.cardColors(containerColor = if (hint.struck) MaterialTheme.colorScheme.surfaceContainerLow
                                                           else MaterialTheme.colorScheme.surfaceContainer)) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
               verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Lightbulb, null, Modifier.size(20.dp),
                     tint = if (hint.struck) Color(0xFF8A8A8A) else MaterialTheme.colorScheme.primary)
                Spacer(Modifier.width(8.dp))
                Text(when {
                    hint.struck -> "Withdrawn"
                    !hint.final -> "Thinking…"
                    else -> "Hint"
                }, Modifier.weight(1f), style = MaterialTheme.typography.labelLarge,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (hint.text.isNotEmpty()) {
                    IconButton(onClick = {   // de hele hint met de bronnen
                        val src = if (hint.sources.isNotEmpty()) "\n\n" + hint.sources.joinToString(" · ") else ""
                        clipboard.setText(AnnotatedString(hint.text + src))
                    }) { Icon(Icons.Outlined.ContentCopy, "Copy hint", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
            // lang drukken: selecteren en kopiëren
            SelectionContainer {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        hint.text.ifEmpty { "…" },
                        style = MaterialTheme.typography.bodyLarge,   // zelfde maat als het transcript
                        color = if (hint.struck) Color(0xFF8A8A8A) else MaterialTheme.colorScheme.onSurface,
                        textDecoration = if (hint.struck) TextDecoration.LineThrough else null,
                    )
                    if (hint.struck && hint.reason != null) {
                        Text(hint.reason, style = MaterialTheme.typography.bodyMedium, color = Color(0xFF8A8A8A))
                    }
                }
            }
            SourceLinks(hint.sources)   // tik: het document van de Mac
            if (hint.final && !hint.struck) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.End),
                    verticalAlignment = Alignment.CenterVertically) {
                    if (rated != 0) Text(if (rated == 1) "Thanks" else "Noted", style = MaterialTheme.typography.labelMedium,
                                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                    FilledTonalIconToggleButton(checked = rated == 1, onCheckedChange = { feedback(hint.id, 1) },
                                                enabled = rated == 0) {
                        Icon(if (rated == 1) Icons.Filled.ThumbUp else Icons.Outlined.ThumbUp, "Useful hint")
                    }
                    FilledTonalIconToggleButton(checked = rated == -1, onCheckedChange = { feedback(hint.id, -1) },
                                                enabled = rated == 0) {
                        Icon(if (rated == -1) Icons.Filled.ThumbDown else Icons.Outlined.ThumbDown, "Not useful")
                    }
                }
            }
        }
    }
}
