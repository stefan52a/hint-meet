package nl.zoofit.hintmeet.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Donker standaard: de telefoon ligt op tafel tijdens een meeting en mag niet oplichten. */
private val Dark = darkColorScheme(
    primary = Color(0xFFFFC94D),     // het 💡-geel van HintMeet
    onPrimary = Color(0xFF231A00),
    background = Color(0xFF101010),
    surface = Color(0xFF181818),
)

@Composable
fun HintMeetTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Dark, content = content)
}
