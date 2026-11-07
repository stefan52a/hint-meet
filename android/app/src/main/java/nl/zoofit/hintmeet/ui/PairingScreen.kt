package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import androidx.activity.compose.rememberLauncherForActivityResult

/** Koppelen: de QR uit HintMeet → Settings → Phone scannen (of de link plakken). */
@Composable
fun PairingScreen(pair: (String?) -> String?) {
    var error by remember { mutableStateOf<String?>(null) }
    var pasted by remember { mutableStateOf("") }
    val scan = rememberLauncherForActivityResult(ScanContract()) { result ->
        if (result.contents != null) error = pair(result.contents)
    }
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        androidx.compose.foundation.layout.Spacer(Modifier.padding(top = 24.dp))
        Text("💡", style = MaterialTheme.typography.displayMedium)
        Text("HintMeet", style = MaterialTheme.typography.headlineLarge)
        Section("Pair with your Mac", androidx.compose.material.icons.Icons.Filled.QrCodeScanner) {
            listOf("Install Tailscale on this phone and on the Mac, signed in to the same account.",
                   "On the Mac: HintMeet → Settings → Phone → Allow phone companion.",
                   "Scan the code that appears there.").forEachIndexed { i, step ->
                androidx.compose.foundation.layout.Row {
                    Text("${i + 1}.  ", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                    Text(step, style = MaterialTheme.typography.bodyLarge)
                }
            }
        }
        Button(onClick = {
            scan.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setPrompt("Scan the code in HintMeet → Settings → Phone").setBeepEnabled(false)
                .setOrientationLocked(false))
        }, modifier = Modifier.fillMaxWidth().height(56.dp)) {
            androidx.compose.material3.Icon(androidx.compose.material.icons.Icons.Filled.QrCodeScanner, null)
            Text("  Scan QR code", style = MaterialTheme.typography.titleMedium)
        }
        OutlinedTextField(value = pasted, onValueChange = { pasted = it }, label = { Text("Or paste the hintmeet:// link") },
                          singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedButton(onClick = { error = pair(pasted) }, enabled = pasted.isNotBlank(),
                       modifier = Modifier.fillMaxWidth()) { Text("Pair") }
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}
