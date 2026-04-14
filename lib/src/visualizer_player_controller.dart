import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'player_models.dart';
import 'playlist_models.dart';
import 'player_controller.dart';
import 'playlist_controller.dart';
import 'visualizer_controller.dart';
import 'rust/api/simple_api.dart' hide FadeSettings, FadeMode;
import 'rust/frb_generated.dart';
import 'fft_processor.dart';
import 'player_state_snapshot.dart';
import 'equalizer_controller.dart';
import 'audio_engine/audio_engine_interface.dart';
import 'audio_engine/android_audio_engine.dart';
import 'audio_engine/rust_audio_engine.dart';
import 'android_track_metadata.dart';
import 'android_media_library.dart';

export 'player_controller.dart';
export 'playlist_controller.dart';
export 'random_playback_models.dart';
export 'visualizer_controller.dart';
export 'equalizer_controller.dart';
export 'playlist_models.dart';
export 'player_state_snapshot.dart';
export 'android_media_library.dart';

/// The top-level modular controller for audio playback and visualization.
class AudioCoreController extends ChangeNotifier
    implements AudioVisualizerParent {
  static const MethodChannel _androidMediaLibraryChannel = MethodChannel(
    'audio_core.media_library',
  );
  static AudioCoreController? _instance;

  factory AudioCoreController({
    int fftSize = 1024,
    double analysisFrequencyHz = 30.0,
    FadeSettings fadeSettings = const FadeSettings(),
    VisualizerOptimizationOptions visualOptions =
        const VisualizerOptimizationOptions(),
  }) {
    return _instance ??= AudioCoreController._internal(
      fftSize: fftSize,
      analysisFrequencyHz: analysisFrequencyHz,
      fadeSettings: fadeSettings,
      visualOptions: visualOptions,
    );
  }

  AudioCoreController._internal({
    required this.fftSize,
    required this.analysisFrequencyHz,
    required FadeSettings fadeSettings,
    VisualizerOptimizationOptions visualOptions =
        const VisualizerOptimizationOptions(),
  }) {
    if (Platform.isAndroid) {
      _engine = AndroidAudioEngine();
    } else {
      _engine = RustAudioEngine();
    }

    player = PlayerController(parent: this);
    _initialFadeSettings = fadeSettings;

    playlist = PlaylistController(parent: this);

    visualizer = VisualizerController(
      fftSize: fftSize,
      visualOptions: visualOptions,
      getLatestFft: () => _latestFftCache,
      parent: this,
    );

    equalizer = EqualizerController(parent: this);
  }

  static const int maxEqualizerBands = EqualizerController.maxEqualizerBands;
  static const double equalizerMinFrequencyHz =
      EqualizerController.minFrequencyHz;
  static const double equalizerMaxFrequencyHz =
      EqualizerController.maxFrequencyHz;
  static const double equalizerBassBoostFrequencyHz =
      EqualizerController.bassBoostFrequencyHz;
  static const double equalizerBassBoostQ = EqualizerController.bassBoostQ;

  final int fftSize;
  final double analysisFrequencyHz;

  late final PlayerController player;
  late final PlaylistController playlist;
  late final VisualizerController visualizer;
  late final EqualizerController equalizer;
  late final FadeSettings _initialFadeSettings;

  List<double> _latestFftCache = const [];

  static bool _rustLibInitialized = false;
  bool _initialized = false;
  bool _isTransitioning = false;
  Timer? _analysisTick;
  Timer? _renderTick;
  StreamSubscription<AudioStatus>? _playbackStateSubscription;

  bool get isSupported =>
      Platform.isAndroid || Platform.isLinux || Platform.isWindows;
  bool get isInitialized => _initialized;
  EqualizerConfig get equalizerConfig => equalizer.config;

  /// Returns the next track in the current playlist sequence.
  AudioTrack? get nextTrack => playlist.nextTrack;

  /// Returns the previous track in the current playlist sequence.
  AudioTrack? get previousTrack => playlist.previousTrack;

  /// Returns a full snapshot of the current state.
  PlayerStateSnapshot get state => PlayerStateSnapshot(
    position: player.position,
    duration: player.duration,
    volume: player.volume,
    currentState: player.currentState,
    playlists: playlist.playlists,
    randomPolicy: playlist.randomPolicy,
    playlistMode: playlist.mode,
    activePlaylist: playlist.activePlaylist,
    currentIndex: playlist.currentIndex,
    track: playlist.currentTrack,
    nextTrack: playlist.nextTrack,
    previousTrack: playlist.previousTrack,
    error: player.error,
    equalizerConfig: equalizer.config,
    isTransitioning: _isTransitioning || player.isFadeActive,
  );

  @override
  AudioEngine get engine => _engine;
  late final AudioEngine _engine;

  Future<void> initialize() async {
    debugPrint('AudioCoreController: Starting initialization');
    if (_initialized) return;
    if (!isSupported) {
      debugPrint('AudioCoreController: NOT SUPPORTED');
      player.setError('Only Android, Linux, and Windows are supported.');
      return;
    }
    debugPrint('AudioCoreController: isSupported = true');

    if (!Platform.isAndroid && !_rustLibInitialized) {
      try {
        debugPrint('AudioCoreController: Initializing RustLib');
        await RustLib.init();
        _rustLibInitialized = true;
      } catch (e) {
        if (!e.toString().contains(
          'Should not initialize flutter_rust_bridge twice',
        )) {
          debugPrint('AudioCoreController: RustLib init failed: $e');
          player.setError('Rust bridge init failed: $e');
          return;
        }
        _rustLibInitialized = true;
      }
    }

    // Apply initial fade settings now that RustLib is ready
    player.setFadeSettings(_initialFadeSettings);

    // Initialize the Rust audio engine (starts device monitoring thread)
    try {
      if (!Platform.isAndroid) {
        debugPrint('AudioCoreController: Initializing Rust App engine');
        await initApp();
      }
    } catch (e) {
      debugPrint('AudioCoreController: Rust App engine init failed: $e');
      player.setError('Audio engine init failed: $e');
      return;
    }

    try {
      debugPrint('AudioCoreController: Initializing Equalizer');
      await equalizer.initialize();
      debugPrint('AudioCoreController: Equalizer initialized');
    } catch (e) {
      debugPrint('AudioCoreController: Equalizer init failed: $e');
      player.setError('Equalizer sync failed: $e');
      return;
    }

    // Initialize Audio Engine
    try {
      await _engine.initialize();
      _playbackStateSubscription = _engine.statusStream.listen((status) {
        player.applySnapshot(
          status.path,
          status.position,
          status.duration,
          status.isPlaying,
          status.volume,
          error: status.error,
        );
        if (status.isPlaying == false &&
            status.duration > Duration.zero &&
            status.position >=
                status.duration - const Duration(milliseconds: 250)) {
          unawaited(_handleAutoTransition());
        }
      });
    } catch (e) {
      player.setError('Audio engine init failed: $e');
      return;
    }

    _analysisTick = Timer.periodic(
      _analysisInterval,
      (_) => unawaited(_onAnalysisTick()),
    );
    _renderTick = Timer.periodic(_renderInterval, (_) => _onRenderTick());

    debugPrint('AudioCoreController: Starting visualizer outputs');
    visualizer.visualizerOutputManager.startAll();
    _initialized = true;
    notifyListeners();
    debugPrint('AudioCoreController: Initialization COMPLETE');
  }

  @override
  void dispose() {
    _analysisTick?.cancel();
    _renderTick?.cancel();
    _playbackStateSubscription?.cancel();
    unawaited(disposeAudio());
    visualizer.dispose();
    player.dispose();
    playlist.dispose();
    super.dispose();
  }

  // --- AudioVisualizerParent Implementation ---

  @override
  void notifyListeners() => super.notifyListeners();

  @override
  Future<void> loadTrack({
    required bool autoPlay,
    Duration? position,
    PlaybackReason reason = PlaybackReason.playlistChanged,
    FadeSettings? fadeSetting,
  }) async {
    final track = playlist.currentTrack;
    if (track == null) return;

    await player.performTransition(
      uri: track.uri,
      autoPlay: autoPlay,
      position: position,
      reason: reason,
      fadeSetting: fadeSetting,
      onStateChanged: (progressing) {
        _isTransitioning = progressing;
        notifyListeners();
      },
    );
    visualizer.resetState();

    // On Android, EQ processor might need re-attaching or re-configuring
    // after a new DataSource is loaded.
    if (Platform.isAndroid) {
      unawaited(
        Future.delayed(
          const Duration(milliseconds: 200),
          () => equalizer.reapply(),
        ),
      );
    }
  }

  @override
  Future<void> clearPlayback() async {
    player.stopPlayback();
    visualizer.resetState();
  }

  /// Resets the playback session to the initial empty state.
  Future<void> resetPlaybackState() async {
    await disposeAudio();
    player.stopPlayback();
    player.setFadeActive(false);
    visualizer.resetState();
    await playlist.resetPlaybackState();
    _latestFftCache = const [];
    _isTransitioning = false;
    notifyListeners();
  }

  @override
  Future<bool> handlePlayRequested() async {
    if (playlist.items.isEmpty) return false;

    if (playlist.mode == PlaylistMode.queue ||
        playlist.mode == PlaylistMode.queueLoop ||
        playlist.mode == PlaylistMode.autoQueueLoop) {
      final hasNext = playlist.resolveAdjacentIndex(next: true);
      if (hasNext == null) {
        await playlist.setActivePlaylist(
          playlist.activePlaylistId!,
          startIndex: 0,
          autoPlay: true,
        );
        return true;
      }
    }
    return false;
  }

  // --- Internal Loops ---

  Duration get _analysisInterval =>
      Duration(microseconds: (1000000.0 / analysisFrequencyHz).round());
  Duration get _renderInterval => Duration(
    microseconds: (1000000.0 / visualizer.options.targetFrameRate).round(),
  );

  Future<void> _onAnalysisTick() async {
    await _refreshLatestFftCache();
    visualizer.processAnalysisTick(player.isPlaying, player.position);
  }

  void _onRenderTick() {
    _advanceLocalPosition();
    visualizer.processRenderTick(
      _renderInterval.inMicroseconds,
      _analysisInterval.inMicroseconds,
    );
  }

  void _advanceLocalPosition() {
    if (!player.isPlaying || player.currentPath == null) return;
    player.updatePosition(player.position + _renderInterval);

    if (player.currentState == PlayerState.completed) {
      unawaited(_handleAutoTransition());
    }
  }

  Future<void> _handleAutoTransition() async {
    if (_isTransitioning || player.currentState != PlayerState.completed) {
      return;
    }

    if (playlist.mode == PlaylistMode.singleLoop) {
      await loadTrack(autoPlay: true, reason: PlaybackReason.autoNext);
      return;
    }

    if (playlist.mode == PlaylistMode.single) return;

    final success = await playlist.playNext(reason: PlaybackReason.autoNext);
    if (!success) {
      // End of queue logic could go here
    }
  }

  Future<void> _refreshLatestFftCache() async {
    try {
      _latestFftCache = await _engine.getLatestFft();
    } catch (e) {
      player.setError('FFT fetch failed: $e');
      _latestFftCache = const [];
    }
  }

  Future<List<double>> getWaveform({
    required int expectedChunks,
    int sampleStride = 1,
    String? filePath,
  }) async {
    final targetPath = filePath ?? player.currentPath;
    if (targetPath == null) return const [];
    try {
      final finalData = await _engine.getWaveform(
        path: targetPath,
        expectedChunks: expectedChunks,
        sampleStride: sampleStride,
      );

      if (finalData.isEmpty) return const [];

      // 为统一视觉效果，如果最高值未达到 1.0，则等比例提升至 1.0
      double maxVal = 0.0;
      for (final v in finalData) {
        if (v > maxVal) maxVal = v;
      }

      if (maxVal > 0 && maxVal < 1.0) {
        final multiplier = 1.0 / maxVal;
        return finalData.map((v) => v * multiplier).toList();
      }

      return finalData;
    } catch (e) {
      player.setError('Waveform failed: $e');
      return const [];
    }
  }

  /// Requests Android audio library permission through the platform bridge.
  Future<bool> ensureAndroidMediaLibraryPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      final granted = await _androidMediaLibraryChannel.invokeMethod<bool>(
        'ensureAudioPermission',
      );
      return granted ?? false;
    } catch (e) {
      debugPrint('ensureAndroidMediaLibraryPermission failed: $e');
      return false;
    }
  }

  /// Scans Android's MediaStore and returns a strongly typed result.
  Future<AndroidMediaLibraryScanResult> scanAndroidMediaLibrary() async {
    if (!Platform.isAndroid) {
      return const AndroidMediaLibraryScanResult(
        permissionGranted: false,
        entries: <AndroidMediaLibraryEntry>[],
        errorCode: 'UNSUPPORTED_PLATFORM',
        errorMessage:
            'Android media library scan is only available on Android.',
      );
    }

    final granted = await ensureAndroidMediaLibraryPermission();
    if (!granted) {
      return const AndroidMediaLibraryScanResult(
        permissionGranted: false,
        entries: <AndroidMediaLibraryEntry>[],
        errorCode: 'PERMISSION_DENIED',
        errorMessage: 'Audio library permission was not granted.',
      );
    }

    try {
      final rawResult = await _androidMediaLibraryChannel
          .invokeMethod<List<Object?>>('scanAudioLibrary');
      final entries = <AndroidMediaLibraryEntry>[];
      for (final item in rawResult ?? const <Object?>[]) {
        if (item is Map<Object?, Object?>) {
          entries.add(AndroidMediaLibraryEntry.fromMap(item));
        } else if (item is Map) {
          entries.add(
            AndroidMediaLibraryEntry.fromMap(item.cast<Object?, Object?>()),
          );
        }
      }

      return AndroidMediaLibraryScanResult(
        permissionGranted: true,
        entries: entries,
      );
    } on PlatformException catch (e) {
      debugPrint('scanAndroidMediaLibrary failed: ${e.code} ${e.message}');
      return AndroidMediaLibraryScanResult(
        permissionGranted: true,
        entries: const <AndroidMediaLibraryEntry>[],
        errorCode: e.code,
        errorMessage: e.message,
      );
    } catch (e) {
      debugPrint('scanAndroidMediaLibrary failed: $e');
      return AndroidMediaLibraryScanResult(
        permissionGranted: true,
        entries: const <AndroidMediaLibraryEntry>[],
        errorCode: 'SCAN_FAILED',
        errorMessage: e.toString(),
      );
    }
  }

  // --- Methods Delegated to Sub-Controllers ---

  Future<void> setEqualizerConfig(EqualizerConfig config) async =>
      equalizer.setConfig(config);
  Future<void> setEqualizerEnabled(bool enabled) async =>
      equalizer.setEnabled(enabled);
  Future<void> setEqualizerBandCount(int bandCount) async =>
      equalizer.setBandCount(bandCount);
  Future<void> setEqualizerBandGain(int bandIndex, double gainDb) async =>
      equalizer.setBandGain(bandIndex, gainDb);
  Future<void> setEqualizerPreamp(double preampDb) async =>
      equalizer.setPreamp(preampDb);
  Future<void> setBassBoost(double gainDb) async =>
      equalizer.setBassBoost(gainDb);
  void resetEqualizerDefaults() => equalizer.resetDefaults();
  List<double> getEqualizerBandCenters({int? bandCount}) =>
      equalizer.getBandCenters(bandCount: bandCount);

  Future<void> removeAllTags({String? path}) async {
    final targetPath = path ?? player.currentPath;
    if (targetPath == null || targetPath.trim().isEmpty) {
      throw StateError('No path provided and no current track is playing.');
    }
    await _engine.removeAllTags(path: targetPath.trim());
  }

  String _resolveTrackPath(AudioTrack track) {
    final filePath = track.metadataValue<String>('filePath');
    final mediaUri = track.metadataValue<String>('mediaUri');
    if (filePath?.trim().isNotEmpty == true) {
      return filePath!;
    }
    return mediaUri ?? track.uri;
  }

  String? _resolveMetadataPath(String? path) {
    final explicitPath = path?.trim();
    if (explicitPath != null && explicitPath.isNotEmpty) {
      return explicitPath;
    }

    final currentPath = player.currentPath?.trim();
    if (currentPath != null && currentPath.isNotEmpty) {
      return currentPath;
    }

    final currentTrack = playlist.currentTrack;
    if (currentTrack == null) {
      return null;
    }

    final resolvedTrackPath = _resolveTrackPath(currentTrack).trim();
    return resolvedTrackPath.isEmpty ? null : resolvedTrackPath;
  }

  Future<bool> _updateMetadataAtPath({
    required String path,
    String? fallbackMediaUri,
    required AndroidTrackMetadataUpdate metadata,
    bool managePlaybackSync = true,
  }) async {
    final file = path.startsWith('content://') ? null : File(path);
    if (file != null && !file.existsSync()) {
      debugPrint('updateMetadata: File does not exist: $path');
      return false;
    }

    final isCurrentTrack = player.currentPath == path;
    final fileSize = file?.lengthSync() ?? 0;
    final needsSync =
        isCurrentTrack && (Platform.isAndroid || fileSize >= 60 * 1024 * 1024);

    try {
      if (managePlaybackSync && needsSync) {
        await _engine.prepareForFileWrite();
        await Future.delayed(const Duration(milliseconds: 200));
      }

      final success = await _engine.updateTrackMetadata(
        path: path,
        metadata: <String, Object?>{
          ...metadata.toMap(),
          'fallbackMediaUri': fallbackMediaUri,
        },
      );
      if (!success) {
        throw StateError(
          Platform.isAndroid
              ? 'Android native metadata update failed.'
              : 'Rust metadata update failed.',
        );
      }

      if (managePlaybackSync && needsSync) {
        await _engine.finishFileWrite();
      }

      notifyListeners();
      return true;
    } catch (e) {
      final errorText = e is PlatformException
          ? [
              if (e.code.isNotEmpty) e.code,
              if (e.message != null && e.message!.isNotEmpty) e.message!,
              if (e.details != null) 'details: ${e.details}',
            ].join(' | ')
          : e.toString();

      debugPrint('updateMetadata failed: $errorText');
      player.setError('Metadata update failed: $errorText');

      if (managePlaybackSync && needsSync) {
        await _engine.finishFileWrite().catchError((_) {});
      }
      return false;
    }
  }

  /// Updates the metadata of a given track.
  ///
  /// Pass [metadata] to write the supplied fields to the track.
  ///
  /// If the track is currently playing, it will call the engine's synchronization
  /// methods to release file handles before writing.
  Future<bool> updateMetadata(
    AudioTrack track, {
    required AndroidTrackMetadataUpdate metadata,
  }) async {
    final path = _resolveTrackPath(track);
    final fallbackMediaUri = track.metadataValue<String>('mediaUri');
    return _updateMetadataAtPath(
      path: path,
      fallbackMediaUri: fallbackMediaUri,
      metadata: metadata,
    );
  }

  /// Reads metadata for the current track or an explicit file path.
  ///
  /// If [path] is omitted, this uses the currently playing track.
  /// If [path] is provided, it reads metadata from that file instead.
  Future<Map<String, Object?>> getTrackMetadata({String? path}) async {
    final targetPath = _resolveMetadataPath(path);
    if (targetPath == null) {
      throw StateError('No path provided and no current track is playing.');
    }

    return _engine.getTrackMetadata(path: targetPath);
  }

  /// Updates metadata for multiple Android tracks in sequence.
  Future<List<bool>> updateMetadataBatch(
    List<AndroidTrackMetadataUpdateRequest> updates,
  ) async {
    final results = <bool>[];
    final needsSync = updates.any((update) {
      if (player.currentPath != update.path) {
        return false;
      }
      if (Platform.isAndroid) {
        return true;
      }
      final file = File(update.path);
      return file.existsSync() && file.lengthSync() >= 60 * 1024 * 1024;
    });

    var preparedForWrite = false;
    try {
      if (needsSync) {
        await _engine.prepareForFileWrite();
        await Future.delayed(const Duration(milliseconds: 200));
        preparedForWrite = true;
      }

      for (final update in updates) {
        results.add(
          await _updateMetadataAtPath(
            path: update.path,
            fallbackMediaUri: update.fallbackMediaUri,
            metadata: update.metadata,
            managePlaybackSync: false,
          ),
        );
      }

      return results;
    } finally {
      if (preparedForWrite) {
        await _engine.finishFileWrite().catchError((_) {});
      }
    }
  }
}
