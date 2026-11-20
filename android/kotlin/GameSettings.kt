package io.github.astartes_gaming.emuera

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.graphics.Typeface
import android.text.InputType
import android.view.View
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.io.File

/**
 * The game's own settings: those of emuera-tty's game settings page (Emuera's settings window) that do something
 * here, kept in the game's emuera.config, which Emuera.exe reads too. `saved` runs as the dialog closes, if anything
 * was written.
 */
fun Activity.showGameSettings(game: File, saved: () -> Unit) {
    class Setting(val key: String, val label: String, val value: String, val source: String, val box: CheckBox?, val field: EditText?) {
        /** what the player has now, if it differs */
        fun changed(): String? {
            val now = box?.let { if (it.isChecked) "YES" else "NO" } ?: field!!.text.toString().trim()
            return now.takeIf { it != value }
        }
    }

    val dp = resources.displayMetrics.density
    val list = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding((20 * dp).toInt(), (8 * dp).toInt(), (20 * dp).toInt(), 0)
    }
    val problem = TextView(this).apply {
        setTextColor(Color.RED)
        visibility = View.GONE
    }
    list.addView(problem)
    list.addView(TextView(this).apply { text = "Saved in the game's emuera.config, which Emuera.exe reads too." })
    var tab = ""
    val settings = Native.gameSettings(game.path).lines().filter { it.isNotEmpty() }.map { line ->
        val f = line.split('\t')
        val (key, label, tabName, kind, value) = f
        val source = f[5]
        if (tabName != tab) {
            tab = tabName
            list.addView(TextView(this).apply {
                text = tabName
                setTypeface(typeface, Typeface.BOLD)
                setPadding(0, (16 * dp).toInt(), 0, 0)
            })
        }
        val shown = if (source == "fixed") "$label (the game doesn't allow changing it)" else label
        if (kind == "bool") {
            val box = CheckBox(this).apply {
                text = shown
                isChecked = value == "YES"
                isEnabled = source != "fixed"
            }
            list.addView(box)
            Setting(key, label, value, source, box, null)
        } else {
            list.addView(TextView(this).apply {
                text = shown
                setPadding(0, (8 * dp).toInt(), 0, 0)
            })
            val field = EditText(this).apply {
                setText(value)
                setSingleLine()
                isEnabled = source != "fixed"
                contentDescription = label
                if (kind.startsWith("int:")) {
                    inputType = InputType.TYPE_CLASS_NUMBER
                    val (_, lo, hi) = kind.split(':')
                    hint = "$lo to $hi"
                } else {
                    hint = "R,G,B"
                }
            }
            list.addView(field)
            Setting(key, label, value, source, null, field)
        }
    }

    var wrote = false
    val dialog = AlertDialog.Builder(this)
        .setTitle("${game.name}: settings")
        .setView(ScrollView(this).apply { addView(list) })
        .setPositiveButton("Save", null)
        .setNeutralButton("Game's defaults", null)
        .setNegativeButton("Cancel", null)
        .create()
    dialog.setOnShowListener {
        // (set here, not on the builder, so that a value that can't be saved keeps the dialog open)
        dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
            val errors = settings.mapNotNull { s ->
                val v = s.changed() ?: return@mapNotNull null
                val e = Native.setGameSetting(game.path, s.key, v)
                if (e.isEmpty()) {
                    wrote = true
                    null
                } else {
                    "${s.label}: $e"
                }
            }
            if (errors.isEmpty()) {
                dialog.dismiss()
            } else {
                problem.text = errors.joinToString("\n")
                problem.visibility = View.VISIBLE
            }
        }
        // the player's own values out of emuera.config: the game's, or Emuera's, again
        dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener {
            for (s in settings) if (s.source == "player" && Native.setGameSetting(game.path, s.key, null).isEmpty()) wrote = true
            dialog.dismiss()
        }
    }
    dialog.setOnDismissListener { if (wrote) saved() }
    dialog.show()
}
