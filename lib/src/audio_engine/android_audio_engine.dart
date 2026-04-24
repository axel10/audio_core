import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../fft_processor.dart';
import '../rust/api/simple_api.dart' as rust;
import '../rust/api/simple/equalizer.dart';
import '../track_artwork.dart';
import '../track_metadata.dart';
import 'audio_engine_interface.dart';

class AndroidAudioEngine implements AudioEngine {
  static const MethodChannel _channel = MethodChannel('my_exoplayer');
  static const EventChannel _fftChannel = EventChannel('my_exoplayer/fft');

  final _statusController = StreamController<AudioStatus>.broadcast();
  StreamSubscription? _fftSubscription;
  String? _currentPath;
  double _currentVolume = 1.0;
  final String _activePlayerId = 'main';
  EqualizerConfig? _lastConfig;
  bool _isPlaying = false;
  List<double> _latestFftCache = const <double>[];
  _PendingAndroidEdit? _pendingEdit;

  @override
  Stream<AudioStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPlayerStateChanged') {
        final String playerId = call.arguments['playerId'] ?? 'main';
        if (playerId == _activePlayerId) {
          final String? playbackState = call.arguments['state']?.toString();
          final int positionMs = call.arguments['position'] ?? 0;
          final int durationMs = call.arguments['duration'] ?? 0;
          final bool isPlaying = call.arguments['isPlaying'] ?? false;
          final String? error = call.arguments['error'];
          final int updateTimeMs =
              call.arguments['updateTime'] ??
              DateTime.now().millisecondsSinceEpoch;

          _isPlaying = isPlaying;

          _statusController.add(
            AudioStatus(
              path: _currentPath,
              playbackState: playbackState,
              position: Duration(milliseconds: positionMs),
              duration: Duration(milliseconds: durationMs),
              isPlaying: isPlaying,
              volume: _currentVolume,
              updateTimeSinceEpochMs: updateTimeMs,
              error: error,
            ),
          );
        }
      }
    });
    _fftSubscription ??= _fftChannel.receiveBroadcastStream().listen(
      _handleFftEvent,
      onError: (_) {},
    );
    // Ensure default player exists on native side
    await _channel.invokeMethod('sayHello');
  }

  @override
  Future<void> dispose() async {
    _pendingEdit = null;
    await _fftSubscription?.cancel();
    _fftSubscription = null;
    _latestFftCache = const <double>[];
    await _statusController.close();
    await _channel.invokeMethod('dispose', {'playerId': 'main'});
    await _channel.invokeMethod('dispose', {'playerId': 'crossfade'});
  }

  @override
  Future<void> stop() async {
    _pendingEdit = null;
    _latestFftCache = const <double>[];
    await _channel.invokeMethod('dispose', {'playerId': 'main'});
    await _channel.invokeMethod('dispose', {'playerId': 'crossfade'});
  }

  @override
  Future<void> load(String path) async {
    _currentPath = path;
    _latestFftCache = const <double>[];
    debugPrint('[AndroidAudioEngine] load path=$path');
    await _channel.invokeMethod('load', {
      'url': path,
      'playerId': _activePlayerId,
    });
  }

  @override
  Future<void> crossfade(
    String path,
    Duration duration, {
    Duration? position,
  }) async {
    debugPrint(
      '[AndroidAudioEngine] crossfade path=$path durationMs=${duration.inMilliseconds} '
      'positionMs=${position?.inMilliseconds}',
    );
    _latestFftCache = const <double>[];
    await _channel.invokeMethod('crossfade', {
      'path': path,
      'durationMs': duration.inMilliseconds,
      if (position != null) 'positionMs': position.inMilliseconds,
      'playerId': _activePlayerId,
    });
    _currentPath = path;
  }

  @override
  Future<void> transition(
    String path,
    Duration duration, {
    Duration? position,
    required bool autoPlay,
    double? targetVolume,
  }) async {
    final resolvedTargetVolume = (targetVolume ?? _currentVolume)
        .clamp(0.0, 1.0)
        .toDouble();
    debugPrint(
      '[AndroidAudioEngine] transition path=$path durationMs=${duration.inMilliseconds} '
      'positionMs=${position?.inMilliseconds} autoPlay=$autoPlay '
      'targetVolume=$resolvedTargetVolume',
    );
    _latestFftCache = const <double>[];
    await _channel.invokeMethod('transition', {
      'path': path,
      'durationMs': duration.inMilliseconds,
      if (position != null) 'positionMs': position.inMilliseconds,
      'playerId': _activePlayerId,
      'autoPlay': autoPlay,
      'targetVolume': resolvedTargetVolume,
    });
    _currentPath = path;
    _currentVolume = resolvedTargetVolume;
  }

  @override
  Future<void> play({Duration? fadeDuration}) async {
    debugPrint(
      '[AndroidAudioEngine] play fadeDurationMs=${fadeDuration?.inMilliseconds ?? 0} '
      'currentPath=$_currentPath volume=$_currentVolume',
    );
    await _channel.invokeMethod('play', {
      'playerId': _activePlayerId,
      'fadeDurationMs': fadeDuration?.inMilliseconds ?? 0,
      'targetVolume': _currentVolume,
    });
  }

  @override
  Future<void> pause({Duration? fadeDuration}) async {
    debugPrint(
      '[AndroidAudioEngine] pause fadeDurationMs=${fadeDuration?.inMilliseconds ?? 0} '
      'currentPath=$_currentPath volume=$_currentVolume',
    );
    await _channel.invokeMethod('pause', {
      'playerId': _activePlayerId,
      'fadeDurationMs': fadeDuration?.inMilliseconds ?? 0,
    });
  }

  @override
  Future<void> seek(Duration position) async {
    debugPrint(
      '[AndroidAudioEngine] seek positionMs=${position.inMilliseconds} currentPath=$_currentPath',
    );
    await _channel.invokeMethod('seek', {
      'position': position.inMilliseconds,
      'playerId': _activePlayerId,
    });
  }

  @override
  Future<void> setVolume(double volume) {
    _currentVolume = volume;
    debugPrint(
      '[AndroidAudioEngine] setVolume volume=$volume currentPath=$_currentPath',
    );
    return _channel.invokeMethod('setVolume', {
      'volume': volume,
      'playerId': _activePlayerId,
      'fadeDurationMs': 0,
    });
  }

  @override
  Future<Duration> getDuration() async {
    final int? ms = await _channel.invokeMethod('getDuration', {
      'playerId': _activePlayerId,
    });
    return Duration(milliseconds: ms ?? 0);
  }

  @override
  Future<PositionSnapshot> getCurrentPosition() async {
    final Map<dynamic, dynamic>? result = await _channel.invokeMethod(
      'getCurrentPosition',
      {'playerId': _activePlayerId},
    );
    return PositionSnapshot(
      position: Duration(milliseconds: (result?['position'] as int?) ?? 0),
      takenAtMs:
          (result?['takenAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<List<double>> getLatestFft() async {
    return List<double>.from(_latestFftCache, growable: false);
  }

  @override
  bool get fftDataIsPreGrouped => true;

  @override
  Future<void> updateVisualizerFftOptions(
    VisualizerOptimizationOptions options,
  ) {
    return _channel.invokeMethod('configureFftProcessing', {
      'frequencyGroups': options.frequencyGroups,
      'skipHighFrequencyGroups': options.skipHighFrequencyGroups,
      'aggregationMode': options.aggregationMode.name,
    });
  }

  @override
  Future<Float32List> getAudioPcm({String? path, int sampleStride = 0}) {
    throw UnsupportedError('PCM extraction is not available on Android.');
  }

  @override
  Future<int> getAudioPcmChannelCount({String? path}) {
    throw UnsupportedError('PCM extraction is not available on Android.');
  }

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  }) async {
    try {
      // Direct native waveform extraction with downsampling
      final List<dynamic>? result = await _channel.invokeMethod('getWaveform', {
        'path': path,
        'expectedChunks': expectedChunks,
        'sampleStride': sampleStride,
      });
      if (result == null) return [];
      // Native returns 0-100, we normalize to 0.0-1.0
      return result.map((e) => (e as num).toDouble() / 100.0).toList();
    } catch (e) {
      return [];
    }
  }

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) async {
    final previous = _lastConfig;
    await _applyConfigToPlayer(
      _activePlayerId,
      config,
      previousConfig: previous,
    );
    _lastConfig = config;
  }

  void _handleFftEvent(dynamic event) {
    if (event is! Map) return;
    final map = event.cast<Object?, Object?>();
    final playerId = map['playerId']?.toString();
    if (playerId != _activePlayerId) return;

    final values = map['values'];
    if (values is! List) return;

    _latestFftCache = values
        .map((entry) => (entry as num?)?.toDouble() ?? 0.0)
        .toList(growable: false);
  }

  Future<void> _applyConfigToPlayer(
    String playerId,
    EqualizerConfig config, {
    EqualizerConfig? previousConfig,
  }) async {
    final previous = previousConfig;
    final enabledChanged =
        previous == null || previous.enabled != config.enabled;
    final preampChanged =
        previous == null || previous.preampDb != config.preampDb;
    final bandCountChanged =
        previous == null || previous.bandCount != config.bandCount;
    final bandGainsChanged =
        previous == null ||
        !listEquals(previous.bandGainsDb, config.bandGainsDb);

    if (enabledChanged) {
      await _channel.invokeMethod('setCppEqualizerEnabled', {
        'enabled': config.enabled,
        'playerId': playerId,
      });
    }
    if (preampChanged) {
      await _channel.invokeMethod('setCppEqualizerPreAmp', {
        'gainDb': config.preampDb,
        'playerId': playerId,
      });
    }
    if (bandCountChanged) {
      await _channel.invokeMethod('setCppEqualizerBandCount', {
        'count': config.bandCount,
        'playerId': playerId,
      });
    }
    if (bandCountChanged || bandGainsChanged) {
      await _channel.invokeMethod('setCppEqualizerConfig', {
        'bandGains': config.bandGainsDb.toList(),
        'playerId': playerId,
      });
    }
  }

  @override
  Future<EqualizerConfig> getEqualizerConfig() async {
    if (_lastConfig != null) return _lastConfig!;
    throw UnimplementedError('getEqualizerConfig not available on Android yet');
  }

  @override
  bool get supportsCrossfade => true;

  @override
  Future<String?> extractFingerprint(String path) async {
    try {
      final String? fingerprint = await _channel.invokeMethod(
        'extractFingerprint',
        {'path': path},
      );
      return fingerprint;
    } catch (e) {
      debugPrint('[AndroidAudioEngine] Fingerprint extraction failed: $e');
      return null;
    }
  }

  // Internal helper for non-AudioEngine interface methods if needed
  Future<Map<String, dynamic>?> getSystemEqualizerParams() async {
    final Map<dynamic, dynamic>? result = await _channel.invokeMethod(
      'getSystemEqualizerParams',
      {'playerId': _activePlayerId},
    );
    return result?.cast<String, dynamic>();
  }

  @override
  Future<void> prepareForFileWrite() async {
    final path = _currentPath;
    if (path == null) return;

    final pos = await getCurrentPosition();
    _pendingEdit = _PendingAndroidEdit(
      path: path,
      position: pos.position,
      wasPlaying: _isPlaying,
    );

    await _channel.invokeMethod('prepareForFileWrite', {
      'playerId': _activePlayerId,
    });
  }

  @override
  Future<void> finishFileWrite() async {
    final edit = _pendingEdit;
    if (edit == null) return;

    try {
      // Reload the audio file and restore the previous playback point.
      await load(edit.path);
      await seek(edit.position);
      if (edit.wasPlaying) {
        await _channel.invokeMethod('play', {
          'playerId': _activePlayerId,
          'fadeDurationMs': 0,
        });
      }
      _pendingEdit = null;
    } catch (_) {
      // Keep the pending snapshot so callers can attempt recovery again.
      rethrow;
    }
  }

  @override
  Future<bool> registerPersistentAccess(String path) async => false;

  @override
  Future<void> forgetPersistentAccess(String path) async {}

  @override
  Future<bool> hasPersistentAccess(String path) async => false;

  @override
  Future<List<String>> listPersistentAccessPaths() async => const <String>[];

  @override
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  }) async {
    final success = await _channel.invokeMethod<bool>('updateTrackMetadata', {
      'path': path,
      'metadata': metadata,
    });
    return success ?? false;
  }

  @override
  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    try {
      final Map<dynamic, dynamic>? result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getTrackMetadata', {
            'path': path,
            if (fallbackMediaUri != null && fallbackMediaUri.trim().isNotEmpty)
              'fallbackMediaUri': fallbackMediaUri.trim(),
          });
      return TrackMetadata.fromMap(
        result?.cast<String, Object?>() ?? <String, Object?>{},
      );
    } catch (e) {
      return TrackMetadata(
        error: e.toString(),
        genres: const <String>[],
        pictures: const [],
      );
    }
  }

  @override
  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    int thumbnailSize = 200,
  }) async {
    final result = await rust.generateTrackArtwork(
      path: path,
      cacheRootPath: cacheRootPath,
      saveLargeArtwork: saveLargeArtwork,
      thumbnailSize: thumbnailSize,
    );
    return GeneratedTrackArtwork(
      artworkFound: result.artworkFound,
      artworkPath: result.artworkPath,
      thumbnailPath: result.thumbnailPath,
      artworkWidth: result.artworkWidth,
      artworkHeight: result.artworkHeight,
      themeColorsBlob: result.themeColorsBlob,
    );
  }

  @override
  Future<void> removeAllTags({String? path}) {
    throw UnimplementedError('removeAllTags is not implemented on Android yet');
  }
}

class _PendingAndroidEdit {
  final String path;
  final Duration position;
  final bool wasPlaying;

  _PendingAndroidEdit({
    required this.path,
    required this.position,
    required this.wasPlaying,
  });
}
