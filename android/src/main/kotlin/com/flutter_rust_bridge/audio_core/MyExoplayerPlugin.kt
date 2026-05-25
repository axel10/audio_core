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
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MimeTypes
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.RendererCapabilities
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer
import androidx.media3.exoplayer.util.EventLogger
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Composition
import androidx.media3.transformer.TransformationRequest

import android.os.Environment
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.documentfile.provider.DocumentFile
import java.io.FileInputStream
import java.util.Locale

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
private class FlacSkippingMediaCodecAudioRenderer(
    context: Context,
    mediaCodecSelector: MediaCodecSelector,
    enableDecoderFallback: Boolean,
    eventHandler: Handler?,
    eventListener: AudioRendererEventListener?,
    audioSink: AudioSink,
) : MediaCodecAudioRenderer(
    context,
    mediaCodecSelector,
    enableDecoderFallback,
    eventHandler,
    eventListener,
    audioSink,
) {
    protected override fun supportsFormat(
        mediaCodecSelector: MediaCodecSelector,
        format: Format,
    ): Int {
        if (MimeTypes.AUDIO_FLAC == format.sampleMimeType) {
            return RendererCapabilities.create(C.FORMAT_UNSUPPORTED_TYPE)
        }
        return super.supportsFormat(mediaCodecSelector, format)
    }
}

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
        private const val REQUEST_PICK_OUTPUT_DIRECTORY = 42109

        init {
            System.loadLibrary("my_exoplayer")
        }

        private fun createPlayerListener(ctxRef: PlayerContext) = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                NativeLog.d(
                    "AudioCore",
                    "listener onPlaybackStateChanged id=${ctxRef.id} state=$state " +
                        "isPlaying=${ctxRef.player.isPlaying} playWhenReady=${ctxRef.player.playWhenReady} " +
                        "pos=${ctxRef.player.currentPosition} duration=${ctxRef.player.duration}",
                )
                if (state == Player.STATE_READY) {
                    instance?.ensureAudioEffects(ctxRef.id)
                }
                instance?.sendPlayerState(ctxRef.id)
            }

            override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                NativeLog.d(
                    "AudioCore",
                    "listener onPlayerError id=${ctxRef.id} error=${error.message}",
                )
                instance?.sendPlayerState(ctxRef.id)
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                NativeLog.d(
                    "AudioCore",
                    "listener onIsPlayingChanged id=${ctxRef.id} isPlaying=$isPlaying " +
                        "playWhenReady=${ctxRef.player.playWhenReady} state=${ctxRef.player.playbackState} " +
                        "pos=${ctxRef.player.currentPosition}",
                )
                playerContexts[ctxRef.id]?.fftProcessor?.isPaused = !isPlaying
                instance?.sendPlayerState(ctxRef.id)
            }

            override fun onPositionDiscontinuity(
                oldPosition: Player.PositionInfo,
                newPosition: Player.PositionInfo,
                reason: Int
            ) {
                NativeLog.d(
                    "AudioCore",
                    "listener onPositionDiscontinuity id=${ctxRef.id} reason=$reason " +
                        "old=${oldPosition.positionMs} new=${newPosition.positionMs} " +
                        "state=${ctxRef.player.playbackState} isPlaying=${ctxRef.player.isPlaying}",
                )
                instance?.sendPlayerState(ctxRef.id)
            }
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
    private lateinit var safChannel: MethodChannel
    private var pendingDirectoryResult: Result? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingMetadataWrite: PendingMetadataWrite? = null
    private var pendingMediaLibraryPermissionResult: Result? = null
    private var crossfadeAnimator: ValueAnimator? = null
    private var crossfadeGeneration: Long = 0L
    private var activeCrossfadeSession: CrossfadeSession? = null
    private var fftEventSink: EventChannel.EventSink? = null
    private val fftEmitHandler = Handler(Looper.getMainLooper())
    private val fftEmitLock = Any()
    private val fftQueue = java.util.concurrent.ConcurrentLinkedQueue<Pair<String, FloatArray>>()
    private var fftConsumerActive: Boolean = false
    private val activeTransformers = java.util.concurrent.ConcurrentHashMap<String, Transformer>()

    private data class FftGroupingConfig(
        val frequencyGroups: Int = 32,
        val skipHighFrequencyGroups: Int = 0,
        val aggregationMode: String = "peak",
    )

    private var fftGroupingConfig = FftGroupingConfig()
    private val fftConsumerRunnable = object : Runnable {
        override fun run() {
            val payload = fftQueue.poll()
            if (payload != null) {
                sendFftPayload(payload.first, payload.second)
            }
            synchronized(fftEmitLock) {
                if (!fftQueue.isEmpty()) {
                    var frameDurationMs = 11L
                    val mainCtx = playerContexts[MAIN_PLAYER_ID]
                    if (mainCtx != null) {
                        val sampleRate = mainCtx.fftProcessor.sampleRate
                        if (sampleRate > 0) {
                            frameDurationMs = (512.0 / sampleRate * 1000.0).toLong().coerceIn(5, 50)
                        }
                    }
                    fftEmitHandler.postDelayed(this, frameDurationMs)
                } else {
                    fftConsumerActive = false
                }
            }
        }
    }

    private data class CrossfadeSession(
        val generation: Long,
        val baseVolume: Float,
        val targetVolume: Float,
    )

    private data class PendingMetadataWrite(
        val updates: List<PendingMetadataWriteItem>,
        val result: Result,
        val returnBatchResults: Boolean,
    )

    private data class PendingMetadataWriteItem(
        val path: String,
        val metadata: Map<String, Any?>? = null,
        val sourcePath: String? = null,
    )

    private sealed class MetadataBatchWriteResult {
        data class Completed(val results: List<Boolean>) : MetadataBatchWriteResult()

        data class PermissionRequired(
            val exception: Exception,
        ) : MetadataBatchWriteResult()
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        instance = this
        context = flutterPluginBinding.applicationContext
        NativeLog.init(flutterPluginBinding.applicationContext)
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
                    fftQueue.clear()
                    fftConsumerActive = false
                }
                fftEmitHandler.removeCallbacks(fftConsumerRunnable)
            }
        })
        
        safChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "com.example.audio_converter/saf")
        safChannel.setMethodCallHandler(safMethodCallHandler)
        
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
            init {
                // Keep the extension renderer in the normal position, but let
                // MediaCodec explicitly step aside for FLAC so only that format
                // falls through to FFmpeg.
                setExtensionRendererMode(EXTENSION_RENDERER_MODE_ON)
            }

            override fun buildAudioRenderers(
                context: Context,
                extensionRendererMode: Int,
                mediaCodecSelector: MediaCodecSelector,
                enableDecoderFallback: Boolean,
                audioSink: AudioSink,
                eventHandler: Handler,
                eventListener: AudioRendererEventListener,
                out: ArrayList<Renderer>,
            ) {
                out.add(
                    FlacSkippingMediaCodecAudioRenderer(
                        context,
                        mediaCodecSelector,
                        enableDecoderFallback,
                        eventHandler,
                        eventListener,
                        audioSink,
                    ),
                )

                if (extensionRendererMode == EXTENSION_RENDERER_MODE_OFF) {
                    return
                }

                // The vendored FFmpeg extension should only receive the FLAC
                // stream because the MediaCodec renderer above explicitly
                // rejects FLAC before renderer selection happens.
                out.add(
                    FfmpegAudioRenderer(
                        eventHandler,
                        eventListener,
                        audioSink,
                    ),
                )
            }

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

        NativeLog.d(
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
//        if(call.method != "getLatestFft"){
//            NativeLog.d(
//                "AudioCore",
//                "onMethodCall method=${call.method} playerId=$playerId args=${call.arguments}",
//            )
//        }

//        NativeLog.d(
//            "AudioCore",
//            "onMethodCall method=${call.method} playerId=$playerId args=${call.arguments}",
//        )


        when (call.method) {
            "sayHello" -> {
                result.success(null)
                return
            }
            "convertFileWithTransformer" -> {
                val inputPath = call.argument<String>("inputPath")
                    ?: return result.error("INVALID_ARGUMENT", "Input path is null", null)
                val outputPath = call.argument<String>("outputPath")
                    ?: return result.error("INVALID_ARGUMENT", "Output path is null", null)
                val bitRate = call.argument<Int>("bitRate")
                val bitRateMode = call.argument<String>("bitRateMode")
                val sampleRate = call.argument<Int>("sampleRate")
                val channels = call.argument<Int>("channels")
                handleConvertFileWithTransformer(
                    inputPath = inputPath,
                    outputPath = outputPath,
                    bitRate = bitRate,
                    bitRateMode = bitRateMode,
                    sampleRate = sampleRate,
                    channels = channels,
                    result = result
                )
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
                Thread {
                    var localPath = path
                    var isTemp = false
                    try {
                        val resolvedPath = ensureLocalPath(path)
                        localPath = resolvedPath.first
                        isTemp = resolvedPath.second

                        val rawWaveform = ChromaprintNative
                            .nativeGetWaveformFromFileFfmpeg(localPath, expectedChunks)
                            ?.toList()

                        if (rawWaveform != null) {
                            // Scale values by 100.0 to match the 0.0 - 100.0 range expected by Dart
                            val scaledWaveform = rawWaveform.map { it * 100.0 }
                            val processedData = if (expectedChunks > 0) {
                                downsampleWaveform(scaledWaveform, expectedChunks)
                            } else {
                                scaledWaveform
                            }
                            result.success(processedData)
                        } else {
                            result.error("WAVEFORM_ERROR", "Failed to extract waveform", null)
                        }
                    } catch (e: Exception) {
                        result.error("WAVEFORM_ERROR", e.message, null)
                    } finally {
                        if (isTemp) {
                            java.io.File(localPath).delete()
                        }
                    }
                }.start()
                return
            }
            "extractFingerprint" -> {
                val path = call.argument<String>("path") ?: return result.error("INVALID_ARGUMENT", "Path is null", null)
                val (localPath, isTemp) = ensureLocalPath(path)
                val safeContext = context ?: return result.error("INTERNAL_ERROR", "Context is null", null)

                Thread {
                    val fingerprint = AudioFingerprintExtractor.extractFingerprint(safeContext, localPath)
                    
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
            "transition" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("INVALID_ARGUMENT", "Path is null", null)
                val durationMs = call.argument<Int>("durationMs")?.toLong() ?: 0L
                val positionMs = call.argument<Int>("positionMs")?.toLong()
                val autoPlay = call.argument<Boolean>("autoPlay") ?: true
                val mainCtx = playerContexts[MAIN_PLAYER_ID] ?: getOrCreatePlayerContext(
                    MAIN_PLAYER_ID,
                )
                val targetVolume =
                    call.argument<Double>("targetVolume")?.toFloat() ?: mainCtx.player.volume
                handleSequentialTransition(
                    path = path,
                    durationMs = durationMs,
                    positionMs = positionMs,
                    autoPlay = autoPlay,
                    targetVolume = targetVolume.coerceIn(0f, 1f),
                    result = result,
                )
                return
            }
            "load" -> {
                val url = call.argument<String>("url") ?: return result.error("INVALID_ARGUMENT", "URL is null", null)
                val ctx = getOrCreatePlayerContext(playerId)
                cancelActiveCrossfade()
                NativeLog.d(
                    "AudioCore",
                    "load start playerId=$playerId url=$url currentCtx=${ctx.id} " +
                        "playWhenReady=${ctx.player.playWhenReady} isPlaying=${ctx.player.isPlaying}",
                )
                val mediaItem = MediaItem.fromUri(Uri.parse(url))
                ctx.player.setMediaItem(mediaItem)
                ctx.player.playWhenReady = false
                ctx.player.prepare()
                NativeLog.d(
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
            "updateTrackMetadataBatch" -> {
                val rawUpdates = call.argument<List<Map<String, Any?>>>("updates")
                    ?: return result.error("INVALID_ARGUMENT", "Updates are null", null)
                handleUpdateTrackMetadataBatch(rawUpdates, result)
                return
            }
            "supportsBatchMetadataWrite" -> {
                result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                return
            }
            "copyTrackMetadataBatch" -> {
                val rawRequests = call.argument<List<Map<String, Any?>>>("requests")
                    ?: return result.error("INVALID_ARGUMENT", "Requests are null", null)
                handleCopyTrackMetadataBatch(rawRequests, result)
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
                val activeCrossfade = playerId == MAIN_PLAYER_ID && activeCrossfadeSession != null
                if (!activeCrossfade) {
                    cancelActiveCrossfade()
                }
                val commandGeneration = beginVolumeCommand(ctx)
                NativeLog.d(
                    "AudioCore",
                    "play start playerId=$playerId fadeDurationMs=$fadeDurationMs " +
                        "targetVolume=$targetVolume state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady} " +
                        "volume=${ctx.player.volume}",
                )
                if (activeCrossfade) {
                    val activeContexts = activePlaybackContexts()
                    activeContexts.forEach { beginVolumeCommand(it) }
                    activeContexts.forEach { it.player.play() }
                } else if (fadeDurationMs > 0) {
                    ctx.player.volume = 0f
                    ctx.player.play()
                    fadeVolumeTo(ctx, targetVolume, fadeDurationMs, commandGeneration)
                } else {
                    ctx.player.play()
                }
                NativeLog.d(
                    "AudioCore",
                    "play issued playerId=$playerId state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady} " +
                        "volume=${ctx.player.volume}",
                )
                result.success(null)
            }
            "pause" -> {
                val fadeDurationMs = call.argument<Int>("fadeDurationMs")?.toLong() ?: 0L
                val activeCrossfade = playerId == MAIN_PLAYER_ID && activeCrossfadeSession != null
                if (!activeCrossfade) {
                    cancelActiveCrossfade()
                }
                val commandGeneration = beginVolumeCommand(ctx)
                NativeLog.d(
                    "AudioCore",
                    "pause start playerId=$playerId fadeDurationMs=$fadeDurationMs " +
                        "state=${ctx.player.playbackState} isPlaying=${ctx.player.isPlaying} " +
                        "playWhenReady=${ctx.player.playWhenReady} volume=${ctx.player.volume}",
                )
                if (activeCrossfade) {
                    val activeContexts = activePlaybackContexts()
                    activeContexts.forEach { beginVolumeCommand(it) }
                    activeContexts.forEach { it.player.pause() }
                } else if (fadeDurationMs > 0) {
                    val originalVolume = ctx.player.volume
                    fadeVolumeTo(ctx, 0f, fadeDurationMs, commandGeneration) {
                        if (ctx.volumeCommandGeneration != commandGeneration) return@fadeVolumeTo
                        ctx.player.pause()
                        ctx.player.volume = originalVolume
                    }
                } else {
                    ctx.player.pause()
                }
                NativeLog.d(
                    "AudioCore",
                    "pause issued playerId=$playerId state=${ctx.player.playbackState} " +
                        "isPlaying=${ctx.player.isPlaying} playWhenReady=${ctx.player.playWhenReady} " +
                        "volume=${ctx.player.volume}",
                )
                result.success(null)
            }
            "seek" -> {
                val positionMs = call.argument<Int>("position")?.toLong() ?: 0L
                if (playerId == MAIN_PLAYER_ID && activeCrossfadeSession != null) {
                    settleActiveCrossfadeIfNeeded()
                }
                val targetCtx = playerContexts[playerId] ?: if (playerId == "main") {
                    try {
                        getOrCreatePlayerContext("main")
                    } catch (e: Exception) {
                        result.error("INIT_ERROR", "Lazy init failed: ${e.message}", null)
                        return
                    }
                } else {
                    null
                }
                if (targetCtx == null) {
                    result.error("PLAYER_NOT_FOUND", "Player context not found for ID: $playerId", null)
                    return
                }
                NativeLog.d(
                    "AudioCore",
                    "seek playerId=$playerId positionMs=$positionMs state=${targetCtx.player.playbackState} " +
                        "isPlaying=${targetCtx.player.isPlaying} playWhenReady=${targetCtx.player.playWhenReady}",
                )
                targetCtx.player.seekTo(positionMs)
                result.success(null)
            }
            "prepareForFileWrite" -> {
                cancelActiveCrossfade()
                beginVolumeCommand(ctx)
                NativeLog.d(
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
                val activeCrossfade = playerId == MAIN_PLAYER_ID && activeCrossfadeSession != null
                if (!activeCrossfade) {
                    cancelActiveCrossfade()
                }
                val commandGeneration = beginVolumeCommand(ctx)
                NativeLog.d(
                    "AudioCore",
                    "setVolume playerId=$playerId volume=$volume fadeDurationMs=$fadeDurationMs " +
                        "state=${ctx.player.playbackState} isPlaying=${ctx.player.isPlaying} " +
                        "playWhenReady=${ctx.player.playWhenReady}",
                )
                if (activeCrossfade) {
                    val activeContexts = activePlaybackContexts()
                    activeContexts.forEach { beginVolumeCommand(it) }
                    activeContexts.forEach { activeCtx ->
                        if (fadeDurationMs > 0) {
                            fadeVolumeTo(
                                activeCtx,
                                volume,
                                fadeDurationMs,
                                activeCtx.volumeCommandGeneration,
                            )
                        } else {
                            activeCtx.player.volume = volume
                        }
                    }
                } else if (fadeDurationMs > 0) {
                    fadeVolumeTo(ctx, volume, fadeDurationMs, commandGeneration)
                } else {
                    ctx.player.volume = volume
                }
                result.success(null)
            }
            "getLatestFft" -> {
                val snapshotCtx = if (playerId == MAIN_PLAYER_ID && activeCrossfadeSession != null) {
                    publicPlaybackContext() ?: ctx
                } else {
                    ctx
                }
                result.success(snapshotCtx.fftProcessor.getLatestMagnitudes().toList())
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
                val snapshotCtx = if (playerId == MAIN_PLAYER_ID && activeCrossfadeSession != null) {
                    publicPlaybackContext() ?: ctx
                } else {
                    ctx
                }
                val pos = snapshotCtx.player.currentPosition
                val now = System.currentTimeMillis()
                result.success(mapOf("position" to (if (pos < 0) 0L else pos), "takenAt" to now))
            }
            "getDuration" -> {
                val snapshotCtx = if (playerId == MAIN_PLAYER_ID && activeCrossfadeSession != null) {
                    publicPlaybackContext() ?: ctx
                } else {
                    ctx
                }
                val duration = snapshotCtx.player.duration
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
                NativeLog.d(
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
        NativeLog.d(
            "AudioCore",
            "handleEnsureAudioPermission start sdk=${Build.VERSION.SDK_INT} " +
                "activityPresent=${activity != null} contextPresent=${context != null}",
        )
        if (hasAudioPermission()) {
            NativeLog.d("AudioCore", "handleEnsureAudioPermission already granted")
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
        NativeLog.d(
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
        NativeLog.d(
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
        NativeLog.d(
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

        NativeLog.d(
            "AudioCore",
            "handleScanAudioLibrary finished count=${items.size} " +
                "permission=${hasAudioPermission()}",
        )
        if (items.isEmpty()) {
            NativeLog.w(
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
        NativeLog.d(
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
                NativeLog.d(
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
                NativeLog.d(
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

            NativeLog.d(
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
                NativeLog.d(
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

            NativeLog.d(
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
                NativeLog.v(
                    "AudioCore",
                    "handleCrossfade tick gen=$generation progress=$progress " +
                        "outgoing=$outgoingVolume incoming=$incomingVolume " +
                        "mainPlaying=${mainCtx.player.isPlaying} incomingPlaying=${incomingCtx.player.isPlaying}",
                )
            }
            animator.addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationCancel(animation: android.animation.Animator) {
                    NativeLog.d(
                        "AudioCore",
                        "handleCrossfade cancel generation=$generation current=${crossfadeGeneration}",
                    )
                    if (crossfadeAnimator === animator) {
                        crossfadeAnimator = null
                    }
                }

                override fun onAnimationEnd(animation: android.animation.Animator) {
                    if (crossfadeGeneration != generation) return
                    NativeLog.d(
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

    private fun handleSequentialTransition(
        path: String,
        durationMs: Long,
        positionMs: Long?,
        autoPlay: Boolean,
        targetVolume: Float,
        result: Result,
    ) {
        try {
            val mainCtx = playerContexts[MAIN_PLAYER_ID] ?: run {
                result.error("PLAYER_NOT_FOUND", "Main player context not found.", null)
                return
            }

            NativeLog.d(
                "AudioCore",
                "handleSequentialTransition start path=$path durationMs=$durationMs " +
                    "positionMs=$positionMs autoPlay=$autoPlay " +
                    "state=${mainCtx.player.playbackState} isPlaying=${mainCtx.player.isPlaying} " +
                    "playWhenReady=${mainCtx.player.playWhenReady} volume=${mainCtx.player.volume}",
            )

            cancelActiveCrossfade()

            val mediaItem = MediaItem.fromUri(Uri.parse(path))
            val shouldFade = durationMs > 0L
            val commandGeneration = beginVolumeCommand(mainCtx)

            fun loadReplacement() {
                mainCtx.player.stop()
                mainCtx.player.clearMediaItems()
                mainCtx.player.setMediaItem(mediaItem)
                mainCtx.player.playWhenReady = autoPlay
                mainCtx.player.volume = if (autoPlay && shouldFade) 0f else targetVolume
                mainCtx.player.prepare()
                if (positionMs != null) {
                    mainCtx.player.seekTo(positionMs)
                }

                if (autoPlay) {
                    mainCtx.player.play()
                    if (shouldFade) {
                        fadeVolumeTo(
                            mainCtx,
                            targetVolume,
                            durationMs,
                            commandGeneration,
                        )
                    }
                }

                sendPlayerState(MAIN_PLAYER_ID)
                result.success(null)
            }

            if (shouldFade && mainCtx.player.isPlaying) {
                fadeVolumeTo(
                    mainCtx,
                    0f,
                    durationMs,
                    commandGeneration,
                ) {
                    if (mainCtx.volumeCommandGeneration != commandGeneration) return@fadeVolumeTo
                    NativeLog.d(
                        "AudioCore",
                        "handleSequentialTransition fadeOutComplete path=$path " +
                            "durationMs=$durationMs autoPlay=$autoPlay",
                    )
                    mainCtx.player.pause()
                    loadReplacement()
                }
            } else {
                loadReplacement()
            }
        } catch (e: Exception) {
            result.error("TRANSITION_FAILED", e.message, mapOf("exception" to e.javaClass.name))
        }
    }

    private fun cancelActiveCrossfade(restoreMainVolume: Boolean = true) {
        val session = activeCrossfadeSession ?: return
        NativeLog.d(
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

        NativeLog.d(
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
        handleUpdateTrackMetadataBatch(
            updates = listOf(
                mapOf(
                    "path" to path,
                    "metadata" to metadata,
                ),
            ),
            result = result,
            returnBatchResults = false,
        )
    }

    private fun handleUpdateTrackMetadataBatch(
        updates: List<Map<String, Any?>>,
        result: Result,
        returnBatchResults: Boolean = true,
    ) {
        val safeContext = context ?: run {
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }

        val normalizedUpdates = updates.mapNotNull { rawUpdate ->
            val path = rawUpdate["path"]?.toString()?.trim()
            val metadata = (rawUpdate["metadata"] as? Map<*, *>)
                ?.entries
                ?.associate { (key, value) -> key.toString() to value }
            if (path.isNullOrEmpty() || metadata == null) {
                null
            } else {
                PendingMetadataWriteItem(path, metadata)
            }
        }

        if (normalizedUpdates.isEmpty()) {
            result.error("INVALID_ARGUMENT", "Updates are empty.", null)
            return
        }

        try {
            when (val batchResult = performMetadataBatchWrite(
                safeContext,
                normalizedUpdates,
                failOnItemError = !returnBatchResults,
            )) {
                is MetadataBatchWriteResult.Completed -> {
                    if (returnBatchResults) {
                        result.success(batchResult.results)
                    } else {
                        result.success(batchResult.results.firstOrNull() == true)
                    }
                }

                is MetadataBatchWriteResult.PermissionRequired -> {
                    requestWritePermission(
                        updates = normalizedUpdates,
                        result = result,
                        exception = batchResult.exception,
                        returnBatchResults = returnBatchResults,
                    )
                }
            }
        } catch (e: MetadataWriteException) {
            val cause = e.cause
            if (cause is android.app.RecoverableSecurityException) {
                requestWritePermission(
                    updates = normalizedUpdates,
                    result = result,
                    exception = cause,
                    returnBatchResults = returnBatchResults,
                )
                return
            }
            if (cause is SecurityException) {
                requestWritePermission(
                    updates = normalizedUpdates,
                    result = result,
                    exception = cause,
                    returnBatchResults = returnBatchResults,
                )
                return
            }

            result.error(
                e.code,
                e.message,
                e.details + mapOf("exception" to (cause?.javaClass?.name ?: e.javaClass.name)),
            )
        } catch (e: android.app.RecoverableSecurityException) {
            requestWritePermission(
                updates = normalizedUpdates,
                result = result,
                exception = e,
                returnBatchResults = returnBatchResults,
            )
        } catch (e: SecurityException) {
            requestWritePermission(
                updates = normalizedUpdates,
                result = result,
                exception = e,
                returnBatchResults = returnBatchResults,
            )
        } catch (e: Exception) {
            e.printStackTrace()
            result.error(
                "WRITE_FAILED",
                e.message,
                mapOf(
                    "paths" to normalizedUpdates.map { it.path },
                    "exception" to e::class.java.name,
                ),
            )
        }
    }

    private fun handleCopyTrackMetadataBatch(
        requests: List<Map<String, Any?>>,
        result: Result,
    ) {
        val safeContext = context ?: run {
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }

        val normalizedRequests = requests.mapNotNull { rawRequest ->
            val sourcePath = rawRequest["sourcePath"]?.toString()?.trim()
            val targetPath = rawRequest["targetPath"]?.toString()?.trim()
            if (sourcePath.isNullOrEmpty() || targetPath.isNullOrEmpty()) {
                null
            } else {
                PendingMetadataWriteItem(
                    path = targetPath,
                    sourcePath = sourcePath,
                )
            }
        }

        if (normalizedRequests.isEmpty()) {
            result.error("INVALID_ARGUMENT", "Requests are empty.", null)
            return
        }

        try {
            when (val batchResult = performMetadataBatchWrite(
                safeContext,
                normalizedRequests,
            )) {
                is MetadataBatchWriteResult.Completed -> {
                    result.success(batchResult.results)
                }

                is MetadataBatchWriteResult.PermissionRequired -> {
                    requestWritePermission(
                        updates = normalizedRequests,
                        result = result,
                        exception = batchResult.exception,
                        returnBatchResults = true,
                    )
                }
            }
        } catch (e: android.app.RecoverableSecurityException) {
            requestWritePermission(
                updates = normalizedRequests,
                result = result,
                exception = e,
                returnBatchResults = true,
            )
        } catch (e: SecurityException) {
            requestWritePermission(
                updates = normalizedRequests,
                result = result,
                exception = e,
                returnBatchResults = true,
            )
        } catch (e: Exception) {
            e.printStackTrace()
            result.error(
                "COPY_FAILED",
                e.message,
                mapOf(
                    "paths" to normalizedRequests.map { it.path },
                    "exception" to e::class.java.name,
                ),
            )
        }
    }

    private fun performMetadataBatchWrite(
        safeContext: Context,
        updates: List<PendingMetadataWriteItem>,
        failOnItemError: Boolean = false,
    ): MetadataBatchWriteResult {
        val results = ArrayList<Boolean>(updates.size)
        for (update in updates) {
            try {
                val metadata = if (update.sourcePath != null) {
                    AndroidMetadataWriter.readMetadata(
                        safeContext,
                        update.sourcePath,
                    ) + mapOf("clearBeforeWrite" to true)
                } else {
                    update.metadata ?: emptyMap()
                }
                NativeLog.d(
                    "AudioCore",
                    "metadata batch write start path=${update.path} " +
                        "sourcePath=${update.sourcePath} " +
                        "fallbackMediaUri=${metadata["fallbackMediaUri"]}",
                )
                val success = AndroidMetadataWriter.updateMetadata(
                    safeContext,
                    update.path,
                    metadata,
                )
                NativeLog.d(
                    "AudioCore",
                    "metadata batch write result path=${update.path} success=$success",
                )
                results.add(success)
            } catch (e: MetadataWriteException) {
                val cause = e.cause
                if (cause is android.app.RecoverableSecurityException) {
                    return MetadataBatchWriteResult.PermissionRequired(cause)
                }
                if (cause is SecurityException) {
                    return MetadataBatchWriteResult.PermissionRequired(cause)
                }
                NativeLog.e(
                    "AudioCore",
                    "metadata write failed path=${update.path} code=${e.code} " +
                        "message=${e.message} details=${e.details}",
                    e,
                )
                if (failOnItemError) {
                    throw e
                }
                results.add(false)
            } catch (e: android.app.RecoverableSecurityException) {
                return MetadataBatchWriteResult.PermissionRequired(e)
            } catch (e: SecurityException) {
                return MetadataBatchWriteResult.PermissionRequired(e)
            } catch (e: Exception) {
                NativeLog.e(
                    "AudioCore",
                    "metadata write failed path=${update.path} message=${e.message}",
                    e,
                )
                if (failOnItemError) {
                    throw e
                }
                results.add(false)
            }
        }
        return MetadataBatchWriteResult.Completed(results)
    }

    private fun requestWritePermission(
        updates: List<PendingMetadataWriteItem>,
        result: Result,
        exception: Exception,
        returnBatchResults: Boolean,
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

        val requestUris = updates.mapNotNull { update ->
            resolveRequestUri(update.path, update.metadata ?: emptyMap())
        }.distinct()

        if (requestUris.isEmpty()) {
            result.error(
                "WRITE_PERMISSION_REQUIRED",
                "This media item cannot be approved for direct rewrite because no MediaStore URI is available.",
                mapOf("paths" to updates.map { it.path }),
            )
            return
        }

        val intentSender = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ can request write access directly through MediaStore.
            val uris = requestUris.map(Uri::parse)
            MediaStore.createWriteRequest(safeContext.contentResolver, uris).intentSender
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

        pendingMetadataWrite = PendingMetadataWrite(
            updates = updates,
            result = result,
            returnBatchResults = returnBatchResults,
        )
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
        if (requestCode == REQUEST_PICK_OUTPUT_DIRECTORY) {
            val result = pendingDirectoryResult
            pendingDirectoryResult = null

            if (result == null) {
                return true
            }

            val safeActivity = activity ?: run {
                result.error("no_activity", "Android activity is not available.", null)
                return true
            }

            if (resultCode != Activity.RESULT_OK || data == null || data.data == null) {
                result.success(null)
                return true
            }

            val treeUri = data.data!!
            val takeFlags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            try {
                safeActivity.contentResolver.takePersistableUriPermission(treeUri, takeFlags)
            } catch (error: SecurityException) {
                NativeLog.w("AudioCore", "Failed to persist SAF permission for $treeUri: ${error.message}")
            }

            val response = mapOf(
                "treeUri" to treeUri.toString(),
                "displayPath" to resolveDisplayPath(treeUri)
            )
            result.success(response)
            return true
        }

        if (requestCode != REQUEST_WRITE_MEDIA) return false

        val pending = pendingMetadataWrite ?: return true
        pendingMetadataWrite = null

        if (resultCode != Activity.RESULT_OK) {
            pending.result.error(
                "WRITE_PERMISSION_DENIED",
                "User denied permission to modify the media item.",
                mapOf("paths" to pending.updates.map { it.path }),
            )
            return true
        }

        val safeContext = context ?: run {
            pending.result.error("INTERNAL_ERROR", "Context is null", null)
            return true
        }

        try {
            when (val batchResult = performMetadataBatchWrite(
                safeContext,
                pending.updates,
                failOnItemError = !pending.returnBatchResults,
            )) {
                is MetadataBatchWriteResult.Completed -> {
                    if (pending.returnBatchResults) {
                        pending.result.success(batchResult.results)
                    } else {
                        pending.result.success(batchResult.results.firstOrNull() == true)
                    }
                }

                is MetadataBatchWriteResult.PermissionRequired -> {
                    pending.result.error(
                        "WRITE_PERMISSION_DENIED",
                        "Additional permission is required to modify one or more media items.",
                        mapOf("paths" to pending.updates.map { it.path }),
                    )
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
            pending.result.error(
                "WRITE_FAILED",
                e.message,
                mapOf(
                    "paths" to pending.updates.map { it.path },
                    "exception" to e::class.java.name,
                ),
            )
        }

        return true
    }

    private fun resolveRequestUri(
        path: String,
        metadata: Map<String, Any?>,
    ): String? {
        val fallbackMediaUri = metadata["fallbackMediaUri"]
            ?.toString()
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
        return when {
            path.startsWith("content://") -> path
            fallbackMediaUri?.startsWith("content://") == true -> fallbackMediaUri
            else -> context?.let { AndroidMetadataWriter.resolveMediaStoreUri(it, path) }
        }
    }

    @OptIn(UnstableApi::class)
    private fun handleConvertFileWithTransformer(
        inputPath: String,
        outputPath: String,
        bitRate: Int?,
        bitRateMode: String?,
        sampleRate: Int?,
        channels: Int?,
        result: Result
    ) {
        val safeContext = context ?: run {
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }

        // Clean up any existing transformer for the same output path
        activeTransformers[outputPath]?.let {
            try {
                it.cancel()
            } catch (e: Exception) {
                e.printStackTrace()
            }
            activeTransformers.remove(outputPath)
        }

        try {
            // Ensure parent directory exists
            val outputFile = java.io.File(outputPath)
            val parentDir = outputFile.parentFile
            if (parentDir != null && !parentDir.exists()) {
                parentDir.mkdirs()
            }

            val inputUri = if (inputPath.startsWith("content://") || inputPath.startsWith("file://")) {
                Uri.parse(inputPath)
            } else {
                Uri.fromFile(java.io.File(inputPath))
            }

            val mediaItem = MediaItem.fromUri(inputUri)
            val editedMediaItem = EditedMediaItem.Builder(mediaItem)
                .setRemoveVideo(true)
                .build()

            val defaultEncoderFactory = androidx.media3.transformer.DefaultEncoderFactory.Builder(safeContext).build()

            val transformerBuilder = Transformer.Builder(safeContext)
                .setAudioMimeType(MimeTypes.AUDIO_AAC)
                .setEncoderFactory(object : androidx.media3.transformer.Codec.EncoderFactory {
                    override fun createForAudioEncoding(format: Format, logSessionId: android.media.metrics.LogSessionId?): androidx.media3.transformer.Codec {
                        val targetBitrate = if (bitRate != null && bitRate > 0) bitRate else 192000
                        val formatBuilder = format.buildUpon()
                            .setAverageBitrate(targetBitrate)
                        
                        if (sampleRate != null && sampleRate > 0) {
                            formatBuilder.setSampleRate(sampleRate)
                        }
                        if (channels != null && channels > 0) {
                            formatBuilder.setChannelCount(channels)
                        }
                        
                        return defaultEncoderFactory.createForAudioEncoding(formatBuilder.build(), logSessionId)
                    }

                    override fun createForVideoEncoding(format: Format, logSessionId: android.media.metrics.LogSessionId?): androidx.media3.transformer.Codec {
                        return defaultEncoderFactory.createForVideoEncoding(format, logSessionId)
                    }
                })

            val listener = object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    activeTransformers.remove(outputPath)
                    val resultMap = mapOf(
                        "success" to true,
                        "engine" to "Media3Transformer",
                        "outputPath" to outputPath,
                        "outputFormat" to "m4a"
                    )
                    result.success(resultMap)
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException
                ) {
                    activeTransformers.remove(outputPath)
                    val errorMsg = exportException.message ?: "Unknown transformer error"
                    val resultMap = mapOf(
                        "success" to false,
                        "engine" to "Media3Transformer",
                        "errorCode" to "transformer_failed",
                        "errorMessage" to errorMsg
                    )
                    result.success(resultMap)
                }
            }

            val transformer = transformerBuilder
                .addListener(listener)
                .build()

            activeTransformers[outputPath] = transformer
            transformer.start(editedMediaItem, outputPath)

        } catch (e: Exception) {
            activeTransformers.remove(outputPath)
            val resultMap = mapOf(
                "success" to false,
                "engine" to "Media3Transformer",
                "errorCode" to "transformer_exception",
                "errorMessage" to (e.message ?: e.toString())
            )
            result.success(resultMap)
        }
    }

    private val safMethodCallHandler = MethodCallHandler { call, originalResult ->
        val result = MainThreadResult(originalResult)
        when (call.method) {
            "pickOutputDirectory" -> {
                pickOutputDirectory(result)
            }
            "saveFileToDirectory" -> {
                saveFileToDirectory(call.arguments, result)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    private fun pickOutputDirectory(result: Result) {
        val safeActivity = activity ?: run {
            result.error("no_activity", "Android activity is not available.", null)
            return
        }
        if (pendingDirectoryResult != null) {
            result.error("already_active", "A directory picker is already active.", null)
            return
        }

        pendingDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    Uri.parse("content://com.android.externalstorage.documents/root/primary")
                )
            }
        }

        try {
            safeActivity.startActivityForResult(intent, REQUEST_PICK_OUTPUT_DIRECTORY)
        } catch (error: Exception) {
            pendingDirectoryResult = null
            result.error("directory_picker_failed", error.message, null)
        }
    }

    private fun saveFileToDirectory(arguments: Any?, result: Result) {
        val safeActivity = activity ?: run {
            result.error("no_activity", "Android activity is not available.", null)
            return
        }
        if (arguments !is Map<*, *>) {
            result.error("invalid_arguments", "Expected a map of arguments.", null)
            return
        }

        val treeUriString = arguments["treeUri"]?.toString()
        val sourcePath = arguments["sourcePath"]?.toString()
        val fileName = arguments["fileName"]?.toString()

        if (treeUriString.isNullOrEmpty()) {
            result.error("invalid_arguments", "Missing treeUri.", null)
            return
        }
        if (sourcePath.isNullOrEmpty()) {
            result.error("invalid_arguments", "Missing sourcePath.", null)
            return
        }
        if (fileName.isNullOrEmpty()) {
            result.error("invalid_arguments", "Missing fileName.", null)
            return
        }

        val treeUri = Uri.parse(treeUriString)
        val tree = DocumentFile.fromTreeUri(safeActivity, treeUri)
        if (tree == null) {
            result.error("save_failed", "Failed to resolve the selected directory.", null)
            return
        }

        try {
            val existing = tree.findFile(fileName)
            existing?.delete()

            val created = tree.createFile(mimeTypeForFileName(fileName), fileName)
            if (created == null) {
                result.error("save_failed", "Failed to create the output file.", null)
                return
            }

            try {
                FileInputStream(sourcePath).use { input ->
                    safeActivity.contentResolver.openOutputStream(created.uri, "w").use { output ->
                        if (output == null) {
                            result.error("save_failed", "Failed to open the output stream.", null)
                            return
                        }

                        val buffer = ByteArray(8192)
                        var read: Int
                        while (input.read(buffer).also { read = it } != -1) {
                            output.write(buffer, 0, read)
                        }
                        output.flush()
                    }
                }
            } catch (e: Exception) {
                result.error("save_failed", e.message, null)
                return
            }

            val response = mapOf(
                "savedUri" to created.uri.toString(),
                "displayPath" to resolveDisplayPath(treeUri) + "/" + fileName
            )
            result.success(response)
        } catch (error: java.io.IOException) {
            NativeLog.e("AudioCore", "Failed to copy output file into SAF directory", error)
            result.error("save_failed", error.message, null)
        }
    }

    private fun resolveDisplayPath(treeUri: Uri): String {
        return try {
            val docId = DocumentsContract.getTreeDocumentId(treeUri)
            val parts = docId.split(":")
            if (parts.size > 1) {
                if ("primary".equals(parts[0], ignoreCase = true)) {
                    Environment.getExternalStorageDirectory().toString() + "/" + parts[1]
                } else {
                    "/storage/" + parts[0] + "/" + parts[1]
                }
            } else {
                treeUri.toString()
            }
        } catch (e: Exception) {
            treeUri.toString()
        }
    }

    private fun mimeTypeForFileName(fileName: String): String {
        val dotIndex = fileName.lastIndexOf('.')
        if (dotIndex < 0 || dotIndex == fileName.length - 1) {
            return "application/octet-stream"
        }

        val extension = fileName.substring(dotIndex + 1).lowercase(Locale.US)
        val mimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
        return mimeType ?: "application/octet-stream"
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



    private fun downsampleWaveform(amplitudes: List<Double>, targetSize: Int): List<Double> {
        if (targetSize <= 0 || amplitudes.isEmpty()) return emptyList()
        if (amplitudes.size <= targetSize) return amplitudes

        val result = ArrayList<Double>(targetSize)
        val chunkSize = amplitudes.size.toDouble() / targetSize
        for (i in 0 until targetSize) {
            val start = (i * chunkSize).toInt()
            val end = ((i + 1) * chunkSize).toInt().coerceAtMost(amplitudes.size)
            var max = 0.0
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
        safChannel.setMethodCallHandler(null)
        mediaLibraryChannel.setMethodCallHandler(null)
        fftEventChannel.setStreamHandler(null)
        fftEventSink = null
        instance = null
        context = null
        pendingMetadataWrite = null
        activeTransformers.values.forEach {
            try {
                it.cancel()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
        activeTransformers.clear()
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

    private fun sendPlayerState(id: String) {
        val ctx = playerContexts[id] ?: return
        val snapshotCtx = if (id == MAIN_PLAYER_ID) publicPlaybackContext() ?: ctx else ctx
        val p = snapshotCtx.player
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
            "updateTime" to System.currentTimeMillis(),
            "error" to p.playerError?.message
        )
        NativeLog.d(
            "AudioCore",
            "sendPlayerState id=$id snapshotId=${snapshotCtx.id} state=${stateMap["state"]} " +
                "isPlaying=${stateMap["isPlaying"]} playWhenReady=${p.playWhenReady} " +
                "volume=${p.volume} position=${stateMap["position"]} duration=$clampedDuration " +
                "error=${stateMap["error"]}",
        )
        inst.channel.invokeMethod("onPlayerStateChanged", stateMap)
    }

    private fun settleActiveCrossfadeIfNeeded() {
        val session = activeCrossfadeSession ?: return
        NativeLog.d(
            "AudioCore",
            "settleActiveCrossfade generation=${session.generation} " +
                "baseVolume=${session.baseVolume} targetVolume=${session.targetVolume}",
        )
        crossfadeAnimator?.cancel()
        crossfadeAnimator = null
        finalizeCrossfade(session.generation)
    }

    private fun publicPlaybackContext(): PlayerContext? {
        if (activeCrossfadeSession != null) {
            return playerContexts[CROSSFADE_PLAYER_ID] ?: playerContexts[MAIN_PLAYER_ID]
        }
        return playerContexts[MAIN_PLAYER_ID]
    }

    private fun activePlaybackContexts(): List<PlayerContext> {
        val contexts = ArrayList<PlayerContext>(2)
        playerContexts[MAIN_PLAYER_ID]?.let { contexts.add(it) }
        if (activeCrossfadeSession != null) {
            playerContexts[CROSSFADE_PLAYER_ID]?.let { incoming ->
                if (contexts.none { it === incoming }) {
                    contexts.add(incoming)
                }
            }
        }
        return contexts
    }

    private fun emitFftData(playerId: String, magnitudes: FloatArray) {
        if (activeCrossfadeSession != null && playerId == MAIN_PLAYER_ID) return
        val routedPlayerId =
            if (activeCrossfadeSession != null && playerId == CROSSFADE_PLAYER_ID) {
                MAIN_PLAYER_ID
            } else {
                playerId
            }
        synchronized(fftEmitLock) {
            fftQueue.add(routedPlayerId to magnitudes.copyOf())
            while (fftQueue.size > 20) {
                fftQueue.poll()
            }
            if (!fftConsumerActive) {
                fftConsumerActive = true
                fftEmitHandler.post(fftConsumerRunnable)
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
