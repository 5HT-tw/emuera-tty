package io.github.astartes_gaming.emuera

import android.media.AudioAttributes
import android.media.MediaPlayer
import android.util.Log

/**
 * The game's sound, as in Emuera-EE: ten effect channels (a new effect takes a free one, else the
 * first) and one looping BGM. Silent while the game is hidden, as it stays alive then. Main thread.
 */
// shortcut: this doesn't ask for audio focus, so it plays alongside another app's music; add that if players mind.
object GameAudio {
    private class Voice(@JvmField val player: MediaPlayer, @JvmField var times: Int) {
        @JvmField var prepared = false
    }

    private val attributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
    private val effects = arrayOfNulls<Voice>(10)
    private var bgm: Voice? = null
    private var hidden = false

    private fun voices() = effects.filterNotNull() + listOfNotNull(bgm)

    /** It has ended, or failed, or something else takes its place. */
    private fun forget(v: Voice) {
        if (bgm === v) bgm = null
        val k = effects.indexOfFirst { it === v }
        if (k >= 0) effects[k] = null
        v.player.release()
    }

    private fun gain(volume: Int) = volume.coerceIn(0, 100) / 100f

    /** `times` 0: the BGM, looping until stopped. */
    fun play(path: String, volume: Int, times: Int) {
        // (a game going on in the background shouldn't leave a burst of effects for when it's back)
        if (hidden && times != 0) return
        val player = MediaPlayer()
        val v = Voice(player, times)
        try {
            player.setAudioAttributes(attributes)
            player.setDataSource(path)
            player.setVolume(gain(volume), gain(volume))
            player.isLooping = times == 0
            player.setOnPreparedListener {
                v.prepared = true
                if (!hidden) it.start()
            }
            player.setOnCompletionListener {
                if (--v.times > 0) it.start() else forget(v)
            }
            player.setOnErrorListener { _, what, extra ->
                // a file it can't play: the game goes on without it, as with no player at all
                Log.w("GameAudio", "$path: error $what, $extra")
                forget(v)
                true
            }
            player.prepareAsync()
        } catch (e: Exception) {
            Log.w("GameAudio", "$path: $e")
            player.release()
            return
        }
        if (times == 0) {
            bgm?.let { forget(it) }
            bgm = v
        } else {
            val free = effects.indexOfFirst { it == null }
            val k = if (free >= 0) free else 0
            effects[k]?.let { forget(it) }
            effects[k] = v
        }
    }

    fun stop(bgm: Boolean) {
        if (bgm) this.bgm?.let { forget(it) } else effects.filterNotNull().forEach { forget(it) }
    }

    fun volumes(effect: Int, bgm: Int) {
        effects.filterNotNull().forEach { it.player.setVolume(gain(effect), gain(effect)) }
        this.bgm?.player?.setVolume(gain(bgm), gain(bgm))
    }

    fun pause() {
        hidden = true
        voices().filter { it.prepared && it.player.isPlaying }.forEach { it.player.pause() }
    }

    fun resume() {
        hidden = false
        voices().filter { it.prepared }.forEach { it.player.start() }
    }
}
