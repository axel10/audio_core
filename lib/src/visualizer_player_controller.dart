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
import 'audio_engine/apple_audio_engine.dart';
import 'audio_engine/android_audio_engine.dart';
import 'audio_engine/rust_audio_engine.dart';
import 'android_track_metadata.dart';
import 'android_media_library.dart';
import 'track_artwork.dart';
import 'track_metadata.dart';

export 'player_controller.dart';
export 'playlist_controller.dart';
export 'random_playback_models.dart';
export 'visualizer_controller.dart';
export 'equalizer_controller.dart';
export 'playlist_models.dart';
export 'player_state_snapshot.dart';
export 'android_media_library.dart';

@visibleForTesting
bool shouldAutoAdvanceFromStatus(AudioStatus status) {
  return status.playbackState == 'ENDED';
}

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
    } else if (Platform.isIOS || Platform.isMacOS) {
      _engine = AppleAudioEngine();
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
      sourceAlreadyGrouped: _engine.fftDataIsPreGrouped,
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
  String? _lastEndedAutoAdvancePath;
  Timer? _analysisTick;
  Timer? _renderTick;
  StreamSubscription<AudioStatus>? _playbackStateSubscription;

  bool get isSupported =>
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isWindows;
  bool get isInitialized => _initialized;
  EqualizerConfig get equalizerConfig => equalizer.config;
  bool get _usesRustPlaybackBackend => Platform.isLinux || Platform.isWindows;
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
    isTransitioning: _isTransitioning,
  );

  @override
  AudioEngine get engine => _engine;
  late final AudioEngine _engine;

  Future<void> initialize() async {
    debugPrint('AudioCoreController: Starting initialization');
    if (_initialized) return;
    if (!isSupported) {
      debugPrint('AudioCoreController: NOT SUPPORTED');
      player.setError(
        'Only Android, iOS, macOS, Linux, and Windows are supported.',
      );
      return;
    }
    debugPrint('AudioCoreController: isSupported = true');

    if (!_rustLibInitialized) {
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

    try {
      if (_usesRustPlaybackBackend) {
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
      await _engine.updateVisualizerFftOptions(visualizer.options);
      _playbackStateSubscription = _engine.statusStream.listen((status) {
        var adjustedPosition = status.position;
        final updateTimeMs = status.updateTimeSinceEpochMs;
        if (updateTimeMs != null && status.isPlaying) {
          final offset = DateTime.now().millisecondsSinceEpoch - updateTimeMs;
          if (offset > 0) {
            adjustedPosition += Duration(milliseconds: offset);
          }
        }

        player.applySnapshot(
          status.path,
          status.playbackState,
          adjustedPosition,
          status.duration,
          status.isPlaying,
          status.volume,
          error: status.error,
        );
        // Use the native snapshot for handoff. Some backends emit ENDED
        // explicitly; Flutter no longer infers completion from position.
        if (shouldAutoAdvanceFromStatus(status)) {
          final endedPath = status.path;
          if (endedPath == null || endedPath != _lastEndedAutoAdvancePath) {
            _lastEndedAutoAdvancePath = endedPath;
            unawaited(_handleAutoTransition());
          }
        } else if (status.playbackState != 'ENDED' &&
            player.currentState != PlayerState.completed) {
          _lastEndedAutoAdvancePath = null;
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
    unawaited(_engine.dispose());
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

    debugPrint(
      '[AudioCoreController] loadTrack track=${track.id} uri=${track.uri} '
      'autoPlay=$autoPlay reason=$reason positionMs=${position?.inMilliseconds} '
      'fadeSetting=${fadeSetting ?? _initialFadeSettings}',
    );

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

  /// Plays a specific track with one high-level command.
  ///
  /// The controller will try to locate the track in existing playlists first.
  /// If it is not found, the track is staged in the queue playlist and played
  /// from there.
  Future<void> playTrack(
    AudioTrack track, {
    String? preferredPlaylistId,
    FadeSettings? fadeSetting,
  }) async {
    final playlistController = playlist;
    final searchOrder = <String?>[
      preferredPlaylistId,
      playlistController.activePlaylistId,
      playlistController.queuePlaylistId,
    ];

    final visited = <String>{};
    for (final playlistId in searchOrder.whereType<String>()) {
      if (!visited.add(playlistId)) continue;
      final playlist = playlistController.playlistById(playlistId);
      final index = playlist?.items.indexWhere((item) => item.id == track.id);
      if (index != null && index >= 0) {
        await playlistController.setActivePlaylist(
          playlistId,
          startIndex: index,
          autoPlay: true,
          fadeSetting: fadeSetting,
        );
        return;
      }
    }

    for (final playlist in playlistController.playlists) {
      if (!visited.add(playlist.id)) continue;
      final index = playlist.items.indexWhere((item) => item.id == track.id);
      if (index >= 0) {
        await playlistController.setActivePlaylist(
          playlist.id,
          startIndex: index,
          autoPlay: true,
          fadeSetting: fadeSetting,
        );
        return;
      }
    }

    await playlistController.ensureQueuePlaylist();
    final queuePlaylist = playlistController.playlistById(
      playlistController.queuePlaylistId,
    );
    final startIndex = queuePlaylist?.items.length ?? 0;
    await playlistController.addTracksToPlaylist(
      playlistController.queuePlaylistId,
      <AudioTrack>[track],
      fadeSetting: fadeSetting,
    );
    await playlistController.setActivePlaylist(
      playlistController.queuePlaylistId,
      startIndex: startIndex,
      autoPlay: true,
      fadeSetting: fadeSetting,
    );
  }

  /// Plays one or more local file paths by merging them into the queue.
  ///
  /// Incoming paths are deduplicated against each other and the current queue.
  /// The first valid path becomes the active item, and [autoPlayFirst]
  /// controls whether playback starts immediately.
  Future<void> playPaths(
    List<String> paths, {
    bool autoPlayFirst = true,
    FadeSettings? fadeSetting,
  }) async {
    if (paths.isEmpty) return;
    if (!isInitialized) {
      await initialize();
    }
    if (!isInitialized) return;

    final resolvedTracks = resolveAudioTracks(paths);
    if (resolvedTracks.isEmpty) return;

    final playlistController = playlist;
    await playlistController.ensureQueuePlaylist();

    final queuePlaylistId = playlistController.queuePlaylistId;
    final queuePlaylist = playlistController.playlistById(queuePlaylistId);
    final existingKeys = <String>{};
    for (final track in queuePlaylist?.items ?? const <AudioTrack>[]) {
      final trackKey =
          _normalizeLocalPathKey(track.uri) ?? _normalizeLocalPathKey(track.id);
      if (trackKey != null) {
        existingKeys.add(trackKey);
      }
    }

    final tracksToAdd = <AudioTrack>[];
    String? firstTargetKey;

    for (final track in resolvedTracks) {
      final key =
          _normalizeLocalPathKey(track.uri) ?? _normalizeLocalPathKey(track.id);
      if (key == null) continue;

      if (existingKeys.contains(key)) {
        firstTargetKey ??= key;
        continue;
      }

      firstTargetKey ??= key;
      tracksToAdd.add(track);
      existingKeys.add(key);
    }

    if (tracksToAdd.isNotEmpty) {
      await playlistController.addTracksToPlaylist(
        queuePlaylistId,
        tracksToAdd,
        fadeSetting: fadeSetting,
      );
    }

    if (firstTargetKey == null) return;

    final updatedQueuePlaylist = playlistController.playlistById(
      queuePlaylistId,
    );
    final targetIndex =
        updatedQueuePlaylist?.items.indexWhere((track) {
          final trackKey =
              _normalizeLocalPathKey(track.uri) ??
              _normalizeLocalPathKey(track.id);
          return trackKey == firstTargetKey;
        }) ??
        -1;
    if (targetIndex < 0) return;

    await playlistController.setActivePlaylist(
      queuePlaylistId,
      startIndex: targetIndex,
      autoPlay: autoPlayFirst,
      fadeSetting: fadeSetting,
    );
  }

  /// Converts local file paths into normalized [AudioTrack] objects.
  ///
  /// The returned tracks are validated and normalized, but they are not
  /// de-duplicated against the current queue. Callers can use them for
  /// library import or any other side effects.
  List<AudioTrack> resolveAudioTracks(List<String> paths) {
    final tracks = <AudioTrack>[];
    final seenKeys = <String>{};

    for (final rawPath in paths) {
      final normalizedPath = _normalizeLocalPath(rawPath);
      if (normalizedPath == null) continue;
      final key = _normalizeLocalPathKey(normalizedPath);
      if (key == null || !seenKeys.add(key)) continue;

      final file = File(normalizedPath);
      if (!file.existsSync()) continue;

      tracks.add(
        AudioTrack(
          id: normalizedPath,
          title: _trackTitleFromPath(normalizedPath),
          uri: normalizedPath,
          metadata: <String, Object?>{'isLike': false, 'playCount': 0},
        ),
      );
    }

    return tracks;
  }

  /// Plays a track by id with one high-level command.
  ///
  /// The controller searches existing playlists for a matching track and then
  /// delegates to [playTrack]. If no track matches, this throws a [StateError].
  Future<void> playTrackById(
    String trackId, {
    String? preferredPlaylistId,
    FadeSettings? fadeSetting,
  }) async {
    final playlistController = playlist;
    final searchOrder = <String?>[
      preferredPlaylistId,
      playlistController.activePlaylistId,
      playlistController.queuePlaylistId,
    ];

    final visited = <String>{};
    for (final playlistId in searchOrder.whereType<String>()) {
      if (!visited.add(playlistId)) continue;
      final playlist = playlistController.playlistById(playlistId);
      final track = _findTrackInPlaylist(playlist, trackId);
      if (track != null) {
        await playTrack(
          track,
          preferredPlaylistId: playlistId,
          fadeSetting: fadeSetting,
        );
        return;
      }
    }

    for (final playlist in playlistController.playlists) {
      if (!visited.add(playlist.id)) continue;
      final track = _findTrackInPlaylist(playlist, trackId);
      if (track != null) {
        await playTrack(
          track,
          preferredPlaylistId: playlist.id,
          fadeSetting: fadeSetting,
        );
        return;
      }
    }

    throw StateError('Track not found: $trackId');
  }

  AudioTrack? _findTrackInPlaylist(Playlist? playlist, String trackId) {
    if (playlist == null) return null;
    for (final track in playlist.items) {
      if (track.id == trackId) return track;
    }
    return null;
  }

  String? _normalizeLocalPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || trimmed.contains('://')) {
      return null;
    }
    return File(trimmed).absolute.path;
  }

  String? _normalizeLocalPathKey(String path) {
    final normalized = _normalizeLocalPath(path);
    if (normalized == null) return null;
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  String _trackTitleFromPath(String path) {
    final uri = File(path).uri;
    if (uri.pathSegments.isNotEmpty) {
      return uri.pathSegments.last;
    }
    return path;
  }

  @override
  Future<void> clearPlayback() async {
    await _engine.stop();
    player.stopPlayback();
    visualizer.resetState();
    _lastEndedAutoAdvancePath = null;
  }

  /// Resets the playback session to the initial empty state.
  Future<void> resetPlaybackState() async {
    await _engine.stop();
    player.stopPlayback();
    visualizer.resetState();
    await playlist.resetPlaybackState();
    _latestFftCache = const [];
    _isTransitioning = false;
    _lastEndedAutoAdvancePath = null;
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

  DateTime? _lastLocalAdvanceTime;
  DateTime? _lastEngineSyncTime;

  void _advanceLocalPosition() {
    if (!player.isPlaying || player.currentPath == null) {
      _lastLocalAdvanceTime = null;
      return;
    }

    final now = DateTime.now();
    final last = _lastLocalAdvanceTime;
    _lastLocalAdvanceTime = now;

    if (last != null) {
      // High-precision elapsed advance without artificial capping.
      // Because we anchor via snapshots, this correctly models time passed.
      final elapsed = now.difference(last);
      player.updatePosition(player.position + elapsed);
    } else {
      player.updatePosition(player.position + _renderInterval);
    }

    // Periodically re-sync with native engine to prevent drift
    if (_lastEngineSyncTime == null ||
        now.difference(_lastEngineSyncTime!) >
            const Duration(milliseconds: 500)) {
      _lastEngineSyncTime = now;
      _engine.getCurrentPosition().then((snapshot) {
        if (player.isPlaying) {
          final offset =
              DateTime.now().millisecondsSinceEpoch - snapshot.takenAtMs;
          var adjustedPos = snapshot.position;
          if (offset > 0) {
            adjustedPos += Duration(milliseconds: offset);
          }
          player.updatePosition(adjustedPos);
        }
      });
    }
  }

  Future<void> _handleAutoTransition() async {
    if (_isTransitioning || player.currentState != PlayerState.completed) {
      return;
    }

    debugPrint(
      '[AudioCoreController] autoTransition mode=${playlist.mode} '
      'current=${playlist.currentTrack?.id} next=${playlist.nextTrack?.id}',
    );

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
    int sampleStride = 0,
    bool normalize = true,
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

      return normalize ? _normalizeWaveform(finalData) : finalData;
    } catch (e) {
      player.setError('Waveform failed: $e');
      return const [];
    }
  }

  List<double> _normalizeWaveform(List<double> waveform) {
    if (waveform.isEmpty) {
      return waveform;
    }

    var maxValue = 0.0;
    for (final value in waveform) {
      if (value > maxValue) {
        maxValue = value;
      }
    }

    if (maxValue <= 0.0) {
      return waveform;
    }

    return waveform
        .map((value) => _roundWaveformValue((value / maxValue).clamp(0.0, 1.0)))
        .toList(growable: false);
  }

  double _roundWaveformValue(double value) {
    return (value * 100).roundToDouble() / 100.0;
  }

  /// Returns decoded PCM samples for the current track or a specific file path.
  ///
  /// If [path] is omitted, this uses the currently loaded track.
  /// [sampleStride] lets native backends skip frames while decoding.
  /// A value of `0` means no skipping.
  Future<Float32List> getAudioPcm({String? path, int sampleStride = 0}) async {
    if (!_initialized) {
      await initialize();
    }

    if (!_initialized) {
      throw StateError('AudioCoreController is not initialized.');
    }

    return _engine.getAudioPcm(path: path, sampleStride: sampleStride);
  }

  /// Registers a persistent Apple security-scoped bookmark for [path].
  ///
  /// On Apple platforms, this lets the app keep using an external file after
  /// the current session ends, as long as the file was selected through the
  /// system file picker at least once.
  Future<bool> registerPersistentAccess({String? path}) async {
    final targetPath = _resolvePersistentAccessPath(path);
    if (targetPath == null) return false;
    return _engine.registerPersistentAccess(targetPath);
  }

  /// Forgets a previously saved persistent Apple security-scoped bookmark.
  Future<void> forgetPersistentAccess({String? path}) async {
    final targetPath = _resolvePersistentAccessPath(path);
    if (targetPath == null) return;
    await _engine.forgetPersistentAccess(targetPath);
  }

  /// Returns whether the controller has a stored persistent access entry.
  Future<bool> hasPersistentAccess({String? path}) async {
    final targetPath = _resolvePersistentAccessPath(path);
    if (targetPath == null) return false;
    return _engine.hasPersistentAccess(targetPath);
  }

  /// Returns all stored persistent access paths known to the Apple backend.
  Future<List<String>> listPersistentAccessPaths() async {
    return _engine.listPersistentAccessPaths();
  }

  /// Requests Android audio library permission through the platform bridge.
  Future<bool> ensureAndroidMediaLibraryPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      debugPrint('[AudioCore][MediaLibrary] ensure permission start');
      final granted = await _androidMediaLibraryChannel.invokeMethod<bool>(
        'ensureAudioPermission',
      );
      debugPrint('[AudioCore][MediaLibrary] ensure permission result=$granted');
      return granted ?? false;
    } catch (e) {
      debugPrint(
        '[AudioCore][MediaLibrary] ensureAndroidMediaLibraryPermission failed: $e',
      );
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
    debugPrint(
      '[AudioCore][MediaLibrary] scan request permissionGranted=$granted',
    );
    if (!granted) {
      return const AndroidMediaLibraryScanResult(
        permissionGranted: false,
        entries: <AndroidMediaLibraryEntry>[],
        errorCode: 'PERMISSION_DENIED',
        errorMessage: 'Audio library permission was not granted.',
      );
    }

    try {
      debugPrint('[AudioCore][MediaLibrary] scanAudioLibrary start');
      final rawResult = await _androidMediaLibraryChannel
          .invokeMethod<List<Object?>>('scanAudioLibrary');
      debugPrint(
        '[AudioCore][MediaLibrary] scanAudioLibrary rawCount='
        '${rawResult?.length ?? 0}',
      );
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

      debugPrint(
        '[AudioCore][MediaLibrary] scanAudioLibrary parsedCount=${entries.length}',
      );
      return AndroidMediaLibraryScanResult(
        permissionGranted: true,
        entries: entries,
      );
    } on PlatformException catch (e) {
      debugPrint(
        '[AudioCore][MediaLibrary] scanAndroidMediaLibrary failed: ${e.code} ${e.message} '
        'details=${e.details}',
      );
      return AndroidMediaLibraryScanResult(
        permissionGranted: true,
        entries: const <AndroidMediaLibraryEntry>[],
        errorCode: e.code,
        errorMessage: e.message,
      );
    } catch (e) {
      debugPrint(
        '[AudioCore][MediaLibrary] scanAndroidMediaLibrary failed: $e',
      );
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

  String? _resolvePersistentAccessPath(String? path) {
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

    return _resolveTrackPath(currentTrack).trim();
  }

  Future<bool> _updateMetadataAtPath({
    required String path,
    String? fallbackMediaUri,
    required AndroidTrackMetadataUpdate metadata,
    bool managePlaybackSync = true,
  }) async {
    final file = path.startsWith('content://') ? null : File(path);
    if (file != null && !file.existsSync()) {
      debugPrint(
        '[AudioCore][Metadata] updateMetadata: File does not exist: $path',
      );
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

      debugPrint('[AudioCore][Metadata] updateMetadata failed: $errorText');
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
  Future<TrackMetadata> getTrackMetadata({String? path}) async {
    final targetPath = _resolveMetadataPath(path);
    if (targetPath == null) {
      throw StateError('No path provided and no current track is playing.');
    }

    return _engine.getTrackMetadata(path: targetPath);
  }

  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    int thumbnailSize = generatedArtworkThumbnailSize,
    double hueCohesion = 0.0,
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (!_initialized) {
      throw StateError('AudioCoreController is not initialized.');
    }

    return _engine.generateTrackArtwork(
      path: path,
      cacheRootPath: cacheRootPath,
      saveLargeArtwork: saveLargeArtwork,
      thumbnailSize: thumbnailSize,
      hueCohesion: hueCohesion,
    );
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
