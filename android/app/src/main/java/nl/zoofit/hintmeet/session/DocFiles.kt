package nl.zoofit.hintmeet.session

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.util.Base64
import androidx.core.content.FileProvider
import java.io.File

/** Documenten van de Mac: in de cache van de app (alleen het laatste), en openen met een app op de telefoon. */
object DocFiles {
    private val textExtensions = setOf("md", "txt", "csv", "json", "log", "yaml", "yml", "xml", "html", "htm")

    fun save(context: Context, name: String, base64: String): File {
        val dir = File(context.cacheDir, "docs").apply { deleteRecursively(); mkdirs() }   // geen stapel oude documenten
        val safe = name.replace(Regex("[/\\\\:\\u0000-\\u001f]"), "_").take(120).ifBlank { "document" }
        return File(dir, safe).apply { writeBytes(Base64.decode(base64, Base64.DEFAULT)) }
    }

    /** Tekst toont de app zelf (Markdown uit de kennisbank heeft op de meeste telefoons geen eigen app). */
    fun isText(mime: String, name: String): Boolean =
        mime.startsWith("text/") || name.substringAfterLast('.', "").lowercase() in textExtensions

    /** Openen met een app die dit soort bestand kan tonen; false als er geen is. */
    fun view(context: Context, file: File, mime: String): Boolean {
        val uri = FileProvider.getUriForFile(context, context.packageName + ".docs", file)
        val intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent); true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }
}
