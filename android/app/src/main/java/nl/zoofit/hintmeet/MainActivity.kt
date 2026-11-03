package nl.zoofit.hintmeet

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import nl.zoofit.hintmeet.protocol.Phase
import nl.zoofit.hintmeet.ui.HintMeetTheme
import nl.zoofit.hintmeet.ui.PairingScreen
import nl.zoofit.hintmeet.ui.MeetingScreen
import nl.zoofit.hintmeet.ui.ReportScreen
import nl.zoofit.hintmeet.ui.StartScreen

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) pairFrom(intent)
        setContent {
            HintMeetTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    Box(Modifier.safeDrawingPadding()) { App(vm) }   // Android 15 tekent tot de rand: niet onder de statusbalk
                }
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        pairFrom(intent)
    }

    /** Een hintmeet://pair-link (getikt, of `adb shell am start -d …`) koppelt meteen. */
    private fun pairFrom(intent: android.content.Intent?) {
        val data = intent?.data ?: return
        if (data.scheme == "hintmeet") vm.offerPairing(data.toString())
    }
}

@Composable
fun App(vm: AppViewModel) {
    val pairing by vm.pairing.collectAsStateWithLifecycle()
    val connected by vm.connected.collectAsStateWithLifecycle()
    val gateway by vm.gateway.collectAsStateWithLifecycle()
    val projects by vm.projects.collectAsStateWithLifecycle()
    val meeting by vm.meeting.collectAsStateWithLifecycle()
    val pending by vm.pendingPairing.collectAsStateWithLifecycle()
    val error by vm.error.collectAsStateWithLifecycle()
    pending?.let { p ->
        AlertDialog(
            onDismissRequest = { vm.confirmPairing(p, false) },
            title = { Text("Pair with this Mac?") },
            text = { Text("A link asks to connect HintMeet to ${p.host}. Only accept if you just opened it from "
                          + "HintMeet on your own Mac.") },
            confirmButton = { TextButton(onClick = { vm.confirmPairing(p, true) }) { Text("Pair") } },
            dismissButton = { TextButton(onClick = { vm.confirmPairing(p, false) }) { Text("Cancel") } },
        )
    }
    error?.let { e ->
        AlertDialog(onDismissRequest = { vm.error.value = null }, text = { Text(e) },
                    confirmButton = { TextButton(onClick = { vm.error.value = null }) { Text("OK") } })
    }
    when {
        pairing == null -> PairingScreen(vm::pair)
        meeting.phase == Phase.RUNNING || meeting.phase == Phase.STOPPING ->
            MeetingScreen(meeting, connected, gateway?.startedAtMs, vm::feedback) { vm.stop() }
        meeting.phase == Phase.ENDED -> ReportScreen(meeting, vm::dismissMeeting)
        else -> StartScreen(connected, gateway, projects, meeting, vm::start, vm::unpair)
    }
}
