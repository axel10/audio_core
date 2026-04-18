import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dart_chromaprint/dart_chromaprint.dart';

import '../rust/api/simple/equalizer.dart';
import '../rust/api/simple_api.dart' as rust;
import '../track_metadata.dart';
import 'audio_engine_interface.dart';
import 'pcm_waveform_support.dart';
import 'rust_metadata_bridge.dart';

class AppleAudioEngine with PcmWaveformSupport implements AudioEngine {
  static const MethodChannel _channel = MethodChannel('my_exoplayer');

  final _statusController = StreamController<AudioStatus>.broadcast();
  String? _currentPath;
  double _currentVolume = 1.0;
  EqualizerConfig? _lastConfig;

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
      final positionMs = (args['position'] as num?)?.toInt() ?? 0;
      final durationMs = (args['duration'] as num?)?.toInt() ?? 0;
      final isPlaying = args['isPlaying'] as bool? ?? false;
      final error = args['error'] as String?;
      final volume = (args['volume'] as num?)?.toDouble() ?? _currentVolume;

      _currentVolume = volume;

      _statusController.add(
        AudioStatus(
          path: _currentPath,
          position: Duration(milliseconds: positionMs),
          duration: Duration(milliseconds: durationMs),
          isPlaying: isPlaying,
          volume: volume,
          error: error,
        ),
      );
    });

    await _channel.invokeMethod('sayHello');
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod('dispose');
    _currentPath = null;
  }

  @override
  Future<void> dispose() async {
    await _statusController.close();
    await _channel.invokeMethod('dispose');
  }

  @override
  Future<void> load(String path) async {
    _currentPath = path;
    await _channel.invokeMethod('load', <String, Object?>{
      'url': path,
      'playerId': 'main',
    });
  }

  @override
  Future<void> crossfade(String path, Duration duration) async {
    _currentPath = path;
    await _channel.invokeMethod('crossfade', <String, Object?>{
      'path': path,
      'durationMs': duration.inMilliseconds,
      'playerId': 'main',
    });
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
  Future<Duration> getDuration() async {
    final int? ms = await _channel.invokeMethod(
      'getDuration',
      <String, Object?>{'playerId': 'main'},
    );
    return Duration(milliseconds: ms ?? 0);
  }

  @override
  Future<Duration> getCurrentPosition() async {
    final int? ms = await _channel.invokeMethod(
      'getCurrentPosition',
      <String, Object?>{'playerId': 'main'},
    );
    return Duration(milliseconds: ms ?? 0);
  }

  @override
  Future<List<double>> getLatestFft() async {
    try {
      final List<dynamic>? result = await _channel.invokeMethod(
        'getLatestFft',
        <String, Object?>{'playerId': 'main'},
      );
      if (result == null) return const <double>[];
      return result.map((e) => (e as num).toDouble()).toList(growable: false);
    } catch (_) {
      return const <double>[];
    }
  }

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
  }) {
    return waveformFromPcm(
      path: path,
      expectedChunks: expectedChunks,
      sampleStride: sampleStride,
    );
  }

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) async {
    _lastConfig = config;
  }

  @override
  Future<EqualizerConfig> getEqualizerConfig() async {
    if (_lastConfig != null) return _lastConfig!;
    return _defaultEqualizerConfig();
  }

  @override
  bool get supportsCrossfade => false;

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
      debugPrint('Fingerprint extraction failed: $e');
      return null;
    }
  }

  @override
  Future<void> prepareForFileWrite() => _channel.invokeMethod(
    'prepareForFileWrite',
    <String, Object?>{'playerId': 'main'},
  );

  @override
  Future<void> finishFileWrite() => _channel.invokeMethod(
    'finishFileWrite',
    <String, Object?>{'playerId': 'main'},
  );

  @override
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  }) async {
    await rust.updateTrackMetadata(
      path: path,
      metadata: trackMetadataUpdateFromMap(metadata),
    );
    return true;
  }

  @override
  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    final metadata = await rust.getTrackMetadata(path: path);
    return trackMetadataFromRust(metadata);
  }

  @override
  Future<void> removeAllTags({String? path}) async {
    final targetPath = path?.trim();
    if (targetPath == null || targetPath.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Path is required here.');
    }
    await rust.removeAllTags(path: targetPath);
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
