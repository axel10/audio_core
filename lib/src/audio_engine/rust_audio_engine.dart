import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../fft_processor.dart';
import '../rust/api/simple_api.dart' as rust;
import '../rust/api/simple/controller.dart' show PlaybackErrorKind;
import '../rust/api/simple/equalizer.dart';
import '../track_metadata.dart';
import '../track_metadata_update.dart';
import '../audio_details.dart';
import '../apple_file_access_holder.dart';
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
          'path=${state.path ?? "null"} kind=${state.errorKind?.name ?? "unknown"} '
          'error=${hasError ? nativeError : "<missing native error>"}',
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
          // 原生没有给 kind 时按曲目错误兜底，与引入 kind 之前的行为一致。
          errorKind: propagatedError == null
              ? null
              : (state.errorKind ?? PlaybackErrorKind.track),
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
        await registerPersistentAccess(path);
        await beginScopedAccess(path, holder: AppleFileAccessHolder.playback);
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
        await registerPersistentAccess(path);
        await beginScopedAccess(path, holder: AppleFileAccessHolder.playback);
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
        await registerPersistentAccess(path);
        await beginScopedAccess(path, holder: AppleFileAccessHolder.playback);
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
    // 一次性读取：用完立刻放掉，不要把 default 桶当常驻授权用。
    final needsScope = _isApple && path != null && path.isNotEmpty;
    if (needsScope) {
      await beginScopedAccess(path, holder: AppleFileAccessHolder.reader);
    }
    try {
      return await rust.getAudioPcm(
        path: path,
        sampleStride: BigInt.from(sampleStride),
      );
    } finally {
      if (needsScope) {
        await endScopedAccess(path, holder: AppleFileAccessHolder.reader);
      }
    }
  }

  @override
  Future<int> getAudioPcmChannelCount({String? path}) async {
    final needsScope = _isApple && path != null && path.isNotEmpty;
    if (needsScope) {
      await beginScopedAccess(path, holder: AppleFileAccessHolder.reader);
    }
    try {
      return await rust.getAudioPcmChannelCount(path: path);
    } finally {
      if (needsScope) {
        await endScopedAccess(path, holder: AppleFileAccessHolder.reader);
      }
    }
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
  Future<String?> pickAuthorizedDirectory() async {
    if (_isApple) {
      return await _amberInvokeMethod<String>('pickAndAuthorizeDirectory');
    }
    return null;
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

  /// 已向原生申请、尚未释放的占用：holder → 路径集合。仅苹果平台使用。
  ///
  /// 原生只能计数，分不清「第二次 begin 是同一次占用的重入」。播放链路
  /// app → 控制器 → 引擎三层各 begin 一次，而释放只发生一次，计数永远回不到零；
  /// 分享链路同理。因此在这里做进程内去重：同一 (holder, 路径) 只下发一次
  /// begin，end 也只下发一次。
  static final Map<String, Set<String>> _scopedAccessPaths =
      <String, Set<String>>{};

  static const String _defaultScopedHolder = 'default';

  static String _scopedHolderKey(String? holder) =>
      (holder == null || holder.isEmpty) ? _defaultScopedHolder : holder;

  @override
  Future<bool> beginScopedAccess(String path, {String? holder}) async {
    if (!_isApple) return true;

    final key = _scopedHolderKey(holder);
    final held = _scopedAccessPaths.putIfAbsent(key, () => <String>{});
    if (held.contains(path)) return true;

    final success = await _amberInvokeMethod<bool>('beginScopedAccess', {
      'path': path,
      'holder': key,
    });
    // begin 返回 false 有两种含义：路径本来就在可访问范围内（系统没有为此
    // 增加引用计数），或系统拒绝。两种情况都不能记成「已持有」，否则后面
    // 的 end 会去减一份并不存在的额度。
    if (success != true) return false;

    held.add(path);
    return true;
  }

  @override
  Future<void> endScopedAccess(String path, {String? holder}) async {
    if (!_isApple) return;

    final key = _scopedHolderKey(holder);
    final held = _scopedAccessPaths[key];
    if (held == null || !held.remove(path)) {
      // 从未真正持有过，不能下发 end：减掉的会是别的调用方或别的 holder 的份额。
      return;
    }
    await _amberInvokeMethod<void>('endScopedAccess', {
      'path': path,
      'holder': key,
    });
  }

  @override
  Future<void> releaseScopedAccessHolder(String holder) async {
    if (!_isApple) return;

    final key = _scopedHolderKey(holder);
    final held = _scopedAccessPaths.remove(key);
    if (held == null) return;
    for (final path in held) {
      await _amberInvokeMethod<void>('endScopedAccess', {
        'path': path,
        'holder': key,
      });
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
  Future<AudioDetails> getAudioDetails({
    required String path,
    String? fallbackMediaUri,
  }) async {
    return getAudioDetailsWithFlutterTaglib(
      path: path,
      fallbackMediaUri: fallbackMediaUri,
    );
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
