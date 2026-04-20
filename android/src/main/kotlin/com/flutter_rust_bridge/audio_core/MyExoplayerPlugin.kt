package com.flutter_rust_bridge.audio_core

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.audiofx.Equalizer
import android.media.audiofx.BassBoost
import android.os.Build
import android.provider.MediaStore
import android.animation.ValueAnimator
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener

@UnstableApi
/** MyExoplayerPlugin */
class MyExoplayerPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    ActivityResultListener,
    RequestPermissionsResultListener {
    private class PlayerContext(
        var id: String,
        val player: ExoPlayer,
        val fftProcessor: FFTAudioProcessor,
        val cppEqualizerProcessor: CppEqualizerProcessor,
        val cppFingerprintProcessor: CppFingerprintProcessor,
        var equalizer: Equalizer? = null,
        var bassBoost: BassBoost? = null,
        var volumeAnimator: ValueAnimator? = null,
        var volumeCommandGeneration: Long = 0L
    )

    companion object {
        private var instance: MyExoplayerPlugin? = null
        private val playerContexts = mutableMapOf<String, PlayerContext>()
        private const val MAIN_PLAYER_ID = "main"
        private const val CROSSFADE_PLAYER_ID = "crossfade"
        private const val REQUEST_WRITE_MEDIA = 43041
        private const val REQUEST_READ_MEDIA = 4892

        init {
            System.loadLibrary("my_exoplayer")
        }

        private fun createPlayerListener(ctxRef: PlayerContext) = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                android.util.Log.d(
                    "AudioCore",
                    "listener onPlaybackStateChanged id=${ctxRef.id} state=$state " +
                        "isPlaying=${ctxRef.player.isPlaying} playWhenReady=${ctxRef.player.playWhenReady} " +
                        "pos=${ctxRef.player.currentPosition} duration=${ctxRef.player.duration}",
                )
                if (state == Player.STATE_READY) {
                    instance?.ensureAudioEffects(ctxRef.id)
                }
                sendPlayerState(ctxRef.id)
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                android.util.Log.d(
                    "AudioCore",
                    "listener onPlayerError id=${ctxRef.id} error=${error.message}",
                )
                sendPlayerState(ctxRef.id)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                android.util.Log.d(
                    "AudioCore",
                    "listener onIsPlayingChanged id=${ctxRef.id} isPlaying=$isPlaying " +
                        "playWhenReady=${ctxRef.player.playWhenReady} state=${ctxRef.player.playbackState} " +
                        "pos=${ctxRef.player.currentPosition}",
                )
                playerContexts[ctxRef.id]?.fftProcessor?.isPaused = !isPlaying
                sendPlayerState(ctxRef.id)
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int
            ) {
                android.util.Log.d(
                    "AudioCore",
                    "listener onPositionDiscontinuity id=${ctxRef.id} reason=$reason " +
                        "old=${oldPosition.positionMs} new=${newPosition.positionMs} " +
                        "state=${ctxRef.player.playbackState} isPlaying=${ctxRef.player.isPlaying}",
                )
                sendPlayerState(ctxRef.id)
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
                "position" to p.currentPosition,
                "error" to p.playerError?.message
            )
            android.util.Log.d(
                "AudioCore",
                "sendPlayerState id=$id state=${stateMap["state"]} " +
                    "isPlaying=${stateMap["isPlaying"]} playWhenReady=${p.playWhenReady} " +
                    "volume=${p.volume} position=${stateMap["position"]} duration=$clampedDuration " +
                    "error=${stateMap["error"]}",
            )
            inst.channel.invokeMethod("onPlayerStateChanged", stateMap)
        }

        private fun beginVolumeCommand(ctx: PlayerContext): Long {
            ctx.volumeAnimator?.cancel()
            ctx.volumeAnimator = null
            ctx.volumeCommandGeneration += 1
            return ctx.volumeCommandGeneration
        }
    }

    private lateinit var channel: MethodChannel
    private lateinit var mediaLibraryChannel: MethodChannel
    private lateinit var fftEventChannel: EventChannel
    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var amplituda: Amplituda? = null
    private var pendingMetadataWrite: PendingMetadataWrite? = null
    private var pendingMediaLibraryPermissionResult: Result? = null
    private var crossfadeAnimator: ValueAnimator? = null
    private var crossfadeGeneration: Long = 0L
    private var activeCrossfadeSession: CrossfadeSession? = null
    private var fftEventSink: EventChannel.EventSink? = null
    private val fftEmitHandler = Handler(Looper.getMainLooper())
    private val fftEmitLock = Any()
    private var fftPendingPayload: Pair<String, FloatArray>? = null
    private var fftLastEmitAtMs: Long = 0L
    private var fftEmitScheduled: Boolean = false

    private data class FftGroupingConfig(
        val frequencyGroups: Int = 32,
        val skipHighFrequencyGroups: Int = 0,
        val aggregationMode: String = "peak",
    )

    private var fftGroupingConfig = FftGroupingConfig()
    private val fftEmitRunnable = Runnable {
        val payload = synchronized(fftEmitLock) {
            fftEmitScheduled = false
            val current = fftPendingPayload
            fftPendingPayload = null
            if (current != null) {
                fftLastEmitAtMs = SystemClock.elapsedRealtime()
            }
            current
        }
        payload?.let { sendFftPayload(it.first, it.second) }
    }

    private data class CrossfadeSession(
        val generation: Long,
        val baseVolume: Float,
        val targetVolume: Float,
    )

    private data class PendingMetadataWrite(
        val path: String,
        val metadata: Map<String, Any?>,
        val result: Result,
    )

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        instance = this
        context = flutterPluginBinding.applicationContext
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "my_exoplayer")
        channel.setMethodCallHandler(this)
        mediaLibraryChannel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            "audio_core.media_library",
        )
        mediaLibraryChannel.setMethodCallHandler(this)
        fftEventChannel = EventChannel(
            flutterPluginBinding.binaryMessenger,
            "my_exoplayer/fft",
        )
        fftEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                fftEventSink = events
            }

            override fun onCancel(arguments: Any?) {
                fftEventSink = null
                synchronized(fftEmitLock) {
                    fftPendingPayload = null
                    fftEmitScheduled = false
                }
                fftEmitHandler.removeCallbacks(fftEmitRunnable)
            }
        })
        
        amplituda = Amplituda(context)
        // Initialize default player
        getOrCreatePlayerContext("main")
    }

    @OptIn(UnstableApi::class)
    private fun getOrCreatePlayerContext(
        id: String,
        handleAudioFocus: Boolean = true,
    ): PlayerContext {
        playerContexts[id]?.let { return it }

        val safeContext = context!!
        val fftProcessor = FFTAudioProcessor(1024)
        val cppEqualizerProcessor = CppEqualizerProcessor()
        val cppFingerprintProcessor = CppFingerprintProcessor()

        val renderersFactory = object : DefaultRenderersFactory(safeContext) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioTrackPlaybackParams: Boolean
            ): AudioSink? {
                return DefaultAudioSink.Builder(context)
                    // We must place cppFingerprintProcessor first, before it gets float-converted by EQ
                    .setAudioProcessors(arrayOf(cppFingerprintProcessor, cppEqualizerProcessor, fftProcessor))
                    .build()
            }
        }

        val audioAttributes = androidx.media3.common.AudioAttributes.Builder()
            .setUsage(androidx.media3.common.C.USAGE_MEDIA)
            .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()

        val player = ExoPlayer.Builder(safeContext, renderersFactory)
            .setAudioAttributes(audioAttributes, handleAudioFocus)
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(androidx.media3.common.C.WAKE_MODE_LOCAL)
            .build()

        android.util.Log.d(
            "AudioCore",
            "createPlayerContext id=$id handleAudioFocus=$handleAudioFocus",
        )
        
        player.addAnalyticsListener(EventLogger())
        cppEqualizerProcessor.setNumBands(10)
        
        val ctx = PlayerContext(id, player, fftProcessor, cppEqualizerProcessor, cppFingerprintProcessor)
        fftProcessor.updateGroupingOptions(
            fftGroupingConfig.frequencyGroups,
            fftGroupingConfig.skipHighFrequencyGroups,
            fftGroupingConfig.aggregationMode,
        )
        fftProcessor.onFftUpdated = { magnitudes ->
            instance?.emitFftData(ctx.id, magnitudes)
        }
        player.addListener(createPlayerListener(ctx))
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

    private class MainThreadResult(private val result: Result) : Result {
        private val handler = Handler(Looper.getMainLooper())
        private var isHandled = java.util.concurrent.atomic.AtomicBoolean(false)

        override fun success(res: Any?) {
            if (isHandled.getAndSet(true)) return
            handler.post {
                result.success(res)
            }
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            if (isHandled.getAndSet(true)) return
            handler.post {
                result.error(errorCode, errorMessage, errorDetails)
            }
        }

        override fun notImplemented() {
            if (isHandled.getAndSet(true)) return
            handler.post {
                result.notImplemented()
            }
        }
    }

    override fun onMethodCall(call: MethodCall, originalResult: Result) {
        val result = MainThreadResult(originalResult)
        val playerId = call.argument<String>("playerId") ?: "main"
        if(call.method != "getLatestFft"){
            android.util.Log.d(
                "AudioCore",
                "onMethodCall method=${call.method} playerId=$playerId args=${call.arguments}",
            )
        }

//        android.util.Log.d(
//            "AudioCore",
//            "onMethodCall method=${call.method} playerId=$playerId args=${call.arguments}",
//        )


        when (call.method) {
            "sayHello" -> {
                result.success(null)
                return
            }
            "ensureAudioPermission" -> {
                handleEnsureAudioPermission(result)
                return
            }
            "scanAudioLibrary" -> {
                handleScanAudioLibrary(result)
                return
            }
            "getWaveform" -> {
                val path = call.argument<String>("path") ?: return result.error("INVALID_ARGUMENT", "Path is null", null)
                val expectedChunks = call.argument<Int>("expectedChunks") ?: 0
                // Amplituda's processing and any content:// materialization can be expensive,
                // so keep it off the main thread to avoid janking the UI.
                Thread {
                    try {
                        val amp = amplituda ?: run {
                            result.error("INTERNAL_ERROR", "Amplituda not initialized", null)
                            return@Thread
                        }

                        val (localPath, isTemp) = ensureLocalPath(path)

                        amp.processAudio(localPath).get({ amResult ->
                            try {
                                val rawData = amResult.amplitudesAsList()
                                val processedData = if (expectedChunks > 0) {
                                    downsample(rawData, expectedChunks)
                                } else {
                                    rawData
                                }
                                result.success(processedData)
                            } finally {
                                if (isTemp) java.io.File(localPath).delete()
                            }
                        }, { error ->
                            try {
                                result.error("AMPLITUDA_ERROR", error.message, null)
                            } finally {
                                if (isTemp) java.io.File(localPath).delete()
                            }
                        })
                    } catch (e: Exception) {
                        result.error("AMPLITUDA_ERROR", e.message, null)
                    }
                }.start()
                return
            }
            "extractFingerprint" -> {
                val path = call.argument<String>("path") ?: return result.error("INVALID_ARGUMENT", "Path is null", null)
                val (localPath, isTemp) = ensureLocalPath(path)
                val safeContext = context ?: return result.error("INTERNAL_ERROR", "Context is null", null)

                Thread {
                    val uri = if (localPath.startsWith("/")) Uri.parse("file://$localPath") else Uri.parse(localPath)
                    val fingerprint = AudioFingerprintExtractor.extractFingerprint(safeContext, uri)
                    
                    if (fingerprint != null) {
                        result.success(fingerprint)
                    } else {
                        result.error("FINGERPRINT_FAILED", "Failed to decode or generate fingerprint", null)
                    }
                    if (isTemp) {
                        java.io.File(localPath).delete()
                    }
                }.start()
                return
            }
            "crossfade" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("INVALID_ARGUMENT", "Path is null", null)
                val durationMs = call.argument<Int>("durationMs")?.toLong() ?: 0L
                val positionMs = call.argument<Int>("positionMs")?.toLong()
                handleCrossfade(path, durationMs, positionMs, result)
                return
            }
            "load" -> {
                val url = call.argument<String>("url") ?: return result.error("INVALID_ARGUMENT", "URL is null", null)
                val ctx = getOrCreatePlayerContext(playerId)
                cancelActiveCrossfade()
                android.util.Log.d(
                    "AudioCore",
                    "load start playerId=$playerId url=$url currentCtx=${ctx.id} " +
                        "playWhenReady=${ctx.player.playWhenReady} isPlaying=${ctx.player.isPlaying}",
                )
                val mediaItem = MediaItem.fromUri(Uri.parse(url))
                ctx.player.setMediaItem(mediaItem)
                ctx.player.playWhenReady = false
                ctx.player.prepare()
                android.util.Log.d(
                    "AudioCore",
                    "load prepared playerId=$playerId url=$url state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady}",
                )
                result.success(null)
                return
            }
            "updateTrackMetadata" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("INVALID_ARGUMENT", "Path is null", null)
                val metadata = call.argument<Map<String, Any?>>("metadata")
                    ?: return result.error("INVALID_ARGUMENT", "Metadata is null", null)

                // The Flutter side sends a normalized map of tag fields here.
                // We keep the plugin layer thin: this method only handles the
                // platform bridge, then delegates the real file rewrite work to
                // AndroidMetadataWriter, which uses TagLib under the hood.
                handleUpdateTrackMetadata(path, metadata, result)
                return
            }
            "getTrackMetadata" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("INVALID_ARGUMENT", "Path is null", null)
                val fallbackMediaUri = call.argument<String>("fallbackMediaUri")
                val safeContext = context ?: return result.error(
                    "INTERNAL_ERROR",
                    "Context is null",
                    null,
                )

                try {
                    val metadata = AndroidMetadataWriter.readMetadata(
                        safeContext,
                        path,
                        fallbackMediaUri,
                    )
                    result.success(metadata)
                } catch (e: MetadataWriteException) {
                    result.error(
                        e.code,
                        e.message,
                        e.details + mapOf(
                            "exception" to (e.cause?.javaClass?.name ?: e.javaClass.name),
                        ),
                    )
                } catch (e: Exception) {
                    e.printStackTrace()
                    result.error(
                        "READ_FAILED",
                        e.message,
                        mapOf(
                            "path" to path,
                            "exception" to e::class.java.name,
                        ),
                    )
                }
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
            if (call.method == "dispose") {
                // Make dispose idempotent so repeated cleanup calls do not fail
                // when the player context has already been removed.
                result.success(null)
                return
            }
            result.error("PLAYER_NOT_FOUND", "Player context not found for ID: $playerId", null)
            return
        }

        when (call.method) {
            "play" -> {
                val fadeDurationMs = call.argument<Int>("fadeDurationMs")?.toLong() ?: 0L
                val targetVolume = call.argument<Double>("targetVolume")?.toFloat() ?: ctx.player.volume
                cancelActiveCrossfade()
                val commandGeneration = beginVolumeCommand(ctx)
                android.util.Log.d(
                    "AudioCore",
                    "play start playerId=$playerId fadeDurationMs=$fadeDurationMs " +
                        "targetVolume=$targetVolume state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady} " +
                        "volume=${ctx.player.volume}",
                )
                if (fadeDurationMs > 0) {
                    ctx.player.volume = 0f
                    ctx.player.play()
                    fadeVolumeTo(ctx, targetVolume, fadeDurationMs, commandGeneration)
                } else {
                    ctx.player.play()
                }
                android.util.Log.d(
                    "AudioCore",
                    "play issued playerId=$playerId state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady} " +
                        "volume=${ctx.player.volume}",
                )
                result.success(null)
            }
            "pause" -> {
                val fadeDurationMs = call.argument<Int>("fadeDurationMs")?.toLong() ?: 0L
                cancelActiveCrossfade()
                val commandGeneration = beginVolumeCommand(ctx)
                android.util.Log.d(
                    "AudioCore",
                    "pause start playerId=$playerId fadeDurationMs=$fadeDurationMs " +
                        "state=${ctx.player.playbackState} isPlaying=${ctx.player.isPlaying} " +
                        "playWhenReady=${ctx.player.playWhenReady} volume=${ctx.player.volume}",
                )
                if (fadeDurationMs > 0) {
                    val originalVolume = ctx.player.volume
                    fadeVolumeTo(ctx, 0f, fadeDurationMs, commandGeneration) {
                        if (ctx.volumeCommandGeneration != commandGeneration) return@fadeVolumeTo
                        ctx.player.pause()
                        ctx.player.volume = originalVolume
                    }
                } else {
                    ctx.player.pause()
                }
                android.util.Log.d(
                    "AudioCore",
                    "pause issued playerId=$playerId state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady} " +
                        "volume=${ctx.player.volume}",
                )
                result.success(null)
            }
            "seek" -> {
                val positionMs = call.argument<Int>("position")?.toLong() ?: 0L
                cancelActiveCrossfade()
                android.util.Log.d(
                    "AudioCore",
                    "seek playerId=$playerId positionMs=$positionMs state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady}",
                )
                ctx.player.seekTo(positionMs)
                result.success(null)
            }
            "prepareForFileWrite" -> {
                cancelActiveCrossfade()
                beginVolumeCommand(ctx)
                android.util.Log.d(
                    "AudioCore",
                    "prepareForFileWrite playerId=$playerId state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady}",
                )
                ctx.player.playWhenReady = false
                ctx.player.stop()
                ctx.player.clearMediaItems()
                ctx.fftProcessor.isPaused = true
                sendPlayerState(playerId)
                result.success(null)
            }
            "setVolume" -> {
                val volume = call.argument<Double>("volume")?.toFloat() ?: 1.0f
                val fadeDurationMs = call.argument<Int>("fadeDurationMs")?.toLong() ?: 0L
                cancelActiveCrossfade()
                val commandGeneration = beginVolumeCommand(ctx)
                android.util.Log.d(
                    "AudioCore",
                    "setVolume playerId=$playerId volume=$volume fadeDurationMs=$fadeDurationMs " +
                        "state=${ctx.player.playbackState} isPlaying=${ctx.player.isPlaying} " +
                        "playWhenReady=${ctx.player.playWhenReady}",
                )
                if (fadeDurationMs > 0) {
                    fadeVolumeTo(ctx, volume, fadeDurationMs, commandGeneration)
                } else {
                    ctx.player.volume = volume
                }
                result.success(null)
            }
            "getLatestFft" -> {
                result.success(ctx.fftProcessor.getLatestMagnitudes().toList())
            }
            "configureFftProcessing" -> {
                val groups = call.argument<Int>("frequencyGroups") ?: 32
                val skipHigh = call.argument<Int>("skipHighFrequencyGroups") ?: 0
                val aggregationMode = call.argument<String>("aggregationMode") ?: "peak"
                fftGroupingConfig = FftGroupingConfig(
                    frequencyGroups = groups.coerceAtLeast(1),
                    skipHighFrequencyGroups = skipHigh.coerceAtLeast(0),
                    aggregationMode = aggregationMode,
                )
                playerContexts.values.forEach { playerContext ->
                    playerContext.fftProcessor.updateGroupingOptions(
                        fftGroupingConfig.frequencyGroups,
                        fftGroupingConfig.skipHighFrequencyGroups,
                        fftGroupingConfig.aggregationMode,
                    )
                }
                result.success(null)
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
                val activeCrossfadeContext = playerId == CROSSFADE_PLAYER_ID && activeCrossfadeSession != null
                android.util.Log.d(
                    "AudioCore",
                    "dispose playerId=$playerId activeCrossfade=$activeCrossfadeContext " +
                        "currentContexts=${playerContexts.keys}",
                )
                if (playerId == MAIN_PLAYER_ID || playerId == CROSSFADE_PLAYER_ID) {
                    cancelActiveCrossfade()
                }
                if (playerContexts.remove(playerId) != null && !activeCrossfadeContext) {
                    releasePlayerContext(ctx)
                } else if (!activeCrossfadeContext && playerId != MAIN_PLAYER_ID && playerId != CROSSFADE_PLAYER_ID) {
                    releasePlayerContext(ctx)
                }
                result.success(null)
            }
            else -> {
                result.notImplemented()
            }
        }

    }

    private fun handleEnsureAudioPermission(result: Result) {
        android.util.Log.d(
            "AudioCore",
            "handleEnsureAudioPermission start sdk=${Build.VERSION.SDK_INT} " +
                "activityPresent=${activity != null} contextPresent=${context != null}",
        )
        if (hasAudioPermission()) {
            android.util.Log.d("AudioCore", "handleEnsureAudioPermission already granted")
            result.success(true)
            return
        }

        if (pendingMediaLibraryPermissionResult != null) {
            result.error(
                "PERMISSION_PENDING",
                "An audio permission request is already in progress.",
                null,
            )
            return
        }

        val safeActivity = activity ?: run {
            result.error(
                "NO_ACTIVITY",
                "Android activity is not attached, cannot request audio permission.",
                null,
            )
            return
        }

        pendingMediaLibraryPermissionResult = result
        android.util.Log.d(
            "AudioCore",
            "handleEnsureAudioPermission requesting permissions=" +
                requiredPermissions().joinToString(","),
        )
        ActivityCompat.requestPermissions(
            safeActivity,
            requiredPermissions(),
            REQUEST_READ_MEDIA,
        )
    }

    private fun handleScanAudioLibrary(result: Result) {
        android.util.Log.d(
            "AudioCore",
            "handleScanAudioLibrary start sdk=${Build.VERSION.SDK_INT} " +
                "permission=${hasAudioPermission()}",
        )
        if (!hasAudioPermission()) {
            result.error(
                "PERMISSION_DENIED",
                "Audio library permission has not been granted.",
                null,
            )
            return
        }

        val safeContext = context ?: run {
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }

        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.RELATIVE_PATH,
            MediaStore.Audio.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.DATA,
        )

        val sortOrder = "${MediaStore.Audio.Media.DATE_ADDED} DESC"
        val items = mutableListOf<Map<String, Any?>>()
        android.util.Log.d(
            "AudioCore",
            "handleScanAudioLibrary query uri=${MediaStore.Audio.Media.EXTERNAL_CONTENT_URI} " +
                "sortOrder=$sortOrder projectionSize=${projection.size}",
        )

        safeContext.contentResolver.query(
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            projection,
            null,
            null,
            sortOrder,
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val displayNameIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val titleIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val durationIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val relativePathIndex = cursor.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
            val bucketNameIndex = cursor.getColumnIndex(MediaStore.Audio.Media.BUCKET_DISPLAY_NAME)
            val mimeTypeIndex = cursor.getColumnIndex(MediaStore.Audio.Media.MIME_TYPE)
            val dateAddedIndex = cursor.getColumnIndex(MediaStore.Audio.Media.DATE_ADDED)
            val dataIndex = cursor.getColumnIndex(MediaStore.Audio.Media.DATA)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIndex)
                val mimeType = if (mimeTypeIndex >= 0) cursor.getString(mimeTypeIndex) else null
                val durationMs = cursor.getLong(durationIndex)
                val isPlayableAudio =
                    (mimeType?.startsWith("audio/") == true) || durationMs > 0L
                if (!isPlayableAudio) {
                    continue
                }

                val contentUri = Uri.withAppendedPath(
                    MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                    id.toString(),
                ).toString()
                val relativePath = if (relativePathIndex >= 0) cursor.getString(relativePathIndex) else null
                val dataPath = if (dataIndex >= 0) cursor.getString(dataIndex) else null
                val folderPath = relativePath?.takeIf { it.isNotBlank() }
                    ?: dataPath?.substringBeforeLast('/', missingDelimiterValue = "")
                    ?: ""

                items.add(
                    mapOf(
                        "id" to id.toString(),
                        "uri" to contentUri,
                        "filePath" to dataPath,
                        "title" to cursor.getString(titleIndex),
                        "displayName" to cursor.getString(displayNameIndex),
                        "artist" to cursor.getString(artistIndex),
                        "album" to cursor.getString(albumIndex),
                        "durationMs" to durationMs,
                        "relativePath" to folderPath,
                        "bucketDisplayName" to if (bucketNameIndex >= 0) cursor.getString(bucketNameIndex) else null,
                        "mimeType" to mimeType,
                        "dateAddedSeconds" to if (dateAddedIndex >= 0) cursor.getLong(dateAddedIndex) else null,
                    ),
                )
            }
        }

        android.util.Log.d(
            "AudioCore",
            "handleScanAudioLibrary finished count=${items.size} " +
                "permission=${hasAudioPermission()}",
        )
        if (items.isEmpty()) {
            android.util.Log.w(
                "AudioCore",
                "MediaStore query returned no playable audio items. Permission granted=${hasAudioPermission()}",
            )
        }

        result.success(items)
    }

    private fun hasAudioPermission(): Boolean {
        val safeActivity = activity
        val safeContext = context ?: return false
        val target = safeActivity ?: safeContext
        return requiredPermissions().all {
            ContextCompat.checkSelfPermission(target, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= 33) {
            arrayOf(Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_READ_MEDIA) return false

        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }

        pendingMediaLibraryPermissionResult?.success(granted)
        pendingMediaLibraryPermissionResult = null
        return true
    }

    private fun fadeVolumeTo(
        ctx: PlayerContext,
        targetVolume: Float,
        durationMs: Long,
        commandGeneration: Long,
        onEnd: (() -> Unit)? = null
    ) {
        android.util.Log.d(
            "AudioCore",
            "fadeVolumeTo start id=${ctx.id} from=${ctx.player.volume} target=$targetVolume " +
                "durationMs=$durationMs generation=$commandGeneration",
        )
        ctx.volumeAnimator?.cancel()
        val startVolume = ctx.player.volume
        val animator = ValueAnimator.ofFloat(startVolume, targetVolume)
        animator.duration = durationMs
        animator.addUpdateListener { animation ->
            if (ctx.volumeCommandGeneration != commandGeneration) {
                animation.cancel()
                return@addUpdateListener
            }
            ctx.player.volume = animation.animatedValue as Float
        }
        animator.addListener(object : android.animation.AnimatorListenerAdapter() {
            override fun onAnimationCancel(animation: android.animation.Animator) {
                android.util.Log.d(
                    "AudioCore",
                    "fadeVolumeTo cancel id=${ctx.id} generation=$commandGeneration " +
                        "currentGeneration=${ctx.volumeCommandGeneration}",
                )
                if (ctx.volumeAnimator === animator) {
                    ctx.volumeAnimator = null
                }
            }

            override fun onAnimationEnd(animation: android.animation.Animator) {
                if (ctx.volumeCommandGeneration != commandGeneration) return
                if (ctx.volumeAnimator === animator) {
                    ctx.volumeAnimator = null
                }
                android.util.Log.d(
                    "AudioCore",
                    "fadeVolumeTo end id=${ctx.id} target=$targetVolume generation=$commandGeneration",
                )
                onEnd?.invoke()
            }
        })
        ctx.volumeAnimator = animator
        Handler(Looper.getMainLooper()).post {
            if (ctx.volumeCommandGeneration != commandGeneration) return@post
            animator.start()
        }
    }

    private fun handleCrossfade(
        path: String,
        durationMs: Long,
        positionMs: Long?,
        result: Result,
    ) {
        try {
            val mainCtx = playerContexts[MAIN_PLAYER_ID] ?: run {
                result.error("PLAYER_NOT_FOUND", "Main player context not found.", null)
                return
            }

            android.util.Log.d(
                "AudioCore",
                "handleCrossfade start path=$path durationMs=$durationMs positionMs=$positionMs " +
                    "mainState=${mainCtx.player.playbackState} mainIsPlaying=${mainCtx.player.isPlaying} " +
                    "mainPlayWhenReady=${mainCtx.player.playWhenReady} mainVolume=${mainCtx.player.volume} " +
                    "contexts=${playerContexts.keys}",
            )

            // ExoPlayer may briefly report isPlaying=false during a normal
            // handoff even though the session is still intended to keep
            // playing. `playWhenReady` is a better signal here because it
            // stays true for active playback and avoids downgrading to an
            // abrupt swap when the state lags by a frame.
            if (durationMs <= 0L || !mainCtx.player.playWhenReady) {
                android.util.Log.d(
                    "AudioCore",
                    "handleCrossfade fallback immediate path=$path durationMs=$durationMs " +
                        "reason=${if (durationMs <= 0L) "zeroDuration" else "playWhenReadyFalse"}",
                )
                cancelActiveCrossfade()
                val mediaItem = MediaItem.fromUri(Uri.parse(path))
                mainCtx.player.setMediaItem(mediaItem)
                mainCtx.player.playWhenReady = true
                mainCtx.player.prepare()
                if (positionMs != null) {
                    mainCtx.player.seekTo(positionMs)
                }
                mainCtx.player.play()
                result.success(null)
                return
            }

            cancelActiveCrossfade()

            val incomingCtx = getOrCreatePlayerContext(
                CROSSFADE_PLAYER_ID,
                handleAudioFocus = false,
            )
            incomingCtx.id = CROSSFADE_PLAYER_ID
            incomingCtx.volumeAnimator?.cancel()
            incomingCtx.volumeAnimator = null

            val baseVolume = mainCtx.player.volume
            val mediaItem = MediaItem.fromUri(Uri.parse(path))

            android.util.Log.d(
                "AudioCore",
                "handleCrossfade deckSetup baseVolume=$baseVolume incomingId=${incomingCtx.id} " +
                    "incomingState=${incomingCtx.player.playbackState} incomingPlaying=${incomingCtx.player.isPlaying}",
            )

            incomingCtx.player.stop()
            incomingCtx.player.clearMediaItems()
            incomingCtx.player.volume = 0f
            incomingCtx.player.setMediaItem(mediaItem)
            incomingCtx.player.playWhenReady = true
            incomingCtx.player.prepare()
            if (positionMs != null) {
                incomingCtx.player.seekTo(positionMs)
            }
            incomingCtx.player.play()

            crossfadeGeneration += 1
            val generation = crossfadeGeneration
            activeCrossfadeSession = CrossfadeSession(
                generation = generation,
                baseVolume = baseVolume,
                targetVolume = baseVolume,
            )

            crossfadeAnimator?.cancel()
            val animator = ValueAnimator.ofFloat(0f, 1f)
            animator.duration = durationMs
            animator.addUpdateListener { animation ->
                if (crossfadeGeneration != generation) {
                    animation.cancel()
                    return@addUpdateListener
                }
                val progress = (animation.animatedValue as Float).coerceIn(0f, 1f)
                val outgoingVolume = (baseVolume * (1f - progress)).coerceIn(0f, 1f)
                val incomingVolume = (baseVolume * progress).coerceIn(0f, 1f)
                mainCtx.player.volume = outgoingVolume
                incomingCtx.player.volume = incomingVolume
                android.util.Log.v(
                    "AudioCore",
                    "handleCrossfade tick gen=$generation progress=$progress " +
                        "outgoing=$outgoingVolume incoming=$incomingVolume " +
                        "mainPlaying=${mainCtx.player.isPlaying} incomingPlaying=${incomingCtx.player.isPlaying}",
                )
            }
            animator.addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationCancel(animation: android.animation.Animator) {
                    android.util.Log.d(
                        "AudioCore",
                        "handleCrossfade cancel generation=$generation current=${crossfadeGeneration}",
                    )
                    if (crossfadeAnimator === animator) {
                        crossfadeAnimator = null
                    }
                }

                override fun onAnimationEnd(animation: android.animation.Animator) {
                    if (crossfadeGeneration != generation) return
                    android.util.Log.d(
                        "AudioCore",
                        "handleCrossfade end generation=$generation current=${crossfadeGeneration}",
                    )
                    if (crossfadeAnimator === animator) {
                        crossfadeAnimator = null
                    }
                    finalizeCrossfade(generation)
                }
            })
            crossfadeAnimator = animator
            Handler(Looper.getMainLooper()).post {
                if (crossfadeGeneration != generation) return@post
                animator.start()
            }

            result.success(null)
        } catch (e: Exception) {
            result.error("CROSSFADE_FAILED", e.message, mapOf("exception" to e.javaClass.name))
        }
    }

    private fun cancelActiveCrossfade(restoreMainVolume: Boolean = true) {
        val session = activeCrossfadeSession ?: return
        android.util.Log.d(
            "AudioCore",
            "cancelActiveCrossfade restoreMainVolume=$restoreMainVolume sessionGen=${session.generation} " +
                "baseVolume=${session.baseVolume} targetVolume=${session.targetVolume} currentGen=$crossfadeGeneration",
        )
        activeCrossfadeSession = null
        crossfadeGeneration += 1
        crossfadeAnimator?.cancel()
        crossfadeAnimator = null

        playerContexts[CROSSFADE_PLAYER_ID]?.let { incoming ->
            incoming.player.stop()
            incoming.player.clearMediaItems()
            releasePlayerContext(incoming)
            playerContexts.remove(CROSSFADE_PLAYER_ID)
        }

        if (restoreMainVolume) {
            playerContexts[MAIN_PLAYER_ID]?.player?.volume = session.baseVolume
        }
    }

    private fun finalizeCrossfade(generation: Long) {
        val session = activeCrossfadeSession ?: return
        if (session.generation != generation) return

        android.util.Log.d(
            "AudioCore",
            "finalizeCrossfade generation=$generation baseVolume=${session.baseVolume} " +
                "targetVolume=${session.targetVolume} contexts=${playerContexts.keys}",
        )

        val incoming = playerContexts[CROSSFADE_PLAYER_ID] ?: run {
            activeCrossfadeSession = null
            return
        }
        val outgoing = playerContexts[MAIN_PLAYER_ID]

        incoming.player.volume = session.targetVolume
        incoming.id = MAIN_PLAYER_ID
        incoming.player.setAudioAttributes(
            androidx.media3.common.AudioAttributes.Builder()
                .setUsage(androidx.media3.common.C.USAGE_MEDIA)
                .setContentType(androidx.media3.common.C.AUDIO_CONTENT_TYPE_MUSIC)
                .build(),
            true,
        )

        outgoing?.let {
            it.player.stop()
            it.player.clearMediaItems()
            releasePlayerContext(it)
        }
        playerContexts.remove(MAIN_PLAYER_ID)
        playerContexts.remove(CROSSFADE_PLAYER_ID)
        playerContexts[MAIN_PLAYER_ID] = incoming
        activeCrossfadeSession = null
        sendPlayerState(MAIN_PLAYER_ID)
    }

    private fun releasePlayerContext(ctx: PlayerContext) {
        ctx.volumeAnimator?.cancel()
        ctx.volumeAnimator = null
        ctx.fftProcessor.onFftUpdated = null
        ctx.player.release()
        ctx.equalizer?.release()
        ctx.bassBoost?.release()
        ctx.cppEqualizerProcessor.release()
        ctx.cppFingerprintProcessor.release()
    }

    private fun handleUpdateTrackMetadata(
        path: String,
        metadata: Map<String, Any?>,
        result: Result,
    ) {
        val safeContext = context ?: run {
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }

        try {
            // This is the actual metadata rewrite step.
            // AndroidMetadataWriter will:
            // 1) open the file as a descriptor,
            // 2) read current tags,
            // 3) merge Flutter's updates,
            // 4) call TagLib.savePropertyMap/savePictures,
            // 5) throw recoverable security errors if Android needs user approval.
            val success = AndroidMetadataWriter.updateMetadata(safeContext, path, metadata)
            if (success) {
                result.success(true)
            } else {
                result.error(
                    "WRITE_FAILED",
                    "Failed to update audio metadata.",
                    mapOf(
                        "path" to path,
                        "metadataKeys" to metadata.keys.sorted(),
                    ),
                )
            }
        } catch (e: MetadataWriteException) {
            val cause = e.cause
            if (cause is android.app.RecoverableSecurityException) {
                requestWritePermission(path, metadata, result, cause)
                return
            }
            if (cause is SecurityException) {
                requestWritePermission(path, metadata, result, cause)
                return
            }

            result.error(
                e.code,
                e.message,
                e.details + mapOf("exception" to (cause?.javaClass?.name ?: e.javaClass.name)),
            )
        } catch (e: android.app.RecoverableSecurityException) {
            requestWritePermission(path, metadata, result, e)
        } catch (e: SecurityException) {
            requestWritePermission(path, metadata, result, e)
        } catch (e: Exception) {
            e.printStackTrace()
            result.error(
                "WRITE_FAILED",
                e.message,
                mapOf(
                    "path" to path,
                    "exception" to e::class.java.name,
                ),
            )
        }
    }

    private fun requestWritePermission(
        path: String,
        metadata: Map<String, Any?>,
        result: Result,
        exception: Exception,
    ) {
        if (pendingMetadataWrite != null) {
            result.error(
                "PERMISSION_PENDING",
                "A metadata write permission request is already in progress.",
                null,
            )
            return
        }

        val safeActivity = activity ?: run {
            result.error(
                "NO_ACTIVITY",
                "Android activity is not attached, cannot request write permission.",
                null,
            )
            return
        }
        val safeContext = context ?: run {
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }

        val fallbackMediaUri = metadata["fallbackMediaUri"]
            ?.toString()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        val requestUri = when {
            path.startsWith("content://") -> path
            // If the player track uses a file path, we try to fall back to the
            // MediaStore content URI. Android's permission dialog can approve
            // rewrites against that URI on newer versions.
            fallbackMediaUri?.startsWith("content://") == true -> fallbackMediaUri
            else -> null
        }

        if (requestUri == null) {
            result.error(
                "WRITE_PERMISSION_REQUIRED",
                "This media item cannot be approved for direct rewrite because no MediaStore URI is available.",
                mapOf("path" to path),
            )
            return
        }

        val uri = Uri.parse(requestUri)
        val intentSender = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ can request write access directly through MediaStore.
            MediaStore.createWriteRequest(safeContext.contentResolver, listOf(uri)).intentSender
        } else if (exception is android.app.RecoverableSecurityException) {
            // Older versions use RecoverableSecurityException's built-in action.
            exception.userAction.actionIntent.intentSender
        } else {
            result.error(
                "WRITE_PERMISSION_REQUIRED",
                "This media item requires user approval to modify.",
                null,
            )
            return
        }

        pendingMetadataWrite = PendingMetadataWrite(path, metadata, result)
        try {
            safeActivity.startIntentSenderForResult(
                intentSender,
                REQUEST_WRITE_MEDIA,
                null,
                0,
                0,
                0,
            )
        } catch (launchError: Exception) {
            pendingMetadataWrite = null
            launchError.printStackTrace()
            result.error("WRITE_PERMISSION_LAUNCH_FAILED", launchError.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_WRITE_MEDIA) return false

        val pending = pendingMetadataWrite ?: return true
        pendingMetadataWrite = null

        if (resultCode != Activity.RESULT_OK) {
            pending.result.error(
                "WRITE_PERMISSION_DENIED",
                "User denied permission to modify the media item.",
                mapOf("path" to pending.path),
            )
            return true
        }

        val safeContext = context ?: run {
            pending.result.error("INTERNAL_ERROR", "Context is null", null)
            return true
        }

        try {
            val success = AndroidMetadataWriter.updateMetadata(
                safeContext,
                pending.path,
                pending.metadata,
            )
            if (success) {
                pending.result.success(true)
            } else {
                pending.result.error(
                    "WRITE_FAILED",
                    "Failed to update audio metadata.",
                    mapOf("path" to pending.path),
                )
            }
        } catch (e: Exception) {
            e.printStackTrace()
            pending.result.error(
                "WRITE_FAILED",
                e.message,
                mapOf(
                    "path" to pending.path,
                    "exception" to e::class.java.name,
                ),
            )
        }

        return true
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
        mediaLibraryChannel.setMethodCallHandler(null)
        fftEventChannel.setStreamHandler(null)
        fftEventSink = null
        instance = null
        amplituda = null
        context = null
        pendingMetadataWrite = null
        pendingMediaLibraryPermissionResult = null
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    private fun emitFftData(playerId: String, magnitudes: FloatArray) {
        synchronized(fftEmitLock) {
            fftPendingPayload = playerId to magnitudes.copyOf()
            val now = SystemClock.elapsedRealtime()
            val elapsed = now - fftLastEmitAtMs
            val throttleMs = 16L
            if (elapsed >= throttleMs && !fftEmitScheduled) {
                fftLastEmitAtMs = now
                val current = fftPendingPayload
                fftPendingPayload = null
                if (current != null) {
                    fftEmitHandler.post { sendFftPayload(current.first, current.second) }
                }
                return
            }

            if (!fftEmitScheduled) {
                fftEmitScheduled = true
                val delay = (throttleMs - elapsed).coerceAtLeast(1L)
                fftEmitHandler.postDelayed(fftEmitRunnable, delay)
            }
        }
    }

    private fun sendFftPayload(playerId: String, magnitudes: FloatArray) {
        val sink = fftEventSink ?: return
        val payload = mapOf(
            "playerId" to playerId,
            "values" to magnitudes.map { it.toDouble() },
        )
        sink.success(payload)
    }
}
