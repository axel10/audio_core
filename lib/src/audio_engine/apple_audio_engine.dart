import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../fft_processor.dart';
import '../rust/api/simple/equalizer.dart';
import 'audio_engine_interface.dart';

class AppleAudioEngine implements AudioEngine {
  static const MethodChannel _channel = MethodChannel('audio_core.player');
  static const EventChannel _fftChannel = EventChannel('audio_core.player/fft');

  final _statusController = StreamController<AudioStatus>.broadcast();
  StreamSubscription? _fftSubscription;
  String? _currentPath;
  double _currentVolume = 1.0;
  EqualizerConfig? _lastConfig;
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
  }

  @override
  Future<void> dispose() async {
    await _fftSubscription?.cancel();
    _fftSubscription = null;
    _latestFftCache = const <double>[];
    _fftEventCount = 0;
    await _statusController.close();
    await _channel.invokeMethod('dispose');
  }

  @override
  Future<void> load(String path) async {
    _currentPath = path;
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
