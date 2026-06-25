import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_core_controller_delegate.dart';
import 'audio_core_playback_coordinator.dart';
import 'player_models.dart';
import 'playlist_models.dart';
import 'player_controller.dart';
import 'playlist_controller.dart';
import 'visualizer_controller.dart';
import 'rust/api/simple_api.dart'
    hide FadeSettings, FadeMode, TrackMetadataUpdate, AudioDetails;
import 'rust/frb_generated.dart';
import 'fft_processor.dart';
import 'player_state_snapshot.dart';
import 'equalizer_controller.dart';
import 'audio_engine/audio_engine_interface.dart';
import 'audio_engine/audio_engine_factory.dart';
import 'audio_engine/audio_analysis_service.dart';
import 'audio_engine/audio_file_access.dart';
import 'android_media_library.dart';
import 'audio_details.dart';
import 'metadata_service.dart';
import 'track_artwork.dart';
import 'track_metadata.dart';
import 'track_metadata_update.dart';
import 'track_metadata_coordinator.dart';

export 'player_controller.dart';
export 'playlist_controller.dart';
export 'random_playback_models.dart';
export 'visualizer_controller.dart';
export 'equalizer_controller.dart';
export 'playlist_models.dart';
export 'player_state_snapshot.dart';
export 'android_media_library.dart';
export 'audio_core_playback_coordinator.dart' show shouldAutoAdvanceFromStatus;

