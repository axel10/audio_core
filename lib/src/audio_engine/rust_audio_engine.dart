import 'dart:async';
import '../fft_processor.dart';
import '../rust/api/simple_api.dart' as rust;
import '../rust/api/simple/equalizer.dart';
import 'audio_engine_interface.dart';

class RustAudioEngine implements AudioEngine {
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
          playbackState: state.playbackState,
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
  bool get fftDataIsPreGrouped => false;

  @override
  Future<void> setEqualizerConfig(EqualizerConfig config) =>
      rust.setAudioEqualizerConfig(config: config);

  @override
  Future<EqualizerConfig> getEqualizerConfig() =>
      rust.getAudioEqualizerConfig();

  @override
  bool get supportsCrossfade => true;
}
