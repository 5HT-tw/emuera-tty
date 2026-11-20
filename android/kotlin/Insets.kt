package io.github.astartes_gaming.emuera

import android.os.Build
import android.view.View
import android.view.WindowInsets

/**
 * Keeps a view's content clear of the status and navigation bars, a notch and the on-screen
 * keyboard. Android 15 lays every app out under all of these and no longer resizes the
 * window for the keyboard, so an app has to do this itself. (On older versions the system
 * still does it, and there's nothing left to apply here.)
 */
fun View.padForSystemBars(extra: Int = 0) {
    setOnApplyWindowInsetsListener { v, insets ->
        if (Build.VERSION.SDK_INT >= 30) {
            val i = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
            v.setPadding(i.left + extra, i.top + extra, i.right + extra, i.bottom + extra)
        } else {
            v.setPadding(extra, extra, extra, extra)
        }
        insets
    }
}
