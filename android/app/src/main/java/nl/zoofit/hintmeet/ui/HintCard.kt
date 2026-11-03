package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.layout.Arrangement
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
        Text(
            hint.text.ifEmpty { "…" },
            fontSize = 26.sp,
            lineHeight = 33.sp,
            color = if (hint.struck) Color(0xFF8A8A8A) else MaterialTheme.colorScheme.onBackground,
            textDecoration = if (hint.struck) TextDecoration.LineThrough else null,
        )
        if (hint.struck && hint.reason != null) {
            Text("Withdrawn: ${hint.reason}", style = MaterialTheme.typography.bodyMedium, color = Color(0xFF8A8A8A))
        }
        if (hint.sources.isNotEmpty()) {
            Text(hint.sources.joinToString(" · "), style = MaterialTheme.typography.bodySmall,
                 color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (hint.final && !hint.struck) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
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
