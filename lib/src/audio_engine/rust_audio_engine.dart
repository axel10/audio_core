import 'dart:async';
import '../rust/api/simple_api.dart' as rust;
import '../rust/api/simple/equalizer.dart';
import '../player_models.dart';
import 'audio_engine_interface.dart';

class RustAudioEngine implements AudioEngine {
  final _statusController = StreamController<AudioStatus>.broadcast();
  StreamSubscription? _subscription;

  @override
  Stream<AudioStatus> get statusStream => _statusController.stream;

  @override
  Future<void> initialize() async {
    _subscription = rust.subscribePlaybackState().listen((state) {
      _statusController.add(
        AudioStatus(
          path: state.path,
          position: Duration(milliseconds: state.positionMs.toInt()),
          duration: Duration(milliseconds: state.durationMs.toInt()),
          isPlaying: state.isPlaying,
          volume: state.volume,
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
  Future<void> load(String path) => rust.loadAudioFile(path: path);

  @override
  Future<void> crossfade(String path, Duration duration) => rust
      .crossfadeToAudioFile(path: path, durationMs: duration.inMilliseconds);

  @override
  Future<void> play() => rust.playAudio();

  @override
  Future<void> pause() => rust.pauseAudio();

  @override
  Future<void> seek(Duration position) =>
      rust.seekAudioMs(positionMs: position.inMilliseconds);

  @override
  Future<void> setVolume(double volume) => rust.setAudioVolume(volume: volume);

  @override
  Future<Duration> getDuration() async {
    final ms = await rust.getAudioDurationMs();
    return Duration(milliseconds: ms.toInt());
  }

  @override
  Future<Duration> getCurrentPosition() async {
    final ms = await rust.getAudioPositionMs();
    return Duration(milliseconds: ms.toInt());
  }

  @override
  Future<List<double>> getLatestFft() async {
    final data = await rust.getLatestFft();
    return data.map((e) => e.toDouble()).toList();
  }

  @override
  Future<List<double>> getWaveform({
    required String path,
    required int expectedChunks,
    int sampleStride = 1,
  }) async {
    final data = await rust.extractWaveformForPath(
      path: path,
      expectedChunks: BigInt.from(expectedChunks),
      sampleStride: BigInt.from(sampleStride),
    );
    return data.toList();
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
  Future<void> setFadeSettings(FadeSettings settings) async {
    // Map our shared model to the Rust-generated model
    await rust.setAudioFadeSettings(
      settings: rust.FadeSettings(
        fadeOnSwitch: settings.fadeOnSwitch,
        fadeOnPauseResume: settings.fadeOnPauseResume,
        durationMs: settings.duration.inMilliseconds.toInt(),
        mode: settings.mode == FadeMode.crossfade
            ? rust.FadeMode.crossfade
            : rust.FadeMode.sequential,
      ),
    );
  }

  @override
  Future<String?> extractFingerprint(String path) async {
    try {
      return await rust.getAudioFingerprint(path: path);
    } catch (e) {
      return null;
    }
  }
}