/// The top-level modular controller for audio playback and visualization.
class AudioCoreController extends ChangeNotifier
    implements AudioCoreControllerDelegate {
  static const MethodChannel _androidMediaLibraryChannel = MethodChannel(
    'audio_core.media_library',
  );
  AudioCoreController({
    this.fftSize = 1024,
    this.analysisFrequencyHz = 30.0,
    FadeSettings fadeSettings = const FadeSettings(),
    VisualizerOptimizationOptions visualOptions =
        const VisualizerOptimizationOptions(),
    AudioEngine? engine,
    AudioAnalysisService? analysisService,
    AudioFileAccess? fileAccess,
    MetadataService? metadataService,
  }) {
    _engine = engine ?? createDefaultAudioEngine();
    _analysisService = analysisService ?? createDefaultAudioAnalysisService();
    _fileAccess = fileAccess ?? createDefaultAudioFileAccess();
    _metadataCoordinator = TrackMetadataCoordinator(
      fileAccess: _fileAccess,
      metadataService: metadataService ?? const FlutterTaglibMetadataService(),
      currentPlaybackPath: () => player.currentPath,
      notifyListeners: () => notifyListeners(),
      reportError: (message) => player.setError(message),
    );
    player = PlayerController(delegate: this);
    _initialFadeSettings = fadeSettings;

    playlist = PlaylistController(delegate: this);

    visualizer = VisualizerController(
      fftSize: fftSize,
      visualOptions: visualOptions,
      getLatestFft: () => _latestFftCache,
      sourceAlreadyGrouped: _engine.fftDataIsPreGrouped,
      delegate: this,
    );

    equalizer = EqualizerController(delegate: this);
    _playbackCoordinator = AudioCorePlaybackCoordinator(
      player: player,
      playlist: playlist,
      loadTrack: loadTrack,
      notifyListeners: notifyListeners,
    );
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
  late final AudioCorePlaybackCoordinator _playbackCoordinator;
  late final FadeSettings _initialFadeSettings;

  List<double> _latestFftCache = const [];

  static bool _rustLibInitialized = false;
  static bool _rustAppInitialized = false;
  bool _initialized = false;
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
    isTransitioning: _playbackCoordinator.isTransitioning,
  );

  @override
  AudioEngine get engine => _engine;
  late final AudioEngine _engine;
  late final AudioAnalysisService _analysisService;
  late final AudioFileAccess _fileAccess;
  late final TrackMetadataCoordinator _metadataCoordinator;

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

    if (!await _initializeRustBridgeIfNeeded()) return;

    // Apply initial fade settings now that RustLib is ready
    player.setFadeSettings(_initialFadeSettings);

    if (!await _initializeRustPlaybackBackendIfNeeded()) return;
    if (!await _initializeEqualizerIfNeeded()) return;
    if (!await _initializeAudioEngineIfNeeded()) return;
    _startControllerLoops();

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

  Future<bool> _initializeRustBridgeIfNeeded() async {
    if (_rustLibInitialized) return true;

    try {
      debugPrint('AudioCoreController: Initializing RustLib');
      await RustLib.init();
      _rustLibInitialized = true;
      return true;
    } catch (e) {
      if (!e.toString().contains(
        'Should not initialize flutter_rust_bridge twice',
      )) {
        debugPrint('AudioCoreController: RustLib init failed: $e');
        player.setError('Rust bridge init failed: $e');
        return false;
      }
      _rustLibInitialized = true;
      return true;
    }
  }

  Future<bool> _initializeRustPlaybackBackendIfNeeded() async {
    try {
      if (_usesRustPlaybackBackend && !_rustAppInitialized) {
        debugPrint('AudioCoreController: Initializing Rust App engine');
        await initApp();
        _rustAppInitialized = true;
      }
      return true;
    } catch (e) {
      debugPrint('AudioCoreController: Rust App engine init failed: $e');
      player.setError('Audio engine init failed: $e');
      return false;
    }
  }

  Future<bool> _initializeEqualizerIfNeeded() async {
    try {
      debugPrint('AudioCoreController: Initializing Equalizer');
      await equalizer.initialize();
      debugPrint('AudioCoreController: Equalizer initialized');
      return true;
    } catch (e) {
      debugPrint('AudioCoreController: Equalizer init failed: $e');
      player.setError('Equalizer sync failed: $e');
      return false;
    }
  }

  Future<bool> _initializeAudioEngineIfNeeded() async {
    try {
      await _engine.initialize();
      await _engine.updateVisualizerFftOptions(visualizer.options);
      _playbackStateSubscription = _engine.statusStream.listen(
        _playbackCoordinator.handlePlaybackStatusUpdate,
      );
      return true;
    } catch (e) {
      player.setError('Audio engine init failed: $e');
      return false;
    }
  }

  void _startControllerLoops() {
    _analysisTick = Timer.periodic(
      _analysisInterval,
      (_) => unawaited(_onAnalysisTick()),
    );
    _renderTick = Timer.periodic(_renderInterval, (_) => _onRenderTick());
  }

  // --- AudioCoreControllerDelegate Implementation ---

  @override
  void notifyListeners() => super.notifyListeners();

  @override
  Future<bool> canPlayTrack(AudioTrack track) async {
    final uri = track.uri.trim();
    if (uri.isEmpty) return false;

    try {
      if (uri.contains('://')) {
        final parsed = Uri.parse(uri);
        if (parsed.scheme == 'file') {
          return File.fromUri(parsed).exists();
        }

        // Non-file URIs are handed off to the audio engine.
        return true;
      }

      return File(uri).exists();
    } catch (_) {
      return false;
    }
  }

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
      onStateChanged: _playbackCoordinator.updateTransitioning,
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
        reconcile: false,
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
    _playbackCoordinator.clearEndedTracking();
  }

  /// Resets the playback session to the initial empty state.
  Future<void> resetPlaybackState() async {
    await _engine.stop();
    player.stopPlayback();
    visualizer.resetState();
    await playlist.resetPlaybackState();
    _latestFftCache = const [];
    _playbackCoordinator.reset();
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

  Future<void> _refreshLatestFftCache() async {
    try {
      _latestFftCache = await _engine.getLatestFft();
      // if (kDebugMode) {
      //   debugPrint(
      //     '[VisualizerController] fft fetch values=${_latestFftCache.length} '
      //     'fetchedAtMs=${DateTime.now().millisecondsSinceEpoch}',
      //   );
      // }
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
    debugPrint(
      '[AudioCore][Waveform] request path=$targetPath expectedChunks=$expectedChunks sampleStride=$sampleStride normalize=$normalize',
    );
    try {
      final finalData = await _analysisService.getWaveform(
        path: targetPath,
        expectedChunks: expectedChunks,
        sampleStride: sampleStride,
      );

      return normalize ? _normalizeWaveform(finalData) : finalData;
    } catch (e) {
      debugPrint('[AudioCore][Waveform] failed: $e');
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

    return _analysisService.getAudioPcm(path: path, sampleStride: sampleStride);
  }

  /// Registers a persistent Apple security-scoped bookmark for [path].
  ///
  /// On Apple platforms, this lets the app keep using an external file after
  /// the current session ends, as long as the file was selected through the
  /// system file picker at least once.
  Future<bool> registerPersistentAccess({String? path}) async {
    final targetPath = _resolvePersistentAccessPath(path);
    if (targetPath == null) return false;
    return _fileAccess.registerPersistentAccess(targetPath);
  }

  /// Forgets a previously saved persistent Apple security-scoped bookmark.
  Future<void> forgetPersistentAccess({String? path}) async {
    final targetPath = _resolvePersistentAccessPath(path);
    if (targetPath == null) return;
    await _fileAccess.forgetPersistentAccess(targetPath);
  }

  /// Returns whether the controller has a stored persistent access entry.
  Future<bool> hasPersistentAccess({String? path}) async {
    final targetPath = _resolvePersistentAccessPath(path);
    if (targetPath == null) return false;
    return _fileAccess.hasPersistentAccess(targetPath);
  }

  /// Returns all stored persistent access paths known to the Apple backend.
  Future<List<String>> listPersistentAccessPaths() async {
    return _fileAccess.listPersistentAccessPaths();
  }

  /// Begins an Apple security-scoped access session for [path].
  Future<bool> beginScopedAccess({required String path}) async {
    final targetPath = _resolvePersistentAccessPath(path);
    if (targetPath == null) return false;
    return _fileAccess.beginScopedAccess(targetPath);
  }

  /// Ends an Apple security-scoped access session for [path].
  Future<void> endScopedAccess({required String path}) async {
    final targetPath = _resolvePersistentAccessPath(path);
    if (targetPath == null) return;
    await _fileAccess.endScopedAccess(targetPath);
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
    await _metadataCoordinator.removeAllTags(path: targetPath.trim());
  }

  String _resolveTrackPath(AudioTrack track) {
    final mediaUri = track.metadataValue<String>('mediaUri')?.trim();
    final filePath = track.metadataValue<String>('filePath')?.trim();

    if (Platform.isAndroid) {
      if (mediaUri != null && mediaUri.isNotEmpty) {
        return mediaUri;
      }
      if (filePath != null && filePath.isNotEmpty) {
        return filePath;
      }
      return track.uri;
    }

    if (filePath != null && filePath.isNotEmpty) {
      return filePath;
    }
    if (mediaUri != null && mediaUri.isNotEmpty) {
      return mediaUri;
    }
    return track.uri;
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

  /// Updates the metadata of a given track.
  ///
  /// Pass [metadata] to write the supplied fields to the track.
  /// On Android, and on iOS/macOS for the currently playing file, the engine
  /// pauses and reloads the track around the write so playback resumes from
  /// the preserved position after the tag update.
  /// Batch copy operations use the same sync behavior.
  Future<bool> updateMetadata(
    AudioTrack track, {
    required TrackMetadataUpdate metadata,
    bool clearBeforeWrite = false,
  }) async {
    final path = _resolveTrackPath(track);
    final fallbackMediaUri = track.metadataValue<String>('mediaUri');
    return _metadataCoordinator.updateMetadata(
      path: path,
      fallbackMediaUri: fallbackMediaUri,
      metadata: metadata,
      clearBeforeWrite: clearBeforeWrite,
    );
  }

  Future<List<bool>> updateMetadataBatch(
    List<TrackMetadataWriteRequest> requests,
  ) async {
    return _metadataCoordinator.updateMetadataBatch(requests: requests);
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

    return _metadataCoordinator.getTrackMetadata(path: targetPath);
  }

  /// Reads audio stream details for the current track or an explicit file path.
  ///
  /// If [path] is omitted, this uses the currently playing track.
  /// If [path] is provided, it reads details from that file instead.
  Future<AudioDetails> getAudioDetails({String? path}) async {
    final targetPath = _resolveMetadataPath(path);
    if (targetPath == null) {
      throw StateError('No path provided and no current track is playing.');
    }

    return _metadataCoordinator.getAudioDetails(path: targetPath);
  }

  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    Uint8List? artworkBytes,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    TrackArtworkOptions options = const TrackArtworkOptions(),
  }) async {
    if (!_initialized) {
      await initialize();
    }
    if (!_initialized) {
      throw StateError('AudioCoreController is not initialized.');
    }

    return _analysisService.generateTrackArtwork(
      path: path,
      artworkBytes: artworkBytes,
      cacheRootPath: cacheRootPath,
      saveLargeArtwork: saveLargeArtwork,
      options: options,
    );
  }

  Future<List<bool>> copyMetadataPairs(
    List<AudioTrack> sources,
    List<AudioTrack> targets,
  ) async {
    if (sources.length != targets.length) {
      throw ArgumentError(
        'Source and target counts must match. '
        'Got ${sources.length} source(s) and ${targets.length} target(s).',
      );
    }
    if (sources.isEmpty) return const <bool>[];

    final requests = <TrackMetadataCopyRequest>[
      for (var i = 0; i < sources.length; i++)
        TrackMetadataCopyRequest(
          sourcePath: _resolveTrackPath(sources[i]),
          targetPath: _resolveTrackPath(targets[i]),
        ),
    ];

    return _metadataCoordinator.copyMetadataBatch(requests: requests);
  }
}
