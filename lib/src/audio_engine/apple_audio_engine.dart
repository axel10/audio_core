import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dart_chromaprint/dart_chromaprint.dart';

import '../fft_processor.dart';
import '../rust/api/simple/equalizer.dart';
import '../rust/api/simple_api.dart' as rust;
import '../track_metadata.dart';
import '../track_metadata_update.dart';
import 'audio_engine_interface.dart';
import 'rust_metadata_bridge.dart';
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
  List<double> _lastLoggedFftFrame = const <double>[];
  int? _lastFftEventAtMs;
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
    await _fftSubscription?.cancel();
    _fftSubscription = null;
    _latestFftCache = const <double>[];
    _lastLoggedFftFrame = const <double>[];
    _lastFftEventAtMs = null;
    _fftEventCount = 0;
    await _channel.invokeMethod('dispose');
    _currentPath = null;
    _preparedWritePaths.clear();
  }

  @override
  Future<void> dispose() async {
    await _fftSubscription?.cancel();
    _fftSubscription = null;
    _latestFftCache = const <double>[];
    _lastLoggedFftFrame = const <double>[];
    _lastFftEventAtMs = null;
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
    _lastLoggedFftFrame = const <double>[];
    _lastFftEventAtMs = null;
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
    _lastLoggedFftFrame = const <double>[];
    _lastFftEventAtMs = null;
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
    _lastLoggedFftFrame = const <double>[];
    _lastFftEventAtMs = null;
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
    int sampleStride = 0,
  }) async {
    final targetPath = _resolvePath(path);
    debugPrint(
      '[AppleAudioEngine] getWaveform path=$targetPath expectedChunks=$expectedChunks',
    );
    try {
      final List<dynamic>? result = await _channel.invokeMethod(
        'getWaveform',
        <String, Object?>{'path': targetPath, 'expectedChunks': expectedChunks},
      );
      if (result == null) {
        return const <double>[];
      }
      return result.map((e) => (e as num).toDouble()).toList(growable: false);
    } catch (e) {
      debugPrint('[AppleAudioEngine] getWaveform failed: $e');
      return const <double>[];
    }
  }

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
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getFingerprintPcm',
        <String, Object?>{'path': path, 'maxDurationMs': 20_000},
      );
      if (result == null) return null;

      final samples = _int16SamplesFromFingerprintResult(result);
      final sampleRate = (result['sampleRate'] as num?)?.toInt() ?? 0;
      final channels = (result['channels'] as num?)?.toInt() ?? 0;
      if (samples.isEmpty || sampleRate <= 0 || channels <= 0) {
        return null;
      }

      return fingerprintFromPcm(
        pcm: samples,
        sampleRate: sampleRate,
        channels: channels,
      );
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
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  }) async {
    final targetPath = _normalizePath(path);
    return _withAppleFileWriteAccess(targetPath, () async {
      await rust.updateTrackMetadata(
        path: targetPath,
        metadata: trackMetadataUpdateFromMap(metadata),
      );
      return true;
    });
  }

  @override
  Future<List<bool>> updateTrackMetadataBatch({
    required List<TrackMetadataWriteRequest> requests,
  }) async {
    if (requests.isEmpty) return const <bool>[];

    final normalizedRequests = requests
        .map(
          (request) => TrackMetadataWriteRequest(
            path: _normalizePath(request.path),
            metadata: request.metadata,
            clearBeforeWrite: request.clearBeforeWrite,
            fallbackMediaUri: request.fallbackMediaUri,
          ),
        )
        .toList(growable: false);
    final paths = normalizedRequests.map((request) => request.path).toSet();

    return _withAppleBatchFileWriteAccess(paths, () async {
      final results = <bool>[];
      for (final request in normalizedRequests) {
        try {
          final metadata = trackMetadataUpdateFromUpdate(
            request.metadata,
            includeEmptyCollections: request.clearBeforeWrite,
          );
          await rust.updateTrackMetadata(
            path: request.path,
            metadata: metadata,
          );
          results.add(true);
        } catch (_) {
          results.add(false);
        }
      }
      return results;
    });
  }

  @override
  Future<bool> supportsBatchMetadataWrite() async => true;

  @override
  Future<List<bool>> copyTrackMetadataBatch({
    required List<TrackMetadataCopyRequest> requests,
  }) async {
    final results = <bool>[];
    for (final request in requests) {
      final sourcePath = _normalizePath(request.sourcePath);
      final targetPath = _normalizePath(request.targetPath);
      results.add(
        await _withAppleFileWriteAccess(targetPath, () async {
          final metadata = await rust.getTrackMetadata(path: sourcePath);
          await rust.removeAllTags(path: targetPath);
          await rust.updateTrackMetadata(path: targetPath, metadata: metadata);
          return true;
        }).catchError((_) => false),
      );
    }
    return results;
  }

  @override
  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    final targetPath = _normalizePath(path);
    final metadata = await rust.getTrackMetadata(path: targetPath);
    return trackMetadataFromRust(metadata);
  }

  @override
  Future<void> removeAllTags({String? path}) async {
    final targetPath = path?.trim();
    if (targetPath == null || targetPath.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Path is required here.');
    }
    final normalizedPath = _normalizePath(targetPath);
    await _withAppleFileWriteAccess(normalizedPath, () async {
      await rust.removeAllTags(path: normalizedPath);
    });
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

  String? _normalizeNullablePath(String? path) {
    final targetPath = path?.trim();
    if (targetPath == null || targetPath.isEmpty) return null;
    return _normalizePath(targetPath);
  }

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

    final deltaMs = _lastFftEventAtMs == null
        ? null
        : receivedAtMs - _lastFftEventAtMs!;
    _lastFftEventAtMs = receivedAtMs;

    if (_fftEventCount <= 5 || _fftEventCount % 30 == 0) {
      final bridgeLagMs = emittedAtMs == null
          ? null
          : receivedAtMs - emittedAtMs;
      final frameDelta = _meanAbsoluteDelta(
        _latestFftCache,
        _lastLoggedFftFrame,
      );
      final peak = _latestFftCache.fold<double>(0.0, (max, value) {
        return value > max ? value : max;
      });
      debugPrint(
        '[AppleAudioEngine] fft received count=$_fftEventCount '
        'nativeEmitCount=${emitCount?.toString() ?? "nil"} '
        'values=$valueCount '
        'deltaMs=${deltaMs?.toString() ?? "nil"} '
        'bridgeLagMs=${bridgeLagMs?.toString() ?? "nil"} '
        'frameDelta=${frameDelta.toStringAsFixed(6)} '
        'peak=${peak.toStringAsFixed(6)} '
        'receivedAtMs=$receivedAtMs '
        'nativeEmittedAtMs=${emittedAtMs?.toString() ?? "nil"}',
      );
      _lastLoggedFftFrame = List<double>.from(_latestFftCache);
    }
  }

  double _meanAbsoluteDelta(List<double> lhs, List<double> rhs) {
    final count = lhs.length < rhs.length ? lhs.length : rhs.length;
    if (count == 0) return 0.0;
    var total = 0.0;
    for (var i = 0; i < count; i++) {
      total += (lhs[i] - rhs[i]).abs();
    }
    return total / count;
  }

  Future<T> _withAppleFileWriteAccess<T>(
    String path,
    Future<T> Function() action,
  ) async {
    if (_preparedWritePaths.contains(path)) {
      return await action();
    }

    final arguments = <String, Object?>{
      'playerId': 'main',
      if (_normalizeNullablePath(_currentPath) != path) 'path': path,
    };

    _preparedWritePaths.add(path);
    try {
      await _channel.invokeMethod('prepareForFileWrite', arguments);
      return await action();
    } finally {
      await _channel.invokeMethod('finishFileWrite', arguments);
      _preparedWritePaths.remove(path);
    }
  }

  Future<T> _withAppleBatchFileWriteAccess<T>(
    Iterable<String> paths,
    Future<T> Function() action,
  ) async {
    final uniquePaths = <String>[];
    final alreadyPrepared = <String>{};
    for (final path in paths) {
      final normalized = _normalizePath(path);
      if (alreadyPrepared.add(normalized) &&
          !_preparedWritePaths.contains(normalized)) {
        uniquePaths.add(normalized);
      }
    }

    if (uniquePaths.isEmpty) {
      return await action();
    }

    _preparedWritePaths.addAll(uniquePaths);
    final arguments = <String, Object?>{
      'playerId': 'main',
      'paths': uniquePaths,
    };
    try {
      await _channel.invokeMethod('prepareForFileWrite', arguments);
      return await action();
    } finally {
      await _channel.invokeMethod('finishFileWrite', arguments);
      for (final path in uniquePaths) {
        _preparedWritePaths.remove(path);
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

  Int16List _int16SamplesFromFingerprintResult(Map<Object?, Object?> result) {
    final rawSamples = result['samples'];
    if (rawSamples is! List) {
      return Int16List(0);
    }

    final samples = Int16List(rawSamples.length);
    for (var i = 0; i < rawSamples.length; i++) {
      final value = (rawSamples[i] as num?)?.toDouble() ?? 0.0;
      samples[i] = (value * 32767.0).round().clamp(-32768, 32767);
    }
    return samples;
  }
}
