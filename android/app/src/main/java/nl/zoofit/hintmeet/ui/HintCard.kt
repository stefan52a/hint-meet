package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import nl.zoofit.hintmeet.protocol.HintUi

/** Eén hint, groot genoeg om van 60 cm te lezen met de telefoon plat op tafel. */
@Composable
fun HintCard(hint: HintUi, rated: Int, feedback: (Int, Int) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 12.dp).verticalScroll(rememberScrollState()),
           verticalArrangement = Arrangement.spacedBy(16.dp)) {
        // lang drukken: selecteren en kopiëren; de knop Copy kopieert de hele hint
        SelectionContainer {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(
                    hint.text.ifEmpty { "…" },
                    style = MaterialTheme.typography.bodyLarge,   // zelfde maat als het transcript
                    color = if (hint.struck) Color(0xFF8A8A8A) else MaterialTheme.colorScheme.onBackground,
                    textDecoration = if (hint.struck) TextDecoration.LineThrough else null,
                )
                if (hint.struck && hint.reason != null) {
                    Text("Withdrawn: ${hint.reason}", style = MaterialTheme.typography.bodyMedium, color = Color(0xFF8A8A8A))
                }
            }
        }
        SourceLinks(hint.sources)   // tik: het document van de Mac
        val clipboard = LocalClipboardManager.current
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            if (hint.text.isNotEmpty()) {
                OutlinedButton(onClick = {
                    val src = if (hint.sources.isNotEmpty()) "\n\n" + hint.sources.joinToString(" · ") else ""
                    clipboard.setText(AnnotatedString(hint.text + src))
                }) { Text("Copy") }
            }
            if (hint.final && !hint.struck) {
                OutlinedButton(onClick = { feedback(hint.id, 1) }, enabled = rated == 0,
                               modifier = Modifier.semantics { contentDescription = "Useful hint" }) {
                    Text(if (rated == 1) "👍 thanks" else "👍")
                }
                OutlinedButton(onClick = { feedback(hint.id, -1) }, enabled = rated == 0,
                               modifier = Modifier.semantics { contentDescription = "Not useful" }) {
                    Text(if (rated == -1) "👎 noted" else "👎")
                }
            }
        }
    }
}
