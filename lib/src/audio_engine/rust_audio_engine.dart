import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../fft_processor.dart';
import '../rust/api/simple_api.dart' as rust;
import '../rust/api/simple/equalizer.dart';
import '../track_metadata.dart';
import '../track_metadata_update.dart';
import '../audio_details.dart';
import 'audio_engine_interface.dart';
import 'flutter_taglib_metadata_bridge.dart';
import 'track_artwork_support.dart';

class RustAudioEngine with TrackArtworkSupport implements AudioEngine {
  static const MethodChannel _appleChannel = MethodChannel('audio_core.player');

  bool get _isApple => Platform.isIOS || Platform.isMacOS;
  final _statusController = StreamController<AudioStatus>.broadcast();
  StreamSubscription? _subscription;
  double _currentVolume = 1.0;

  @override
  Stream<AudioStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _subscription = rust.subscribePlaybackState().listen((state) {
      _currentVolume = state.volume.clamp(0.0, 1.0);
      final nativeError = state.error?.trim();
      final hasError = nativeError != null && nativeError.isNotEmpty;
      final isErrorState = state.playbackState == 'ERROR';
      if (hasError || isErrorState) {
        debugPrint(
          '[RustAudioEngine] Playback error state=${state.playbackState ?? "null"} '
          'path=${state.path ?? "null"} error=${hasError ? nativeError : "<missing native error>"}',
        );
      }
      final propagatedError = hasError
          ? nativeError
          : (isErrorState
                ? 'Native playback entered ERROR without a reason'
                : null);
      _statusController.add(
        AudioStatus(
          path: state.path,
          playbackState: state.playbackState,
          position: Duration(milliseconds: state.positionMs.toInt()),
          duration: Duration(milliseconds: state.durationMs.toInt()),
          isPlaying: state.isPlaying,
          volume: state.volume,
          updateTimeSinceEpochMs: DateTime.now().millisecondsSinceEpoch,
          error: propagatedError,
        ),
      );
    });
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _statusController.close();
    await rust.disposeAudio();
  }

  @override
  Future<void> stop() {
    return rust.disposeAudio();
  }

  @override
  Future<void> load(String path) async {
    try {
      if (_isApple && path.isNotEmpty) {
        await beginScopedAccess(path);
      }
      await rust.loadAudioFile(path: path);
    } catch (e, st) {
      debugPrint('[RustAudioEngine] loadAudioFile failed for "$path": $e\n$st');
      rethrow;
    }
  }

  @override
  Future<void> crossfade(
    String path,
    Duration duration, {
    Duration? position,
  }) async {
    try {
      if (_isApple && path.isNotEmpty) {
        await beginScopedAccess(path);
      }
      await rust.crossfadeToAudioFile(
        path: path,
        durationMs: duration.inMilliseconds,
      );
    } catch (e, st) {
      debugPrint(
        '[RustAudioEngine] crossfadeToAudioFile failed for "$path": $e\n$st',
      );
      rethrow;
    }
  }

  @override
  Future<void> transition(
    String path,
    Duration duration, {
    Duration? position,
    required bool autoPlay,
    double? targetVolume,
  }) async {
    try {
      if (_isApple && path.isNotEmpty) {
        await beginScopedAccess(path);
      }
      final resolvedTargetVolume = (targetVolume ?? _currentVolume)
          .clamp(0.0, 1.0)
          .toDouble();

      if (duration > Duration.zero) {
        await rust.pauseAudio(fadeDurationMs: duration.inMilliseconds);
      }

      await rust.setAudioVolume(volume: resolvedTargetVolume);
      await rust.loadAudioFile(path: path);
      if (position != null) {
        await rust.seekAudioMs(positionMs: position.inMilliseconds);
      }

      if (autoPlay) {
        await rust.playAudio(fadeDurationMs: duration.inMilliseconds);
      }
      _currentVolume = resolvedTargetVolume;
    } catch (e, st) {
      debugPrint('[RustAudioEngine] transition failed for "$path": $e\n$st');
      rethrow;
    }
  }

  @override
  Future<void> play({Duration? fadeDuration}) async {
    try {
      await rust.playAudio(fadeDurationMs: fadeDuration?.inMilliseconds ?? 0);
    } catch (e, st) {
      debugPrint('[RustAudioEngine] playAudio failed: $e\n$st');
      rethrow;
    }
  }

  @override
  Future<void> pause({Duration? fadeDuration}) =>
      rust.pauseAudio(fadeDurationMs: fadeDuration?.inMilliseconds ?? 0);

  @override
  Future<void> seek(Duration position) async {
    try {
      await rust.seekAudioMs(positionMs: position.inMilliseconds);
    } catch (e, st) {
      debugPrint('[RustAudioEngine] seekAudioMs failed: $e\n$st');
      rethrow;
    }
  }

  @override
  Future<void> setVolume(double volume) =>
      rust.setAudioVolume(volume: volume).then((_) {
        _currentVolume = volume.clamp(0.0, 1.0);
      });

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    print('[AudioTrace][DartEngineSpeed] forwarding speed=$speed');
    await rust.setPlaybackSpeed(speed: speed);
    print('[AudioTrace][DartEngineSpeed] forwarded speed=$speed');
  }

  @override
  Future<double> getPlaybackSpeed() async {
    final speed = await rust.getPlaybackSpeed();
    return speed;
  }

  @override
  Future<String> getDecodeEngine() => Future.value(rust.getAudioDecodeEngine());

  @override
  Future<Duration> getDuration() async {
    final ms = await rust.getAudioDurationMs();
    return Duration(milliseconds: ms.toInt());
  }

  @override
  Future<PositionSnapshot> getCurrentPosition() async {
    final ms = await rust.getAudioPositionMs();
    return PositionSnapshot(
      position: Duration(milliseconds: ms.toInt()),
      takenAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<List<double>> getLatestFft() async {
    final data = await rust.getLatestFft();
    return data.map((e) => e.toDouble()).toList();
  }

  @override
  Future<void> updateVisualizerFftOptions(
    VisualizerOptimizationOptions options,
  ) async {}

  @override
  Future<void> setFftCaptureEnabled(bool enabled) async {}

  @override
  bool get fftDataIsPreGrouped => false;

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  }) => loadWaveformFromRust(
    path: path,
    expectedChunks: expectedChunks,
    sampleStride: sampleStride,
  );

  @override
  Stream<List<double>> streamWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  }) async* {
    final waveform = await getWaveform(
      path: path,
      expectedChunks: expectedChunks,
      sampleStride: sampleStride,
    );
    if (waveform.isNotEmpty) {
      yield waveform;
    }
  }

  @override
  Future<Float32List> getAudioPcm({String? path, int sampleStride = 0}) async {
    if (_isApple && path != null && path.isNotEmpty) {
      await beginScopedAccess(path);
    }
    return rust.getAudioPcm(
      path: path,
      sampleStride: BigInt.from(sampleStride),
    );
  }

  @override
  Future<int> getAudioPcmChannelCount({String? path}) async {
    if (_isApple && path != null && path.isNotEmpty) {
      await beginScopedAccess(path);
    }
    return rust.getAudioPcmChannelCount(path: path);
  }

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) =>
      rust.setAudioEqualizerConfig(config: config);

  @override
  Future<EqualizerConfig> getEqualizerConfig() =>
      rust.getAudioEqualizerConfig();

  @override
  bool get supportsCrossfade => true;

  @override
  String normalizeArtworkPath(String path) => path;

  @override
  Future<String?> extractFingerprint(String path) async {
    try {
      return await rust.getAudioFingerprint(path: path);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> prepareForFileWrite() async {
    await rust.prepareForFileWrite();
    if (_isApple) {
      final currentPath = rust.getLoadedAudioPath();
      await _amberInvokeMethod('prepareForFileWrite', <String, Object?>{
        if (currentPath != null) 'path': currentPath,
      });
    }
  }

  @override
  Future<void> finishFileWrite() async {
    await rust.finishFileWrite();
    if (_isApple) {
      final currentPath = rust.getLoadedAudioPath();
      await _amberInvokeMethod('finishFileWrite', <String, Object?>{
        if (currentPath != null) 'path': currentPath,
      });
    }
  }

  // Helper to handle ignore/suppress method channel invocation if needed
  Future<T?> _amberInvokeMethod<T>(String method, [dynamic arguments]) async {
    try {
      return await _appleChannel.invokeMethod<T>(method, arguments);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> registerPersistentAccess(String path) async {
    if (_isApple) {
      final success = await _amberInvokeMethod<bool>(
        'registerPersistentAccess',
        {'path': path},
      );
      return success ?? false;
    }
    return false;
  }

  @override
  Future<void> forgetPersistentAccess(String path) async {
    if (_isApple) {
      await _amberInvokeMethod<void>('forgetPersistentAccess', {'path': path});
    }
  }

  @override
  Future<bool> hasPersistentAccess(String path) async {
    if (_isApple) {
      final success = await _amberInvokeMethod<bool>('hasPersistentAccess', {
        'path': path,
      });
      return success ?? false;
    }
    return false;
  }

  @override
  Future<List<String>> listPersistentAccessPaths() async {
    if (_isApple) {
      final paths = await _appleChannel.invokeListMethod<String>(
        'listPersistentAccessPaths',
      );
      return paths ?? const <String>[];
    }
    return const <String>[];
  }

  @override
  Future<bool> beginScopedAccess(String path) async {
    if (_isApple) {
      final success = await _amberInvokeMethod<bool>('beginScopedAccess', {
        'path': path,
      });
      return success ?? false;
    }
    return true;
  }

  @override
  Future<void> endScopedAccess(String path) async {
    if (_isApple) {
      await _amberInvokeMethod<void>('endScopedAccess', {'path': path});
    }
  }

  @override
  Future<bool> updateTrackMetadata({
    required String path,
    required Map<String, Object?> metadata,
  }) async {
    return updateTrackMetadataWithFlutterTaglib(
      path: path,
      fallbackMediaUri: metadata['fallbackMediaUri'] as String?,
      metadata: metadata,
    );
  }

  @override
  Future<List<bool>> updateTrackMetadataBatch({
    required List<TrackMetadataWriteRequest> requests,
  }) async {
    return updateTrackMetadataBatchWithFlutterTaglib(requests: requests);
  }

  @override
  Future<bool> supportsBatchMetadataWrite() async => true;

  @override
  Future<List<bool>> copyTrackMetadataBatch({
    required List<TrackMetadataCopyRequest> requests,
  }) async {
    return copyTrackMetadataBatchWithFlutterTaglib(requests: requests);
  }

  @override
  Future<TrackMetadata> getTrackMetadata({
    required String path,
    String? fallbackMediaUri,
  }) async {
    try {
      final metadata = await readTrackMetadataWithFlutterTaglib(
        path,
        fallbackMediaUri: fallbackMediaUri,
      );
      return metadata ??
          TrackMetadata(
            error: 'Failed to read metadata via flutter_taglib.',
            genres: const <String>[],
            pictures: const [],
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
  Future<AudioDetails> getAudioDetails({required String path}) async {
    return getAudioDetailsWithFlutterTaglib(path: path);
  }

  @override
  Future<void> removeAllTags({String? path}) async {
    final targetPath = path?.trim();
    if (targetPath == null || targetPath.isEmpty) {
      throw ArgumentError.value(path, 'path', 'Path is required here.');
    }
    final success = await removeAllTagsWithFlutterTaglib(targetPath);
    if (!success) {
      throw StateError('Failed to remove tags via flutter_taglib.');
    }
  }
}
