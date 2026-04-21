import 'dart:async';
import 'dart:typed_data';
import '../fft_processor.dart';
import '../rust/api/simple_api.dart' as rust;
import '../rust/api/simple/equalizer.dart';
import '../track_metadata.dart';
import 'audio_engine_interface.dart';
import 'pcm_waveform_support.dart';
import 'rust_metadata_bridge.dart';

class RustAudioEngine with PcmWaveformSupport implements AudioEngine {
  final _statusController = StreamController<AudioStatus>.broadcast();
  StreamSubscription? _subscription;
  double _currentVolume = 1.0;

  @override
  Stream<AudioStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _subscription = rust.subscribePlaybackState().listen((state) {
      _currentVolume = state.volume.clamp(0.0, 1.0);
      _statusController.add(
        AudioStatus(
          path: state.path,
          playbackState: null,
          position: Duration(milliseconds: state.positionMs.toInt()),
          duration: Duration(milliseconds: state.durationMs.toInt()),
          isPlaying: state.isPlaying,
          volume: state.volume,
          updateTimeSinceEpochMs: DateTime.now().millisecondsSinceEpoch,
          error: state.error,
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
  Future<void> load(String path) {
    return rust.loadAudioFile(path: path);
  }

  @override
  Future<void> crossfade(
    String path,
    Duration duration, {
    Duration? position,
  }) => rust.crossfadeToAudioFile(
    path: path,
    durationMs: duration.inMilliseconds,
  );

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
  }

  @override
  Future<void> play({Duration? fadeDuration}) =>
      rust.playAudio(fadeDurationMs: fadeDuration?.inMilliseconds ?? 0);

  @override
  Future<void> pause({Duration? fadeDuration}) =>
      rust.pauseAudio(fadeDurationMs: fadeDuration?.inMilliseconds ?? 0);

  @override
  Future<void> seek(Duration position) =>
      rust.seekAudioMs(positionMs: position.inMilliseconds);

  @override
  Future<void> setVolume(double volume) =>
      rust.setAudioVolume(volume: volume).then((_) {
        _currentVolume = volume.clamp(0.0, 1.0);
      });

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
  bool get fftDataIsPreGrouped => false;

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 0,
  }) => waveformFromPcm(
    path: path,
    expectedChunks: expectedChunks,
    sampleStride: sampleStride,
  );

  @override
  Future<Float32List> getAudioPcm({String? path, int sampleStride = 0}) =>
      rust.getAudioPcm(path: path, sampleStride: BigInt.from(sampleStride));

  @override
  Future<int> getAudioPcmChannelCount({String? path}) =>
      rust.getAudioPcmChannelCount(path: path);

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) =>
      rust.setAudioEqualizerConfig(config: config);

  @override
  Future<EqualizerConfig> getEqualizerConfig() =>
      rust.getAudioEqualizerConfig();

  @override
  bool get supportsCrossfade => true;

  @override
  Future<String?> extractFingerprint(String path) async {
    try {
      return await rust.getAudioFingerprint(path: path);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> prepareForFileWrite() => rust.prepareForFileWrite();

  @override
  Future<void> finishFileWrite() => rust.finishFileWrite();

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
}
