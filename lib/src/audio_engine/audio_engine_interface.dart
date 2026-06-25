import 'dart:async';
import '../fft_processor.dart';
import '../rust/api/simple/equalizer.dart';

/// Define a snapshot for highly accurate position synchronization.
class PositionSnapshot {
  final Duration position;
  final int takenAtMs;

  PositionSnapshot({required this.position, required this.takenAtMs});
}

/// Define a unified status update for all platforms.
class AudioStatus {
  final String? path;
  final String? playbackState;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final double volume;
  final String? error;
  final int? updateTimeSinceEpochMs;

  AudioStatus({
    this.path,
    this.playbackState,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.volume,
    this.updateTimeSinceEpochMs,
    this.error,
  });
}

abstract class AudioEngine {
  Future<void> initialize();
  Future<void> stop();
  Future<void> dispose();

  Future<void> load(String path);
  Future<void> crossfade(String path, Duration duration, {Duration? position});
  Future<void> transition(
    String path,
    Duration duration, {
    Duration? position,
    required bool autoPlay,
    double? targetVolume,
  }) async {
    throw UnimplementedError('transition is not implemented on this platform.');
  }

  Future<void> play({Duration? fadeDuration});
  Future<void> pause({Duration? fadeDuration});
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);

  Future<Duration> getDuration();
  Future<PositionSnapshot> getCurrentPosition();

  // Visualization
  Future<List<double>> getLatestFft();
  Future<void> updateVisualizerFftOptions(
    VisualizerOptimizationOptions options,
  );
  bool get fftDataIsPreGrouped;

  // Effects
  Future<void> setEqualizerConfig(EqualizerConfig config);
  Future<EqualizerConfig> getEqualizerConfig();

  // Platform specific features (optional or capabilities-based)
  bool get supportsCrossfade;

  // Audio Fingerprinting
  // Status updates
  Stream<AudioStatus> get statusStream;

  Future<String> getDecodeEngine();
}
