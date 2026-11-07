package nl.zoofit.hintmeet.ui

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** Donker standaard: de telefoon ligt op tafel tijdens een meeting en mag niet oplichten. Geel = het 💡 van HintMeet. */
private val Dark = darkColorScheme(
    primary = Color(0xFFFFC94D),
    onPrimary = Color(0xFF261A00),
    primaryContainer = Color(0xFF3D2F00),
    onPrimaryContainer = Color(0xFFFFE08F),
    secondary = Color(0xFF8FB8FF),          // het blauw van het icoon: bronnen, links
    onSecondary = Color(0xFF00285C),
    secondaryContainer = Color(0xFF1B3358),
    onSecondaryContainer = Color(0xFFD6E3FF),
    tertiary = Color(0xFF7FD99A),           // ✓ klopt met het dossier
    onTertiary = Color(0xFF00391A),
    tertiaryContainer = Color(0xFF12361F),
    onTertiaryContainer = Color(0xFFA6F5BC),
    background = Color(0xFF0E0E10),
    onBackground = Color(0xFFE8E6E1),
    surface = Color(0xFF0E0E10),
    onSurface = Color(0xFFE8E6E1),
    surfaceVariant = Color(0xFF2A2A2E),
    onSurfaceVariant = Color(0xFFB4B1AA),
    surfaceContainerLowest = Color(0xFF0A0A0C),
    surfaceContainerLow = Color(0xFF151518),
    surfaceContainer = Color(0xFF1A1A1E),
    surfaceContainerHigh = Color(0xFF222226),
    surfaceContainerHighest = Color(0xFF2B2B30),
    outline = Color(0xFF4A4A50),
    outlineVariant = Color(0xFF2E2E33),
    error = Color(0xFFFF8A80),
    onError = Color(0xFF5C0000),
    errorContainer = Color(0xFF5C1414),
    onErrorContainer = Color(0xFFFFDAD6),
)

private val base = Typography()
private val Type = Typography(
    headlineLarge = base.headlineLarge.copy(fontWeight = FontWeight.SemiBold),
    headlineSmall = base.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
    titleLarge = base.titleLarge.copy(fontWeight = FontWeight.SemiBold),
    titleMedium = base.titleMedium.copy(fontWeight = FontWeight.SemiBold),
    bodyLarge = base.bodyLarge.copy(fontSize = 18.sp, lineHeight = 26.sp),   // hints en transcript, van 60 cm leesbaar
    labelLarge = base.labelLarge.copy(fontWeight = FontWeight.SemiBold),
)

private val Shape = Shapes(
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
)

@Composable
fun HintMeetTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = Dark, typography = Type, shapes = Shape, content = content)
}
