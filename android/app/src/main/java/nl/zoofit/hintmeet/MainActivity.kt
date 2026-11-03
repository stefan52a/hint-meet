package nl.zoofit.hintmeet

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
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
import nl.zoofit.hintmeet.ui.StartScreen

class MainActivity : ComponentActivity() {
    private val vm: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) pairFrom(intent)
        setContent {
            HintMeetTheme {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) { App(vm) }
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
        if (data.scheme == "hintmeet") vm.pair(data.toString())
    }
}

@Composable
fun App(vm: AppViewModel) {
    val pairing by vm.pairing.collectAsStateWithLifecycle()
    val connected by vm.connected.collectAsStateWithLifecycle()
    val gateway by vm.gateway.collectAsStateWithLifecycle()
    val projects by vm.projects.collectAsStateWithLifecycle()
    val meeting by vm.meeting.collectAsStateWithLifecycle()
    when {
        pairing == null -> PairingScreen(vm::pair)
        meeting.phase == Phase.RUNNING || meeting.phase == Phase.STOPPING -> MeetingPlaceholder(meeting.hints.lastOrNull()?.text) { vm.stop() }
        meeting.phase == Phase.ENDED -> MeetingPlaceholder(meeting.report ?: "Meeting ended (${meeting.stoppedBy})") { vm.dismissMeeting() }
        else -> StartScreen(connected, gateway, projects, meeting, vm::start, vm::unpair)
    }
}

/** Tijdelijk, tot het meetingscherm er is (Task 9). */
@Composable
private fun MeetingPlaceholder(text: String?, action: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Text(text ?: "Listening…", style = MaterialTheme.typography.headlineMedium)
        Button(onClick = action) { Text("Stop / Close") }
    }
}
