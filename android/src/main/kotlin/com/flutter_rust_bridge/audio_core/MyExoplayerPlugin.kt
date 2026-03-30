package com.flutter_rust_bridge.audio_core

import android.content.Context
import android.net.Uri
import android.media.audiofx.Equalizer
import android.media.audiofx.BassBoost
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.util.EventLogger
import com.linc.amplituda.Amplituda

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

import android.animation.ValueAnimator
import android.os.Handler
import android.os.Looper

@UnstableApi
/** MyExoplayerPlugin */
class MyExoplayerPlugin : FlutterPlugin, MethodCallHandler {
    private class PlayerContext(
        val id: String,
        val player: ExoPlayer,
        val fftProcessor: FFTAudioProcessor,
        val cppEqualizerProcessor: CppEqualizerProcessor,
        var equalizer: Equalizer? = null,
        var bassBoost: BassBoost? = null,
        var volumeAnimator: ValueAnimator? = null
    )

    companion object {
        private var instance: MyExoplayerPlugin? = null
        private val playerContexts = mutableMapOf<String, PlayerContext>()

        init {
            System.loadLibrary("my_exoplayer")
        }

        private fun createPlayerListener(id: String) = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_READY) {
                    instance?.ensureAudioEffects(id)
                }
                sendPlayerState(id)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                sendPlayerState(id)
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int
            ) {
                sendPlayerState(id)
            }
        }

        private fun sendPlayerState(id: String) {
            val ctx = playerContexts[id] ?: return
            val p = ctx.player
            val inst = instance ?: return
            val duration = p.duration
            val clampedDuration = if (duration < 0) 0L else duration
            
            val stateMap = mapOf(
                "playerId" to id,
                "state" to when (p.playbackState) {
                    Player.STATE_IDLE -> "IDLE"
                    Player.STATE_BUFFERING -> "BUFFERING"
                    Player.STATE_READY -> "READY"
                    Player.STATE_ENDED -> "ENDED"
                    else -> "UNKNOWN"
                },
                "isPlaying" to p.isPlaying,
                "duration" to clampedDuration,
                "position" to p.currentPosition
            )
            inst.channel.invokeMethod("onPlayerStateChanged", stateMap)
        }
    }

    private lateinit var channel: MethodChannel
    private var context: Context? = null
    private var amplituda: Amplituda? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        instance = this
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "my_exoplayer")
        channel.setMethodCallHandler(this)
        
        amplituda = Amplituda(context)
        // Initialize default player
        getOrCreatePlayerContext("main")
    }

    @OptIn(UnstableApi::class)
    private fun getOrCreatePlayerContext(id: String): PlayerContext {
        playerContexts[id]?.let { return it }

        val safeContext = context!!
        val fftProcessor = FFTAudioProcessor(1024)
        val cppEqualizerProcessor = CppEqualizerProcessor()

        val renderersFactory = object : DefaultRenderersFactory(safeContext) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean
            ): AudioSink? {
                return DefaultAudioSink.Builder(context)
                    .setAudioProcessors(arrayOf(cppEqualizerProcessor, fftProcessor))
                    .build()
            }
        }

        val audioAttributes = androidx.media3.common.AudioAttributes.Builder()
            .setUsage(androidx.media3.common.C.USAGE_MEDIA)
            .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()

        val player = ExoPlayer.Builder(safeContext, renderersFactory)
            .setAudioAttributes(audioAttributes, true)
            .build()
        
        player.addAnalyticsListener(EventLogger())
        cppEqualizerProcessor.setNumBands(10)
        
        val ctx = PlayerContext(id, player, fftProcessor, cppEqualizerProcessor)
        player.addListener(createPlayerListener(id))
        playerContexts[id] = ctx
        return ctx
    }

    private fun ensureAudioEffects(id: String) {
        val ctx = playerContexts[id] ?: return
        val sessionId = ctx.player.audioSessionId
        if (sessionId != 0 && (ctx.equalizer == null || ctx.equalizer?.id != sessionId)) {
            try {
                ctx.equalizer?.release()
                ctx.bassBoost?.release()
                
                ctx.equalizer = Equalizer(0, sessionId)
                ctx.bassBoost = BassBoost(0, sessionId)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        val playerId = call.argument<String>("playerId") ?: "main"
//        android.util.Log.d("MyExoplayer", "onMethodCall: ${call.method} for $playerId")
        
        when (call.method) {
            "sayHello" -> {
                result.success(null)
                return
            }
            "getWaveform" -> {
                val path = call.argument<String>("path") ?: return result.error("INVALID_ARGUMENT", "Path is null", null)
                val expectedChunks = call.argument<Int>("expectedChunks") ?: 0
                val amp = amplituda ?: return result.error("INTERNAL_ERROR", "Amplituda not initialized", null)
                
                val (localPath, isTemp) = ensureLocalPath(path)
                
                amp.processAudio(localPath).get({ amResult ->
                    val rawData = amResult.amplitudesAsList()
                    val processedData = if (expectedChunks > 0) {
                        downsample(rawData, expectedChunks)
                    } else {
                        rawData
                    }
                    Handler(Looper.getMainLooper()).post {
                        result.success(processedData)
                        if (isTemp) java.io.File(localPath).delete()
                    }
                }, { error ->
                    Handler(Looper.getMainLooper()).post {
                        result.error("AMPLITUDA_ERROR", error.message, null)
                        if (isTemp) java.io.File(localPath).delete()
                    }
                })
                return
            }
            "load" -> {
                val url = call.argument<String>("url") ?: return result.error("INVALID_ARGUMENT", "URL is null", null)
                val ctx = getOrCreatePlayerContext(playerId)
                val mediaItem = MediaItem.fromUri(Uri.parse(url))
                ctx.player.setMediaItem(mediaItem)
                ctx.player.playWhenReady = false
                ctx.player.prepare()
                result.success(null)
                return
            }
        }

        val ctx = playerContexts[playerId] ?: if (playerId == "main") {
            try {
                getOrCreatePlayerContext("main")
            } catch (e: Exception) {
                result.error("INIT_ERROR", "Lazy init failed: ${e.message}", null)
                return
            }
        } else {
            null
        }

        if (ctx == null) {
            result.error("PLAYER_NOT_FOUND", "Player context not found for ID: $playerId", null)
            return
        }

        when (call.method) {
            "play" -> {
                val fadeDurationMs = call.argument<Int>("fadeDurationMs")?.toLong() ?: 0L
                val targetVolume = call.argument<Double>("targetVolume")?.toFloat() ?: ctx.player.volume
                if (fadeDurationMs > 0) {
                    ctx.player.volume = 0f
                    ctx.player.play()
                    fadeVolumeTo(ctx, targetVolume, fadeDurationMs)
                } else {
                    ctx.player.play()
                }
                result.success(null)
            }
            "pause" -> {
                val fadeDurationMs = call.argument<Int>("fadeDurationMs")?.toLong() ?: 0L
                if (fadeDurationMs > 0) {
                    val originalVolume = ctx.player.volume
                    fadeVolumeTo(ctx, 0f, fadeDurationMs) {
                        ctx.player.pause()
                        ctx.player.volume = originalVolume
                    }
                } else {
                    ctx.player.pause()
                }
                result.success(null)
            }
            "seek" -> {
                val positionMs = call.argument<Int>("position")?.toLong() ?: 0L
                ctx.player.seekTo(positionMs)
                result.success(null)
            }
            "setVolume" -> {
                val volume = call.argument<Double>("volume")?.toFloat() ?: 1.0f
                val fadeDurationMs = call.argument<Int>("fadeDurationMs")?.toLong() ?: 0L
                if (fadeDurationMs > 0) {
                    fadeVolumeTo(ctx, volume, fadeDurationMs)
                } else {
                    ctx.player.volume = volume
                }
                result.success(null)
            }
            "getLatestFft" -> {
                result.success(ctx.fftProcessor.getLatestMagnitudes().toList())
            }
            "getCurrentPosition" -> {
                val pos = ctx.player.currentPosition
                result.success(if (pos < 0) 0L else pos)
            }
            "getDuration" -> {
                val duration = ctx.player.duration
                result.success(if (duration < 0) 0L else duration)
            }
            "setEqualizerConfig" -> {
                ensureAudioEffects(playerId)
                val eq = ctx.equalizer
                val bb = ctx.bassBoost
                if (eq == null || bb == null) {
                    result.error("EFFECT_ERROR", "Equalizer not initialized", null)
                    return
                }

                val enabled = call.argument<Boolean>("enabled") ?: false
                val bandGains = call.argument<List<Double>>("bandGains")
                val bassBoostDb = call.argument<Double>("bassBoostDb") ?: 0.0

                eq.enabled = enabled
                bb.enabled = enabled

                if (bandGains != null) {
                    val numBands = eq.numberOfBands.toInt()
                    for (i in 0 until numBands) {
                        if (i < bandGains.size) {
                            val level = (bandGains[i] * 100).toInt().toShort()
                            val range = eq.bandLevelRange
                            val clampedLevel = if (level < range[0]) range[0] else if (level > range[1]) range[1] else level
                            eq.setBandLevel(i.toShort(), clampedLevel)
                        }
                    }
                }
                val strength = (bassBoostDb * 1000 / 15.0).toInt().coerceIn(0, 1000).toShort()
                bb.setStrength(strength)
                result.success(null)
            }
            "setCppEqualizerConfig" -> {
                val bandGains = call.argument<List<Double>>("bandGains")
                if (bandGains != null) {
                    for (i in 0 until bandGains.size) {
                        ctx.cppEqualizerProcessor.setBandGain(i, bandGains[i].toFloat())
                    }
                }
                result.success(null)
            }
            "setCppEqualizerPreAmp" -> {
                val gainDb = call.argument<Double>("gainDb")?.toFloat() ?: 0f
                ctx.cppEqualizerProcessor.setPreAmp(gainDb)
                result.success(null)
            }
            "setCppEqualizerBandCount" -> {
                val count = call.argument<Int>("count") ?: 10
                ctx.cppEqualizerProcessor.setNumBands(count)
                result.success(null)
            }
            "setCppEqualizerEnabled" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                ctx.cppEqualizerProcessor.setEnabled(enabled)
                if (enabled) {
                    ctx.equalizer?.enabled = false
                    ctx.bassBoost?.enabled = false
                }
                result.success(null)
            }
            "getSystemEqualizerParams" -> {
                ensureAudioEffects(playerId)
                val eq = ctx.equalizer
                if (eq == null) {
                    result.error("EFFECT_ERROR", "Equalizer not initialized", null)
                    return
                }
                val numBands = eq.numberOfBands.toInt()
                val frequencies = mutableListOf<Int>()
                for (i in 0 until numBands) {
                    frequencies.add(eq.getCenterFreq(i.toShort()))
                }
                val range = eq.bandLevelRange
                val params = mapOf(
                    "numBands" to numBands,
                    "frequencies" to frequencies,
                    "minLevel" to range[0].toInt(),
                    "maxLevel" to range[1].toInt()
                )
                result.success(params)
            }
            "dispose" -> {
                playerContexts.remove(playerId)
                releasePlayerContext(ctx)
                result.success(null)
            }
            else -> {
                result.notImplemented()
            }
        }

    }

    private fun fadeVolumeTo(ctx: PlayerContext, targetVolume: Float, durationMs: Long, onEnd: (() -> Unit)? = null) {
        ctx.volumeAnimator?.cancel()
        val startVolume = ctx.player.volume
        val animator = ValueAnimator.ofFloat(startVolume, targetVolume)
        animator.duration = durationMs
        animator.addUpdateListener { animation ->
            ctx.player.volume = animation.animatedValue as Float
        }
        animator.addListener(object : android.animation.AnimatorListenerAdapter() {
            override fun onAnimationEnd(animation: android.animation.Animator) {
                onEnd?.invoke()
            }
        })
        ctx.volumeAnimator = animator
        Handler(Looper.getMainLooper()).post {
            animator.start()
        }
    }

    private fun releasePlayerContext(ctx: PlayerContext) {
        ctx.player.release()
        ctx.equalizer?.release()
        ctx.bassBoost?.release()
        ctx.cppEqualizerProcessor.release()
    }

    private fun ensureLocalPath(path: String): Pair<String, Boolean> {
        if (!path.startsWith("content://")) return Pair(path, false)
        
        val ctx = context ?: return Pair(path, false)
        try {
            val uri = Uri.parse(path)
            val tempFile = java.io.File(ctx.cacheDir, "temp_waveform_" + System.currentTimeMillis())
            ctx.contentResolver.openInputStream(uri)?.use { input ->
                tempFile.outputStream().use { output ->
                    input.copyTo(output)
                }
            }
            return Pair(tempFile.absolutePath, true)
        } catch (e: Exception) {
            e.printStackTrace()
            return Pair(path, false)
        }
    }

    private fun downsample(amplitudes: List<Int>, targetSize: Int): List<Int> {
        if (targetSize <= 0 || amplitudes.isEmpty()) return emptyList()
        if (amplitudes.size <= targetSize) return amplitudes
        
        val result = ArrayList<Int>(targetSize)
        val chunkSize = amplitudes.size.toDouble() / targetSize
        for (i in 0 until targetSize) {
            val start = (i * chunkSize).toInt()
            val end = ((i + 1) * chunkSize).toInt().coerceAtMost(amplitudes.size)
            var max = 0
            for (j in start until end) {
                val value = amplitudes.get(j)
                if (value > max) max = value
            }
            result.add(max)
        }
        return result
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        instance = null
        amplituda = null
        context = null
    }
}
