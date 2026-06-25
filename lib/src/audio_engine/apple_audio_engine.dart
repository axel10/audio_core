import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../fft_processor.dart';
import '../rust/api/simple/equalizer.dart';
import '../rust/api/simple_api.dart' as rust;
import '../track_artwork.dart';
import 'audio_engine_interface.dart';
import 'track_artwork_support.dart';

class AppleAudioEngine with TrackArtworkSupport implements AudioEngine {
  static const MethodChannel _channel = MethodChannel('audio_core.player');
  static const EventChannel _fftChannel = EventChannel('audio_core.player/fft');

  final _statusController = StreamController<AudioStatus>.broadcast();
  StreamSubscription? _fftSubscription;
  String? _currentPath;
  double _currentVolume = 1.0;
  EqualizerConfig? _lastConfig;
  final Set<String> _preparedWritePaths = <String>{};
  List<double> _latestFftCache = const <double>[];
  int _fftEventCount = 0;

  @override
  Stream<AudioStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onPlayerStateChanged') {
        return;
      }

      final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
      _currentPath = args['path'] as String? ?? _currentPath;
      final playbackState =
          args['playbackState'] as String? ?? args['state'] as String?;
      final positionMs = (args['position'] as num?)?.toInt() ?? 0;
      final durationMs = (args['duration'] as num?)?.toInt() ?? 0;
      final isPlaying = args['isPlaying'] as bool? ?? false;
      final error = args['error'] as String?;
      final volume = (args['volume'] as num?)?.toDouble() ?? _currentVolume;
      final updateTimeMs =
          (args['updateTime'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;

      _currentVolume = volume;

      _statusController.add(
        AudioStatus(
          path: _currentPath,
          playbackState: playbackState,
          position: Duration(milliseconds: positionMs),
          duration: Duration(milliseconds: durationMs),
          isPlaying: isPlaying,
          volume: volume,
          updateTimeSinceEpochMs: updateTimeMs,
          error: error,
        ),
      );
    });

    _fftSubscription ??= _fftChannel.receiveBroadcastStream().listen(
      _handleFftEvent,
      onError: (_) {},
    );

    await _channel.invokeMethod('sayHello');
  }

  @override
  Future<void> stop() async {
    _latestFftCache = const <double>[];
    _fftEventCount = 0;
    // Keep the FFT event stream subscription alive across soft resets.
    // `Reset Player State` uses `stop()`, and canceling here prevents future
    // loads from receiving FFT frames unless the whole controller is
    // re-initialized.
    await _channel.invokeMethod('dispose');
    _currentPath = null;
    _preparedWritePaths.clear();
  }

  @override
  Future<void> dispose() async {
    await _fftSubscription?.cancel();
    _fftSubscription = null;
    _latestFftCache = const <double>[];
    _fftEventCount = 0;
    await _statusController.close();
    await _channel.invokeMethod('dispose');
    _preparedWritePaths.clear();
  }

  @override
  Future<void> load(String path) async {
    _currentPath = path;
    _preparedWritePaths.clear();
    _latestFftCache = const <double>[];
    _fftEventCount = 0;
    await _channel.invokeMethod('load', <String, Object?>{
      'url': path,
      'playerId': 'main',
    });
  }

  @override
  Future<void> crossfade(
    String path,
    Duration duration, {
    Duration? position,
  }) async {
    _currentPath = path;
    _latestFftCache = const <double>[];
    _fftEventCount = 0;
    await _channel.invokeMethod('crossfade', <String, Object?>{
      'path': path,
      'durationMs': duration.inMilliseconds,
      if (position != null) 'positionMs': position.inMilliseconds,
      'playerId': 'main',
    });
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

    if (duration > Duration.zero) {
      await pause(fadeDuration: duration);
    }

    _currentVolume = resolvedTargetVolume;
    _latestFftCache = const <double>[];
    _fftEventCount = 0;
    await setVolume(resolvedTargetVolume);
    await load(path);

    if (position != null) {
      await seek(position);
    }

    if (autoPlay) {
      await play(fadeDuration: duration);
    }

    _currentPath = path;
  }

  @override
  Future<void> play({Duration? fadeDuration}) async {
    await _channel.invokeMethod('play', <String, Object?>{
      'playerId': 'main',
      'fadeDurationMs': fadeDuration?.inMilliseconds ?? 0,
      'targetVolume': _currentVolume,
    });
  }

  @override
  Future<void> pause({Duration? fadeDuration}) async {
    await _channel.invokeMethod('pause', <String, Object?>{
      'playerId': 'main',
      'fadeDurationMs': fadeDuration?.inMilliseconds ?? 0,
    });
  }

  @override
  Future<void> seek(Duration position) => _channel.invokeMethod(
    'seek',
    <String, Object?>{'playerId': 'main', 'position': position.inMilliseconds},
  );

  @override
  Future<void> setVolume(double volume) async {
    _currentVolume = volume.clamp(0.0, 1.0);
    await _channel.invokeMethod('setVolume', <String, Object?>{
      'playerId': 'main',
      'volume': _currentVolume,
      'fadeDurationMs': 0,
    });
  }

  @override
  Future<String> getDecodeEngine() async => 'apple-native+ffmpeg-fallback';

  @override
  Future<Duration> getDuration() async {
    final int? ms = await _channel.invokeMethod(
      'getDuration',
      <String, Object?>{'playerId': 'main'},
    );
    return Duration(milliseconds: ms ?? 0);
  }

  @override
  Future<PositionSnapshot> getCurrentPosition() async {
    final Map<Object?, Object?>? result = await _channel
        .invokeMethod<Map<Object?, Object?>>(
          'getCurrentPosition',
          <String, Object?>{'playerId': 'main'},
        );
    return PositionSnapshot(
      position: Duration(
        milliseconds: (result?['position'] as num?)?.toInt() ?? 0,
      ),
      takenAtMs:
          (result?['takenAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<List<double>> getLatestFft() async {
    return List<double>.from(_latestFftCache, growable: false);
  }

  @override
  Future<void> updateVisualizerFftOptions(
    VisualizerOptimizationOptions options,
  ) async {
    await _channel.invokeMethod('configureFftProcessing', <String, Object?>{
      'frequencyGroups': options.frequencyGroups,
      'skipHighFrequencyGroups': options.skipHighFrequencyGroups,
      'aggregationMode': options.aggregationMode.name,
    });
  }

  @override
  bool get fftDataIsPreGrouped => false;

  @override
  Future<Float32List> getAudioPcm({String? path, int sampleStride = 0}) async {
    final targetPath = _resolvePath(path);
    final List<dynamic>? result = await _channel.invokeMethod(
      'getAudioPcm',
      <String, Object?>{'path': targetPath, 'sampleStride': sampleStride},
    );
    if (result == null) {
      return Float32List(0);
    }
    return Float32List.fromList(
      result.map((e) => (e as num).toDouble()).toList(growable: false),
    );
  }

  @override
  Future<int> getAudioPcmChannelCount({String? path}) async {
    final targetPath = _resolvePath(path);
    final int? result = await _channel.invokeMethod<int>(
      'getAudioPcmChannelCount',
      <String, Object?>{'path': targetPath},
    );
    return result ?? 1;
  }

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 4,
  }) => loadWaveformFromRust(
    path: _resolvePath(path),
    expectedChunks: expectedChunks,
    sampleStride: sampleStride,
  );

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) async {
    await _channel.invokeMethod(
      'setEqualizerConfig',
      _equalizerConfigToMap(config),
    );
    _lastConfig = config;
  }

  @override
  Future<EqualizerConfig> getEqualizerConfig() async {
    try {
      final Map<dynamic, dynamic>? result = await _channel.invokeMethod(
        'getEqualizerConfig',
      );
      if (result != null) {
        final config = _equalizerConfigFromMap(result.cast<Object?, Object?>());
        _lastConfig = config;
        return config;
      }
    } catch (_) {
      // Fall back to cached/default state if the native bridge is unavailable.
    }

    if (_lastConfig != null) return _lastConfig!;
    return _defaultEqualizerConfig();
  }

  @override
  bool get supportsCrossfade => true;

  @override
  Future<String?> extractFingerprint(String path) async {
    try {
      return await rust.getAudioFingerprint(path: path);
    } catch (e) {
      debugPrint('[AppleAudioEngine] Fingerprint extraction failed: $e');
      return null;
    }
  }

  @override
  Future<void> prepareForFileWrite() async {
    final targetPath = _currentPath?.trim();
    if (targetPath != null && targetPath.isNotEmpty) {
      _preparedWritePaths.add(_normalizePath(targetPath));
    }
    try {
      await _channel.invokeMethod('prepareForFileWrite', <String, Object?>{
        'playerId': 'main',
      });
    } catch (_) {
      if (targetPath != null && targetPath.isNotEmpty) {
        _preparedWritePaths.remove(_normalizePath(targetPath));
      }
      rethrow;
    }
  }

  @override
  Future<void> finishFileWrite() async {
    final targetPath = _currentPath?.trim();
    if (targetPath != null && targetPath.isNotEmpty) {
      _preparedWritePaths.remove(_normalizePath(targetPath));
    }
    await _channel.invokeMethod('finishFileWrite', <String, Object?>{
      'playerId': 'main',
    });
  }

  @override
  Future<bool> registerPersistentAccess(String path) async {
    final normalizedPath = _normalizePath(path);
    final bool? result = await _channel.invokeMethod<bool>(
      'registerPersistentAccess',
      <String, Object?>{'path': normalizedPath},
    );
    return result ?? false;
  }

  @override
  Future<void> forgetPersistentAccess(String path) async {
    final normalizedPath = _normalizePath(path);
    await _channel.invokeMethod('forgetPersistentAccess', <String, Object?>{
      'path': normalizedPath,
    });
  }

  @override
  Future<bool> hasPersistentAccess(String path) async {
    final normalizedPath = _normalizePath(path);
    final bool? result = await _channel.invokeMethod<bool>(
      'hasPersistentAccess',
      <String, Object?>{'path': normalizedPath},
    );
    return result ?? false;
  }

  @override
  Future<List<String>> listPersistentAccessPaths() async {
    final List<dynamic>? result = await _channel.invokeMethod(
      'listPersistentAccessPaths',
    );
    if (result == null) return const <String>[];
    return result
        .map((entry) => entry.toString())
        .where((entry) => entry.trim().isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<bool> beginScopedAccess(String path) async {
    final normalizedPath = _normalizePath(path);
    final bool? result = await _channel.invokeMethod<bool>(
      'beginScopedAccess',
      <String, Object?>{'path': normalizedPath},
    );
    return result ?? false;
  }

  @override
  Future<void> endScopedAccess(String path) async {
    final normalizedPath = _normalizePath(path);
    await _channel.invokeMethod('endScopedAccess', <String, Object?>{
      'path': normalizedPath,
    });
  }

  @override
  Future<GeneratedTrackArtwork> generateTrackArtwork({
    required String path,
    Uint8List? artworkBytes,
    required String cacheRootPath,
    required bool saveLargeArtwork,
    TrackArtworkOptions options = const TrackArtworkOptions(),
  }) async {
    final targetPath = _normalizePath(path);
    final normalizedCacheRootPath = _normalizePath(cacheRootPath);
    final result = await _withAppleFileReadAccess(targetPath, () async {
      return rust.generateTrackArtwork(
        path: targetPath,
        artworkBytes: artworkBytes,
        cacheRootPath: normalizedCacheRootPath,
        saveLargeArtwork: saveLargeArtwork,
        thumbnailSize: options.thumbnailSize,
        meshStylePreset: options.meshStylePreset.index,
        hueCohesion: options.hueCohesion,
        paletteBlurRadius: options.paletteBlurRadius,
        meshMuddyPenaltyMultiplier: options.meshMuddyPenaltyMultiplier,
        meshPopulationStrength: options.meshPopulationStrength,
        meshContrastStrength: options.meshContrastStrength,
        meshHarmonyStrength: options.meshHarmonyStrength,
        meshVibrancyStrength: options.meshVibrancyStrength,
      );
    });
    return GeneratedTrackArtwork.fromRust(result);
  }

  String _resolvePath(String? path) {
    final targetPath = path?.trim();
    if (targetPath != null && targetPath.isNotEmpty) {
      return targetPath;
    }
    final current = _currentPath?.trim();
    if (current != null && current.isNotEmpty) {
      return current;
    }
    throw StateError('A path is required for PCM extraction.');
  }

  String _normalizePath(String path) {
    final targetPath = path.trim();
    if (targetPath.startsWith('file://')) {
      return Uri.parse(targetPath).toFilePath();
    }
    return targetPath;
  }

  @override
  String normalizeArtworkPath(String path) => _normalizePath(path);

  void _handleFftEvent(dynamic event) {
    final receivedAtMs = DateTime.now().millisecondsSinceEpoch;
    if (event is Map) {
      final emitCount = (event['emitCount'] as num?)?.toInt();
      final emittedAtMs = (event['emittedAtMs'] as num?)?.toInt();
      final values = event['values'];
      if (values is List) {
        _latestFftCache = values
            .map((e) => (e as num).toDouble())
            .toList(growable: false);
        _fftEventCount += 1;
        _logFftEvent(
          receivedAtMs: receivedAtMs,
          emitCount: emitCount,
          emittedAtMs: emittedAtMs,
          valueCount: _latestFftCache.length,
        );
        return;
      }
      final payload = event['payload'];
      if (payload is Map) {
        final nestedEmitCount =
            (payload['emitCount'] as num?)?.toInt() ?? emitCount;
        final nestedEmittedAtMs =
            (payload['emittedAtMs'] as num?)?.toInt() ?? emittedAtMs;
        final nestedValues = payload['values'];
        if (nestedValues is List) {
          _latestFftCache = nestedValues
              .map((e) => (e as num).toDouble())
              .toList(growable: false);
          _fftEventCount += 1;
          _logFftEvent(
            receivedAtMs: receivedAtMs,
            emitCount: nestedEmitCount,
            emittedAtMs: nestedEmittedAtMs,
            valueCount: _latestFftCache.length,
          );
          return;
        }
      }
      if (payload is List) {
        _latestFftCache = payload
            .map((e) => (e as num).toDouble())
            .toList(growable: false);
        _fftEventCount += 1;
        _logFftEvent(
          receivedAtMs: receivedAtMs,
          emitCount: emitCount,
          emittedAtMs: emittedAtMs,
          valueCount: _latestFftCache.length,
        );
        return;
      }
    } else if (event is List) {
      _latestFftCache = event
          .map((e) => (e as num).toDouble())
          .toList(growable: false);
      _fftEventCount += 1;
      _logFftEvent(
        receivedAtMs: receivedAtMs,
        emitCount: null,
        emittedAtMs: null,
        valueCount: _latestFftCache.length,
      );
      return;
    }

    _latestFftCache = const <double>[];
  }

  void _logFftEvent({
    required int receivedAtMs,
    required int? emitCount,
    required int? emittedAtMs,
    required int valueCount,
  }) {
    if (!kDebugMode) return;

    if (_fftEventCount <= 5 || _fftEventCount % 30 == 0) {
      // debugPrint(
      //   '[AppleAudioEngine] fft received count=$_fftEventCount '
      //   'nativeEmitCount=${emitCount?.toString() ?? "nil"} '
      //   'values=$valueCount '
      //   'receivedAtMs=$receivedAtMs '
      //   'nativeEmittedAtMs=${emittedAtMs?.toString() ?? "nil"}',
      // );
    }
  }

  Future<T> _withAppleFileReadAccess<T>(
    String path,
    Future<T> Function() action,
  ) async {
    final normalizedPath = _normalizePath(path);
    final beganScopedAccess = await beginScopedAccess(normalizedPath);
    try {
      return await action();
    } finally {
      if (beganScopedAccess) {
        await endScopedAccess(normalizedPath);
      }
    }
  }

  EqualizerConfig _defaultEqualizerConfig() {
    const bandCount = 20;
    return EqualizerConfig(
      enabled: false,
      bandCount: bandCount,
      preampDb: 0.0,
      bassBoostDb: 0.0,
      bassBoostFrequencyHz: 80.0,
      bassBoostQ: 0.75,
      bandGainsDb: Float32List(bandCount),
    );
  }

  Map<String, Object?> _equalizerConfigToMap(EqualizerConfig config) {
    return <String, Object?>{
      'enabled': config.enabled,
      'bandCount': config.bandCount,
      'preampDb': config.preampDb,
      'bassBoostDb': config.bassBoostDb,
      'bassBoostFrequencyHz': config.bassBoostFrequencyHz,
      'bassBoostQ': config.bassBoostQ,
      'bandGainsDb': config.bandGainsDb.toList(growable: false),
    };
  }

  EqualizerConfig _equalizerConfigFromMap(Map<Object?, Object?> map) {
    final rawGains = map['bandGainsDb'];
    final gains = rawGains is List
        ? Float32List.fromList(
            rawGains
                .map((entry) => (entry as num?)?.toDouble() ?? 0.0)
                .toList(growable: false),
          )
        : Float32List(0);

    return EqualizerConfig(
      enabled: map['enabled'] as bool? ?? false,
      bandCount: (map['bandCount'] as num?)?.toInt() ?? 0,
      preampDb: (map['preampDb'] as num?)?.toDouble() ?? 0.0,
      bassBoostDb: (map['bassBoostDb'] as num?)?.toDouble() ?? 0.0,
      bassBoostFrequencyHz:
          (map['bassBoostFrequencyHz'] as num?)?.toDouble() ?? 80.0,
      bassBoostQ: (map['bassBoostQ'] as num?)?.toDouble() ?? 0.75,
      bandGainsDb: gains,
    );
  }
}
