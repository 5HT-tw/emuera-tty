package io.github.astartes_gaming.emuera

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import java.io.File
import java.io.IOException

/** There while a game runs: left behind, it says the game's process died without saying why. */
fun gameMarker(c: Context) = File(c.filesDir, "game-running")

/** Holds a game's name while it restarts: its menu ends its process, and the list starts it again. */
fun restartMarker(c: Context) = File(c.filesDir, "game-restart")

/** What the engine logged last, with a way to send it to someone. `done` runs as the dialog closes. */
fun Activity.showEngineLog(title: String, log: File, done: () -> Unit = {}) {
    val text = try {
        log.readText().takeLast(64 * 1024)
    } catch (e: IOException) {
        ""
    }
    val news = text.lines().filter { it.isNotBlank() && !it.startsWith("timing:") && !it.startsWith("loaded ") }.takeLast(12).joinToString("\n")
    val shown = news.ifEmpty { "The engine didn't log why." }
    AlertDialog.Builder(this)
        .setTitle(title)
        .setMessage(shown)
        .setCancelable(false)
        .setPositiveButton("Share") { _, _ ->
            val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text.ifEmpty { shown })
            startActivity(Intent.createChooser(send, null))
            done()
        }
        .setNegativeButton("Close") { _, _ -> done() }
        .show()
}
